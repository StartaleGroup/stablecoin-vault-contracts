// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {SUSDRVault} from '../../src/vaults/4626/SUSDRVault.sol';
import {USDR} from '../../src/coin/mock/USDR.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

contract UnitSUSDRVault is Test {
    SUSDRVault internal vault;
    USDR internal usdr;
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
    
    uint256 internal constant INITIAL_USDR_AMOUNT = 10000 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 1000 ether;

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    function setUp() external {
        _deployContracts();
        _setupUsers();
    }

    function _deployContracts() internal {
        mToken = new MockM();
        swapFacility = new MockSwapFacility();
        proxyAdmin = new ProxyAdmin(admin);

        USDR implementation = new USDR(address(mToken), address(swapFacility));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeWithSelector(USDR.initialize.selector, 'USDR', 'USDR', admin, yieldRecipient)
        );
        usdr = USDR(address(proxy));

        vault = new SUSDRVault(IERC20(address(usdr)), admin, pauser);
    }

    function _setupUsers() internal {
        deal(address(mToken), depositorA, INITIAL_USDR_AMOUNT);
        deal(address(mToken), depositorB, INITIAL_USDR_AMOUNT);
        deal(address(mToken), depositorC, INITIAL_USDR_AMOUNT);
        deal(address(mToken), yieldDistributor, INITIAL_USDR_AMOUNT);

        vm.startPrank(depositorA);
        mToken.transfer(address(swapFacility), INITIAL_USDR_AMOUNT);
        vm.stopPrank();

        vm.startPrank(address(swapFacility));
        usdr.wrap(depositorA, INITIAL_USDR_AMOUNT);
        vm.stopPrank();

        vm.startPrank(depositorB);
        mToken.transfer(address(swapFacility), INITIAL_USDR_AMOUNT);
        vm.stopPrank();

        vm.startPrank(address(swapFacility));
        usdr.wrap(depositorB, INITIAL_USDR_AMOUNT);
        vm.stopPrank();

        vm.startPrank(depositorC);
        mToken.transfer(address(swapFacility), INITIAL_USDR_AMOUNT);
        vm.stopPrank();

        vm.startPrank(address(swapFacility));
        usdr.wrap(depositorC, INITIAL_USDR_AMOUNT);
        vm.stopPrank();

        vm.startPrank(yieldDistributor);
        mToken.transfer(address(swapFacility), INITIAL_USDR_AMOUNT);
        vm.stopPrank();

        vm.startPrank(address(swapFacility));
        usdr.wrap(yieldDistributor, INITIAL_USDR_AMOUNT);
        vm.stopPrank();
    }

    function test_constructor() external view {
        assertEq(vault.name(), 'Staked USDR');
        assertEq(vault.symbol(), 'sUSDR');
        assertEq(address(vault.asset()), address(usdr));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
    }

    function test_deposit_single_user() external {
        vm.startPrank(depositorA);
        usdr.approve(address(vault), DEPOSIT_AMOUNT);

        uint256 expectedShares = vault.previewDeposit(DEPOSIT_AMOUNT);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(depositorA, depositorA, DEPOSIT_AMOUNT, expectedShares);
        
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, depositorA);
        vm.stopPrank();

        assertEq(shares, expectedShares);
        assertEq(vault.balanceOf(depositorA), shares);
        assertEq(vault.totalSupply(), shares);
        assertEq(usdr.balanceOf(address(vault)), DEPOSIT_AMOUNT);
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
        assertEq(usdr.balanceOf(address(vault)), DEPOSIT_AMOUNT * 3);
    }

    function test_yield_distribution_increases_pps() external {
        _depositFor(depositorA, DEPOSIT_AMOUNT);
        _depositFor(depositorB, DEPOSIT_AMOUNT);
        
        uint256 initialPPS = vault.convertToAssets(1 ether);
        uint256 yieldAmount = 500 ether;
        
        vm.startPrank(yieldDistributor);
        usdr.transfer(address(vault), yieldAmount);
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
        usdr.transfer(address(vault), yieldAmount);
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
        usdr.transfer(address(vault), yieldAmount);
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
        usdr.approve(address(vault), assetsRequired);
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
        assertEq(usdr.balanceOf(depositorA), INITIAL_USDR_AMOUNT - DEPOSIT_AMOUNT + withdrawAmount);
    }

    function test_pause_functionality() external {
        vm.prank(pauser);
        vault.pause(true);

        vm.startPrank(depositorA);
        usdr.approve(address(vault), DEPOSIT_AMOUNT);
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
        usdr.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, depositorA);
        vm.stopPrank();
    }

    function test_revert_mint_when_paused() external {
        vm.prank(pauser);
        vault.pause(true);

        vm.startPrank(depositorA);
        usdr.approve(address(vault), DEPOSIT_AMOUNT);
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
        usdr.approve(address(vault), DEPOSIT_AMOUNT - 1);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, depositorA);
        vm.stopPrank();
    }

    function test_revert_deposit_insufficient_balance() external {
        address poorUser = makeAddr('poorUser');
        
        vm.startPrank(poorUser);
        usdr.approve(address(vault), DEPOSIT_AMOUNT);
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
        usdr.transfer(address(vault), yieldAmount);
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
        usdr.transfer(address(vault), 100 ether);
        vm.stopPrank();
        
        uint256 assetsAfterFirstYield = vault.convertToAssets(initialShares);
        
        vm.startPrank(yieldDistributor);
        usdr.transfer(address(vault), 150 ether);
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
        usdr.transfer(address(vault), 500 ether);
        vm.stopPrank();

        _depositFor(depositorB, DEPOSIT_AMOUNT);
        uint256 sharesB = vault.balanceOf(depositorB);
        
        assertLt(sharesB, sharesA);
        assertEq(sharesA, DEPOSIT_AMOUNT);
    }

    function test_zero_deposit_allowed() external {
        vm.startPrank(depositorA);
        usdr.approve(address(vault), 0);
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

    // Todo: review in main implementation and base (according to USDR decimals in soneium deployment)
    function test_decimals() external view {
        assertEq(vault.decimals(), usdr.decimals());
    }

    function test_redeem_partial_shares() external {
        _depositFor(depositorA, DEPOSIT_AMOUNT);
        uint256 totalShares = vault.balanceOf(depositorA);
        uint256 sharesToRedeem = totalShares / 2;
        
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
        uint256 initialBalance = usdr.balanceOf(depositorA);
        
        vm.expectEmit(true, true, true, true);
        emit Withdraw(depositorA, depositorA, depositorA, expectedAssets, sharesToRedeem);
        
        vm.startPrank(depositorA);
        uint256 assetsReceived = vault.redeem(sharesToRedeem, depositorA, depositorA);
        vm.stopPrank();

        assertEq(assetsReceived, expectedAssets);
        assertEq(vault.balanceOf(depositorA), totalShares - sharesToRedeem);
        assertEq(usdr.balanceOf(depositorA), initialBalance + assetsReceived);
    }

    function test_redeem_all_shares() external {
        _depositFor(depositorA, DEPOSIT_AMOUNT);
        uint256 totalShares = vault.balanceOf(depositorA);
        
        uint256 expectedAssets = vault.previewRedeem(totalShares);
        uint256 initialBalance = usdr.balanceOf(depositorA);
        
        vm.startPrank(depositorA);
        uint256 assetsReceived = vault.redeem(totalShares, depositorA, depositorA);
        vm.stopPrank();

        assertEq(assetsReceived, expectedAssets);
        assertEq(vault.balanceOf(depositorA), 0);
        assertEq(usdr.balanceOf(depositorA), initialBalance + assetsReceived);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_redeem_to_different_receiver() external {
        _depositFor(depositorA, DEPOSIT_AMOUNT);
        uint256 sharesToRedeem = vault.balanceOf(depositorA);
        
        uint256 receiverInitialBalance = usdr.balanceOf(depositorB);
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
        
        vm.startPrank(depositorA);
        uint256 assetsReceived = vault.redeem(sharesToRedeem, depositorB, depositorA);
        vm.stopPrank();

        assertEq(assetsReceived, expectedAssets);
        assertEq(vault.balanceOf(depositorA), 0);
        assertEq(usdr.balanceOf(depositorB), receiverInitialBalance + assetsReceived);
    }

    function test_redeem_with_approval() external {
        _depositFor(depositorA, DEPOSIT_AMOUNT);
        uint256 sharesToRedeem = vault.balanceOf(depositorA);
        
        vm.prank(depositorA);
        vault.approve(depositorB, sharesToRedeem);
        
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
        uint256 receiverInitialBalance = usdr.balanceOf(depositorC);
        
        vm.startPrank(depositorB);
        uint256 assetsReceived = vault.redeem(sharesToRedeem, depositorC, depositorA);
        vm.stopPrank();

        assertEq(assetsReceived, expectedAssets);
        assertEq(vault.balanceOf(depositorA), 0);
        assertEq(usdr.balanceOf(depositorC), receiverInitialBalance + assetsReceived);
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
        usdr.transfer(address(vault), 300 ether);
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
        usdr.transfer(address(vault), 100 ether);
        usdr.transfer(address(vault), 150 ether);
        usdr.transfer(address(vault), 75 ether);
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
        usdr.transfer(address(vault), largeYieldAmount);
        vm.stopPrank();
        
        uint256 depositAmountForB = DEPOSIT_AMOUNT;
        uint256 expectedSharesForB = vault.previewDeposit(depositAmountForB);
        
        vm.startPrank(depositorB);
        usdr.approve(address(vault), depositAmountForB);
        uint256 actualSharesForB = vault.deposit(depositAmountForB, depositorB);
        vm.stopPrank();
        
        assertEq(actualSharesForB, expectedSharesForB);
        assertLt(actualSharesForB, depositAmountForB);
        assertLt(vault.balanceOf(depositorB), vault.balanceOf(depositorA));
    }

    function _depositFor(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdr.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }
}