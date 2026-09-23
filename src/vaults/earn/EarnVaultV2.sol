// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {BoostRewardsLib} from './BoostRewardsLib.sol';
import {EarnVaultUpgradeable} from './EarnVaultUpgradeable.sol';
import {ERC1967Utils} from 'lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from 'lib/openzeppelin-contracts/contracts/utils/math/Math.sol';

/// @title EarnVaultV2 (auto-compounding yield)
/// @notice Adds base-tier auto-compounding on top of EarnVaultUpgradeable (V1): a user's
///         pending USDSC yield now folds directly into their own principal on every
///         settlement, instead of sitting in a separately-claimable `accrued` balance. See
///         base-tier-auto-compounding.md for the full design rationale.
/// @dev Also adds a boostKeeper role (own ERC-7201 namespace, separate from V1's base storage) for
///      onBoostCredit(), which credits VIP boost as principal directly to user ADDRESSES - no on-chain
///      identity registry. A V1 proxy is upgraded to this implementation with
///      ProxyAdmin.upgradeAndCall carrying initializeV2(initialBoostKeeper) (reinitializer(2)).
/// @dev Boost is AA-wallet-only for v1: the backend created those wallets and holds the
///      user -> AA-address mapping, so the keeper passes addresses and the vault never needs to
///      resolve an identity. Restoring identity-based crediting later, if ever wanted:
///      (A) EOAs eligible, mapping kept off-chain - no contract change; the keeper just passes those
///          addresses too.
///      (B) mapping on-chain - a V3 subclass adds a registry reference in its OWN ERC-7201
///          namespace and an onBoostCreditByIdentity() that resolves identityId -> address and feeds
///          the same address-keyed path (_creditBoostEntry). Purely additive: onBoostCredit() can
///          stay live alongside it, so AA users (by address) and identity-linked EOAs (by identity)
///          can be credited in parallel with no hard cutover; the keeper chooses which to call.
///          src/identity/IdentityRegistry.sol is kept in the repo for this, unwired and unaudited.
/// @dev One address per user is currently guaranteed only by the backend (each user has exactly
///      one AA wallet); nothing on-chain enforces it. If EOAs become eligible, that becomes a real
///      uniqueness constraint the reward engine (scenario A) or the registry (scenario B) must
///      enforce, or a user can split a balance across addresses to capture top boost bands.
///      V1 stays the
///      frozen, currently-live reference - its only changes were `virtual` modifiers and NatSpec
///      so this contract can override it, with no behaviour change; do not add feature logic there
///      going forward - extend it here, or in a further V3/V4/... subclass of this contract.
/// @dev Known, accepted inefficiency: withdraw()/claim() (inherited unchanged from V1) call
///      _settle() - which already settles every active boost token here - and then call the
///      inherited _claimBoostRewards(), whose BoostRewardsLib.claimBoostReward() internally
///      re-runs settleBoost() per token before paying out. That re-run computes a zero delta
///      (the index is already caught up) but still costs a bounded number of extra SLOADs
///      (at most MAX_BOOST_TOKENS = 10). Not fixed here: claimBoostReward() combines
///      settle-then-pay in one library call used by both V1 and V2, so avoiding this would
///      mean either modifying the shared library (widening blast radius onto V1's own
///      behavior) or duplicating its payout logic here - not worth it for a bounded,
///      low-single-digit-thousand-gas cost.
contract EarnVaultV2 is EarnVaultUpgradeable {
  using SafeERC20 for IERC20;

  /// @notice Emitted when a user's pending USDSC yield is folded into their own principal
  /// @param user User whose yield was compounded
  /// @param amount Amount of USDSC yield folded into principal
  /// @dev Declared here rather than in the shared IEarnVaultEventsAndErrors interface -
  ///      deliberate, since that interface is meant to stay untouched as V1's frozen surface
  event Compounded(address indexed user, uint256 amount);

  /// @custom:storage-location erc7201:startale.storage.EarnVaultV2.BoostCredit
  /// @dev An earlier revision had an `identityRegistry` field between these two. It was deleted
  ///      outright - NOT replaced by a gap placeholder - because EarnVaultV2 had never been
  ///      deployed, so lastCreditedCycle now sits at base + 1. Once deployed, never remove or
  ///      reorder fields here; add new state in a new namespace (see scenario B above).
  struct BoostCreditStorage {
    address boostKeeper;
    mapping(address user => uint256) lastCreditedCycle;
  }

  // keccak256(abi.encode(uint256(keccak256("startale.storage.EarnVaultV2.BoostCredit")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant BOOST_CREDIT_STORAGE_LOCATION =
    0x554142adb35c10dc49454118de8343ddca3b3dda8789b6f7bf924bfb6955ee00;

  function _getBoostCreditStorage() internal pure returns (BoostCreditStorage storage $$) {
    assembly {
      $$.slot := BOOST_CREDIT_STORAGE_LOCATION
    }
  }

  event BoostKeeperChanged(address indexed actor, address indexed oldKeeper, address indexed newKeeper);
  event BoostCredited(address indexed user, uint256 amount, uint256 indexed cycleId);
  /// @notice Why onBoostCredit() skipped an entry instead of crediting it
  /// @dev VaultAddress: the entry is this vault's own address. Blacklisted: the address is
  ///      blacklisted (which can happen at any time, including after earlier credits).
  enum BoostSkipReason {
    VaultAddress,
    Blacklisted
  }

  /// @notice Emitted for an entry onBoostCredit() skipped instead of crediting. Its amount stays in
  ///         the vault as unreserved surplus (recoverable via sweepSurplusToTreasury()), and its
  ///         cycleId is NOT consumed, so it can be credited later in the same cycle.
  event BoostCreditSkipped(address indexed user, uint256 amount, uint256 indexed cycleId, BoostSkipReason reason);
  /// @notice Emitted once per onBoostCredit() call, after every entry has been processed - lets the
  ///         off-chain reward engine confirm "did all of cycle N's batches land?" with a single
  ///         indexed query instead of aggregating every BoostCredited event
  /// @param entryCount Entries submitted in the batch
  /// @param total Sum of all submitted amounts (the amount the funding check required)
  /// @param skippedCount Entries skipped (see BoostCreditSkipped); entryCount - skippedCount were credited
  /// @param skippedTotal Sum of skipped amounts - left in the vault as unreserved surplus
  event BoostCycleCredited(
    uint256 indexed cycleId, uint256 entryCount, uint256 total, uint256 skippedCount, uint256 skippedTotal
  );

  error NotBoostKeeper();
  error NotProxyAdmin();
  error LengthMismatch();
  error StaleCycle();

  modifier onlyBoostKeeper() {
    _onlyBoostKeeper();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initialize the boostKeeper role added on top of V1 (reinitializer for upgrades)
  /// @dev SECURITY: callable only by the proxy's ERC-1967 admin, i.e. the ProxyAdmin contract.
  ///      An OZ v5 TransparentUpgradeableProxy lets its admin reach the implementation only via
  ///      upgradeToAndCall (any other admin call reverts ProxyDeniedAdminAccess), and OZ v5's
  ///      ProxyAdmin only issues that from upgradeAndCall. So this runs only as the calldata of
  ///      `ProxyAdmin.upgradeAndCall(proxy, v2Impl, abi.encodeCall(EarnVaultV2.initializeV2, (...)))`,
  ///      atomically with the upgrade, and cannot be front-run.
  /// @dev What the gate prevents: without it, after an upgrade with empty calldata anyone could call
  ///      this first and install themselves as boostKeeper. The funding check in onBoostCredit()
  ///      bounds what they could credit to USDSC held above claimReserve (e.g. donations, or funding
  ///      transferred ahead of a separate credit call), and the owner could replace them via
  ///      setBoostKeeper() - but it is still an attacker-controlled role and must not be possible.
  /// @dev If an upgrade lands without this call, boost credit is simply disabled (boostKeeper is
  ///      address(0), so onlyBoostKeeper rejects every caller; the rest of the vault works). To
  ///      recover, either repeat upgradeAndCall to the same implementation with this call, or have
  ///      the owner call setBoostKeeper().
  /// @dev Deliberately NOT `msg.sender == owner()`: under upgradeAndCall, msg.sender here is the
  ///      ProxyAdmin contract, not this vault's owner, so that gate would revert every upgrade.
  ///      (The ProxyAdmin can't usefully be the owner either: the proxy blocks it from calling any
  ///      vault function, including acceptOwnership().)
  /// @dev Fresh deploy (no V1 history): do NOT pass this as the proxy's constructor calldata - OZ
  ///      v5's TransparentUpgradeableProxy runs that calldata before it creates the ProxyAdmin, so
  ///      the admin slot is still zero and this reverts NotProxyAdmin. Construct the proxy with the
  ///      base initialize(), then ProxyAdmin.upgradeAndCall to the same implementation with this.
  /// @dev Assumes upgrades go through a TransparentUpgradeableProxy's ProxyAdmin. Where the caller
  ///      is not the ERC-1967 admin - a proxy with no admin (the admin slot is zero), or a UUPS-style
  ///      upgrade path where the owner calls upgradeToAndCall - this rejects the call and any
  ///      upgradeToAndCall carrying it reverts as a whole. Such a move needs this gate replaced
  ///      (owner() would then be the right check); test_InitializeV2_ProxyWithoutAdmin_RejectsEvenOwner
  ///      pins the current behaviour, so changing the gate also requires updating that test.
  /// @param initialBoostKeeper Address authorized to call onBoostCredit()
  function initializeV2(address initialBoostKeeper) public reinitializer(2) {
    if (msg.sender != ERC1967Utils.getAdmin()) revert NotProxyAdmin();
    if (initialBoostKeeper == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    _getBoostCreditStorage().boostKeeper = initialBoostKeeper;
  }

  /// @notice Current address authorized to call onBoostCredit()
  function boostKeeper() external view returns (address) {
    return _getBoostCreditStorage().boostKeeper;
  }

  /// @notice Update the boost keeper address
  /// @param newKeeper New boost keeper address
  function setBoostKeeper(address newKeeper) external onlyOwner {
    if (newKeeper == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    BoostCreditStorage storage $$ = _getBoostCreditStorage();
    address old = $$.boostKeeper;
    $$.boostKeeper = newKeeper;
    emit BoostKeeperChanged(msg.sender, old, newKeeper);
  }

  function _onlyBoostKeeper() internal view {
    if (msg.sender != _getBoostCreditStorage().boostKeeper) revert NotBoostKeeper();
  }

  /// @notice Last cycleId successfully credited to `user` - the replay guard
  function lastCreditedCycle(address user) external view returns (uint256) {
    return _getBoostCreditStorage().lastCreditedCycle[user];
  }

  /// @notice Credit VIP boost directly as principal to each address in the batch
  /// @dev MUST be called AFTER transferring the batch's total USDSC to this contract - mirrors
  ///      onYield()'s discipline: verify balance covers claimReserve + total BEFORE crediting
  ///      anything, so a failed batch credits nothing. cycleId must be strictly greater than the
  ///      address's lastCreditedCycle for EVERY entry, or the whole batch reverts - the explicit
  ///      replay guard (a duplicate address in one batch reverts StaleCycle on its second
  ///      occurrence once the first is credited). A zero address also reverts the whole batch.
  ///      Gated whenNotPaused, like the other principal-changing entry points (deposit()/
  ///      withdraw()/claim()/compound()/compoundMany()).
  /// @dev All-or-nothing for funding, replay and malformed input (insufficient balance, stale
  ///      cycleId, zero address, length mismatch revert the whole batch), but per-entry for
  ///      eligibility: an entry that is this vault's own address or a blacklisted address is
  ///      SKIPPED - BoostCreditSkipped is emitted, nothing is credited, and its cycleId is not
  ///      consumed, so it can be credited later once eligible. Mirrors compoundMany()'s
  ///      skip-blacklisted behaviour, so one address blacklisted after earlier credits cannot fail
  ///      every other address's credit. The funding check still covers skipped amounts; they stay as
  ///      unreserved surplus, recoverable via sweepSurplusToTreasury().
  /// @dev A zero-amount entry is NOT a no-op: it still passes every check, consumes the address's
  ///      cycleId (a later non-zero credit for the same cycle then reverts StaleCycle) and emits
  ///      BoostCredited. The off-chain engine must drop zero amounts before batching.
  /// @param cycleId Monotonic per-address cycle identifier for this credit. Must be >= 1 - since
  ///        lastCreditedCycle[user] defaults to 0 for a never-credited address and the guard is
  ///        `cycleId <= lastCreditedCycle`, a cycleId of 0 would always revert StaleCycle.
  /// @param users Addresses to credit (AA wallets for v1 - the backend resolves user -> address)
  /// @param amounts USDSC amounts to credit, index-aligned with users
  function onBoostCredit(
    uint256 cycleId,
    address[] calldata users,
    uint256[] calldata amounts
  ) external whenNotPaused onlyBoostKeeper nonReentrant {
    if (users.length != amounts.length) revert LengthMismatch();

    uint256 total = 0;
    for (uint256 i = 0; i < amounts.length; i++) {
      total += amounts[i];
    }

    EarnVaultStorage storage $ = _getStorage();
    uint256 bal = $.USDSC.balanceOf(address(this));
    if (bal < $.claimReserve + total) revert IEarnVaultEventsAndErrors.InsufficientFunding();

    uint256 skippedCount = 0;
    uint256 skippedTotal = 0;
    for (uint256 i = 0; i < users.length; i++) {
      if (!_creditBoostEntry(cycleId, users[i], amounts[i])) {
        skippedCount++;
        skippedTotal += amounts[i];
      }
    }

    emit BoostCycleCredited(cycleId, users.length, total, skippedCount, skippedTotal);
  }

  /// @dev Processes one onBoostCredit() entry. Reverts (failing the whole batch) on a zero address
  ///      or a stale cycleId; returns false - having emitted BoostCreditSkipped and changed nothing
  ///      else - when `user` is this vault or blacklisted; otherwise credits it and returns true.
  ///      Address-keyed on purpose: a future identity-based entry point (see contract NatSpec,
  ///      scenario B) resolves identityId -> address and calls this unchanged.
  function _creditBoostEntry(uint256 cycleId, address user, uint256 amount) internal returns (bool credited) {
    if (user == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    BoostCreditStorage storage $$ = _getBoostCreditStorage();
    if (cycleId <= $$.lastCreditedCycle[user]) revert StaleCycle();

    // Per-entry eligibility skips; it does not fail the batch. The vault's own address is the ONLY
    // guard against crediting principal to itself. An address can become blacklisted at any time,
    // including after earlier credits. Either way the entry is skipped, not credited.
    EarnVaultStorage storage $ = _getStorage();
    if (user == address(this) || $.isBlacklisted[user]) {
      BoostSkipReason reason = user == address(this) ? BoostSkipReason.VaultAddress : BoostSkipReason.Blacklisted;
      emit BoostCreditSkipped(user, amount, cycleId, reason);
      return false;
    }

    // Replay guard written only on an actual credit - a skip is not a payment.
    $$.lastCreditedCycle[user] = cycleId;

    _settle(user);

    $.principal[user] += amount;
    $.totalPrincipal += amount;
    $.claimReserve += amount;

    emit BoostCredited(user, amount, cycleId);
    return true;
  }

  /// @notice Settle `user`'s pending USDSC yield, folding it into their own principal
  /// @dev Deliberately permissionless: this can only ever increase `user`'s own recorded
  ///      principal, and never transfers or moves any token anywhere - there is nothing for
  ///      an unrelated caller to gain or misdirect by calling this for someone else. Intended
  ///      to be called by a keeper on a schedule for passive depositors who never call
  ///      deposit/withdraw/claim themselves; a no-op (zero pending yield) is not an error.
  /// @dev Cadence note: this need not (and should not) run as often as onYield(). Between two
  ///      onYield() calls globalIndex doesn't move, so compounding more often than that is a
  ///      wasted transaction - and compounding frequency has strongly diminishing returns
  ///      versus onYield()'s own cadence (the gap between hourly and daily compounding is a
  ///      handful of basis points a year at typical APRs). A daily keeper cadence captures
  ///      essentially all of the benefit at a fraction of the transaction volume. See
  ///      base-tier-auto-compounding.md's "Cadence and gas sizing" section for the full
  ///      analysis and measured compoundMany() gas figures at realistic population scale.
  /// @param user Address whose pending yield should be compounded into principal
  function compound(address user) external whenNotPaused nonReentrant {
    _checkNotBlacklisted(user);
    _settle(user);
  }

  /// @notice Batched version of compound() - settles pending USDSC yield for many users in one tx
  /// @dev Blacklisted addresses are skipped rather than reverting the whole batch, since a
  ///      keeper-supplied list may include a since-blacklisted address
  /// @param users Addresses whose pending yield should be compounded into principal
  function compoundMany(address[] calldata users) external whenNotPaused nonReentrant {
    EarnVaultStorage storage $ = _getStorage();
    for (uint256 i = 0; i < users.length; i++) {
      address user = users[i];
      if ($.isBlacklisted[user]) continue;
      _settle(user);
    }
  }

  /// @notice USDSC yield accrued since this user's last settlement, not yet folded into
  ///         principal - i.e. what compound()/deposit()/withdraw()/claim() would fold in if
  ///         called right now
  function pendingYield(address user) external view returns (uint256) {
    return _pendingYield(user);
  }

  /// @dev Internal body of pendingYield(), so views here don't pay for an external self-call
  function _pendingYield(address user) internal view returns (uint256) {
    EarnVaultStorage storage $ = _getStorage();
    uint256 p = $.principal[user];
    if (p == 0) return 0;
    uint256 ui = $.userIndex[user];
    uint256 gi = $.globalIndex;
    if (gi <= ui) return 0;
    return Math.mulDiv(p, gi - ui, $.RAY);
  }

  /// @dev Returns exactly what claim() would pay out in USDSC right now: only legacy `accrued`
  ///      balances that predate auto-compounding. Does NOT include pending yield - that folds
  ///      into principal on next settlement, not into a claim() payout. Use pendingYield() or
  ///      totalValue() to see unsettled yield.
  function claimable(address user) external view virtual override returns (uint256) {
    EarnVaultStorage storage $ = _getStorage();
    return $.accrued[user];
  }

  /// @notice Get user's total value (principal + legacy claimable + unsettled pending yield)
  /// @dev Accurate even for a passive user who hasn't been settled recently, since pending
  ///      yield hasn't been folded into principal yet but still belongs to them
  function totalValue(address user) external view virtual override returns (uint256) {
    EarnVaultStorage storage $ = _getStorage();
    return $.principal[user] + $.accrued[user] + _pendingYield(user);
  }

  /// @notice Get user's complete account info in one call
  /// @dev userClaimable is what claim() would pay in USDSC right now (legacy accrued only);
  ///      userTotal includes principal + userClaimable + any unsettled pending yield, so it
  ///      stays accurate even if this user hasn't been settled/compounded recently
  function getUserInfo(address user)
    external
    view
    virtual
    override
    returns (uint256 userPrincipal, uint256 userClaimable, uint256 userTotal, uint256 userLastIndex)
  {
    EarnVaultStorage storage $ = _getStorage();
    userPrincipal = $.principal[user];
    userLastIndex = $.userIndex[user];
    userClaimable = $.accrued[user];

    userTotal = userPrincipal + userClaimable + _pendingYield(user);
  }

  /// @notice Get version info
  function getVersion() external pure virtual override returns (string memory) {
    return 'EarnVaultV2';
  }

  /// @notice Get all claimable rewards for a user (USDSC yield + all boost rewards)
  /// @dev Overridden purely to swap in pendingYield() for the USDSC leg - V1's version calls
  ///      this.claimable(user), which under V2 returns only legacy accrued and would silently
  ///      under-report a normal post-upgrade user's real (pending) USDSC yield here otherwise
  /// @param user User address to check
  /// @return usdscClaimable Legacy accrued USDSC plus unsettled pending yield
  /// @return boostTokens Array of boost token addresses
  /// @return boostAmounts Array of claimable amounts for each boost token
  function getAllClaimables(address user)
    external
    view
    virtual
    override
    returns (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts)
  {
    EarnVaultStorage storage $ = _getStorage();
    _checkNotBlacklisted(user);

    usdscClaimable = $.accrued[user] + _pendingYield(user);

    boostTokens = new address[]($.activeBoostTokens.length);
    boostAmounts = new uint256[]($.activeBoostTokens.length);

    for (uint256 i = 0; i < $.activeBoostTokens.length; i++) {
      address token = $.activeBoostTokens[i];
      boostTokens[i] = token;
      boostAmounts[i] = BoostRewardsLib.getClaimableBoostReward(
        user, token, $.principal[user], $.userBoostIndex[user][token], $.boostGlobalIndex[token], $.userBoostAccrued
      );
    }
  }

  /// @dev Internal helper to handle deposit logic (shared by deposit() and depositWithPermit())
  /// @dev Overridden purely to drop V1's own boost-settle loop, which is redundant (though
  ///      harmless - BoostRewardsLib.settleBoost is idempotent on an unchanged index) once
  ///      _settle() itself always settles boost first, using pre-compound principal, before
  ///      this function even runs. Keeping it would rely on that idempotency as an unstated
  ///      convention rather than have correctness be structural.
  /// @param user Address of the user depositing
  /// @param amount Amount of USDSC tokens to deposit
  function _deposit(address user, uint256 amount) internal virtual override {
    EarnVaultStorage storage $ = _getStorage();
    _settle(user); // already settles boost (pre-compound principal) as part of settling USDSC yield

    $.USDSC.safeTransferFrom(user, address(this), amount);
    $.principal[user] += amount;
    $.totalPrincipal += amount;
    $.claimReserve += amount; // reserve principal 1:1

    emit Deposit(user, amount);
  }

  /// @dev Settles user's USDSC yield by folding it directly into principal (auto-compounding),
  ///      and settles boost rewards for all active tokens using the principal held up to this
  ///      point in time - i.e. BEFORE any USDSC yield gets folded in below. Must run boost
  ///      settlement first: boost rewards are weighted by principal, and if this folded USDSC
  ///      yield into principal first, a subsequent boost settlement would over-credit rewards
  ///      for a period the user only held the smaller, pre-compound principal.
  /// @dev Emits Compounded whenever anything is actually folded in - from EVERY call site
  ///      (deposit/withdraw/claim/compound/compoundMany all route through this one function),
  ///      not just the explicit compound()/compoundMany() entry points. Centralizing the
  ///      emission here, rather than in a wrapper only the keeper-facing functions call,
  ///      means an off-chain indexer sees every instance of compounding, including the ones
  ///      that happen implicitly as a side effect of a user's own deposit/withdraw/claim.
  /// @param user Address to settle
  function _settle(address user) internal virtual override {
    EarnVaultStorage storage $ = _getStorage();
    uint256 p = $.principal[user];

    for (uint256 i = 0; i < $.activeBoostTokens.length; i++) {
      address token = $.activeBoostTokens[i];
      BoostRewardsLib.settleBoost(user, token, p, $.boostGlobalIndex[token], $.userBoostIndex, $.userBoostAccrued);
    }

    if (p == 0) {
      $.userIndex[user] = $.globalIndex;
      return;
    }

    uint256 ui = $.userIndex[user];
    uint256 gi = $.globalIndex;
    if (gi > ui) {
      // Auto-compound: fold owed USDSC yield into principal, not accrued. No token
      // movement - claimReserve already backs this amount either way (it was added
      // there at onYield() time).
      uint256 owed = Math.mulDiv(p, gi - ui, $.RAY);
      $.principal[user] += owed;
      $.totalPrincipal += owed;
      if (owed > 0) emit Compounded(user, owed);
    }
    $.userIndex[user] = gi;
  }
}
