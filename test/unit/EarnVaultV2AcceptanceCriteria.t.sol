// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'lib/forge-std/src/Test.sol';
import {PausableUpgradeable} from 'lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol';
import {Ownable} from 'lib/openzeppelin-contracts/contracts/access/Ownable.sol';

/// @title EarnVaultV2 product acceptance criteria
/// @notice One test (or small group) per acceptance criterion that the contract can enforce. Tiers
///         live off-chain: the reward engine decides each address's tier and boost amount, and the
///         vault only sees onBoostCredit(cycleId, users, amounts). So "Silver" and "Gold" here are
///         what a simulated engine (_engineCredit) credits on top of the base APY that every
///         depositor gets from onYield().
/// @dev Not covered here, because the current design does not satisfy them or they are not
///      contract behaviour:
///      - "Pause never blocks withdrawals": withdraw() is whenNotPaused in V1 and V2, so pause
///        does block withdrawals. Needs a product or contract decision.
///      - Design doc sections and QA sign-off.
contract EarnVaultV2AcceptanceCriteriaTest is Test {
  EarnVaultV2 vault;
  MockUSDSC usdsc;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address redistributor = makeAddr('redistributor');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address operator = makeAddr('operator');
  address boostKeeper = makeAddr('boostKeeper');
  address compoundKeeper = makeAddr('compoundKeeper');

  address baseUser = makeAddr('base');
  address silverUser = makeAddr('silver');
  address goldUser = makeAddr('gold');

  uint256 constant DEPOSIT = 10_000e6;
  // Illustrative yearly rates: 5% base for everyone, +2% Silver, +4% Gold
  uint256 constant BASE_BPS = 500;
  uint256 constant SILVER_BOOST_BPS = 200;
  uint256 constant GOLD_BOOST_BPS = 400;

  function setUp() public {
    usdsc = new MockUSDSC();
    (address proxy, ProxyAdmin pa) = _deployV1();
    _upgradeToV2(proxy, pa);
    vault = EarnVaultV2(payable(proxy));
  }

  // ---------------------------------------------------------------------------------------------
  // AC: A Silver and a Gold depositor accrue their boosted APY on the same vault, and a Base
  //     depositor accrues the base APY.
  // ---------------------------------------------------------------------------------------------

  function test_AC_TiersAccrueTheirOwnApyOnOneVault() public {
    _depositAs(baseUser, DEPOSIT);
    _depositAs(silverUser, DEPOSIT);
    _depositAs(goldUser, DEPOSIT);

    _yieldForOneYear();
    _engineCredit(1, _tierUsers(), _tierBoostBps(SILVER_BOOST_BPS, GOLD_BOOST_BPS));

    uint256 base = DEPOSIT * BASE_BPS / 10_000;
    assertEq(vault.totalValue(baseUser), DEPOSIT + base, 'base: base APY only');
    assertEq(vault.totalValue(silverUser), DEPOSIT + base + DEPOSIT * SILVER_BOOST_BPS / 10_000, 'silver');
    assertEq(vault.totalValue(goldUser), DEPOSIT + base + DEPOSIT * GOLD_BOOST_BPS / 10_000, 'gold');
    _assertBacked();
  }

  // ---------------------------------------------------------------------------------------------
  // AC: Promotion applies to an existing deposit with no new deposit. Demotion stops boost accrual
  //     and moves no funds.
  // ---------------------------------------------------------------------------------------------

  function test_AC_PromotionAppliesToExistingDepositWithoutNewDeposit() public {
    _depositAs(silverUser, DEPOSIT);
    uint256 walletBefore = usdsc.balanceOf(silverUser);

    // Period 1: still Base, so the engine credits nothing for this address
    _yieldForOneYear();
    assertEq(vault.lastCreditedCycle(silverUser), 0);
    uint256 valueAsBase = vault.totalValue(silverUser);

    // Period 2: promoted to Silver (its first boost cycle). No deposit, no approval, no transaction from the user
    address[] memory one = _one(silverUser);
    uint256[] memory boost = new uint256[](1);
    boost[0] = DEPOSIT * SILVER_BOOST_BPS / 10_000;
    _engineCredit(1, one, boost);

    assertEq(vault.totalValue(silverUser), valueAsBase + boost[0], 'boost applied to existing deposit');
    assertEq(usdsc.balanceOf(silverUser), walletBefore, 'user wallet untouched');
    assertEq(vault.lastCreditedCycle(silverUser), 1);
  }

  function test_AC_DemotionStopsBoostAndMovesNoFunds() public {
    _depositAs(goldUser, DEPOSIT);
    _depositAs(baseUser, DEPOSIT);

    // Cycle 1: Gold, boosted
    address[] memory one = _one(goldUser);
    uint256[] memory boost = new uint256[](1);
    boost[0] = DEPOSIT * GOLD_BOOST_BPS / 10_000;
    _engineCredit(1, one, boost);
    uint256 valueAfterBoost = vault.totalValue(goldUser);

    // Demoted to Base. The engine simply stops including the address; nothing is called for it
    uint256 vaultBal = usdsc.balanceOf(address(vault));
    uint256 wallet = usdsc.balanceOf(goldUser);
    uint256 principal = vault.principal(goldUser);

    // Cycle 2: someone else gets credited, the demoted user does not
    _engineCredit(2, _one(silverUser), boost);

    assertEq(vault.principal(goldUser), principal, 'no boost after demotion');
    assertEq(vault.lastCreditedCycle(goldUser), 1);
    assertEq(usdsc.balanceOf(goldUser), wallet, 'no funds moved to or from the user');
    assertEq(usdsc.balanceOf(address(vault)), vaultBal + boost[0], 'only the new credit was funded');
    // earlier boost is kept and keeps earning base yield like any principal
    assertEq(vault.totalValue(goldUser), valueAfterBoost);
    _yieldForOneYear();
    assertGt(vault.totalValue(goldUser), valueAfterBoost);
    _assertBacked();
  }

  // ---------------------------------------------------------------------------------------------
  // AC: Deposits succeed and accrue the base APY while the off-chain tier service is unavailable.
  // ---------------------------------------------------------------------------------------------

  function test_AC_DepositsAndBaseApyWorkWhileTierServiceIsDown() public {
    // The tier service (boost keeper) never calls the vault in this test
    _depositAs(goldUser, DEPOSIT);
    _yieldForOneYear();
    _depositAs(baseUser, DEPOSIT); // a new deposit while the service is still down
    _yieldForOneYear();

    vm.prank(compoundKeeper);
    vault.compoundMany(_tierUsers());

    assertGt(vault.principal(goldUser), DEPOSIT + DEPOSIT * BASE_BPS / 10_000, 'base APY over two periods');
    assertGt(vault.principal(baseUser), DEPOSIT, 'late depositor earns base APY');
    assertEq(vault.latestCycleId(), 0, 'no boost cycle ran');

    // When the service comes back it catches up from cycle 1; nothing is stuck
    uint256[] memory boost = new uint256[](1);
    boost[0] = 1e6;
    _engineCredit(1, _one(goldUser), boost);
    assertEq(vault.latestCycleId(), 1);
    _assertBacked();
  }

  // ---------------------------------------------------------------------------------------------
  // AC: Yield compounds into principal for all depositors with no user signature and no user gas.
  // ---------------------------------------------------------------------------------------------

  function test_AC_KeeperCompoundsEveryoneWithoutUserAction() public {
    _depositAs(baseUser, DEPOSIT);
    _depositAs(silverUser, DEPOSIT);
    _depositAs(goldUser, DEPOSIT);
    _yieldForOneYear();

    address[] memory users = _tierUsers();
    uint256[] memory expected = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      expected[i] = vault.principal(users[i]) + vault.pendingYield(users[i]);
      assertGt(vault.pendingYield(users[i]), 0);
    }

    // Only the keeper sends a transaction; it signs nothing on the users' behalf
    vm.prank(compoundKeeper);
    vault.compoundMany(users);

    for (uint256 i = 0; i < 3; i++) {
      assertEq(vault.principal(users[i]), expected[i], 'yield folded into principal');
      assertEq(vault.pendingYield(users[i]), 0);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // AC: The keeper role cannot move principal to an external address.
  // ---------------------------------------------------------------------------------------------

  function test_AC_BoostKeeperCannotMovePrincipalOut() public {
    _depositAs(baseUser, DEPOSIT);
    _depositAs(goldUser, DEPOSIT);
    uint256 vaultBal = usdsc.balanceOf(address(vault));
    uint256 baseP = vault.principal(baseUser);

    vm.startPrank(boostKeeper);
    // it has no principal of its own, and withdraw() only ever pays msg.sender
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientPrincipal.selector);
    vault.withdraw(1);
    // every function that moves tokens out is owner-only
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, boostKeeper));
    vault.recoverERC20(address(usdsc), boostKeeper, 1);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, boostKeeper));
    vault.sweepSurplusToTreasury();
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, boostKeeper));
    vault.setTreasury(boostKeeper);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, boostKeeper));
    vault.setBoostKeeper(boostKeeper);
    vm.stopPrank();

    assertEq(usdsc.balanceOf(address(vault)), vaultBal);
    assertEq(vault.principal(baseUser), baseP);
  }

  /// @dev Whatever batch the keeper sends, onBoostCredit only adds principal: no token leaves the
  ///      vault and no address's principal goes down.
  function testFuzz_AC_BoostCreditNeverMovesTokensOutOrReducesPrincipal(
    address a,
    address b,
    uint96 x,
    uint96 y
  ) public {
    vm.assume(a != address(0) && b != address(0) && a != b);
    _depositAs(baseUser, DEPOSIT);
    _depositAs(goldUser, DEPOSIT);

    address[] memory users = new address[](4);
    uint256[] memory amounts = new uint256[](4);
    (users[0], users[1], users[2], users[3]) = (a, b, address(vault), goldUser);
    (amounts[0], amounts[1], amounts[2], amounts[3]) = (x, y, 1e6, 1e6);
    if (a == goldUser || b == goldUser) users[3] = makeAddr('other');

    uint256 total = uint256(x) + y + 2e6;
    usdsc.mint(address(vault), total);
    uint256 vaultBal = usdsc.balanceOf(address(vault));
    uint256[] memory before = new uint256[](4);
    for (uint256 i = 0; i < 4; i++) {
      before[i] = vault.principal(users[i]);
    }
    uint256 baseP = vault.principal(baseUser);

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    assertEq(usdsc.balanceOf(address(vault)), vaultBal, 'tokens left the vault');
    for (uint256 i = 0; i < 4; i++) {
      assertGe(vault.principal(users[i]), before[i], 'principal reduced');
    }
    if (a != baseUser && b != baseUser) assertEq(vault.principal(baseUser), baseP);
    assertEq(vault.principal(address(vault)), 0, 'vault address is never credited');
    _assertBacked();
  }

  // ---------------------------------------------------------------------------------------------
  // AC: Pause blocks deposits and compounding.
  // ---------------------------------------------------------------------------------------------

  function test_AC_PauseBlocksDepositsCompoundingAndBoostCredit() public {
    _depositAs(goldUser, DEPOSIT);
    _yieldForOneYear();
    vm.prank(pauser);
    vault.pause();

    usdsc.mint(baseUser, DEPOSIT);
    vm.startPrank(baseUser);
    usdsc.approve(address(vault), DEPOSIT);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.deposit(DEPOSIT);
    vm.stopPrank();

    vm.startPrank(compoundKeeper);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.compound(goldUser);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.compoundMany(_one(goldUser));
    vm.stopPrank();

    uint256[] memory boost = new uint256[](1);
    boost[0] = 1e6;
    usdsc.mint(address(vault), 1e6);
    vm.prank(boostKeeper);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.onBoostCredit(1, _one(goldUser), boost);

    // nothing changed while paused; after unpause everything works again
    assertEq(vault.principal(goldUser), DEPOSIT);
    vm.prank(pauser);
    vault.unpause();
    vm.prank(compoundKeeper);
    vault.compound(goldUser);
    assertGt(vault.principal(goldUser), DEPOSIT);
  }

  // ---------------------------------------------------------------------------------------------
  // AC: Withdraw returns principal plus accrued yield in one transaction, at any tier.
  // ---------------------------------------------------------------------------------------------

  function test_AC_WithdrawReturnsPrincipalPlusYieldInOneTxAtAnyTier() public {
    _depositAs(baseUser, DEPOSIT);
    _depositAs(silverUser, DEPOSIT);
    _depositAs(goldUser, DEPOSIT);
    _yieldForOneYear();
    _engineCredit(1, _tierUsers(), _tierBoostBps(SILVER_BOOST_BPS, GOLD_BOOST_BPS));
    _yieldForOneYear(); // pending (uncompounded) yield on top, so withdraw must settle it too

    address[] memory users = _tierUsers();
    for (uint256 i = 0; i < 3; i++) {
      address u = users[i];
      uint256 owed = vault.totalValue(u);
      uint256 wallet = usdsc.balanceOf(u);
      assertGt(owed, DEPOSIT);

      vm.prank(u);
      vault.withdraw(owed); // a single call, for principal + base yield + boost

      assertEq(usdsc.balanceOf(u) - wallet, owed);
      assertEq(vault.totalValue(u), 0);
    }
    assertEq(vault.totalPrincipal(), 0);
    _assertBacked();
  }

  // ---------------------------------------------------------------------------------------------
  // AC: Existing depositor balances and accrued yield carry over with no user action.
  // ---------------------------------------------------------------------------------------------

  function test_AC_ExistingBalancesAndYieldCarryOverWithoutUserAction() public {
    (address proxy, ProxyAdmin pa) = _deployV1();
    EarnVaultUpgradeable v1 = EarnVaultUpgradeable(payable(proxy));
    address alice = makeAddr('alice'); // has legacy accrued yield (settled under V1)
    address bob = makeAddr('bob'); // has only pending yield (never settled)

    _depositInto(proxy, alice, DEPOSIT);
    _depositInto(proxy, bob, DEPOSIT);
    _yieldInto(proxy, 1000e6);
    _depositInto(proxy, alice, 1e6); // settles alice under V1: her yield moves to `accrued`
    _yieldInto(proxy, 1000e6);

    uint256 aliceValue = v1.totalValue(alice);
    uint256 bobValue = v1.totalValue(bob);
    uint256 aliceAccrued = v1.accrued(alice);
    assertGt(aliceAccrued, 0);

    _upgradeToV2(proxy, pa);
    EarnVaultV2 v2 = EarnVaultV2(payable(proxy));

    // no user transaction anywhere below
    assertEq(v2.totalValue(alice), aliceValue);
    assertEq(v2.totalValue(bob), bobValue);
    assertEq(v2.accrued(alice), aliceAccrued);

    address[] memory both = new address[](2);
    (both[0], both[1]) = (alice, bob);
    vm.prank(compoundKeeper);
    v2.compoundMany(both);
    assertEq(v2.principal(bob), bobValue, 'bob pending yield now principal');
    assertEq(v2.totalValue(alice), aliceValue);

    // and both can still exit in full
    vm.prank(bob);
    v2.withdraw(bobValue);
    assertEq(usdsc.balanceOf(bob), bobValue);
    uint256 aliceP = v2.principal(alice);
    vm.prank(alice);
    v2.withdraw(aliceP); // withdraw also pays out legacy accrued
    assertEq(usdsc.balanceOf(alice), aliceValue);
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  function _deployV1() internal returns (address proxy, ProxyAdmin pa) {
    TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
      )
    );
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    proxy = address(p);
    pa = ProxyAdmin(address(uint160(uint256(vm.load(proxy, adminSlot)))));
  }

  function _upgradeToV2(address proxy, ProxyAdmin pa) internal {
    address impl = address(new EarnVaultV2());
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(proxy),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, type(uint256).max))
    );
  }

  function _depositAs(address user, uint256 amount) internal {
    _depositInto(address(vault), user, amount);
  }

  function _depositInto(address v, address user, uint256 amount) internal {
    usdsc.mint(user, amount);
    vm.startPrank(user);
    usdsc.approve(v, amount);
    EarnVaultUpgradeable(payable(v)).deposit(amount);
    vm.stopPrank();
  }

  /// @dev The redistributor's part: base APY on the whole vault for one year, one onYield()
  function _yieldForOneYear() internal {
    _yieldInto(address(vault), vault.totalPrincipal() * BASE_BPS / 10_000);
  }

  function _yieldInto(address v, uint256 amount) internal {
    usdsc.mint(v, amount);
    vm.prank(redistributor);
    EarnVaultUpgradeable(payable(v)).onYield(amount);
  }

  /// @dev The off-chain engine's part: fund the batch, then credit it
  function _engineCredit(uint256 cycleId, address[] memory users, uint256[] memory amounts) internal {
    uint256 total;
    for (uint256 i = 0; i < amounts.length; i++) {
      total += amounts[i];
    }
    usdsc.mint(address(vault), total);
    vm.prank(boostKeeper);
    vault.onBoostCredit(cycleId, users, amounts);
  }

  function _tierUsers() internal view returns (address[] memory u) {
    u = new address[](3);
    (u[0], u[1], u[2]) = (baseUser, silverUser, goldUser);
  }

  /// @dev Boost for one year on DEPOSIT; Base gets 0 (skipped by the vault, ZeroAmount)
  function _tierBoostBps(uint256 silverBps, uint256 goldBps) internal pure returns (uint256[] memory a) {
    a = new uint256[](3);
    (a[0], a[1], a[2]) = (0, DEPOSIT * silverBps / 10_000, DEPOSIT * goldBps / 10_000);
  }

  function _one(address u) internal pure returns (address[] memory a) {
    a = new address[](1);
    a[0] = u;
  }

  function _assertBacked() internal view {
    assertGe(usdsc.balanceOf(address(vault)), vault.claimReserve(), 'vault under-reserved');
  }
}
