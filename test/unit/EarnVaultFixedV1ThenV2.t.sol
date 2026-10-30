// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

/// @dev Stand-in redistributor: the snapshot getters V2's deposit pause reads, and onYield delivery
contract RedistributorStub {
  uint256 public lastSnapshotTimestamp;
  uint256 public snapshotMaxAge = 120;

  function snapshot() external {
    lastSnapshotTimestamp = block.timestamp;
  }

  function yield(EarnVaultUpgradeable vault, uint256 amount) external {
    vault.onYield(amount);
  }
}

/// @title The fixed EarnVaultUpgradeable, then EarnVaultV2, on one proxy
/// @notice Step 1 of the planned live path ships EarnVaultUpgradeable as it stands in this repo (the
///         V1 contract with the boost-reward fixes); step 2 upgrades the same proxy to EarnVaultV2.
///         These tests pin the fixed V1's behaviour (boost rewards must be funded, claims and
///         withdrawals as V1, no deposit pause) and check that the V2 upgrade changes no position,
///         keeps the vault solvent and lets everyone exit in full.
contract EarnVaultFixedV1ThenV2Test is Test {
  EarnVaultUpgradeable vault;
  MockUSDSC usdsc;
  ProxyAdmin proxyAdmin;
  RedistributorStub redistributor;
  address proxy;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address keeper = makeAddr('boostRewardKeeper');
  address alice = makeAddr('alice');
  address bob = makeAddr('bob');
  address carol = makeAddr('carol');
  address[] users;

  function setUp() public {
    usdsc = new MockUSDSC();
    redistributor = new RedistributorStub();
    proxy = address(
      new TransparentUpgradeableProxy(
        address(new EarnVaultUpgradeable()),
        admin,
        abi.encodeWithSelector(
          EarnVaultUpgradeable.initialize.selector,
          address(usdsc),
          owner,
          address(redistributor),
          treasury,
          pauser,
          keeper
        )
      )
    );
    vault = EarnVaultUpgradeable(payable(proxy));
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(proxy, adminSlot)))));
    users = [alice, bob, carol];
    for (uint256 i = 0; i < users.length; i++) {
      usdsc.mint(users[i], 1_000_000e6);
      vm.prank(users[i]);
      usdsc.approve(proxy, type(uint256).max);
    }
    _deposit(alice, 10_000e6);
    _deposit(bob, 5000e6);
    _yield(30e6);
    _boost(50e6);
  }

  // ---------------------------------------------------------------------------------------------
  // Fixed V1: boost rewards
  // ---------------------------------------------------------------------------------------------

  function test_FixedV1_BoostRewardMustBeFunded() public {
    vm.prank(keeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(usdsc), 50e6);

    usdsc.mint(proxy, 50e6 - 1);
    vm.prank(keeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(usdsc), 50e6);

    usdsc.mint(proxy, 1);
    vm.prank(keeper);
    vault.onBoostReward(address(usdsc), 50e6);
    _assertSolvent();
  }

  /// @dev Without new funding, not even 1 unit of what the vault owes can be indexed as boost
  function test_FixedV1_CannotIndexOwedFundsAsBoost() public {
    assertEq(vault.surplusUSDSC(), 0);
    vm.prank(keeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(usdsc), 1);
  }

  function test_FixedV1_OnlyUsdscBoost() public {
    MockUSDSC other = new MockUSDSC();
    other.mint(proxy, 100e6);
    vm.prank(keeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.BoostTokenNotUSDSC.selector);
    vault.onBoostReward(address(other), 100e6);
  }

  function test_FixedV1_NoDepositorsBoostCannotTakeOwedFunds() public {
    _exitAllV1();
    assertEq(vault.totalPrincipal(), 0);
    // with no depositors the boost would go to the treasury, but only from new funding
    vm.prank(keeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostTokenBalance.selector);
    vault.onBoostReward(address(usdsc), 1e6);
    _assertSolvent();
  }

  function test_FixedV1_SweepAndRecoverOnlySurplus() public {
    usdsc.mint(proxy, 7e6);
    vm.prank(owner);
    vault.sweepSurplusToTreasury();
    assertEq(usdsc.balanceOf(treasury), 7e6);
    _assertSolvent();
    vm.prank(pauser);
    vault.pause();
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.recoverERC20(address(usdsc), treasury, 1);
  }

  function test_FixedV1_UnfundedYieldRejected() public {
    vm.prank(address(redistributor));
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onYield(1);
  }

  // ---------------------------------------------------------------------------------------------
  // Fixed V1: users see V1 behaviour
  // ---------------------------------------------------------------------------------------------

  /// @dev Claim pays base yield and boost together, exactly what getAllClaimables reports
  function test_FixedV1_ClaimPaysBaseAndBoost() public {
    (uint256 base,, uint256[] memory boost) = vault.getAllClaimables(alice);
    assertGt(base, 0);
    assertGt(boost[0], 0);
    uint256 b = usdsc.balanceOf(alice);
    vm.prank(alice);
    vault.claim();
    assertEq(usdsc.balanceOf(alice) - b, base + boost[0]);
    assertEq(vault.principal(alice), 10_000e6, 'principal unchanged: no compounding on V1');
    _assertSolvent();
  }

  /// @dev withdraw(principal) is a full exit on V1: yield and boost are paid alongside
  function test_FixedV1_WithdrawPrincipalIsFullExit() public {
    uint256 owed = vault.totalValue(alice) + vault.getClaimableBoostReward(alice, address(usdsc));
    uint256 b = usdsc.balanceOf(alice);
    vm.prank(alice);
    vault.withdraw(10_000e6);
    assertEq(usdsc.balanceOf(alice) - b, owed);
    assertEq(vault.totalValue(alice), 0);
  }

  /// @dev No deposit pause on V1, even right after a snapshot
  function test_FixedV1_NoDepositPause() public {
    redistributor.snapshot();
    _deposit(carol, 1000e6);
    assertEq(vault.principal(carol), 1000e6);
    (bool ok,) = proxy.staticcall(abi.encodeWithSignature('depositsLocked()'));
    assertFalse(ok);
  }

  function test_FixedV1_RemoveBoostRewardTokenGone() public {
    vm.prank(owner);
    (bool ok,) = proxy.call(abi.encodeWithSignature('removeBoostRewardToken(address)', address(0xdEaD)));
    assertFalse(ok);
  }

  // ---------------------------------------------------------------------------------------------
  // Fixed V1 -> V2
  // ---------------------------------------------------------------------------------------------

  function test_UpgradeToV2_ValuesUnchangedAndSolvent() public {
    _yield(10e6);
    bytes memory before = _values();
    _upgradeToV2();
    assertEq(_values(), before);
    assertEq(EarnVaultV2(payable(proxy)).getVersion(), 'EarnVaultV2');
    _assertSolvent();
  }

  function test_UpgradeToV2_DepositPauseAppearsWithdrawalsStayOpen() public {
    _upgradeToV2();
    redistributor.snapshot();
    (bool locked, uint256 unlocksAt) = EarnVaultV2(payable(proxy)).depositsLocked();
    assertTrue(locked);
    vm.prank(carol);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, unlocksAt));
    vault.deposit(1000e6);
    uint256 b = usdsc.balanceOf(bob);
    vm.prank(bob);
    vault.withdraw(1000e6);
    assertGe(usdsc.balanceOf(bob) - b, 1000e6);
    vm.warp(unlocksAt);
    _deposit(carol, 1000e6);
    assertEq(vault.principal(carol), 1000e6);
  }

  function test_UpgradeToV2_EveryoneExitsWhole() public {
    _upgradeToV2();
    _yield(20e6);
    _boost(50e6);
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      if (vault.principal(u) + EarnVaultV2(payable(proxy)).pendingYield(u) == 0) continue;
      uint256 owed = vault.totalValue(u) + vault.getClaimableBoostReward(u, address(usdsc));
      uint256 b = usdsc.balanceOf(u);
      vm.prank(u);
      EarnVaultV2(payable(proxy)).withdrawAll();
      assertEq(usdsc.balanceOf(u) - b, owed);
    }
    _assertSolvent();
  }

  function test_UpgradeToV2_InitializeOnlyOnceAndOnlyViaProxyAdmin() public {
    _upgradeToV2();
    vm.prank(owner);
    vm.expectRevert();
    EarnVaultV2(payable(proxy)).initializeV2(owner, 1);
    address impl = address(new EarnVaultV2());
    bytes memory init = abi.encodeCall(EarnVaultV2.initializeV2, (owner, 1_000_000));
    vm.prank(admin);
    vm.expectRevert();
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, init);
  }

  function test_UpgradeToV2_InitializeV2FromAnyoneButProxyAdminReverts() public {
    address impl = address(new EarnVaultV2());
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, '');
    vm.prank(owner);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    EarnVaultV2(payable(proxy)).initializeV2(owner, 1_000_000);
    bytes memory zeroCap = abi.encodeCall(EarnVaultV2.initializeV2, (owner, 0));
    vm.prank(admin);
    vm.expectRevert(EarnVaultV2.ZeroMaxBoostPerBatch.selector);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, zeroCap);
  }

  function test_UpgradeToV2_BoostCreditNamespaceStartsEmpty() public {
    bytes32 ns = 0x554142adb35c10dc49454118de8343ddca3b3dda8789b6f7bf924bfb6955ee00;
    for (uint256 i = 0; i < 4; i++) {
      assertEq(vm.load(proxy, bytes32(uint256(ns) + i)), bytes32(0));
    }
    _upgradeToV2();
    assertEq(EarnVaultV2(payable(proxy)).boostKeeper(), owner);
    assertEq(EarnVaultV2(payable(proxy)).maxBoostPerBatch(), 1_000_000);
  }

  /// @dev Unchanged V1 behaviour, pinned: a pause stops user actions, unpause restores them, and
  ///      no position moves
  function test_FixedV1_PauseStopsUserActionsAndKeepsPositions() public {
    bytes memory before = _values();
    vm.prank(pauser);
    vault.pause();
    vm.startPrank(alice);
    vm.expectRevert();
    vault.withdraw(1e6);
    vm.expectRevert();
    vault.claim();
    vm.stopPrank();
    vm.prank(pauser);
    vault.unpause();
    assertEq(_values(), before);
    vm.prank(alice);
    vault.withdraw(1e6);
  }

  function test_FixedV1_BlacklistedCannotActButPositionKept() public {
    uint256 p = vault.principal(bob);
    vm.prank(owner);
    vault.setBlacklisted(bob, true);
    vm.startPrank(bob);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.withdraw(1e6);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.claim();
    vm.stopPrank();
    vm.prank(owner);
    vault.setBlacklisted(bob, false);
    assertEq(vault.principal(bob), p);
    vm.prank(bob);
    vault.withdraw(p);
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------
  // Fuzz: random activity on the fixed V1, the upgrade, random activity on V2, then everyone exits
  // ---------------------------------------------------------------------------------------------

  function testFuzz_TwoStep_SolventThroughoutAndEveryoneWhole(uint256 seed) public {
    for (uint256 i = 0; i < 12; i++) {
      _randomAction(uint256(keccak256(abi.encode(seed, 'v1', i))), false);
      _assertSolvent();
    }
    bytes memory before = _values();
    _upgradeToV2();
    assertEq(_values(), before, 'upgrade changed a position');
    _assertSolvent();
    for (uint256 i = 0; i < 12; i++) {
      _randomAction(uint256(keccak256(abi.encode(seed, 'v2', i))), true);
      _assertSolvent();
    }
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      if (vault.principal(u) + EarnVaultV2(payable(proxy)).pendingYield(u) == 0) continue;
      uint256 owed = vault.totalValue(u) + vault.getClaimableBoostReward(u, address(usdsc));
      uint256 b = usdsc.balanceOf(u);
      vm.prank(u);
      EarnVaultV2(payable(proxy)).withdrawAll();
      assertEq(usdsc.balanceOf(u) - b, owed, 'not paid in full');
    }
    _assertSolvent();
  }

  function _randomAction(uint256 r, bool v2) internal {
    address u = users[r % users.length];
    uint256 kind = (r >> 8) % 9;
    uint256 amount = bound(r >> 16, 1e6, 20_000e6);
    if (kind == 0) {
      if (v2) {
        (bool locked, uint256 unlocksAt) = EarnVaultV2(payable(proxy)).depositsLocked();
        if (locked) vm.warp(unlocksAt);
      }
      _deposit(u, amount);
    } else if (kind == 1) {
      uint256 p = vault.principal(u);
      if (p > 0) {
        vm.prank(u);
        vault.withdraw(bound(amount, 1, p));
      }
    } else if (kind == 2) {
      // claim pays exactly what is owed, and only reverts when nothing is owed. V1 pays accrued plus
      // pending; V2 folds pending into principal first and pays accrued (legacy) plus boost
      uint256 base = v2 ? vault.accrued(u) : vault.totalValue(u) - vault.principal(u);
      uint256 expected = base + vault.getClaimableBoostReward(u, address(usdsc));
      uint256 b = usdsc.balanceOf(u);
      vm.prank(u);
      if (expected == 0) vm.expectRevert(IEarnVaultEventsAndErrors.NothingToClaim.selector);
      vault.claim();
      assertEq(usdsc.balanceOf(u) - b, expected, 'claim paid a different amount');
    } else if (kind == 3) {
      if (vault.totalPrincipal() > 0) _yield(bound(amount, 1, 100e6));
    } else if (kind == 4) {
      if (vault.totalPrincipal() > 0) _boost(bound(amount, 1, 100e6));
    } else if (kind == 5) {
      // an unfunded boost is always refused, whatever the state
      uint256 over = vault.surplusUSDSC() + bound(amount, 1, 100e6);
      bytes4 expected = vault.totalPrincipal() == 0
        ? IEarnVaultEventsAndErrors.InsufficientBoostTokenBalance.selector
        : IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector;
      vm.prank(keeper);
      vm.expectRevert(expected);
      vault.onBoostReward(address(usdsc), over);
    } else if (kind == 6) {
      // a donation, then a sweep: only the donation leaves
      usdsc.mint(proxy, bound(amount, 1, 100e6));
      uint256 surplus = vault.surplusUSDSC();
      uint256 t = usdsc.balanceOf(treasury);
      vm.prank(owner);
      vault.sweepSurplusToTreasury();
      assertEq(usdsc.balanceOf(treasury) - t, surplus);
    } else if (kind == 7) {
      // pause and unpause leave every position as it was
      bytes memory before = _values();
      vm.prank(pauser);
      vault.pause();
      vm.prank(u);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      vault.deposit(1e6);
      vm.prank(pauser);
      vault.unpause();
      assertEq(_values(), before);
    } else {
      redistributor.snapshot();
      vm.warp(block.timestamp + 1 hours);
    }
  }

  // ---------------------------------------------------------------------------------------------

  // ---------------------------------------------------------------------------------------------
  // Emergency pause and rollback (V2 -> fixed V1 -> V2). Rolling back to the live V1 needs the live
  // code and is covered by the fork suite
  // ---------------------------------------------------------------------------------------------

  /// @dev The paused flag lives in the proxy's storage: it survives every upgrade and rollback
  function test_Pause_CarriesAcrossUpgradesAndRollback() public {
    vm.prank(pauser);
    vault.pause();
    bytes memory before = _values();
    _upgradeToV2();
    assertTrue(vault.paused());
    _rollbackToFixed();
    assertTrue(vault.paused());
    _reupgradeToV2();
    assertTrue(vault.paused());
    assertEq(_values(), before);
    vm.prank(alice);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.withdraw(1e6);
    vm.prank(pauser);
    vault.unpause();
    _exitAllV2();
  }

  /// @dev While paused, user actions and boosts stop but yield keeps being indexed, on both versions
  function test_Pause_StopsUserActionsYieldKeepsFlowing() public {
    for (uint256 stage = 0; stage < 2; stage++) {
      if (stage == 1) _upgradeToV2();
      usdsc.mint(proxy, 1e6); // funding for the boost attempt below, before the snapshot of values
      vm.prank(pauser);
      vault.pause();
      bytes memory before = _values();
      vm.startPrank(alice);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      vault.deposit(1e6);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      vault.withdraw(1e6);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      vault.claim();
      vm.stopPrank();
      vm.prank(keeper);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      vault.onBoostReward(address(usdsc), 1e6);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      vault.depositWithPermit(alice, 1e6, block.timestamp, 0, bytes32(0), bytes32(0));
      if (stage == 1) {
        EarnVaultV2 v2 = EarnVaultV2(payable(proxy));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        v2.compoundMany(users);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        v2.compound(alice);
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        v2.withdrawAll();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        v2.depositWithAuthorization(alice, 1e6, 0, block.timestamp + 1, bytes32(0), '');
        address[] memory who = new address[](1);
        uint256[] memory amt = new uint256[](1);
        (who[0], amt[0]) = (alice, 1e6);
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        v2.onBoostCredit(1, who, amt);
      }
      assertEq(_values(), before, 'pause moved a position');
      uint256 gi = vault.globalIndex();
      _yield(10e6);
      assertGt(vault.globalIndex(), gi, 'yield must keep flowing while paused');
      _assertSolvent();
      // owner functions keep working while paused; USDSC can only leave as surplus
      vm.startPrank(owner);
      vault.setBoostRewardKeeper(keeper);
      vault.setBlacklisted(carol, true);
      vault.setBlacklisted(carol, false);
      usdsc.mint(proxy, 3e6); // a donation
      uint256 t = usdsc.balanceOf(treasury);
      vault.recoverERC20(address(usdsc), treasury, 1e6);
      vault.sweepSurplusToTreasury();
      vm.stopPrank();
      assertEq(usdsc.balanceOf(treasury) - t, 4e6, 'only the donation and the earlier funding left');
      _assertSolvent();
      vm.prank(pauser);
      vault.unpause();
    }
    _exitAllV2();
  }

  /// @dev V2 state that the fixed V1 does not know (boost credits, compounded yield, the cycle
  ///      counter) survives a rollback as plain principal, and a later re-upgrade carries on
  function test_Rollback_AfterCreditsAndCompounding_ThenReupgrade() public {
    _upgradeToV2();
    EarnVaultV2 v2 = EarnVaultV2(payable(proxy));
    vm.prank(owner);
    v2.setMaxBoostPerBatch(100e6);
    _yield(20e6);
    _credit(1, 30e6, 15e6);
    v2.compoundMany(users);
    _boost(10e6);
    bytes memory before = _values();

    _rollbackToFixed();
    assertEq(vault.getVersion(), 'EarnVaultV1');
    assertEq(_values(), before, 'rollback moved a position');
    _assertSolvent();
    // fixed V1 behaviour again: no deposit pause, claim pays base plus boost
    redistributor.snapshot();
    _deposit(carol, 100e6);
    _yield(5e6);
    _boost(5e6);
    (uint256 base,, uint256[] memory boost) = vault.getAllClaimables(alice);
    uint256 b = usdsc.balanceOf(alice);
    vm.prank(alice);
    vault.claim();
    assertEq(usdsc.balanceOf(alice) - b, base + boost[0]);
    _assertSolvent();

    bytes memory mid = _values();
    _reupgradeToV2();
    assertEq(_values(), mid, 're-upgrade moved a position');
    assertEq(v2.boostKeeper(), owner);
    assertEq(v2.maxBoostPerBatch(), 100e6);
    assertEq(v2.latestCycleId(), 1);
    assertEq(v2.lastCreditedCycle(alice), 1);
    vm.warp(block.timestamp + 1 hours); // past the snapshot taken above
    // a cycle already paid cannot be paid again; the next one works
    usdsc.mint(proxy, 1e6);
    address[] memory one = new address[](1);
    uint256[] memory amt = new uint256[](1);
    (one[0], amt[0]) = (alice, 1e6);
    vm.prank(owner);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    v2.onBoostCredit(1, one, amt);
    _credit(2, 10e6, 10e6);
    _assertSolvent();
    _exitAllV2();
  }

  /// @dev Rolling back inside a V2 deposit pause reopens deposits at once; the pending
  ///      distribution still lands
  function test_Rollback_DuringDepositPause() public {
    _upgradeToV2();
    redistributor.snapshot();
    (bool locked,) = EarnVaultV2(payable(proxy)).depositsLocked();
    assertTrue(locked);
    _rollbackToFixed();
    _deposit(carol, 500e6);
    assertEq(vault.principal(carol), 500e6);
    _yield(8e6);
    _assertSolvent();
    _reupgradeToV2();
    _exitAllV2();
  }

  /// @dev Random activity while moving back and forth between the fixed V1 and V2. The vault can
  ///      stay paused across switches, switches can land inside a V2 deposit-pause window, and V2
  ///      boost credits and compounding happen between switches. Solvent and fully owed after
  ///      every step; everyone exits whole at the end
  function testFuzz_RollbackCycles_SolventAndEveryoneWhole(uint256 seed) public {
    bool onV2;
    bool everV2;
    bool paused;
    for (uint256 i = 0; i < 30; i++) {
      uint256 r = uint256(keccak256(abi.encode(seed, 'cycle', i)));
      uint256 pick = r % 10;
      if (pick == 0 || pick == 1) {
        bytes memory before = _values();
        if (onV2) {
          _rollbackToFixed();
        } else if (everV2) {
          _reupgradeToV2();
        } else {
          _upgradeToV2();
          everV2 = true;
          vm.prank(owner);
          EarnVaultV2(payable(proxy)).setMaxBoostPerBatch(1000e6);
        }
        onV2 = !onV2;
        assertEq(_values(), before, 'an upgrade or rollback moved a position');
        assertEq(vault.paused(), paused, 'pause flag lost');
      } else if (pick == 2) {
        vm.prank(pauser);
        paused ? vault.unpause() : vault.pause();
        paused = !paused;
      } else if (pick == 3) {
        redistributor.snapshot(); // no warp: the next steps may land inside a deposit-pause window
      } else if (paused) {
        // user actions are refused, yield keeps flowing, nothing else moves
        address u = users[r % users.length];
        vm.prank(u);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.deposit(1e6);
        if (vault.totalPrincipal() > 0) _yield(bound(r >> 16, 1, 50e6));
      } else if (onV2 && pick == 4) {
        (bool locked,) = EarnVaultV2(payable(proxy)).depositsLocked();
        if (!locked && vault.principal(alice) + vault.principal(bob) > 0) {
          _credit(EarnVaultV2(payable(proxy)).latestCycleId() + 1, bound(r >> 16, 0, 20e6), bound(r >> 40, 0, 20e6));
        }
      } else if (onV2 && pick == 5) {
        EarnVaultV2(payable(proxy)).compoundMany(users);
        for (uint256 k = 0; k < users.length; k++) {
          assertEq(EarnVaultV2(payable(proxy)).pendingYield(users[k]), 0);
        }
      } else {
        _randomAction(r >> 3, onV2);
      }
      _assertSolvent();
    }
    if (paused) {
      vm.prank(pauser);
      vault.unpause();
    }
    if (!onV2) everV2 ? _reupgradeToV2() : _upgradeToV2();
    _exitAllV2();
  }

  function _rollbackToFixed() internal {
    address impl = address(new EarnVaultUpgradeable());
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, '');
    assertEq(vault.getVersion(), 'EarnVaultV1');
  }

  /// @dev After a rollback the initialized version is already 2: re-upgrade with empty data
  function _reupgradeToV2() internal {
    address impl = address(new EarnVaultV2());
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, '');
    assertEq(vault.getVersion(), 'EarnVaultV2');
  }

  function _credit(uint256 cycleId, uint256 toAlice, uint256 toBob) internal {
    usdsc.mint(proxy, toAlice + toBob);
    address[] memory who = new address[](2);
    uint256[] memory amt = new uint256[](2);
    (who[0], who[1], amt[0], amt[1]) = (alice, bob, toAlice, toBob);
    uint256 pa = vault.principal(alice);
    vm.prank(owner);
    EarnVaultV2(payable(proxy)).onBoostCredit(cycleId, who, amt);
    assertGe(vault.principal(alice), pa + toAlice, 'credit not added to principal');
    assertEq(EarnVaultV2(payable(proxy)).lastCreditedCycle(alice) == cycleId, toAlice > 0);
  }

  function _exitAllV2() internal {
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      if (vault.principal(u) + EarnVaultV2(payable(proxy)).pendingYield(u) == 0) continue;
      uint256 owed = vault.totalValue(u) + vault.getClaimableBoostReward(u, address(usdsc));
      uint256 b = usdsc.balanceOf(u);
      vm.prank(u);
      EarnVaultV2(payable(proxy)).withdrawAll();
      assertEq(usdsc.balanceOf(u) - b, owed, 'not paid in full');
    }
    assertEq(vault.totalPrincipal(), 0);
    // nothing owed is left behind across upgrades and rollbacks: only rounding dust remains
    assertLe(vault.claimReserve(), 1000, 'base yield left behind');
    assertLe(vault.boostClaimReserve(address(usdsc)), 1000, 'boost left behind');
    _assertSolvent();
  }

  function _upgradeToV2() internal {
    address impl = address(new EarnVaultV2());
    bytes memory init = abi.encodeCall(EarnVaultV2.initializeV2, (owner, 1_000_000));
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, init);
  }

  function _values() internal view returns (bytes memory s) {
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      s = abi.encode(
        s, vault.principal(u), vault.accrued(u), vault.totalValue(u), vault.getClaimableBoostReward(u, address(usdsc))
      );
    }
    s = abi.encode(s, vault.totalPrincipal(), vault.claimReserve(), vault.globalIndex(), usdsc.balanceOf(proxy));
  }

  function _exitAllV1() internal {
    for (uint256 i = 0; i < users.length; i++) {
      uint256 p = vault.principal(users[i]);
      if (p == 0) continue;
      vm.prank(users[i]);
      vault.withdraw(p);
    }
  }

  function _deposit(address u, uint256 amount) internal {
    usdsc.mint(u, amount);
    vm.prank(u);
    vault.deposit(amount);
  }

  function _yield(uint256 amount) internal {
    usdsc.mint(proxy, amount);
    redistributor.yield(vault, amount);
  }

  function _boost(uint256 amount) internal {
    usdsc.mint(proxy, amount);
    vm.prank(keeper);
    vault.onBoostReward(address(usdsc), amount);
  }

  /// @dev The balance covers both reserves, and the reserves cover what every user is owed
  function _assertSolvent() internal view {
    assertGe(usdsc.balanceOf(proxy), vault.claimReserve() + vault.boostClaimReserve(address(usdsc)), 'under-reserved');
    uint256 owedBase;
    uint256 owedBoost;
    for (uint256 i = 0; i < users.length; i++) {
      owedBase += vault.totalValue(users[i]);
      owedBoost += vault.getClaimableBoostReward(users[i], address(usdsc));
    }
    assertGe(vault.claimReserve(), vault.totalPrincipal(), 'reserve below principal');
    assertGe(vault.claimReserve(), owedBase, 'reserve below what users are owed');
    assertGe(vault.boostClaimReserve(address(usdsc)), owedBoost, 'boost reserve below what users are owed');
  }
}
