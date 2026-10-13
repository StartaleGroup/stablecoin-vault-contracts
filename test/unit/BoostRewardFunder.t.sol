// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BoostRewardFunder} from '../../src/distributor/BoostRewardFunder.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'lib/forge-std/src/Test.sol';
import {PausableUpgradeable} from 'lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol';
import {Ownable} from 'lib/openzeppelin-contracts/contracts/access/Ownable.sol';

contract BoostRewardFunderTest is Test {
  BoostRewardFunder funder;
  EarnVaultUpgradeable vault;
  MockUSDSC usdsc;

  address owner = makeAddr('owner'); // the Safe
  address operator = makeAddr('operator'); // the automated bot
  address alice = makeAddr('alice');
  address treasury = makeAddr('treasury');

  uint256 constant DAILY = 50e6;
  uint256 constant MAX_PER_CALL = 100e6;
  uint256 constant MAX_PER_DAY = 150e6;

  function setUp() public {
    usdsc = new MockUSDSC();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      makeAddr('admin'),
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        makeAddr('redistributor'),
        treasury,
        owner,
        owner
      )
    );
    vault = EarnVaultUpgradeable(payable(address(proxy)));
    funder = new BoostRewardFunder(address(vault), address(usdsc), owner, operator, MAX_PER_CALL, MAX_PER_DAY);
    vm.prank(owner);
    vault.setBoostRewardKeeper(address(funder));

    usdsc.mint(alice, 1_000_000e6);
    vm.startPrank(alice);
    usdsc.approve(address(vault), 1_000_000e6);
    vault.deposit(1_000_000e6);
    vm.stopPrank();

    usdsc.mint(operator, 10_000e6);
    vm.prank(operator);
    usdsc.approve(address(funder), type(uint256).max);
  }

  function test_FundsAndIndexesInOneCall() public {
    uint256 vaultBal = usdsc.balanceOf(address(vault));
    vm.prank(operator);
    funder.fund(DAILY);

    assertEq(usdsc.balanceOf(address(vault)), vaultBal + DAILY);
    assertEq(vault.boostClaimReserve(address(usdsc)), DAILY);
    assertEq(vault.getClaimableBoostReward(alice, address(usdsc)), DAILY);
    assertEq(usdsc.balanceOf(address(funder)), 0, 'funder never holds tokens');
  }

  function test_IndexedAmountAlwaysEqualsFundedAmount(uint256 amount) public {
    amount = bound(amount, 1, MAX_PER_CALL);
    uint256 vaultBal = usdsc.balanceOf(address(vault));
    uint256 reserve = vault.boostClaimReserve(address(usdsc));
    vm.prank(operator);
    funder.fund(amount);
    assertEq(usdsc.balanceOf(address(vault)) - vaultBal, vault.boostClaimReserve(address(usdsc)) - reserve);
    assertGe(usdsc.balanceOf(address(vault)), vault.claimReserve() + vault.boostClaimReserve(address(usdsc)));
  }

  function test_OperatorWithoutFundsCannotIndexAnything() public {
    address broke = makeAddr('broke');
    vm.prank(owner);
    funder.setOperator(broke);
    vm.prank(broke);
    vm.expectRevert(bytes('allow')); // allowance is checked before balance
    funder.fund(DAILY);
    assertEq(vault.boostClaimReserve(address(usdsc)), 0);
  }

  function test_OperatorWithTokensButNoApprovalCannotIndex() public {
    vm.prank(operator);
    usdsc.approve(address(funder), 0);
    vm.prank(operator);
    vm.expectRevert(bytes('allow')); // operator has balance but no allowance
    funder.fund(DAILY);
    assertEq(vault.boostClaimReserve(address(usdsc)), 0);
  }

  function test_OnlyOperatorCanFund() public {
    vm.prank(alice);
    vm.expectRevert(BoostRewardFunder.NotOperator.selector);
    funder.fund(DAILY);
  }

  /// @dev The funder is now the vault's keeper; the old key (or anyone) can't call the vault directly
  function test_VaultRejectsDirectCallsOnceFunderIsKeeper() public {
    vm.prank(operator);
    vm.expectRevert(IEarnVaultEventsAndErrors.NotBoostRewardKeeper.selector);
    vault.onBoostReward(address(usdsc), DAILY);
  }

  function test_PerCallCap() public {
    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(BoostRewardFunder.AboveMaxPerCall.selector, MAX_PER_CALL + 1, MAX_PER_CALL));
    funder.fund(MAX_PER_CALL + 1);
  }

  function test_DailyCapResetsNextDay() public {
    vm.startPrank(operator);
    funder.fund(MAX_PER_CALL);
    funder.fund(MAX_PER_DAY - MAX_PER_CALL);
    vm.expectRevert(abi.encodeWithSelector(BoostRewardFunder.AboveDailyLimit.selector, MAX_PER_DAY, 1, MAX_PER_DAY));
    funder.fund(1);

    vm.warp(block.timestamp + 1 days);
    funder.fund(DAILY);
    vm.stopPrank();
    assertEq(funder.fundedToday(), DAILY);
  }

  function test_ZeroCapsPauseTheProgramme() public {
    vm.prank(owner);
    funder.setLimits(0, 0);
    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(BoostRewardFunder.AboveMaxPerCall.selector, DAILY, 0));
    funder.fund(DAILY);
  }

  function test_OnlyOwnerConfigures() public {
    vm.startPrank(operator);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
    funder.setOperator(operator);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
    funder.setLimits(type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function test_TokenMustBeVaultAsset() public {
    MockUSDSC other = new MockUSDSC();
    vm.expectRevert(BoostRewardFunder.TokenIsNotVaultAsset.selector);
    new BoostRewardFunder(address(vault), address(other), owner, operator, 1, 1);
  }

  function test_MaxPerCallCannotExceedMaxPerDay() public {
    vm.expectRevert(BoostRewardFunder.MaxPerCallAboveMaxPerDay.selector);
    new BoostRewardFunder(address(vault), address(usdsc), owner, operator, 2, 1);
    vm.prank(owner);
    vm.expectRevert(BoostRewardFunder.MaxPerCallAboveMaxPerDay.selector);
    funder.setLimits(2, 1);
  }

  function test_ZeroAmountAndZeroAddressRejected() public {
    vm.prank(operator);
    vm.expectRevert(BoostRewardFunder.ZeroAmount.selector);
    funder.fund(0);

    vm.prank(owner);
    vm.expectRevert(BoostRewardFunder.ZeroAddress.selector);
    funder.setOperator(address(0));

    vm.expectRevert(BoostRewardFunder.ZeroAddress.selector);
    new BoostRewardFunder(address(0), address(usdsc), owner, operator, 1, 1);
  }

  function test_RenounceOwnershipDisabled() public {
    vm.prank(owner);
    vm.expectRevert(BoostRewardFunder.RenounceOwnershipDisabled.selector);
    funder.renounceOwnership();
    assertEq(funder.owner(), owner);
  }

  function test_FundRevertsWhileVaultPaused() public {
    vm.prank(owner);
    vault.pause();
    vm.prank(operator);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    funder.fund(DAILY);
    assertEq(vault.boostClaimReserve(address(usdsc)), 0);
  }

  function test_FundWithNoDepositorsGoesToTreasury() public {
    vm.prank(alice);
    vault.withdraw(1_000_000e6);
    uint256 treasuryBal = usdsc.balanceOf(treasury);

    vm.prank(operator);
    funder.fund(DAILY);

    assertEq(usdsc.balanceOf(treasury), treasuryBal + DAILY);
    assertEq(vault.boostClaimReserve(address(usdsc)), 0);
  }

  function test_LoweringDailyCapBelowFundedTodayBlocksUntilNextDay() public {
    vm.prank(operator);
    funder.fund(100e6);
    vm.prank(owner);
    funder.setLimits(50e6, 50e6);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(BoostRewardFunder.AboveDailyLimit.selector, 100e6, 1, 50e6));
    funder.fund(1);

    vm.warp(block.timestamp + 1 days);
    vm.prank(operator);
    funder.fund(1);
    assertEq(funder.fundedToday(), 1);
  }
}
