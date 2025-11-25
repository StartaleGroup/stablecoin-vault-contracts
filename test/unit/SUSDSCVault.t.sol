// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {USDSC} from '../../src/coin/mock/USDSC.sol';
import {ISUSDSCVaultEventsAndErrors} from '../../src/interfaces/vaults/4626/ISUSDSCVaultEventsAndErrors.sol';
import {SUSDSCVault} from '../../src/vaults/4626/SUSDSCVault.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';

contract UnitSUSDSCVault is Test {
  SUSDSCVault internal vault;
  USDSC internal usdsc;
  MockM internal mToken;
  MockSwapFacility internal swapFacility;
  ProxyAdmin internal proxyAdmin;

  address internal admin = makeAddr('admin');
  address internal pauser = makeAddr('pauser');
  address internal yieldRecipient = makeAddr('yieldRecipient');
  address internal yieldDistributor = makeAddr('yieldDistributor');

  address internal depositorA = makeAddr('depositorA');
  address internal depositorB = makeAddr('depositorB');
  address internal depositorC = makeAddr('depositorC');

  uint256 internal constant INITIAL_USDSC_AMOUNT = 10_000 ether;
  uint256 internal constant DEPOSIT_AMOUNT = 1000 ether;

  event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(
    address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
  );

  function setUp() external {
    _deployContracts();
    _setupUsers();
  }

  function _deployContracts() internal {
    mToken = new MockM();
    swapFacility = new MockSwapFacility();
    proxyAdmin = new ProxyAdmin(admin);

    USDSC implementation = new USDSC(address(mToken), address(swapFacility));
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(implementation),
      address(proxyAdmin),
      abi.encodeWithSelector(USDSC.initialize.selector, 'USDSC', 'USDSC', admin, yieldRecipient)
    );
    usdsc = USDSC(address(proxy));

    vault = new SUSDSCVault(IERC20(address(usdsc)), admin, pauser);
  }

  function _setupUsers() internal {
    deal(address(mToken), depositorA, INITIAL_USDSC_AMOUNT);
    deal(address(mToken), depositorB, INITIAL_USDSC_AMOUNT);
    deal(address(mToken), depositorC, INITIAL_USDSC_AMOUNT);
    deal(address(mToken), yieldDistributor, INITIAL_USDSC_AMOUNT);

    vm.startPrank(depositorA);
    bool success = mToken.transfer(address(swapFacility), INITIAL_USDSC_AMOUNT);
    require(success, 'Transfer failed');
    vm.stopPrank();

    vm.startPrank(address(swapFacility));
    usdsc.wrap(depositorA, INITIAL_USDSC_AMOUNT);
    vm.stopPrank();

    vm.startPrank(depositorB);
    success = mToken.transfer(address(swapFacility), INITIAL_USDSC_AMOUNT);
    require(success, 'Transfer failed');
    vm.stopPrank();

    vm.startPrank(address(swapFacility));
    usdsc.wrap(depositorB, INITIAL_USDSC_AMOUNT);
    vm.stopPrank();

    vm.startPrank(depositorC);
    success = mToken.transfer(address(swapFacility), INITIAL_USDSC_AMOUNT);
    require(success, 'Transfer failed');
    vm.stopPrank();

    vm.startPrank(address(swapFacility));
    usdsc.wrap(depositorC, INITIAL_USDSC_AMOUNT);
    vm.stopPrank();

    vm.startPrank(yieldDistributor);
    success = mToken.transfer(address(swapFacility), INITIAL_USDSC_AMOUNT);
    require(success, 'Transfer failed');
    vm.stopPrank();

    vm.startPrank(address(swapFacility));
    usdsc.wrap(yieldDistributor, INITIAL_USDSC_AMOUNT);
    vm.stopPrank();
  }

  function test_constructor() external view {
    assertEq(vault.name(), 'Staked Startale USD');
    assertEq(vault.symbol(), 'sUSDSC');
    assertEq(address(vault.asset()), address(usdsc));
    assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
  }

  function test_deposit_single_user() external {
    vm.startPrank(depositorA);
    usdsc.approve(address(vault), DEPOSIT_AMOUNT);

    uint256 expectedShares = vault.previewDeposit(DEPOSIT_AMOUNT);

    vm.expectEmit(true, true, false, true);
    emit Deposit(depositorA, depositorA, DEPOSIT_AMOUNT, expectedShares);

    uint256 shares = vault.deposit(DEPOSIT_AMOUNT, depositorA);
    vm.stopPrank();

    assertEq(shares, expectedShares);
    assertEq(vault.balanceOf(depositorA), shares);
    assertEq(vault.totalSupply(), shares);
    assertEq(usdsc.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
  }

  function test_deposit_multiple_users() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    _depositFor(depositorB, DEPOSIT_AMOUNT);
    _depositFor(depositorC, DEPOSIT_AMOUNT);

    assertEq(vault.balanceOf(depositorA), DEPOSIT_AMOUNT);
    assertEq(vault.balanceOf(depositorB), DEPOSIT_AMOUNT);
    assertEq(vault.balanceOf(depositorC), DEPOSIT_AMOUNT);
    assertEq(vault.totalSupply(), DEPOSIT_AMOUNT * 3);
    assertEq(usdsc.balanceOf(address(vault)), DEPOSIT_AMOUNT * 3);
  }

  function test_yield_distribution_increases_pps() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    _depositFor(depositorB, DEPOSIT_AMOUNT);

    uint256 initialPPS = vault.convertToAssets(1 ether);
    uint256 yieldAmount = 500 ether;

    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), yieldAmount);
    require(success, 'Transfer failed');
    vm.stopPrank();

    uint256 newPPS = vault.convertToAssets(1 ether);
    assertGt(newPPS, initialPPS);
    assertEq(vault.totalAssets(), DEPOSIT_AMOUNT * 2 + yieldAmount);
  }

  function test_redeem_after_yield_distribution() external {
    uint256 depositAmount = DEPOSIT_AMOUNT;

    _depositFor(depositorA, depositAmount);
    uint256 initialShares = vault.balanceOf(depositorA);

    uint256 yieldAmount = 200 ether;
    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), yieldAmount);
    require(success, 'Transfer failed');
    vm.stopPrank();

    vm.startPrank(depositorA);
    uint256 assetsReceived = vault.redeem(initialShares, depositorA, depositorA);
    vm.stopPrank();

    assertGt(assetsReceived, depositAmount);
    assertEq(vault.balanceOf(depositorA), 0);
  }

  function test_multiple_users_yield_distribution_scenario() external {
    _depositFor(depositorA, 1000 ether);
    _depositFor(depositorB, 2000 ether);
    _depositFor(depositorC, 1500 ether);

    uint256 totalDeposited = 4500 ether;
    uint256 yieldAmount = 450 ether; // let's say 10% yield

    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), yieldAmount);
    require(success, 'Transfer failed');
    vm.stopPrank();

    assertEq(vault.totalAssets(), totalDeposited + yieldAmount);

    uint256 sharesA = vault.balanceOf(depositorA);
    uint256 sharesB = vault.balanceOf(depositorB);
    uint256 sharesC = vault.balanceOf(depositorC);

    vm.startPrank(depositorA);
    uint256 assetsA = vault.redeem(sharesA, depositorA, depositorA);
    vm.stopPrank();

    vm.startPrank(depositorB);
    uint256 assetsB = vault.redeem(sharesB, depositorB, depositorB);
    vm.stopPrank();

    vm.startPrank(depositorC);
    uint256 assetsC = vault.redeem(sharesC, depositorC, depositorC);
    vm.stopPrank();

    assertGt(assetsA, 1000 ether);
    assertGt(assetsB, 2000 ether);
    assertGt(assetsC, 1500 ether);

    assertApproxEqAbs(assetsA + assetsB + assetsC, totalDeposited + yieldAmount, 3);
  }

  function test_mint_functionality() external {
    uint256 sharesToMint = 1000 ether;
    uint256 assetsRequired = vault.previewMint(sharesToMint);

    vm.startPrank(depositorA);
    usdsc.approve(address(vault), assetsRequired);
    uint256 assets = vault.mint(sharesToMint, depositorA);
    vm.stopPrank();

    assertEq(assets, assetsRequired);
    assertEq(vault.balanceOf(depositorA), sharesToMint);
  }

  function test_withdraw_functionality() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);

    uint256 withdrawAmount = 500 ether;
    uint256 expectedShares = vault.previewWithdraw(withdrawAmount);

    vm.startPrank(depositorA);
    uint256 shares = vault.withdraw(withdrawAmount, depositorA, depositorA);
    vm.stopPrank();

    assertEq(shares, expectedShares);
    assertEq(usdsc.balanceOf(depositorA), INITIAL_USDSC_AMOUNT - DEPOSIT_AMOUNT + withdrawAmount);
  }

  function test_pause_functionality() external {
    vm.prank(pauser);
    vault.pause(true);

    vm.startPrank(depositorA);
    usdsc.approve(address(vault), DEPOSIT_AMOUNT);
    vm.expectRevert();
    vault.deposit(DEPOSIT_AMOUNT, depositorA);
    vm.stopPrank();

    vm.prank(pauser);
    vault.pause(false);

    vm.startPrank(depositorA);
    vault.deposit(DEPOSIT_AMOUNT, depositorA);
    vm.stopPrank();

    assertEq(vault.balanceOf(depositorA), DEPOSIT_AMOUNT);
  }

  function test_revert_deposit_when_paused() external {
    vm.prank(pauser);
    vault.pause(true);

    vm.startPrank(depositorA);
    usdsc.approve(address(vault), DEPOSIT_AMOUNT);
    vm.expectRevert();
    vault.deposit(DEPOSIT_AMOUNT, depositorA);
    vm.stopPrank();
  }

  function test_revert_mint_when_paused() external {
    vm.prank(pauser);
    vault.pause(true);

    vm.startPrank(depositorA);
    usdsc.approve(address(vault), DEPOSIT_AMOUNT);
    vm.expectRevert();
    vault.mint(DEPOSIT_AMOUNT, depositorA);
    vm.stopPrank();
  }

  function test_revert_withdraw_when_paused() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);

    vm.prank(pauser);
    vault.pause(true);

    vm.startPrank(depositorA);
    vm.expectRevert();
    vault.withdraw(500 ether, depositorA, depositorA);
    vm.stopPrank();
  }

  function test_revert_redeem_when_paused() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);

    vm.prank(pauser);
    vault.pause(true);

    vm.startPrank(depositorA);
    vm.expectRevert();
    vault.redeem(500 ether, depositorA, depositorA);
    vm.stopPrank();
  }

  function test_revert_pause_unauthorized() external {
    vm.prank(depositorA);
    vm.expectRevert();
    vault.pause(true);
  }

  function test_revert_deposit_insufficient_allowance() external {
    vm.startPrank(depositorA);
    usdsc.approve(address(vault), DEPOSIT_AMOUNT - 1);
    vm.expectRevert();
    vault.deposit(DEPOSIT_AMOUNT, depositorA);
    vm.stopPrank();
  }

  function test_revert_deposit_insufficient_balance() external {
    address poorUser = makeAddr('poorUser');

    vm.startPrank(poorUser);
    usdsc.approve(address(vault), DEPOSIT_AMOUNT);
    vm.expectRevert();
    vault.deposit(DEPOSIT_AMOUNT, poorUser);
    vm.stopPrank();
  }

  function test_revert_withdraw_insufficient_shares() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);

    vm.startPrank(depositorA);
    vm.expectRevert();
    vault.withdraw(DEPOSIT_AMOUNT + 1, depositorA, depositorA);
    vm.stopPrank();
  }

  function test_revert_redeem_insufficient_shares() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);

    vm.startPrank(depositorA);
    vm.expectRevert();
    vault.redeem(DEPOSIT_AMOUNT + 1, depositorA, depositorA);
    vm.stopPrank();
  }

  function test_yield_distribution_proportional_gains() external {
    _depositFor(depositorA, 1000 ether);
    _depositFor(depositorB, 3000 ether);

    uint256 sharesA = vault.balanceOf(depositorA);
    uint256 sharesB = vault.balanceOf(depositorB);

    uint256 yieldAmount = 800 ether;
    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), yieldAmount);
    require(success, 'Transfer failed');
    vm.stopPrank();

    uint256 assetsA = vault.convertToAssets(sharesA);
    uint256 assetsB = vault.convertToAssets(sharesB);

    assertApproxEqRel(assetsA, 1200 ether, 1e16); // ~1200 (1000 + 200 yield)
    assertApproxEqRel(assetsB, 3600 ether, 1e16); // ~3600 (3000 + 600 yield)
  }

  function test_consecutive_yield_distributions() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);

    uint256 initialShares = vault.balanceOf(depositorA);

    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), 100 ether);
    require(success, 'Transfer failed');
    vm.stopPrank();

    uint256 assetsAfterFirstYield = vault.convertToAssets(initialShares);

    vm.startPrank(yieldDistributor);
    success = usdsc.transfer(address(vault), 150 ether);
    require(success, 'Transfer failed');
    vm.stopPrank();

    uint256 assetsAfterSecondYield = vault.convertToAssets(initialShares);

    assertGt(assetsAfterFirstYield, DEPOSIT_AMOUNT);
    assertGt(assetsAfterSecondYield, assetsAfterFirstYield);
    assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + 250 ether);
  }

  function test_deposit_after_yield_reduces_shares() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 sharesA = vault.balanceOf(depositorA);

    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), 500 ether);
    require(success, 'Transfer failed');
    vm.stopPrank();

    _depositFor(depositorB, DEPOSIT_AMOUNT);
    uint256 sharesB = vault.balanceOf(depositorB);

    assertLt(sharesB, sharesA);
    assertEq(sharesA, DEPOSIT_AMOUNT);
  }

  function test_zero_deposit_allowed() external {
    vm.startPrank(depositorA);
    usdsc.approve(address(vault), 0);
    uint256 shares = vault.deposit(0, depositorA);
    vm.stopPrank();

    assertEq(shares, 0);
    assertEq(vault.balanceOf(depositorA), 0);
  }

  function test_zero_mint_allowed() external {
    vm.startPrank(depositorA);
    uint256 assets = vault.mint(0, depositorA);
    vm.stopPrank();

    assertEq(assets, 0);
    assertEq(vault.balanceOf(depositorA), 0);
  }

  function test_maxDeposit_maxMint() external view {
    assertEq(vault.maxDeposit(depositorA), type(uint256).max);
    assertEq(vault.maxMint(depositorA), type(uint256).max);
  }

  function test_maxWithdraw_maxRedeem() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);

    assertEq(vault.maxWithdraw(depositorA), vault.convertToAssets(vault.balanceOf(depositorA)));
    assertEq(vault.maxRedeem(depositorA), vault.balanceOf(depositorA));
  }

  function test_previewFunctions_consistency() external view {
    uint256 assets = 1000 ether;
    uint256 shares = 1000 ether;

    assertEq(vault.previewDeposit(assets), vault.convertToShares(assets));
    assertEq(vault.previewMint(shares), vault.convertToAssets(shares));
    assertEq(vault.previewWithdraw(assets), vault.convertToShares(assets));
    assertEq(vault.previewRedeem(shares), vault.convertToAssets(shares));
  }

  function test_access_control_roles() external view {
    assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
    assertFalse(vault.hasRole(vault.PAUSER_ROLE(), depositorA));
    assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), depositorA));
  }

  // Todo: review in main implementation and base (according to USDSC decimals in soneium deployment)
  function test_decimals() external view {
    assertEq(vault.decimals(), usdsc.decimals());
  }

  function test_redeem_partial_shares() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 totalShares = vault.balanceOf(depositorA);
    uint256 sharesToRedeem = totalShares / 2;

    uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
    uint256 initialBalance = usdsc.balanceOf(depositorA);

    vm.expectEmit(true, true, true, true);
    emit Withdraw(depositorA, depositorA, depositorA, expectedAssets, sharesToRedeem);

    vm.startPrank(depositorA);
    uint256 assetsReceived = vault.redeem(sharesToRedeem, depositorA, depositorA);
    vm.stopPrank();

    assertEq(assetsReceived, expectedAssets);
    assertEq(vault.balanceOf(depositorA), totalShares - sharesToRedeem);
    assertEq(usdsc.balanceOf(depositorA), initialBalance + assetsReceived);
  }

  function test_redeem_all_shares() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 totalShares = vault.balanceOf(depositorA);

    uint256 expectedAssets = vault.previewRedeem(totalShares);
    uint256 initialBalance = usdsc.balanceOf(depositorA);

    vm.startPrank(depositorA);
    uint256 assetsReceived = vault.redeem(totalShares, depositorA, depositorA);
    vm.stopPrank();

    assertEq(assetsReceived, expectedAssets);
    assertEq(vault.balanceOf(depositorA), 0);
    assertEq(usdsc.balanceOf(depositorA), initialBalance + assetsReceived);
    assertEq(vault.totalSupply(), 0);
    assertEq(vault.totalAssets(), 0);
  }

  function test_redeem_to_different_receiver() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 sharesToRedeem = vault.balanceOf(depositorA);

    uint256 receiverInitialBalance = usdsc.balanceOf(depositorB);
    uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);

    vm.startPrank(depositorA);
    uint256 assetsReceived = vault.redeem(sharesToRedeem, depositorB, depositorA);
    vm.stopPrank();

    assertEq(assetsReceived, expectedAssets);
    assertEq(vault.balanceOf(depositorA), 0);
    assertEq(usdsc.balanceOf(depositorB), receiverInitialBalance + assetsReceived);
  }

  function test_redeem_with_approval() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 sharesToRedeem = vault.balanceOf(depositorA);

    vm.prank(depositorA);
    vault.approve(depositorB, sharesToRedeem);

    uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
    uint256 receiverInitialBalance = usdsc.balanceOf(depositorC);

    vm.startPrank(depositorB);
    uint256 assetsReceived = vault.redeem(sharesToRedeem, depositorC, depositorA);
    vm.stopPrank();

    assertEq(assetsReceived, expectedAssets);
    assertEq(vault.balanceOf(depositorA), 0);
    assertEq(usdsc.balanceOf(depositorC), receiverInitialBalance + assetsReceived);
    assertEq(vault.allowance(depositorA, depositorB), 0);
  }

  function test_redeem_multiple_times_same_user() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 totalShares = vault.balanceOf(depositorA);
    uint256 firstRedeemShares = totalShares / 3;
    uint256 secondRedeemShares = totalShares / 3;

    vm.startPrank(depositorA);
    uint256 firstAssets = vault.redeem(firstRedeemShares, depositorA, depositorA);
    uint256 secondAssets = vault.redeem(secondRedeemShares, depositorA, depositorA);
    vm.stopPrank();

    uint256 remainingShares = vault.balanceOf(depositorA);
    assertEq(remainingShares, totalShares - firstRedeemShares - secondRedeemShares);
    assertGt(firstAssets, 0);
    assertGt(secondAssets, 0);
    assertApproxEqAbs(firstAssets, secondAssets, 1);
  }

  function test_redeem_with_yield_between_deposits() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 sharesA = vault.balanceOf(depositorA);

    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), 300 ether);
    require(success, 'Transfer failed');
    vm.stopPrank();

    _depositFor(depositorB, DEPOSIT_AMOUNT);
    uint256 sharesB = vault.balanceOf(depositorB);

    vm.startPrank(depositorA);
    uint256 assetsA = vault.redeem(sharesA, depositorA, depositorA);
    vm.stopPrank();

    vm.startPrank(depositorB);
    uint256 assetsB = vault.redeem(sharesB, depositorB, depositorB);
    vm.stopPrank();

    assertGt(assetsA, DEPOSIT_AMOUNT);
    assertApproxEqAbs(assetsB, DEPOSIT_AMOUNT, 1);
    assertLt(sharesB, sharesA);
  }

  function test_redeem_precision() external {
    uint256 smallDeposit = 1 ether;
    _depositFor(depositorA, smallDeposit);

    uint256 shares = vault.balanceOf(depositorA);
    uint256 expectedAssets = vault.previewRedeem(shares);

    vm.startPrank(depositorA);
    uint256 actualAssets = vault.redeem(shares, depositorA, depositorA);
    vm.stopPrank();

    assertEq(actualAssets, expectedAssets);
    assertEq(actualAssets, smallDeposit);
  }

  function test_redeem_after_multiple_yield_distributions() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 initialShares = vault.balanceOf(depositorA);

    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), 100 ether);
    require(success, 'Transfer failed');
    success = usdsc.transfer(address(vault), 150 ether);
    require(success, 'Transfer failed');
    success = usdsc.transfer(address(vault), 75 ether);
    require(success, 'Transfer failed');
    vm.stopPrank();

    uint256 expectedAssets = vault.previewRedeem(initialShares);

    vm.startPrank(depositorA);
    uint256 assetsReceived = vault.redeem(initialShares, depositorA, depositorA);
    vm.stopPrank();

    assertEq(assetsReceived, expectedAssets);
    assertApproxEqAbs(assetsReceived, DEPOSIT_AMOUNT + 325 ether, 1);
    assertEq(vault.balanceOf(depositorA), 0);
  }

  function test_redeem_consistency_with_convert_functions() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 shares = vault.balanceOf(depositorA);

    uint256 previewAssets = vault.previewRedeem(shares);
    uint256 convertAssets = vault.convertToAssets(shares);

    assertEq(previewAssets, convertAssets);

    vm.startPrank(depositorA);
    uint256 actualAssets = vault.redeem(shares, depositorA, depositorA);
    vm.stopPrank();

    assertEq(actualAssets, previewAssets);
  }

  function test_high_pps_yield_arrival_reduces_mint_shares() external {
    _depositFor(depositorA, DEPOSIT_AMOUNT);

    uint256 largeYieldAmount = 2000 ether;
    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), largeYieldAmount);
    require(success, 'Transfer failed');
    vm.stopPrank();

    uint256 depositAmountForB = DEPOSIT_AMOUNT;
    uint256 expectedSharesForB = vault.previewDeposit(depositAmountForB);

    vm.startPrank(depositorB);
    usdsc.approve(address(vault), depositAmountForB);
    uint256 actualSharesForB = vault.deposit(depositAmountForB, depositorB);
    vm.stopPrank();

    assertEq(actualSharesForB, expectedSharesForB);
    assertLt(actualSharesForB, depositAmountForB);
    assertLt(vault.balanceOf(depositorB), vault.balanceOf(depositorA));
  }

  function test_zero_total_supply_yield_distribution() external {
    // Test scenario: yield arrives when total supply is zero
    // This tests edge case behavior when there are no shareholders

    uint256 yieldAmount = 1000 ether;

    // Verify initial state - no shares, no assets
    assertEq(vault.totalSupply(), 0);
    assertEq(vault.totalAssets(), 0);

    // Send yield to vault when there are no shareholders
    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), yieldAmount);
    require(success, 'Transfer failed');
    vm.stopPrank();

    // Vault should have assets but no shares
    assertEq(vault.totalAssets(), yieldAmount);
    assertEq(vault.totalSupply(), 0);

    // First depositor gets reduced shares due to ERC4626 inflation protection
    uint256 depositAmount = 500 ether;

    vm.startPrank(depositorA);
    usdsc.approve(address(vault), depositAmount);
    uint256 shares = vault.deposit(depositAmount, depositorA);
    vm.stopPrank();

    // Due to ERC4626 inflation protection, when assets exist but totalSupply is 0:
    // shares = assets * (totalSupply + 10^decimalsOffset) / (totalAssets + 1)
    // shares = 500 * (0 + 1) / (1000 + 1) = 500/1001 ≈ 0.499 (rounds down to 0)
    // This prevents inflation attacks by making early deposits less favorable
    uint256 expectedShares = (depositAmount * 1) / (yieldAmount + 1); // Should be 0 due to rounding
    assertEq(shares, expectedShares);
    assertEq(vault.balanceOf(depositorA), shares);

    // Total assets should include both deposit and previous yield
    assertEq(vault.totalAssets(), depositAmount + yieldAmount);

    // If shares is 0, depositor gets nothing back (this is the inflation protection working)
    if (shares > 0) {
      uint256 expectedAssets = vault.previewRedeem(shares);
      vm.startPrank(depositorA);
      uint256 assetsReceived = vault.redeem(shares, depositorA, depositorA);
      vm.stopPrank();

      assertEq(assetsReceived, expectedAssets);
    } else {
      // When shares is 0, the depositor has lost their deposit due to inflation protection
      // This is expected behavior to prevent the inflation attack
      assertEq(vault.balanceOf(depositorA), 0);

      // Test that a larger deposit can overcome the inflation protection
      uint256 largerDeposit = 2000 ether; // Larger than existing assets

      vm.startPrank(depositorB);
      usdsc.approve(address(vault), largerDeposit);
      uint256 largerShares = vault.deposit(largerDeposit, depositorB);
      vm.stopPrank();

      // With a larger deposit, shares should be > 0
      uint256 expectedLargerShares = (largerDeposit * 1) / (vault.totalAssets() - largerDeposit + 1);
      assertEq(largerShares, expectedLargerShares);
      assertGt(largerShares, 0);
    }
  }

  function test_very_small_deposits() external {
    // Test vault behavior with extremely small deposit amounts
    // This tests precision and rounding edge cases

    // Start with a reasonable deposit to establish the vault
    uint256 initialDeposit = 1000 ether;
    _depositFor(depositorA, initialDeposit);

    // Now test very small amounts
    uint256 verySmallAmount = 1; // 1 wei
    uint256 smallAmount = 1000; // 1000 wei

    // Test 1: Very small deposit (1 wei) - might result in 0 shares due to rounding
    vm.startPrank(depositorB);
    usdsc.approve(address(vault), verySmallAmount);
    uint256 shares1 = vault.deposit(verySmallAmount, depositorB);
    vm.stopPrank();

    // Very small deposits might result in 0 shares due to rounding
    // This is expected behavior for dust amounts
    assertEq(vault.balanceOf(depositorB), shares1);

    // Test 2: Slightly larger small deposit
    vm.startPrank(depositorC);
    usdsc.approve(address(vault), smallAmount);
    uint256 shares2 = vault.deposit(smallAmount, depositorC);
    vm.stopPrank();

    assertEq(vault.balanceOf(depositorC), shares2);
    // shares2 might still be 0 if amount is too small

    // Test 3: Test with amounts that should definitely get shares
    uint256 reasonableSmallAmount = 0.001 ether; // 1000000000000000 wei

    vm.startPrank(depositorB);
    usdsc.approve(address(vault), reasonableSmallAmount);
    uint256 shares3 = vault.deposit(reasonableSmallAmount, depositorB);
    vm.stopPrank();

    // This should definitely get shares
    assertGt(shares3, 0);
    assertEq(vault.balanceOf(depositorB), shares1 + shares3);

    // Test 4: Add yield and verify behavior
    uint256 yieldAmount = 100 ether;
    vm.startPrank(yieldDistributor);
    bool success = usdsc.transfer(address(vault), yieldAmount);
    require(success, 'Transfer failed');
    vm.stopPrank();

    // Test 5: Verify that small shareholders get proportional yield
    if (shares3 > 0) {
      uint256 assetsB = vault.convertToAssets(vault.balanceOf(depositorB));
      assertGt(assetsB, reasonableSmallAmount); // Should have gained from yield

      // Test redemption
      vm.startPrank(depositorB);
      uint256 actualAssetsB = vault.redeem(vault.balanceOf(depositorB), depositorB, depositorB);
      vm.stopPrank();

      assertEq(actualAssetsB, assetsB);
    }

    // Test 6: Very small mint operation
    uint256 verySmallShares = 1;
    uint256 assetsRequired = vault.previewMint(verySmallShares);

    if (assetsRequired > 0) {
      vm.startPrank(depositorC);
      usdsc.approve(address(vault), assetsRequired);
      uint256 actualAssets = vault.mint(verySmallShares, depositorC);
      vm.stopPrank();

      assertEq(actualAssets, assetsRequired);
      assertEq(vault.balanceOf(depositorC), shares2 + verySmallShares);
    }

    // Test 7: Test minimum viable deposit amount
    // Find the minimum amount that results in at least 1 share
    uint256 minViableDeposit = vault.previewMint(1);
    if (minViableDeposit > 0) {
      address testUser = makeAddr('testUser');
      deal(address(mToken), testUser, minViableDeposit * 2);

      // Setup USDSC for test user
      vm.startPrank(testUser);
      success = mToken.transfer(address(swapFacility), minViableDeposit * 2);
      require(success, 'Transfer failed');
      vm.stopPrank();

      vm.startPrank(address(swapFacility));
      usdsc.wrap(testUser, minViableDeposit * 2);
      vm.stopPrank();

      vm.startPrank(testUser);
      usdsc.approve(address(vault), minViableDeposit);
      uint256 minShares = vault.deposit(minViableDeposit, testUser);
      vm.stopPrank();

      assertGe(minShares, 1);
    }
  }

  // ===== recoverNonAssetERC20 Tests =====

  function test_recoverNonAssetERC20_success() external {
    // Create a mock ERC20 token for testing recovery
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);
    uint256 recoveryAmount = 1000 ether;

    // Mint tokens to the vault (simulating accidental transfer)
    mockToken.mint(address(vault), recoveryAmount);
    assertEq(mockToken.balanceOf(address(vault)), recoveryAmount);

    // Admin should be able to recover the tokens
    address recipient = makeAddr('recipient');
    uint256 initialRecipientBalance = mockToken.balanceOf(recipient);

    vm.prank(admin);
    vault.recoverNonAssetERC20(address(mockToken), recipient, recoveryAmount);

    // Verify tokens were transferred
    assertEq(mockToken.balanceOf(address(vault)), 0);
    assertEq(mockToken.balanceOf(recipient), initialRecipientBalance + recoveryAmount);
  }

  function test_recoverNonAssetERC20_partial_recovery() external {
    // Test partial recovery of tokens
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);
    uint256 totalAmount = 1000 ether;
    uint256 recoveryAmount = 300 ether;

    // Mint tokens to the vault
    mockToken.mint(address(vault), totalAmount);

    address recipient = makeAddr('recipient');

    vm.prank(admin);
    vault.recoverNonAssetERC20(address(mockToken), recipient, recoveryAmount);

    // Verify partial recovery
    assertEq(mockToken.balanceOf(address(vault)), totalAmount - recoveryAmount);
    assertEq(mockToken.balanceOf(recipient), recoveryAmount);
  }

  function test_recoverNonAssetERC20_multiple_tokens() external {
    // Test recovery of different tokens
    MockERC20 mockToken1 = new MockERC20('Mock Token 1', 'MOCK1', 18);
    MockERC20 mockToken2 = new MockERC20('Mock Token 2', 'MOCK2', 6);

    uint256 amount1 = 500 ether;
    uint256 amount2 = 1000 * 10 ** 6; // 1000 tokens with 6 decimals

    mockToken1.mint(address(vault), amount1);
    mockToken2.mint(address(vault), amount2);

    address recipient1 = makeAddr('recipient1');
    address recipient2 = makeAddr('recipient2');

    // Recover different tokens to different recipients
    vm.startPrank(admin);
    vault.recoverNonAssetERC20(address(mockToken1), recipient1, amount1);
    vault.recoverNonAssetERC20(address(mockToken2), recipient2, amount2);
    vm.stopPrank();

    // Verify recoveries
    assertEq(mockToken1.balanceOf(address(vault)), 0);
    assertEq(mockToken1.balanceOf(recipient1), amount1);
    assertEq(mockToken2.balanceOf(address(vault)), 0);
    assertEq(mockToken2.balanceOf(recipient2), amount2);
  }

  function test_recoverNonAssetERC20_does_not_affect_vault_operations() external {
    // Test that recovery doesn't affect normal vault operations
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);
    uint256 recoveryAmount = 1000 ether;

    // Setup vault with normal deposits
    _depositFor(depositorA, DEPOSIT_AMOUNT);
    uint256 initialShares = vault.balanceOf(depositorA);
    uint256 initialAssets = vault.totalAssets();

    // Add mock token to vault
    mockToken.mint(address(vault), recoveryAmount);

    // Recovery should not affect vault state
    vm.prank(admin);
    vault.recoverNonAssetERC20(address(mockToken), depositorB, recoveryAmount);

    // Verify vault operations are unaffected
    assertEq(vault.balanceOf(depositorA), initialShares);
    assertEq(vault.totalAssets(), initialAssets);

    // Test that normal operations still work
    _depositFor(depositorB, DEPOSIT_AMOUNT);
    assertEq(vault.balanceOf(depositorB), DEPOSIT_AMOUNT);
  }

  // ===== recoverNonAssetERC20 Negative Tests =====

  function test_revert_recoverNonAssetERC20_not_admin() external {
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);
    uint256 recoveryAmount = 1000 ether;
    mockToken.mint(address(vault), recoveryAmount);

    // Non-admin should not be able to recover tokens
    vm.prank(depositorA);
    vm.expectRevert();
    vault.recoverNonAssetERC20(address(mockToken), depositorA, recoveryAmount);

    // Pauser should not be able to recover tokens
    vm.prank(pauser);
    vm.expectRevert();
    vault.recoverNonAssetERC20(address(mockToken), pauser, recoveryAmount);
  }

  function test_revert_recoverNonAssetERC20_asset_token() external {
    // Should not be able to recover the vault's asset token (USDSC)
    uint256 recoveryAmount = 1000 ether;

    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(ISUSDSCVaultEventsAndErrors.TokenCannotBeUSDSC.selector));
    vault.recoverNonAssetERC20(address(usdsc), admin, recoveryAmount);
  }

  function test_revert_recoverNonAssetERC20_zero_token_address() external {
    uint256 recoveryAmount = 1000 ether;

    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(ISUSDSCVaultEventsAndErrors.TokenCannotBeZeroAddress.selector));
    vault.recoverNonAssetERC20(address(0), admin, recoveryAmount);
  }

  function test_revert_recoverNonAssetERC20_zero_to_address() external {
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);
    uint256 recoveryAmount = 1000 ether;
    mockToken.mint(address(vault), recoveryAmount);

    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(ISUSDSCVaultEventsAndErrors.ToCannotBeZeroAddress.selector));
    vault.recoverNonAssetERC20(address(mockToken), address(0), recoveryAmount);
  }

  function test_revert_recoverNonAssetERC20_zero_amount() external {
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);
    mockToken.mint(address(vault), 1000 ether);

    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(ISUSDSCVaultEventsAndErrors.AmountCannotBeZero.selector));
    vault.recoverNonAssetERC20(address(mockToken), admin, 0);
  }

  function test_revert_recoverNonAssetERC20_insufficient_balance() external {
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);
    uint256 vaultBalance = 500 ether;
    uint256 recoveryAmount = 1000 ether; // More than vault has

    mockToken.mint(address(vault), vaultBalance);

    // Should revert when trying to recover more than available
    vm.prank(admin);
    vm.expectRevert(); // SafeTransferLib will revert on insufficient balance
    vault.recoverNonAssetERC20(address(mockToken), admin, recoveryAmount);
  }

  function test_revert_recoverNonAssetERC20_invalid_token_address() external {
    // Test with a non-contract address (should fail when SafeTransferLib tries to call it)
    address invalidToken = makeAddr('invalidToken');
    uint256 recoveryAmount = 1000 ether;

    vm.prank(admin);
    vm.expectRevert(); // SafeTransferLib will revert on invalid token address
    vault.recoverNonAssetERC20(invalidToken, admin, recoveryAmount);
  }

  function test_recoverNonAssetERC20_edge_cases() external {
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);

    // Test recovery with 1 wei
    mockToken.mint(address(vault), 1);

    vm.prank(admin);
    vault.recoverNonAssetERC20(address(mockToken), admin, 1);

    assertEq(mockToken.balanceOf(address(vault)), 0);
    assertEq(mockToken.balanceOf(admin), 1);

    // Test recovery of a large amount (but not max uint256 to avoid overflow)
    uint256 largeAmount = 1e30; // Very large but safe amount
    mockToken.mint(address(vault), largeAmount);

    vm.prank(admin);
    vault.recoverNonAssetERC20(address(mockToken), admin, largeAmount);

    assertEq(mockToken.balanceOf(address(vault)), 0);
    assertEq(mockToken.balanceOf(admin), 1 + largeAmount);
  }

  function test_recoverNonAssetERC20_admin_role_changes() external {
    MockERC20 mockToken = new MockERC20('Mock Token', 'MOCK', 18);
    uint256 recoveryAmount = 1000 ether;
    mockToken.mint(address(vault), recoveryAmount);

    address newAdmin = makeAddr('newAdmin');

    // First verify that the original admin has the role
    assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));

    // Grant admin role to new admin (using the original admin)
    vm.startPrank(admin);
    vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin);
    vm.stopPrank();

    // Verify new admin has the role
    assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin));

    // New admin should be able to recover
    vm.startPrank(newAdmin);
    vault.recoverNonAssetERC20(address(mockToken), newAdmin, recoveryAmount);
    vm.stopPrank();

    assertEq(mockToken.balanceOf(newAdmin), recoveryAmount);

    // Test revoke admin role - mint more tokens first
    mockToken.mint(address(vault), recoveryAmount);

    // Original admin revokes the new admin's role
    vm.startPrank(admin);
    vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin);
    vm.stopPrank();

    // Verify role was revoked
    assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin));

    // Revoked admin should not be able to recover
    vm.startPrank(newAdmin);
    vm.expectRevert();
    vault.recoverNonAssetERC20(address(mockToken), newAdmin, recoveryAmount);
    vm.stopPrank();

    // But original admin should still be able to recover
    vm.startPrank(admin);
    vault.recoverNonAssetERC20(address(mockToken), admin, recoveryAmount);
    vm.stopPrank();

    assertEq(mockToken.balanceOf(admin), recoveryAmount);
  }

  function _depositFor(address user, uint256 amount) internal {
    vm.startPrank(user);
    usdsc.approve(address(vault), amount);
    vault.deposit(amount, user);
    vm.stopPrank();
  }
}
