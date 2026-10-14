// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVault} from '../../src/vaults/earn/EarnVault.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'lib/forge-std/src/Test.sol';

/// @title USDSC as both vault asset and boost token
/// @notice USDSC backs two reserves at once: claimReserve (principal + yield) and
///         boostClaimReserve[USDSC] (boost rewards owed). Every check that moves or reserves USDSC must
///         count both: onBoostReward, onYield, onBoostCredit, sweepSurplusToTreasury and recoverERC20.
contract EarnVaultUsdscBoostReserveTest is Test {
  EarnVaultV2 vault;
  MockUSDSC usdsc;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address redistributor = makeAddr('redistributor');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address boostRewardKeeper = makeAddr('boostRewardKeeper'); // V1 onBoostReward keeper
  address boostKeeper = makeAddr('boostKeeper'); // V2 onBoostCredit keeper
  address alice = makeAddr('alice');
  address bob = makeAddr('bob');

  uint256 constant ALICE = 600_000e6;
  uint256 constant BOB = 400_000e6;
  uint256 constant DAILY_BOOST = 50e6;

  function setUp() public {
    usdsc = new MockUSDSC();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        redistributor,
        treasury,
        pauser,
        boostRewardKeeper
      )
    );
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), adminSlot)))));
    address impl = address(new EarnVaultV2());
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, type(uint256).max))
    );
    vault = EarnVaultV2(payable(address(proxy)));

    _deposit(alice, ALICE);
    _deposit(bob, BOB);
    // the live shape: USDSC already registered as a boost token with an outstanding reserve
    _fundedBoost(DAILY_BOOST);
  }

  // ---------------------------------------------------------------------------------------------
  // onBoostReward(USDSC) must be funded on top of everything already owed in USDSC
  // ---------------------------------------------------------------------------------------------

  function test_UnfundedUsdscBoostReverts() public {
    uint256 freeHeadroom = usdsc.balanceOf(address(vault)) - _required();
    assertEq(freeHeadroom, 0);

    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(usdsc), 1);
  }

  function test_BoostAgainstExistingBalanceReverts() public {
    // the whole balance minus the boost reserve: unfunded, so it must be refused
    uint256 amount = usdsc.balanceOf(address(vault)) - vault.boostClaimReserve(address(usdsc));
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(usdsc), amount);
  }

  /// @dev A keeper that is also a depositor still cannot index more USDSC than it funded
  function test_DepositingKeeperStillNeedsFundedBoost() public {
    uint256 keeperDeposit = vault.totalPrincipal();
    _deposit(boostRewardKeeper, keeperDeposit);

    uint256 amount = usdsc.balanceOf(address(vault)) - vault.boostClaimReserve(address(usdsc));
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(usdsc), amount);

    vm.prank(boostRewardKeeper);
    vault.withdraw(keeperDeposit);
    assertEq(usdsc.balanceOf(boostRewardKeeper), keeperDeposit, 'keeper gained nothing');
    _exitAllAndAssertWhole();
  }

  function test_FundedDailyRoundStillWorks() public {
    uint256 reserveBefore = vault.boostClaimReserve(address(usdsc));
    for (uint256 day = 0; day < 3; day++) {
      _fundedBoost(DAILY_BOOST);
    }
    assertEq(vault.boostClaimReserve(address(usdsc)), reserveBefore + 3 * DAILY_BOOST);
    _assertSolvent();
    _exitAllAndAssertWhole();
  }

  function test_ExactFundingPasses_OneUnitShortReverts() public {
    usdsc.mint(address(vault), DAILY_BOOST - 1);
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(usdsc), DAILY_BOOST);

    usdsc.mint(address(vault), 1);
    vm.prank(boostRewardKeeper);
    vault.onBoostReward(address(usdsc), DAILY_BOOST);
    _assertSolvent();
  }

  /// @dev No depositors left, but USDSC is still owed as boost rewards: the treasury branch of
  ///      onBoostReward must not hand that USDSC to the treasury
  function test_NoDepositors_TreasuryBoostCannotTakeOwedUsdsc() public {
    _exitEveryone();
    _seedOwed(BOOST_RESERVE_FIELD, 1000e6);

    uint256 headroom = usdsc.balanceOf(address(vault)) - _required();
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostTokenBalance.selector);
    vault.onBoostReward(address(usdsc), headroom + 1);

    usdsc.mint(address(vault), DAILY_BOOST);
    vm.prank(boostRewardKeeper);
    vault.onBoostReward(address(usdsc), DAILY_BOOST);
    assertEq(usdsc.balanceOf(treasury), DAILY_BOOST);
    _assertSolvent();
  }

  /// @dev No depositors left, but USDSC is still owed (legacy accrued): the treasury branch of
  ///      onYield must not hand that USDSC to the treasury
  function test_NoDepositors_TreasuryYieldCannotTakeOwedUsdsc() public {
    _exitEveryone();
    _seedOwed(CLAIM_RESERVE_FIELD, 1000e6);

    uint256 headroom = usdsc.balanceOf(address(vault)) - _required();
    vm.prank(redistributor);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onYield(headroom + 1);

    usdsc.mint(address(vault), 100e6);
    vm.prank(redistributor);
    vault.onYield(100e6);
    assertEq(usdsc.balanceOf(treasury), 100e6);
    _assertSolvent();
  }

  /// @dev Same rule for any boost token: with no depositors, an unfunded boost must not send tokens
  ///      still owed as boost rewards to the treasury
  function test_NoDepositors_NonUsdscBoostCannotTakeOwedTokens() public {
    MockERC20 astr = new MockERC20('Astar', 'ASTR', 18);
    astr.mint(address(vault), 100e18);
    vm.prank(boostRewardKeeper);
    vault.onBoostReward(address(astr), 100e18);
    _exitEveryone(); // claims are paid on withdraw, so seed an unclaimed entitlement back in
    bytes32 slot = keccak256(abi.encode(address(astr), bytes32(uint256(EARN_VAULT_STORAGE) + BOOST_RESERVE_FIELD)));
    vm.store(address(vault), slot, bytes32(uint256(40e18)));
    astr.mint(address(vault), 40e18 - astr.balanceOf(address(vault)));

    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostTokenBalance.selector);
    vault.onBoostReward(address(astr), 40e18);
    assertEq(astr.balanceOf(treasury), 0);
  }

  /// @dev First-ever USDSC boost (empty activeBoostTokens): same rule applies
  function test_FirstUsdscBoostOnFreshVault_MustBeFunded() public {
    TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        redistributor,
        treasury,
        pauser,
        boostRewardKeeper
      )
    );
    EarnVaultUpgradeable fresh = EarnVaultUpgradeable(payable(address(p)));
    usdsc.mint(alice, ALICE);
    vm.startPrank(alice);
    usdsc.approve(address(fresh), ALICE);
    fresh.deposit(ALICE);
    vm.stopPrank();
    assertEq(fresh.boostClaimReserve(address(usdsc)), 0);

    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    fresh.onBoostReward(address(usdsc), ALICE);

    usdsc.mint(address(fresh), DAILY_BOOST);
    vm.prank(boostRewardKeeper);
    fresh.onBoostReward(address(usdsc), DAILY_BOOST);
    assertEq(fresh.boostClaimReserve(address(usdsc)), DAILY_BOOST);
  }

  function test_NonUsdscBoostTokenUnaffected() public {
    MockERC20 astr = new MockERC20('Astar', 'ASTR', 18);
    astr.mint(address(vault), 1000e18);
    vm.prank(boostRewardKeeper);
    vault.onBoostReward(address(astr), 1000e18);
    assertEq(vault.boostClaimReserve(address(astr)), 1000e18);

    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(astr), 1);
  }

  // ---------------------------------------------------------------------------------------------
  // The same aliasing, other direction: paths that must not spend owed USDSC boost rewards
  // ---------------------------------------------------------------------------------------------

  function test_SurplusUsdscIsTheTrueSurplus() public {
    assertEq(vault.surplusUSDSC(), 0, 'setUp leaves no surplus');
    usdsc.mint(address(vault), 7e6);
    assertEq(vault.surplusUSDSC(), 7e6);
    vm.prank(owner);
    vault.sweepSurplusToTreasury();
    assertEq(vault.surplusUSDSC(), 0);
    assertEq(usdsc.balanceOf(treasury), 7e6);
  }

  /// @dev The upgradeable vault's boost getters return the same values as the non-upgradeable
  ///      twin's public state for the same sequence of actions
  function test_BoostGettersMatchTwin() public {
    EarnVault twin = new EarnVault(address(usdsc), owner, redistributor, treasury, pauser, boostRewardKeeper);
    EarnVaultV2 v2 = _freshV2();
    address[2] memory vs = [address(v2), address(twin)];
    for (uint256 i = 0; i < 2; i++) {
      address v = vs[i];
      _depositInto(v, alice, 600e6);
      _depositInto(v, bob, 400e6);
      usdsc.mint(v, 30e6);
      vm.prank(boostRewardKeeper);
      EarnVaultUpgradeable(payable(v)).onBoostReward(address(usdsc), 30e6);
      _depositInto(v, alice, 1e6); // settles alice: index updated, boost moved into accrued
    }
    assertEq(v2.boostGlobalIndex(address(usdsc)), twin.boostGlobalIndex(address(usdsc)));
    assertEq(v2.boostGlobalIndex(address(usdsc)), uint256(30e6) * 1e27 / 1000e6);
    assertEq(v2.userBoostIndex(alice, address(usdsc)), twin.userBoostIndex(alice, address(usdsc)));
    assertEq(v2.userBoostIndex(alice, address(usdsc)), v2.boostGlobalIndex(address(usdsc)));
    assertEq(v2.userBoostIndex(bob, address(usdsc)), twin.userBoostIndex(bob, address(usdsc)));
    assertEq(v2.userBoostAccrued(alice, address(usdsc)), twin.userBoostAccrued(alice, address(usdsc)));
    assertEq(v2.userBoostAccrued(alice, address(usdsc)), 18e6);
    assertEq(v2.userBoostAccrued(bob, address(usdsc)), 0, 'bob not settled yet');
    assertEq(v2.activeBoostTokens(0), twin.activeBoostTokens(0));
    assertEq(v2.activeBoostTokens(0), address(usdsc));
    assertEq(v2.boostClaimReserve(address(usdsc)), twin.boostClaimReserve(address(usdsc)));
    vm.expectRevert();
    v2.activeBoostTokens(1);
  }

  function test_SweepLeavesOwedBoostRewards() public {
    usdsc.mint(address(vault), 7e6); // a real donation
    vm.prank(owner);
    vault.sweepSurplusToTreasury();
    assertEq(usdsc.balanceOf(treasury), 7e6, 'only the donation is surplus');
    _assertSolvent();
    _exitAllAndAssertWhole();
  }

  function test_RecoverUsdscCannotTakeOwedBoostRewards() public {
    usdsc.mint(address(vault), 7e6);
    vm.prank(pauser);
    vault.pause();
    vm.startPrank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.ExceedsSurplus.selector);
    vault.recoverERC20(address(usdsc), treasury, 7e6 + 1);
    vault.recoverERC20(address(usdsc), treasury, 7e6);
    vm.stopPrank();
    _assertSolvent();
  }

  function test_UnfundedOnYieldCannotUseOwedBoostRewards() public {
    vm.prank(redistributor);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onYield(1);

    usdsc.mint(address(vault), 100e6);
    vm.prank(redistributor);
    vault.onYield(100e6);
    _assertSolvent();
  }

  function test_OnBoostCreditCannotUseOwedBoostRewards() public {
    address[] memory users = new address[](1);
    uint256[] memory amounts = new uint256[](1);
    users[0] = alice;
    amounts[0] = 1;
    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onBoostCredit(1, users, amounts);

    amounts[0] = 25e6;
    usdsc.mint(address(vault), 25e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    _assertSolvent();
  }

  function testFuzz_SolvencyHoldsAcrossBoostAndYield(uint64 boost, uint64 yield_, uint64 credit) public {
    boost = uint64(bound(boost, 1, 1_000_000e6));
    yield_ = uint64(bound(yield_, 1, 1_000_000e6));
    credit = uint64(bound(credit, 1, 1_000_000e6));

    // unfunded attempts all fail
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    vault.onBoostReward(address(usdsc), boost);
    vm.prank(redistributor);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onYield(yield_);

    // funded ones succeed and keep the vault solvent
    _fundedBoost(boost);
    usdsc.mint(address(vault), yield_);
    vm.prank(redistributor);
    vault.onYield(yield_);
    address[] memory users = new address[](1);
    uint256[] memory amounts = new uint256[](1);
    (users[0], amounts[0]) = (bob, credit);
    usdsc.mint(address(vault), credit);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    _assertSolvent();
    _exitAllAndAssertWhole();
  }

  // ---------------------------------------------------------------------------------------------
  // Non-upgradeable twin
  // ---------------------------------------------------------------------------------------------

  function test_NonUpgradeableTwin_UnfundedUsdscBoostReverts() public {
    EarnVault twin = new EarnVault(address(usdsc), owner, redistributor, treasury, pauser, boostRewardKeeper);
    usdsc.mint(alice, ALICE);
    vm.startPrank(alice);
    usdsc.approve(address(twin), ALICE);
    twin.deposit(ALICE);
    vm.stopPrank();

    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    twin.onBoostReward(address(usdsc), ALICE);

    usdsc.mint(address(twin), DAILY_BOOST);
    vm.prank(boostRewardKeeper);
    twin.onBoostReward(address(usdsc), DAILY_BOOST);

    vm.prank(redistributor);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    twin.onYield(1);

    usdsc.mint(address(twin), 3e6);
    assertEq(twin.surplusUSDSC(), 3e6);
    vm.prank(owner);
    twin.sweepSurplusToTreasury();
    assertEq(twin.surplusUSDSC(), 0);
    assertEq(usdsc.balanceOf(treasury), 3e6);

    usdsc.mint(address(twin), 2e6);
    vm.prank(pauser);
    twin.pause();
    vm.startPrank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.ExceedsSurplus.selector);
    twin.recoverERC20(address(usdsc), treasury, 2e6 + 1);
    twin.recoverERC20(address(usdsc), treasury, 2e6);
    vm.stopPrank();
    assertGe(usdsc.balanceOf(address(twin)), twin.claimReserve() + twin.boostClaimReserve(address(usdsc)));
  }

  // ---------------------------------------------------------------------------------------------

  // EarnVault ERC-7201 struct fields (EarnVaultStorageBase): claimReserve is field 9, the
  // boostClaimReserve mapping is field 15
  bytes32 constant EARN_VAULT_STORAGE = 0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;
  uint256 constant CLAIM_RESERVE_FIELD = 9;
  uint256 constant BOOST_RESERVE_FIELD = 15;

  function _exitEveryone() internal {
    uint256 aliceP = vault.principal(alice);
    uint256 bobP = vault.principal(bob);
    vm.prank(alice);
    vault.withdraw(aliceP);
    vm.prank(bob);
    vault.withdraw(bobP);
    assertEq(vault.totalPrincipal(), 0);
  }

  /// @dev Puts `amount` of backed, still-owed USDSC into one reserve (a state normally reached by
  ///      users who have not claimed yet), with the matching USDSC in the vault
  function _seedOwed(uint256 field, uint256 amount) internal {
    bytes32 slot = field == BOOST_RESERVE_FIELD
      ? keccak256(abi.encode(address(usdsc), bytes32(uint256(EARN_VAULT_STORAGE) + field)))
      : bytes32(uint256(EARN_VAULT_STORAGE) + field);
    vm.store(address(vault), slot, bytes32(uint256(vm.load(address(vault), slot)) + amount));
    usdsc.mint(address(vault), amount);
    _assertSolvent();
  }

  function _freshV2() internal returns (EarnVaultV2 v2) {
    TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        redistributor,
        treasury,
        pauser,
        boostRewardKeeper
      )
    );
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(address(p), adminSlot)))));
    address impl = address(new EarnVaultV2());
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(p)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, type(uint256).max))
    );
    v2 = EarnVaultV2(payable(address(p)));
  }

  function _depositInto(address v, address user, uint256 amount) internal {
    usdsc.mint(user, amount);
    vm.startPrank(user);
    usdsc.approve(v, amount);
    EarnVaultUpgradeable(payable(v)).deposit(amount);
    vm.stopPrank();
  }

  function _deposit(address user, uint256 amount) internal {
    usdsc.mint(user, amount);
    vm.startPrank(user);
    usdsc.approve(address(vault), amount);
    vault.deposit(amount);
    vm.stopPrank();
  }

  /// @dev The legitimate keeper flow: transfer the reward in, then index it
  function _fundedBoost(uint256 amount) internal {
    usdsc.mint(address(vault), amount);
    vm.prank(boostRewardKeeper);
    vault.onBoostReward(address(usdsc), amount);
  }

  function _required() internal view returns (uint256) {
    return vault.claimReserve() + vault.boostClaimReserve(address(usdsc));
  }

  function _assertSolvent() internal view {
    assertGe(usdsc.balanceOf(address(vault)), _required(), 'vault under-reserved');
  }

  /// @dev Both depositors withdraw everything (principal, yield, boost) and are paid in full
  function _exitAllAndAssertWhole() internal {
    address[2] memory users = [alice, bob];
    // the boost reserve covers every depositor's boost entitlement
    uint256 entitled =
      vault.getClaimableBoostReward(alice, address(usdsc)) + vault.getClaimableBoostReward(bob, address(usdsc));
    assertGe(vault.boostClaimReserve(address(usdsc)), entitled, 'boost reserve < entitlements');
    for (uint256 i = 0; i < 2; i++) {
      address u = users[i];
      uint256 owed = vault.totalValue(u) + vault.getClaimableBoostReward(u, address(usdsc));
      uint256 before = usdsc.balanceOf(u);
      uint256 all = vault.principal(u) + vault.pendingYield(u);
      vm.prank(u);
      vault.withdraw(all);
      assertEq(usdsc.balanceOf(u) - before, owed, 'depositor not paid in full');
    }
    _assertSolvent();
  }
}
