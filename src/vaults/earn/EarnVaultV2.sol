// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IIdentityRegistry} from '../../interfaces/identity/IIdentityRegistry.sol';
import {IEarnVaultEventsAndErrors} from '../../interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {BoostRewardsLib} from './BoostRewardsLib.sol';
import {EarnVaultUpgradeable} from './EarnVaultUpgradeable.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from 'lib/openzeppelin-contracts/contracts/utils/math/Math.sol';

/// @title EarnVaultV2 (auto-compounding yield)
/// @notice Adds base-tier auto-compounding on top of EarnVaultUpgradeable (V1): a user's
///         pending USDSC yield now folds directly into their own principal on every
///         settlement, instead of sitting in a separately-claimable `accrued` balance. See
///         base-tier-auto-compounding.md for the full design rationale.
/// @dev Also adds a boostKeeper role and a settable IIdentityRegistry reference (own ERC-7201
///      namespace, separate from V1's base storage) for onBoostCredit() - upgrading a V1 proxy
///      to this implementation now requires calling initializeV2(initialBoostKeeper,
///      initialIdentityRegistry) via reinitializer(2). V1 itself is left untouched and stays the
///      frozen, currently-live reference; do not add feature logic there going forward - extend
///      it here, or in a further V3/V4/... subclass of this contract, mirroring this same pattern.
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
  struct BoostCreditStorage {
    address boostKeeper;
    IIdentityRegistry identityRegistry;
    mapping(bytes32 identityId => uint256) lastCreditedCycle;
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
  event IdentityRegistryChanged(address indexed actor, address indexed oldRegistry, address indexed newRegistry);
  event BoostCredited(bytes32 indexed identityId, address indexed addr, uint256 amount, uint256 indexed cycleId);
  /// @notice Emitted once per onBoostCredit() call, after every entry in the batch has been
  ///         credited - lets the off-chain reward engine confirm "did all of cycle N's batches
  ///         land?" with a single indexed query instead of aggregating every BoostCredited event
  event BoostCycleCredited(uint256 indexed cycleId, uint256 entryCount, uint256 total);

  error NotBoostKeeper();
  error LengthMismatch();
  error StaleCycle();
  error IdentityNotRegistered();

  modifier onlyBoostKeeper() {
    _onlyBoostKeeper();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initialize the boostKeeper/identityRegistry roles added on top of V1 (reinitializer for upgrades)
  /// @dev SECURITY: this function is `public` with no caller gating - reinitializer(2) only
  ///      ensures it can run once, not who runs it. It MUST be called in the same transaction as
  ///      the proxy upgrade itself, i.e. bundled as the calldata argument to `upgradeAndCall`
  ///      (mirroring how every test in this repo upgrades: `upgradeAndCall(proxy, newImpl,
  ///      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector, ...))`). NEVER upgrade with
  ///      empty calldata and call this separately afterwards - the implementation is live and
  ///      callable the instant the upgrade transaction lands, so any gap between upgrade and
  ///      initialization is an open window for anyone to front-run this call and set themselves
  ///      as boostKeeper with an identityRegistry they control, letting them mint themselves
  ///      unlimited principal via onBoostCredit() the moment onlyBoostKeeper would otherwise
  ///      start applying.
  /// @param initialBoostKeeper Address authorized to call onBoostCredit()
  /// @param initialIdentityRegistry IIdentityRegistry used to resolve identityId -> address
  function initializeV2(address initialBoostKeeper, address initialIdentityRegistry) public reinitializer(2) {
    if (initialBoostKeeper == address(0) || initialIdentityRegistry == address(0)) {
      revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    }
    BoostCreditStorage storage $$ = _getBoostCreditStorage();
    $$.boostKeeper = initialBoostKeeper;
    $$.identityRegistry = IIdentityRegistry(initialIdentityRegistry);
  }

  /// @notice Current address authorized to call onBoostCredit()
  function boostKeeper() external view returns (address) {
    return _getBoostCreditStorage().boostKeeper;
  }

  /// @notice Current IIdentityRegistry used to resolve identityId -> address
  function identityRegistry() external view returns (address) {
    return address(_getBoostCreditStorage().identityRegistry);
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

  /// @notice Update the IIdentityRegistry reference
  /// @dev Settable, not immutable - risk-bearing: a bad value silently misroutes an entire
  ///      cycle's boost credit. Owner-gated, event on change.
  /// @param newRegistry New IIdentityRegistry address
  function setIdentityRegistry(address newRegistry) external onlyOwner {
    if (newRegistry == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    BoostCreditStorage storage $$ = _getBoostCreditStorage();
    address old = address($$.identityRegistry);
    $$.identityRegistry = IIdentityRegistry(newRegistry);
    emit IdentityRegistryChanged(msg.sender, old, newRegistry);
  }

  function _onlyBoostKeeper() internal view {
    if (msg.sender != _getBoostCreditStorage().boostKeeper) revert NotBoostKeeper();
  }

  /// @notice Last cycleId successfully credited for a given identity - the replay guard
  function lastCreditedCycle(bytes32 identityId) external view returns (uint256) {
    return _getBoostCreditStorage().lastCreditedCycle[identityId];
  }

  /// @notice Credit VIP boost directly as principal for each identity in the batch
  /// @dev MUST be called AFTER transferring the batch's total USDSC to this contract - mirrors
  ///      onYield()'s discipline: verify balance covers claimReserve + total BEFORE crediting
  ///      anything, so a failed batch credits nothing. cycleId must be strictly greater than the
  ///      identity's lastCreditedCycle for EVERY entry, or the whole batch reverts - this is the
  ///      replay guard a Merkle-based distributor would have gotten for free via a claimed
  ///      mapping; dropping Merkle means it must be explicit. An unregistered identityId or an
  ///      unset registry reverts the whole batch (fail-closed) rather than silently skipping.
  ///      Gated whenNotPaused like every other principal-mutating function (deposit()/compound()/
  ///      compoundMany()/onBoostReward()).
  /// @dev Blacklisted addresses revert the whole batch (fail-closed), unlike compoundMany()'s
  ///      skip-and-continue - consistent with this function's existing all-or-nothing discipline
  ///      for insufficient-balance/unregistered-identity/stale-cycle. Checked AFTER resolving
  ///      the identityId to an address via the registry, since blacklisting is keyed by address.
  /// @param cycleId Monotonic per-identity cycle identifier for this credit. Must be >= 1 - since
  ///        lastCreditedCycle[identityId] defaults to 0 for a never-credited identity and the
  ///        guard below is `cycleId <= lastCreditedCycle`, a cycleId of 0 would always revert
  ///        StaleCycle for every identity, even on their first-ever credit.
  /// @param identityIds Opaque identifiers for the loyalty identities being credited
  /// @param amounts USDSC amounts to credit, index-aligned with identityIds
  function onBoostCredit(
    uint256 cycleId,
    bytes32[] calldata identityIds,
    uint256[] calldata amounts
  ) external whenNotPaused onlyBoostKeeper nonReentrant {
    if (identityIds.length != amounts.length) revert LengthMismatch();

    BoostCreditStorage storage $$ = _getBoostCreditStorage();
    IIdentityRegistry registry = $$.identityRegistry;
    if (address(registry) == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();

    uint256 total = 0;
    for (uint256 i = 0; i < amounts.length; i++) {
      total += amounts[i];
    }

    EarnVaultStorage storage $ = _getStorage();
    uint256 bal = $.USDSC.balanceOf(address(this));
    if (bal < $.claimReserve + total) revert IEarnVaultEventsAndErrors.InsufficientFunding();

    for (uint256 i = 0; i < identityIds.length; i++) {
      bytes32 identityId = identityIds[i];
      uint256 amount = amounts[i];

      if (cycleId <= $$.lastCreditedCycle[identityId]) revert StaleCycle();
      $$.lastCreditedCycle[identityId] = cycleId;

      address user = registry.registeredAddress(identityId);
      if (user == address(0)) revert IdentityNotRegistered();
      // Belt-and-braces alongside IdentityRegistry's own reserved-address check on its
      // `earnVault` field (see setEarnVault()/_isReserved() there): if that registration-side
      // guard is ever bypassed or misconfigured (e.g. setEarnVault() pointed at a stale vault
      // address after an upgrade), this makes it structurally impossible for the vault to ever
      // credit principal to itself, rather than relying solely on the other contract's wiring.
      if (user == address(this)) revert IdentityNotRegistered();
      _checkNotBlacklisted(user);

      _settle(user);

      $.principal[user] += amount;
      $.totalPrincipal += amount;
      $.claimReserve += amount;

      emit BoostCredited(identityId, user, amount, cycleId);
    }

    emit BoostCycleCredited(cycleId, identityIds.length, total);
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
    return $.principal[user] + $.accrued[user] + this.pendingYield(user);
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

    uint256 pending = 0;
    uint256 gi = $.globalIndex;
    if (userPrincipal > 0 && gi > userLastIndex) {
      pending = Math.mulDiv(userPrincipal, gi - userLastIndex, $.RAY);
    }

    userTotal = userPrincipal + userClaimable + pending;
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

    usdscClaimable = $.accrued[user] + this.pendingYield(user);

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
