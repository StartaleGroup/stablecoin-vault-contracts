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

/// @title EarnVaultV2.withdrawAll()
/// @notice Builds V1 state (a legacy `accrued` balance and an unsettled backlog), upgrades the same
///         proxy to EarnVaultV2, and checks that withdrawAll() closes a position completely -
///         principal, yield folded in by its own settlement, legacy accrued and boost rewards -
///         where withdraw(principal(user)) quoted beforehand leaves the folded yield behind.
contract EarnVaultV2WithdrawAllTest is Test {
  EarnVaultV2 vault;
  MockUSDSC usdsc;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address redistributor = makeAddr('redistributor');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address operator = makeAddr('operator'); // boost reward keeper

  address legacyUser = makeAddr('legacyUser'); // pre-upgrade `accrued` balance
  address passiveUser = makeAddr('passiveUser'); // never settled before the upgrade
  address alice = makeAddr('alice');
  address bob = makeAddr('bob');

  function setUp() public {
    usdsc = new MockUSDSC();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
      )
    );
    EarnVaultUpgradeable v1 = EarnVaultUpgradeable(payable(address(proxy)));

    address[4] memory actors = [legacyUser, passiveUser, alice, bob];
    for (uint256 i = 0; i < actors.length; i++) {
      usdsc.mint(actors[i], 100_000e6);
      vm.prank(actors[i]);
      usdsc.approve(address(proxy), type(uint256).max);
    }

    vm.prank(legacyUser);
    v1.deposit(1000e6);
    _yield(address(v1), 300e6);
    vm.prank(legacyUser);
    v1.deposit(1e6); // settles under V1: owed moves into `accrued`
    require(v1.claimable(legacyUser) > 0, 'setup: no legacy accrued');

    vm.prank(passiveUser);
    v1.deposit(2000e6);
    _yield(address(v1), 400e6);

    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    ProxyAdmin proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), adminSlot)))));
    address v2 = address(new EarnVaultV2());
    bytes memory init = abi.encodeCall(EarnVaultV2.initializeV2, (makeAddr('boostKeeper'), type(uint256).max));
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), v2, init);
    vault = EarnVaultV2(payable(address(proxy)));
  }

  // ---------------------------------------------------------------------------------------------
  // The residual withdrawAll() exists for
  // ---------------------------------------------------------------------------------------------

  /// @dev withdraw(principal(user)) settles first, folding pending yield into principal, then
  ///      withdraws only the quoted amount - the folded yield stays behind as principal
  function test_WithdrawQuotedPrincipal_LeavesFoldedYieldBehind() public {
    _deposit(alice, 1000e6);
    _yield(address(vault), 100e6);
    uint256 pending = vault.pendingYield(alice);
    assertGt(pending, 0);

    uint256 quoted = vault.principal(alice);
    vm.prank(alice);
    vault.withdraw(quoted);
    assertEq(vault.principal(alice), pending, 'folded yield left as principal');
  }

  // ---------------------------------------------------------------------------------------------
  // withdrawAll(): positive
  // ---------------------------------------------------------------------------------------------

  function test_WithdrawAll_ClosesPositionIncludingFoldedYield() public {
    _deposit(alice, 1000e6);
    _yield(address(vault), 100e6);
    uint256 expected = vault.principal(alice) + vault.pendingYield(alice);
    uint256 totalBefore = vault.totalPrincipal();
    uint256 reserveBefore = vault.claimReserve();
    uint256 balBefore = usdsc.balanceOf(alice);

    vm.expectEmit(true, false, false, true, address(vault));
    emit IEarnVaultEventsAndErrors.Withdraw(alice, expected);
    vm.prank(alice);
    vault.withdrawAll();

    assertEq(usdsc.balanceOf(alice) - balBefore, expected, 'paid principal + folded yield');
    assertEq(vault.principal(alice), 0);
    assertEq(vault.pendingYield(alice), 0);
    assertEq(vault.totalValue(alice), 0);
    // the folded yield joins totalPrincipal and leaves again with the rest: net, alice's deposit
    assertEq(vault.totalPrincipal(), totalBefore - 1000e6);
    assertEq(vault.claimReserve(), reserveBefore - expected);
    _assertSolvent();
  }

  /// @dev A V1 depositor never settled before the upgrade: their whole backlog folds in and is paid
  function test_WithdrawAll_PassiveV1UserGetsBacklog() public {
    uint256 expected = vault.totalValue(passiveUser);
    assertGt(expected, 2000e6, 'backlog present');
    uint256 balBefore = usdsc.balanceOf(passiveUser);

    vm.prank(passiveUser);
    vault.withdrawAll();

    assertEq(usdsc.balanceOf(passiveUser) - balBefore, expected);
    assertEq(vault.totalValue(passiveUser), 0);
    _assertSolvent();
  }

  /// @dev Legacy `accrued` and boost rewards are paid out in the same call, exactly as withdraw() does
  function test_WithdrawAll_AlsoPaysLegacyAccruedAndBoost() public {
    usdsc.mint(address(vault), 50e6);
    vm.prank(operator);
    vault.onBoostReward(address(usdsc), 50e6);

    uint256 accrued = vault.claimable(legacyUser);
    uint256 boost = vault.getClaimableBoostReward(legacyUser, address(usdsc));
    assertGt(accrued, 0);
    assertGt(boost, 0);
    uint256 expected = vault.totalValue(legacyUser) + boost;
    uint256 balBefore = usdsc.balanceOf(legacyUser);

    vm.prank(legacyUser);
    vault.withdrawAll();

    assertEq(usdsc.balanceOf(legacyUser) - balBefore, expected, 'principal + folded yield + accrued + boost');
    assertEq(vault.totalValue(legacyUser), 0);
    assertEq(vault.claimable(legacyUser), 0);
    assertEq(vault.getClaimableBoostReward(legacyUser, address(usdsc)), 0);
    _assertSolvent();
  }

  /// @dev Same outcome as withdraw() of the post-settlement principal, for an identical position
  function test_WithdrawAll_MatchesWithdrawOfSettledPrincipal() public {
    _deposit(alice, 1000e6);
    _deposit(bob, 1000e6);
    _yield(address(vault), 100e6);

    uint256 aliceBefore = usdsc.balanceOf(alice);
    uint256 bobBefore = usdsc.balanceOf(bob);
    vm.prank(alice);
    vault.withdrawAll();
    uint256 settled = vault.principal(bob) + vault.pendingYield(bob);
    vm.prank(bob);
    vault.withdraw(settled);

    assertEq(usdsc.balanceOf(alice) - aliceBefore, usdsc.balanceOf(bob) - bobBefore);
    assertEq(vault.principal(alice), 0);
    assertEq(vault.principal(bob), 0);
  }

  /// @dev Yield indexed between quoting and executing is still withdrawn, so no residual remains
  function test_WithdrawAll_IncludesYieldIndexedAfterQuote() public {
    _deposit(alice, 1000e6);
    uint256 quoted = vault.totalValue(alice);
    _yield(address(vault), 100e6); // lands before the user's transaction
    uint256 balBefore = usdsc.balanceOf(alice);
    vm.prank(alice);
    vault.withdrawAll();
    assertGt(usdsc.balanceOf(alice) - balBefore, quoted);
    assertEq(vault.totalValue(alice), 0);
  }

  // ---------------------------------------------------------------------------------------------
  // withdrawAll(): negative
  // ---------------------------------------------------------------------------------------------

  function test_WithdrawAll_NoPrincipalReverts() public {
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.ZeroAmount.selector);
    vault.withdrawAll();
  }

  function test_WithdrawAll_AfterFullExitReverts() public {
    _deposit(alice, 1000e6);
    vm.startPrank(alice);
    vault.withdrawAll();
    vm.expectRevert(IEarnVaultEventsAndErrors.ZeroAmount.selector);
    vault.withdrawAll();
    vm.stopPrank();
  }

  function test_WithdrawAll_BlacklistedReverts() public {
    _deposit(alice, 1000e6);
    vm.prank(owner);
    vault.setBlacklisted(alice, true);
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.withdrawAll();
  }

  function test_WithdrawAll_PausedReverts() public {
    _deposit(alice, 1000e6);
    vm.prank(pauser);
    vault.pause();
    vm.prank(alice);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.withdrawAll();
  }

  /// @dev Only the caller's own position is touched
  function test_WithdrawAll_LeavesOtherPositionsUntouched() public {
    _deposit(alice, 1000e6);
    _deposit(bob, 500e6);
    _yield(address(vault), 100e6);
    uint256 bobValue = vault.totalValue(bob);
    vm.prank(alice);
    vault.withdrawAll();
    assertEq(vault.totalValue(bob), bobValue);
  }

  // ---------------------------------------------------------------------------------------------
  // withdraw() is unchanged by the shared body
  // ---------------------------------------------------------------------------------------------

  function test_Withdraw_ZeroStillReverts() public {
    _deposit(alice, 1000e6);
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.ZeroAmount.selector);
    vault.withdraw(0);
  }

  /// @dev The blacklist check still comes before the zero-amount check
  function test_Withdraw_BlacklistedZeroStillRevertsBlacklisted() public {
    vm.prank(owner);
    vault.setBlacklisted(alice, true);
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.withdraw(0);
  }

  function test_Withdraw_MoreThanSettledPrincipalStillReverts() public {
    _deposit(alice, 1000e6);
    _yield(address(vault), 100e6);
    uint256 over = vault.principal(alice) + vault.pendingYield(alice) + 1;
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientPrincipal.selector);
    vault.withdraw(over);
  }

  function test_Withdraw_MaxUintIsNotAFullExit() public {
    _deposit(alice, 1000e6);
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientPrincipal.selector);
    vault.withdraw(type(uint256).max);
  }

  // ---------------------------------------------------------------------------------------------

  function _deposit(address user, uint256 amount) internal {
    vm.prank(user);
    vault.deposit(amount);
  }

  function _yield(address v, uint256 amount) internal {
    usdsc.mint(v, amount);
    vm.prank(redistributor);
    EarnVaultUpgradeable(payable(v)).onYield(amount);
  }

  function _assertSolvent() internal view {
    assertGe(
      usdsc.balanceOf(address(vault)),
      vault.claimReserve() + vault.boostClaimReserve(address(usdsc)),
      'vault under-reserved'
    );
  }
}
