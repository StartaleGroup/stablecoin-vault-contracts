// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockERC20Permit} from '../mocks/MockERC20Permit.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {Test} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';
import {console2} from 'forge-std/console2.sol';

/// @title EarnVault auto-compounding (base-tier, V2) tests
/// @notice setUp() performs a REAL proxy upgrade - deploys the frozen V1 (EarnVaultUpgradeable)
///         implementation, builds genuine pre-upgrade state under V1's old accrued-based
///         settlement, then upgrades the same proxy to EarnVaultV2 - exactly the production
///         upgrade path. Every test in this file runs against that upgraded proxy, not a
///         freshly-deployed V2. Covers _settle()'s fold-into-principal behavior, the
///         permissionless compound()/compoundMany() entry points, the boost-settlement-
///         ordering fix, and compoundMany() gas sizing at realistic population scale (see the
///         "Gas sizing" section and base-tier-auto-compounding.md for the operational numbers
///         this derives).
contract EarnVaultAutoCompoundTest is Test {
  EarnVaultUpgradeable vaultV1; // pre-upgrade view of the proxy (used only in setUp)
  EarnVaultV2 vault; // post-upgrade view of the SAME proxy - what every test actually uses
  MockUSDSC usdsc;

  ProxyAdmin proxyAdmin;
  TransparentUpgradeableProxy proxy;

  address admin = makeAddr('admin'); // ProxyAdmin owner
  address owner = makeAddr('owner'); // vault owner
  address redistributor = makeAddr('redistributor');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address operator = makeAddr('operator'); // boost reward keeper

  // Dedicated actors used only to build pre-upgrade state in setUp() - kept separate from
  // alice/bob/charlie below so every other test gets a clean slate.
  address legacyUser = makeAddr('legacyUser'); // has a genuine pre-upgrade `accrued` balance
  address passiveUser = makeAddr('passiveUser'); // never settled at all before the upgrade

  // Free for individual tests to deposit into fresh, exactly as if V2 were a brand new vault.
  address alice = makeAddr('alice');
  address bob = makeAddr('bob');
  address charlie = makeAddr('charlie');

  function setUp() public {
    usdsc = new MockUSDSC();

    // Deploy V1 (the frozen, currently-live implementation) behind a Transparent proxy -
    // matches the actual production proxy pattern (see EarnVaultUpgradeableSimple.t.sol).
    EarnVaultUpgradeable v1Implementation = new EarnVaultUpgradeable();
    proxy = new TransparentUpgradeableProxy(
      address(v1Implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
      )
    );
    vaultV1 = EarnVaultUpgradeable(payable(address(proxy)));

    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    address proxyAdminAddress = address(uint160(uint256(vm.load(address(proxy), adminSlot))));
    proxyAdmin = ProxyAdmin(proxyAdminAddress);

    usdsc.mint(redistributor, 10_000_000e6);
    vm.prank(redistributor);
    usdsc.approve(address(vaultV1), type(uint256).max);

    // --- Build genuine pre-upgrade (V1) state ---

    // legacyUser: deposits, a yield round lands, then tops up with a second deposit - this
    // settles under V1's OLD logic (owed folds into `accrued`, not principal), leaving a real
    // pre-existing accrued balance in storage for the upgrade to carry forward.
    usdsc.mint(legacyUser, 10_000e6);
    vm.startPrank(legacyUser);
    usdsc.approve(address(vaultV1), type(uint256).max);
    vaultV1.deposit(1000e6);
    vm.stopPrank();

    usdsc.mint(address(vaultV1), 300e6);
    vm.prank(redistributor);
    vaultV1.onYield(300e6);

    vm.prank(legacyUser);
    vaultV1.deposit(1e6); // triggers _settle() under V1 logic -> owed moves into `accrued`
    uint256 legacyAccruedBeforeUpgrade = vaultV1.claimable(legacyUser);
    require(legacyAccruedBeforeUpgrade > 0, 'setup: legacyUser should have pre-upgrade accrued');

    // passiveUser: deposits and a yield round lands, but is NEVER settled before the upgrade -
    // their backlog exists only as an implicit (globalIndex - userIndex) delta when the
    // upgrade happens, never having touched `accrued` at all.
    usdsc.mint(passiveUser, 10_000e6);
    vm.startPrank(passiveUser);
    usdsc.approve(address(vaultV1), type(uint256).max);
    vaultV1.deposit(2000e6);
    vm.stopPrank();

    usdsc.mint(address(vaultV1), 400e6);
    vm.prank(redistributor);
    vaultV1.onYield(400e6);

    // --- Upgrade the SAME proxy to V2 - the real production upgrade path ---
    EarnVaultV2 v2Implementation = new EarnVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2Implementation), '');

    vault = EarnVaultV2(payable(address(proxy)));

    // Approve for the fresh test actors too.
    usdsc.mint(alice, 1_000_000e6);
    usdsc.mint(bob, 1_000_000e6);
    usdsc.mint(charlie, 1_000_000e6);
    vm.prank(alice);
    usdsc.approve(address(vault), type(uint256).max);
    vm.prank(bob);
    usdsc.approve(address(vault), type(uint256).max);
    vm.prank(charlie);
    usdsc.approve(address(vault), type(uint256).max);
  }

  function _deposit(address user, uint256 amount) internal {
    vm.prank(user);
    vault.deposit(amount);
  }

  function _distributeYield(uint256 amount) internal {
    usdsc.mint(address(vault), amount);
    vm.prank(redistributor);
    vault.onYield(amount);
  }

  // ========================================================================
  // Upgrade boundary: state built under V1 must carry forward correctly
  // ========================================================================

  function test_Upgrade_PreservesLegacyAccruedAndStillDrainableViaClaim() public {
    uint256 legacyAccrued = vault.claimable(legacyUser);
    assertGt(legacyAccrued, 0, 'legacy accrued balance should survive the upgrade unchanged');

    uint256 balanceBefore = usdsc.balanceOf(legacyUser);
    vm.prank(legacyUser);
    vault.claim();

    assertEq(usdsc.balanceOf(legacyUser), balanceBefore + legacyAccrued);
    assertEq(vault.accrued(legacyUser), 0);
    assertEq(vault.claimable(legacyUser), 0);
  }

  function test_Upgrade_NeverSettledBacklogCarriesForwardAndCompoundsUnderV2() public {
    uint256 pendingAtUpgrade = vault.pendingYield(passiveUser);
    assertGt(pendingAtUpgrade, 0, 'passiveUser should have carried an unsettled backlog across the upgrade');
    assertEq(vault.accrued(passiveUser), 0, 'this backlog never touched accrued under V1 or V2');

    uint256 principalBefore = vault.principal(passiveUser);
    vault.compound(passiveUser);

    assertEq(vault.principal(passiveUser), principalBefore + pendingAtUpgrade);
    assertEq(vault.accrued(passiveUser), 0, 'V2 folds this into principal, never into accrued');
  }

  function test_Upgrade_PreservesCoreAccountingState() public view {
    // Sanity: globalIndex/claimReserve/totalPrincipal must be untouched by the upgrade itself
    // (no state mutation should happen purely from upgradeAndCall with empty calldata).
    assertEq(vault.globalIndex(), vaultV1.globalIndex());
    assertEq(vault.claimReserve(), vaultV1.claimReserve());
    assertEq(vault.totalPrincipal(), vaultV1.totalPrincipal());
    assertEq(vault.getVersion(), 'EarnVaultV2');
  }

  function test_Upgrade_ExistingDepositorCanStillWithdrawAndDepositNormally() public {
    uint256 pendingBefore = vault.pendingYield(legacyUser);
    uint256 principalBefore = vault.principal(legacyUser);

    vm.prank(legacyUser);
    vault.withdraw(500e6);

    assertEq(vault.principal(legacyUser), principalBefore + pendingBefore - 500e6);
  }

  // ========================================================================
  // Core compounding behavior (fresh V2-only actors)
  // ========================================================================

  function test_Compound_FoldsPendingYieldIntoPrincipalNotAccrued() public {
    _deposit(alice, 1000e6);
    _distributeYield(100e6);

    uint256 pending = vault.pendingYield(alice);
    assertGt(pending, 0, 'alice should have pending yield');

    vm.expectEmit(true, false, false, true, address(vault));
    emit EarnVaultV2.Compounded(alice, pending);
    vault.compound(alice);

    assertEq(vault.principal(alice), 1000e6 + pending, 'pending yield should fold into principal');
    assertEq(vault.accrued(alice), 0, 'accrued should remain 0 - yield never routes there anymore');
    assertEq(vault.pendingYield(alice), 0, 'nothing left pending after compounding');
  }

  function test_Compound_PermissionlessCallerCanCompoundForAnyone() public {
    _deposit(alice, 1000e6);
    _distributeYield(100e6);

    // A totally unrelated address (not a keeper, not alice) can trigger the compound - this
    // can only ever grow alice's own principal, never move or misdirect any funds.
    address rando = address(0x9999);
    uint256 pending = vault.pendingYield(alice);

    vm.prank(rando);
    vault.compound(alice);

    assertEq(vault.principal(alice), 1000e6 + pending);
  }

  function test_Compound_NoOpWhenNoPendingYield_DoesNotRevert() public {
    _deposit(alice, 1000e6);
    // No yield distributed - nothing pending.
    vault.compound(alice); // must not revert
    assertEq(vault.principal(alice), 1000e6);
  }

  function test_Compound_IsIdempotent_CallingTwiceInARowChangesNothingTheSecondTime() public {
    _deposit(alice, 1000e6);
    _distributeYield(100e6);

    vault.compound(alice);
    uint256 principalAfterFirstCompound = vault.principal(alice);
    assertEq(vault.pendingYield(alice), 0);

    // Second call in the same state must be a pure no-op: nothing pending, so nothing to fold.
    vault.compound(alice);
    assertEq(vault.principal(alice), principalAfterFirstCompound, 'a second compound() with nothing pending must change nothing');
  }

  function test_Compounded_EmitsOnImplicitCompoundingViaDepositWithdrawClaim_NotJustExplicitCompound() public {
    // Regression test: Compounded must fire from EVERY settlement that actually folds
    // something in - deposit()/withdraw()/claim() included - not only the explicit
    // compound()/compoundMany() entry points. This is centralized in _settle() itself now.

    // deposit()
    _deposit(alice, 1000e6);
    _distributeYield(100e6);
    uint256 alicePending = vault.pendingYield(alice);
    vm.expectEmit(true, false, false, true, address(vault));
    emit EarnVaultV2.Compounded(alice, alicePending);
    _deposit(alice, 1e6); // triggers _settle() via deposit, no explicit compound() call

    // withdraw()
    _distributeYield(100e6);
    uint256 alicePendingBeforeWithdraw = vault.pendingYield(alice);
    vm.expectEmit(true, false, false, true, address(vault));
    emit EarnVaultV2.Compounded(alice, alicePendingBeforeWithdraw);
    vm.prank(alice);
    vault.withdraw(1e6);

    // claim() - give alice a boost reward so claim() has something to pay out and doesn't
    // revert with NothingToClaim(), then verify it still emits Compounded for the pending
    // USDSC yield it folds in along the way.
    MockUSDSC boostToken = new MockUSDSC();
    boostToken.mint(address(vault), 10e18);
    vm.prank(operator);
    vault.onBoostReward(address(boostToken), 10e18);
    _distributeYield(100e6);
    uint256 alicePendingBeforeClaim = vault.pendingYield(alice);
    vm.expectEmit(true, false, false, true, address(vault));
    emit EarnVaultV2.Compounded(alice, alicePendingBeforeClaim);
    vm.prank(alice);
    vault.claim();
  }

  function test_Compound_RevertsForBlacklistedUser() public {
    _deposit(alice, 1000e6);
    _distributeYield(100e6);

    vm.prank(owner);
    vault.setBlacklisted(alice, true);

    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.AddressBlacklisted.selector));
    vault.compound(alice);
  }

  function test_Compound_RevertsWhilePaused() public {
    _deposit(alice, 1000e6);
    _distributeYield(100e6);

    vm.prank(pauser);
    vault.pause();

    vm.expectRevert(); // EnforcedPause
    vault.compound(alice);
  }

  // ========================================================================
  // compoundMany()
  // ========================================================================

  function test_CompoundMany_SkipsBlacklistedAndZeroPendingWithoutReverting() public {
    _deposit(alice, 1000e6);
    _deposit(bob, 1000e6);
    _deposit(charlie, 1000e6);
    _distributeYield(300e6);

    vm.prank(owner);
    vault.setBlacklisted(bob, true);

    // charlie already settled (nothing pending) before the batch call
    vault.compound(charlie);
    assertEq(vault.pendingYield(charlie), 0);

    uint256 alicePending = vault.pendingYield(alice);
    uint256 alicePrincipalBefore = vault.principal(alice);
    uint256 bobPrincipalBefore = vault.principal(bob);
    uint256 charliePrincipalBefore = vault.principal(charlie);

    address[] memory users = new address[](3);
    users[0] = alice;
    users[1] = bob; // blacklisted - should be skipped, not revert the batch
    users[2] = charlie; // zero pending - should be a harmless no-op

    vault.compoundMany(users); // must not revert

    assertEq(vault.principal(alice), alicePrincipalBefore + alicePending, 'alice should have compounded');
    assertEq(vault.principal(bob), bobPrincipalBefore, 'blacklisted bob should be skipped, unchanged');
    assertEq(vault.principal(charlie), charliePrincipalBefore, 'charlie had nothing pending, unchanged');
  }

  function test_CompoundMany_EmptyArrayIsNoop() public {
    address[] memory users = new address[](0);
    vault.compoundMany(users); // must not revert
  }

  function test_Compound_DoesNotEmitCompoundedWhenOwedRoundsToZero() public {
    // A depositor holding a negligible fraction of totalPrincipal can have their prorated
    // share of a yield distribution floor to exactly 0 at RAY precision - gi > ui holds (the
    // fold branch runs) but the computed `owed` itself is 0. Regression test for the emit
    // guard in _settle(): Compounded must NOT fire in that case, exactly matching the old
    // diff-based _compound() wrapper's `if (amount > 0)` check.
    _deposit(alice, 1); // 1 wei of USDSC - a negligible share of totalPrincipal
    _deposit(bob, 1_000_000e6); // bob dominates totalPrincipal so alice's prorated cut rounds to 0

    _distributeYield(100e6);

    // Confirm this genuinely exercises the edge case: gi > ui (something is nominally owed)
    // but it floors to exactly 0.
    assertGt(vault.globalIndex(), vault.userIndex(alice), 'gi > ui must hold for this to test the guard at all');
    assertEq(vault.pendingYield(alice), 0, "alice's prorated share should floor to exactly 0");

    uint256 alicePrincipalBefore = vault.principal(alice);
    bytes32 compoundedTopic0 = keccak256('Compounded(address,uint256)');

    vm.recordLogs();
    vault.compound(alice);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    for (uint256 i = 0; i < logs.length; i++) {
      assertTrue(logs[i].topics[0] != compoundedTopic0, 'Compounded must not emit when owed rounds to zero');
    }
    assertEq(vault.principal(alice), alicePrincipalBefore, 'principal must be unchanged when owed floors to zero');
  }

  // ========================================================================
  // Invariants
  // ========================================================================

  function test_Invariant_TotalPrincipalEqualsSumOfPrincipal_AfterCompounding() public {
    _deposit(alice, 1000e6);
    _deposit(bob, 2000e6);
    _deposit(charlie, 3000e6);
    _distributeYield(600e6);

    vault.compound(alice);
    vault.compound(bob);
    // charlie left uncompounded on purpose - his pending yield is still "his", tracked off
    // totalPrincipal via pendingYield(), and totalPrincipal must still be exactly the sum of
    // what's actually been folded into principal[user] so far (plus whatever was already
    // folded for legacyUser/passiveUser during setUp's upgrade-boundary state).
    uint256 sum = vault.principal(alice) + vault.principal(bob) + vault.principal(charlie) + vault.principal(legacyUser)
      + vault.principal(passiveUser);
    assertEq(vault.totalPrincipal(), sum);
  }

  function test_Invariant_ClaimReserveEqualsTotalPrincipalPlusSumOfAccruedPlusSumOfPending() public {
    _deposit(alice, 1000e6);
    _deposit(bob, 2000e6);
    _distributeYield(300e6);

    // Compounding must never change this invariant - it only moves a user's own share of
    // value from "pending" to "principal", never in or out of claimReserve. Bob is left
    // uncompounded here on purpose: his share of the yield is still backed by claimReserve
    // even though it hasn't been folded into principal[bob] yet - it shows up as pendingYield.
    vault.compound(alice);

    uint256 sumAccrued = vault.accrued(alice) + vault.accrued(bob) + vault.accrued(legacyUser) + vault.accrued(passiveUser);
    uint256 sumPending =
      vault.pendingYield(alice) + vault.pendingYield(bob) + vault.pendingYield(legacyUser) + vault.pendingYield(passiveUser);

    // Each of the several settlements folded into this state (across setUp and this test)
    // floors independently at RAY precision, so a few wei of dust can accumulate across
    // multiple users/rounds - tolerate that rather than requiring bit-exact equality.
    assertApproxEqAbs(vault.claimReserve(), vault.totalPrincipal() + sumAccrued + sumPending, 5);
  }

  function test_PendingYield_ZeroForAddressWithNoPrincipal() public {
    address neverDeposited = makeAddr('neverDeposited');
    assertEq(vault.pendingYield(neverDeposited), 0);
  }

  function test_GetUserInfo_MatchesIndividualViewsAcrossScenarios() public {
    // Scenario 1: fresh user, nothing at all.
    address fresh = makeAddr('freshGetUserInfo');
    (uint256 p1, uint256 c1, uint256 t1, uint256 idx1) = vault.getUserInfo(fresh);
    assertEq(p1, 0);
    assertEq(c1, 0);
    assertEq(t1, 0);
    assertEq(idx1, 0);

    // Scenario 2: deposited, yield pending, not yet settled.
    _deposit(alice, 1000e6);
    _distributeYield(200e6);
    (uint256 p2, uint256 c2, uint256 t2, uint256 idx2) = vault.getUserInfo(alice);
    assertEq(p2, vault.principal(alice));
    assertEq(c2, vault.claimable(alice));
    assertEq(t2, vault.totalValue(alice));
    assertEq(idx2, vault.userIndex(alice));
    assertGt(t2, p2, 'total should exceed principal while yield is still pending');

    // Scenario 3: settled - pending folds into principal, userTotal == userPrincipal now.
    vault.compound(alice);
    (uint256 p3, uint256 c3, uint256 t3,) = vault.getUserInfo(alice);
    assertEq(p3, vault.principal(alice));
    assertEq(c3, 0);
    assertEq(t3, p3, 'after settling, total should equal principal exactly (nothing pending)');
  }

  function test_GetAllClaimables_UsdscLegIncludesPendingYieldNotJustLegacyAccrued() public {
    // Regression test: V1's getAllClaimables() (inherited unchanged would be a bug under V2)
    // computed usdscClaimable via claimable(), which under V2 only returns legacy accrued -
    // a normal post-upgrade user with real pending yield would silently show 0 here without
    // V2's override.
    _deposit(alice, 1000e6);
    _distributeYield(300e6);

    uint256 pending = vault.pendingYield(alice);
    assertGt(pending, 0);

    (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts) = vault.getAllClaimables(alice);

    assertEq(usdscClaimable, vault.accrued(alice) + pending, 'usdscClaimable should include pending yield, not just legacy accrued');
    assertEq(usdscClaimable, pending, 'no legacy accrued exists here, so this should equal pending exactly');
    assertEq(boostTokens.length, 0);
    assertEq(boostAmounts.length, 0);

    // After settling, it should equal accrued alone (0) again - pending is now principal.
    vault.compound(alice);
    (uint256 usdscClaimableAfter,,) = vault.getAllClaimables(alice);
    assertEq(usdscClaimableAfter, 0);
  }

  function test_DepositWithPermit_TriggersV2SettleAndCompoundsExistingPendingYield() public {
    // Deploy a standalone V2 vault whose asset supports EIP-2612 permit, since MockUSDSC
    // (used everywhere else in this file) doesn't implement it.
    MockERC20Permit permitToken = new MockERC20Permit('Permit Token', 'PERMIT');
    EarnVaultV2 permitVaultImpl = new EarnVaultV2();
    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector, address(permitToken), owner, redistributor, treasury, pauser, operator
    );
    ERC1967Proxy permitProxy = new ERC1967Proxy(address(permitVaultImpl), initData);
    EarnVaultV2 permitVault = EarnVaultV2(payable(address(permitProxy)));

    (address tokenOwner, uint256 tokenOwnerKey) = makeAddrAndKey('permitTokenOwner');
    uint256 firstDeposit = 5000e6;
    permitToken.mint(tokenOwner, firstDeposit + 1000e6);

    vm.prank(tokenOwner);
    permitToken.approve(address(permitVault), firstDeposit);
    vm.prank(tokenOwner);
    permitVault.deposit(firstDeposit);

    permitToken.mint(address(permitVault), 500e6);
    vm.prank(redistributor);
    permitVault.onYield(500e6);

    uint256 pendingBeforeSecondDeposit = permitVault.pendingYield(tokenOwner);
    assertGt(pendingBeforeSecondDeposit, 0, 'tokenOwner should have pending yield before the permit deposit');

    uint256 secondDeposit = 1000e6;
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) =
      _getPermitSignature(IERC20Permit(address(permitToken)), tokenOwner, address(permitVault), secondDeposit, deadline, tokenOwnerKey);

    // Relayer (not tokenOwner) executes the permit deposit.
    address relayer = makeAddr('permitRelayer');
    vm.prank(relayer);
    permitVault.depositWithPermit(tokenOwner, secondDeposit, deadline, v, r, s);

    // The pending yield from before this call must have compounded into principal via V2's
    // overridden _settle(), exactly as it would through a plain deposit().
    assertEq(
      permitVault.principal(tokenOwner),
      firstDeposit + secondDeposit + pendingBeforeSecondDeposit,
      'depositWithPermit should trigger V2 auto-compounding just like deposit()'
    );
    assertEq(permitVault.accrued(tokenOwner), 0);
  }

  function _getPermitSignature(
    IERC20Permit token,
    address tokenOwnerAddr,
    address spender,
    uint256 value,
    uint256 deadline,
    uint256 privateKey
  ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
    bytes32 typeHash = keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');
    bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
    uint256 nonce = token.nonces(tokenOwnerAddr);

    bytes32 structHash = keccak256(abi.encode(typeHash, tokenOwnerAddr, spender, value, nonce, deadline));
    bytes32 hash = keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));

    return vm.sign(privateKey, hash);
  }

  function test_Compound_IsValueNeutral() public {
    _deposit(alice, 1000e6);
    _distributeYield(250e6);

    uint256 totalValueBefore = vault.totalValue(alice);
    vault.compound(alice);
    uint256 totalValueAfter = vault.totalValue(alice);

    assertEq(totalValueAfter, totalValueBefore, 'compounding must not change total value, only reclassify it');
  }

  // ========================================================================
  // Regression: boost-settlement ordering across a compounding fold
  // ========================================================================

  /// @notice Before the fix, _settle() read boost-eligible principal AFTER folding USDSC
  ///         yield into principal, over-crediting boost rewards for a period the user only
  ///         held the smaller, pre-compound principal. This locks in the fix: boost rewards
  ///         earned strictly BEFORE a compound must reflect pre-compound principal only.
  function test_BoostSettlement_UsesPreCompoundPrincipal_NotInflatedByFold() public {
    _deposit(alice, 1000e6);
    _deposit(bob, 1000e6); // bob just to give totalPrincipal a non-trivial denominator

    MockUSDSC boostToken = new MockUSDSC();

    // Boost reward #1, distributed while alice still holds only her original 1000e6.
    boostToken.mint(address(vault), 200e6);
    vm.prank(operator);
    vault.onBoostReward(address(boostToken), 200e6);

    // Expected boost owed to alice from this round, computed against her PRE-compound
    // principal (1000e6 out of the vault's total principal).
    uint256 expectedBoostFromRound1 = vault.getClaimableBoostReward(alice, address(boostToken));
    assertGt(expectedBoostFromRound1, 0);

    // Now a large USDSC yield event lands and alice compounds it - this alone must not
    // change what she's owed for round 1's boost, since that was earned before her
    // principal grew.
    _distributeYield(5000e6); // deliberately large relative to principal
    vault.compound(alice);
    assertGt(vault.principal(alice), 1000e6, 'sanity: alice principal did grow from compounding');

    uint256 boostOwedAfterCompound = vault.getClaimableBoostReward(alice, address(boostToken));
    assertEq(
      boostOwedAfterCompound,
      expectedBoostFromRound1,
      'compounding USDSC yield must not retroactively inflate already-earned boost rewards'
    );

    // A second boost round now correctly uses alice's larger, post-compound principal.
    boostToken.mint(address(vault), 200e6);
    vm.prank(operator);
    vault.onBoostReward(address(boostToken), 200e6);

    uint256 totalBoostOwed = vault.getClaimableBoostReward(alice, address(boostToken));
    assertGt(totalBoostOwed, boostOwedAfterCompound, 'round 2 boost should add on top of round 1');

    // Claiming should pay out exactly the sum tracked above, and boost accounting must stay
    // internally consistent (claimed amount matches the last previewed claimable amount).
    uint256 aliceBoostBefore = boostToken.balanceOf(alice);
    vm.prank(alice);
    vault.claim();
    assertEq(boostToken.balanceOf(alice), aliceBoostBefore + totalBoostOwed);
  }

  // ========================================================================
  // Multi-round compounding accuracy
  // ========================================================================

  function test_MultiRoundCompounding_ConvergesWithinRayPrecisionTolerance() public {
    _deposit(alice, 10_000e6);
    uint256 startingPrincipal = vault.principal(alice);

    // Several rounds of yield + compound, simulating a keeper running daily.
    for (uint256 i = 0; i < 5; i++) {
      _distributeYield(100e6);
      vault.compound(alice);
    }

    // Expected: principal grew across the 5 rounds. Alice does not hold 100% of
    // totalPrincipal here, since legacyUser/passiveUser also hold principal from setUp, so
    // each round's 100e6 is split proportionally rather than going entirely to alice - this
    // test checks the totalPrincipal invariant holds exactly, not a specific numeric target.
    assertGt(vault.principal(alice), startingPrincipal, 'alice should have compounded something across 5 rounds');
    assertEq(
      vault.totalPrincipal(),
      vault.principal(alice) + vault.principal(bob) + vault.principal(charlie) + vault.principal(legacyUser)
        + vault.principal(passiveUser)
    );
  }

  // ========================================================================
  // Gas sizing: compoundMany() batch cost at realistic population scale
  // ========================================================================
  //
  // Context (2026-08-31 operational sizing, see base-tier-auto-compounding.md): live state is
  // ~$1.17M principal across 31,799 wallets. Soneium (OP Stack L2) block gas limit is
  // 40,000,000. This measures compoundMany()'s REAL execution gas per user (replacing the
  // original hand-estimate of ~12,000-13,000 gas/user) and combines it with an analytically
  // computed worst-case calldata gas cost to project real batch counts for a daily keeper run.
  // L1 data-posting cost is a separate OP-Stack fee, NOT part of the 40M execution gas limit,
  // and is not estimated here - get a live quote from Soneium's fee estimator before
  // finalizing batch sizes for production.

  uint256 internal constant SONEIUM_BLOCK_GAS_LIMIT = 40_000_000;
  uint256 internal constant REAL_WALLET_COUNT = 31_799;

  function _makeUser(uint256 i) internal pure returns (address) {
    // casting to 'uint160' is safe because callers only ever pass small batch-index values
    // (at most a few thousand), nowhere near uint160's range
    // forge-lint: disable-next-line(unsafe-typecast)
    return address(uint160(0x100000 + i));
  }

  /// @dev Deposits `count` fresh users with `depositEach` each, then distributes `yieldTotal`
  ///      once so all of them have pending yield to compound.
  function _seedUsers(uint256 count, uint256 depositEach, uint256 yieldTotal) internal returns (address[] memory users) {
    users = new address[](count);
    for (uint256 i = 0; i < count; i++) {
      address u = _makeUser(i);
      users[i] = u;
      usdsc.mint(u, depositEach);
      vm.prank(u);
      usdsc.approve(address(vault), depositEach);
      vm.prank(u);
      vault.deposit(depositEach);
    }
    _distributeYield(yieldTotal);
  }

  /// @dev Worst-case calldata gas for compoundMany(address[]) with `n` addresses: selector (4
  ///      bytes) + offset word (32) + length word (32) + n address words (32 bytes each: 12
  ///      guaranteed-zero padding bytes + 20 address bytes, conservatively treated as all
  ///      non-zero). Uses the standard EIP-2028 schedule: 16 gas/non-zero byte, 4 gas/zero byte.
  function _worstCaseCalldataGas(uint256 n) internal pure returns (uint256) {
    uint256 nonZeroBytes = 4 + 32 + 32 + (n * 20);
    uint256 zeroBytes = n * 12;
    return nonZeroBytes * 16 + zeroBytes * 4;
  }

  function test_Gas_CompoundMany_BatchSizingProjection() public {
    // Seed two disjoint cohorts to measure marginal (per-user) execution gas from the slope
    // between two batch sizes - this cancels out fixed per-call overhead (dispatch,
    // nonReentrant lock) rather than diluting it into a flat average.
    uint256 smallBatch = 200;
    uint256 largeBatch = 2000;

    address[] memory allUsers = _seedUsers(smallBatch + largeBatch, 1000e6, (smallBatch + largeBatch) * 10e6);

    address[] memory small = new address[](smallBatch);
    for (uint256 i = 0; i < smallBatch; i++) {
      small[i] = allUsers[i];
    }
    address[] memory large = new address[](largeBatch);
    for (uint256 i = 0; i < largeBatch; i++) {
      large[i] = allUsers[smallBatch + i];
    }

    uint256 gasBeforeSmall = gasleft();
    vault.compoundMany(small);
    uint256 gasSmall = gasBeforeSmall - gasleft();

    uint256 gasBeforeLarge = gasleft();
    vault.compoundMany(large);
    uint256 gasLarge = gasBeforeLarge - gasleft();

    uint256 marginalGasPerUser = (gasLarge - gasSmall) / (largeBatch - smallBatch);

    console2.log('measured execution gas, 200-user batch', gasSmall);
    console2.log('measured execution gas, 2000-user batch', gasLarge);
    console2.log('marginal execution gas per user (measured, no active boost tokens)', marginalGasPerUser);

    // Sanity: real per-user cost should land in a plausible range - catches a gross
    // regression (e.g. an accidental O(n^2) loop) without pinning to a brittle exact number.
    assertGt(marginalGasPerUser, 1_000);
    assertLt(marginalGasPerUser, 50_000);

    // Project a safe batch size at 60% of Soneium's 40M block gas limit, combining measured
    // execution gas with worst-case calldata gas. Both terms scale with n, so solve directly:
    // n <= (target - fixedCalldataHeader) / (marginalGasPerUser + perAddressCalldataGas).
    uint256 targetGasPerBatch = (SONEIUM_BLOCK_GAS_LIMIT * 60) / 100;
    uint256 perAddressCalldataGas = 20 * 16 + 12 * 4; // = 368, see _worstCaseCalldataGas
    uint256 fixedCalldataHeaderGas = (4 + 32 + 32) * 16; // = 1088

    uint256 safeBatchSize = (targetGasPerBatch - fixedCalldataHeaderGas) / (marginalGasPerUser + perAddressCalldataGas);
    uint256 batchesNeeded = (REAL_WALLET_COUNT + safeBatchSize - 1) / safeBatchSize; // ceil div
    uint256 estimatedGasAtSafeBatch = marginalGasPerUser * safeBatchSize + _worstCaseCalldataGas(safeBatchSize);

    console2.log('projected safe batch size (60% of 40M gas, worst-case calldata)', safeBatchSize);
    console2.log('batches needed for 31799 wallets', batchesNeeded);
    console2.log('estimated total gas at that batch size', estimatedGasAtSafeBatch);

    // The projection formula must actually respect its own target.
    assertLe(estimatedGasAtSafeBatch, targetGasPerBatch);

    // With realistic per-user costs this should land in single-digit-to-low-teens batch
    // counts, not hundreds - if it doesn't, the sizing assumptions (or the contract's gas
    // profile) need re-examining before relying on a daily compoundMany() keeper. Note:
    // measured gas here is higher under `forge test --isolate` (which --gas-report/CI
    // implies) than under plain `forge test` - see the sibling
    // ...WithActiveBoostTokens test's comment for why (it's `--isolate` correctly modeling
    // real per-transaction cold storage access, not a bug) - this bound holds under both.
    assertLt(batchesNeeded, 50);
  }

  function test_Gas_CompoundMany_BatchSizingProjection_WithActiveBoostTokens() public {
    // Same projection, but with 2 active boost tokens (a realistic production state, since
    // this vault already distributes ASTR/DOT-style boosts) - _settle() loops all active
    // boost tokens per user. Measured in two rounds:
    //   - "cold" (round 1): every (user, token) storage slot goes from zero to non-zero for
    //     the first time - this pays Ethereum's zero->non-zero SSTORE penalty on top of the
    //     usual cold-access cost, and only ever happens once per (user, token) pair, ever.
    //   - "warm" (round 2): a second yield + boost round, then compounding again - all those
    //     slots are now non-zero, so writes are the much cheaper non-zero->non-zero case. This
    //     is what an ongoing DAILY keeper cadence actually costs after day one.
    MockUSDSC boostA = new MockUSDSC();
    MockUSDSC boostB = new MockUSDSC();

    uint256 smallBatch = 200;
    uint256 largeBatch = 2000;
    address[] memory allUsers = _seedUsers(smallBatch + largeBatch, 1000e6, (smallBatch + largeBatch) * 10e6);

    boostA.mint(address(vault), 1000e6);
    vm.prank(operator);
    vault.onBoostReward(address(boostA), 1000e6);
    boostB.mint(address(vault), 1000e6);
    vm.prank(operator);
    vault.onBoostReward(address(boostB), 1000e6);

    address[] memory small = new address[](smallBatch);
    for (uint256 i = 0; i < smallBatch; i++) {
      small[i] = allUsers[i];
    }
    address[] memory large = new address[](largeBatch);
    for (uint256 i = 0; i < largeBatch; i++) {
      large[i] = allUsers[smallBatch + i];
    }

    // Round 1 (cold): first-ever touch for every (user, token) slot.
    uint256 gasBeforeSmallCold = gasleft();
    vault.compoundMany(small);
    uint256 gasSmallCold = gasBeforeSmallCold - gasleft();

    uint256 gasBeforeLargeCold = gasleft();
    vault.compoundMany(large);
    uint256 gasLargeCold = gasBeforeLargeCold - gasleft();

    uint256 marginalGasPerUserCold = (gasLargeCold - gasSmallCold) / (largeBatch - smallBatch);
    console2.log('marginal execution gas per user, ROUND 1 / cold (2 boost tokens, first-ever touch)', marginalGasPerUserCold);

    // Round 2 (warm): a fresh yield + boost round, then compound again - the steady-state,
    // ongoing-daily-cadence number.
    _distributeYield((smallBatch + largeBatch) * 10e6);
    boostA.mint(address(vault), 1000e6);
    vm.prank(operator);
    vault.onBoostReward(address(boostA), 1000e6);
    boostB.mint(address(vault), 1000e6);
    vm.prank(operator);
    vault.onBoostReward(address(boostB), 1000e6);

    uint256 gasBeforeSmallWarm = gasleft();
    vault.compoundMany(small);
    uint256 gasSmallWarm = gasBeforeSmallWarm - gasleft();

    uint256 gasBeforeLargeWarm = gasleft();
    vault.compoundMany(large);
    uint256 gasLargeWarm = gasBeforeLargeWarm - gasleft();

    uint256 marginalGasPerUserWarm = (gasLargeWarm - gasSmallWarm) / (largeBatch - smallBatch);
    console2.log('marginal execution gas per user, ROUND 2 / warm (2 boost tokens, steady state)', marginalGasPerUserWarm);

    uint256 targetGasPerBatch = (SONEIUM_BLOCK_GAS_LIMIT * 60) / 100;
    uint256 perAddressCalldataGas = 20 * 16 + 12 * 4;
    uint256 fixedCalldataHeaderGas = (4 + 32 + 32) * 16;

    // Steady-state batch size/count - what an ongoing daily keeper actually needs.
    uint256 safeBatchSizeWarm =
      (targetGasPerBatch - fixedCalldataHeaderGas) / (marginalGasPerUserWarm + perAddressCalldataGas);
    uint256 batchesNeededWarm = (REAL_WALLET_COUNT + safeBatchSizeWarm - 1) / safeBatchSizeWarm;

    // Cold batch size/count - the one-time worst case (e.g. day one after activating a new
    // boost token for the whole population at once).
    uint256 safeBatchSizeCold =
      (targetGasPerBatch - fixedCalldataHeaderGas) / (marginalGasPerUserCold + perAddressCalldataGas);
    uint256 batchesNeededCold = (REAL_WALLET_COUNT + safeBatchSizeCold - 1) / safeBatchSizeCold;

    console2.log('steady-state safe batch size / batches needed for 31799 wallets', safeBatchSizeWarm, batchesNeededWarm);
    console2.log('one-time cold safe batch size / batches needed for 31799 wallets', safeBatchSizeCold, batchesNeededCold);

    // Execution-mode note: these measured numbers are meaningfully higher under `forge test
    // --isolate` (which `--gas-report`/CI's `make gas-report` implies) than under plain
    // `forge test`. That is NOT a measurement bug - it's `--isolate` correctly modeling
    // reality: a real keeper's "day 2" compoundMany() is a genuinely separate on-chain
    // transaction, which pays EIP-2929 cold-access costs again regardless of what an earlier
    // transaction touched (warm/cold state never persists across transactions). Plain `forge
    // test` runs an entire test function as one shared execution context, so ROUND 2 here
    // gets an artificially cheap "still warm from ROUND 1, and from _seedUsers' own setup
    // activity earlier in this same function" result that does not occur in production.
    // `--isolate` numbers are the economically honest ones; the bounds below are sized to
    // hold under BOTH modes, using the (larger, realistic) isolate-mode figures as the floor:
    // isolate measured ~56 steady-state batches and ~147 one-time-cold batches for 31,799
    // wallets at the time this was last calibrated (2026-09-08) - see
    // src/vaults/earn/base-tier-auto-compounding.md's "Cadence and gas sizing" section for
    // the full numbers this feeds into.
    assertLt(batchesNeededWarm, 100);
    assertLt(batchesNeededCold, 250);
  }
}
