// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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
/// @dev Adds NO new storage - this is a pure logic upgrade over V1. Upgrading a V1 proxy to
///      this implementation needs no initializer call (upgrade with empty calldata). V1 itself
///      is left untouched and stays the frozen, currently-live reference; do not add feature
///      logic there going forward - extend it here, or in a further V3/V4/... subclass of this
///      contract, mirroring this same pattern.
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

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
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
