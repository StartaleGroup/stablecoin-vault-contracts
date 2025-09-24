// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {EarnVault} from "../../src/vaults/earn/EarnVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract EarnVaultBoostTest is Test {
    EarnVault public earnVault;
    MockERC20 public usdr;
    MockERC20 public astr;
    MockERC20 public dot;
    
    address public admin = makeAddr("admin");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public treasury = makeAddr("treasury");
    address public pauser = makeAddr("pauser");
    
    uint256 public constant INITIAL_SUPPLY = 1_000_000e6;
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;
    uint256 public constant ASTR_REWARD = 100e18;
    uint256 public constant DOT_REWARD = 50e18;

    function setUp() public {
        // Deploy tokens
        usdr = new MockERC20("USDR Token", "USDR", 6);
        astr = new MockERC20("ASTR Token", "ASTR", 18);
        dot = new MockERC20("DOT Token", "DOT", 18);
        
        // Deploy EarnVault
        earnVault = new EarnVault(
            address(usdr),
            admin,
            admin, // yield redistributor
            treasury,
            pauser
        );
        
        // Setup initial balances
        usdr.mint(admin, INITIAL_SUPPLY);
        astr.mint(admin, ASTR_REWARD);
        dot.mint(admin, DOT_REWARD);
        
        // Setup users
        usdr.mint(user1, DEPOSIT_AMOUNT * 3);
        usdr.mint(user2, DEPOSIT_AMOUNT * 3);
        
        // Approve vault
        vm.startPrank(user1);
        usdr.approve(address(earnVault), DEPOSIT_AMOUNT * 3);
        vm.stopPrank();
        
        vm.startPrank(user2);
        usdr.approve(address(earnVault), DEPOSIT_AMOUNT * 3);
        vm.stopPrank();
    }

    function test_BoostRewardDistribution() public {
        // Both users deposit equal amounts
        vm.prank(user1);
        earnVault.deposit(DEPOSIT_AMOUNT);
        
        vm.prank(user2);
        earnVault.deposit(DEPOSIT_AMOUNT);
        
        // Admin distributes ASTR boost rewards
        vm.startPrank(admin);
        astr.approve(address(earnVault), ASTR_REWARD);
        astr.transfer(address(earnVault), ASTR_REWARD);
        earnVault.onBoostReward(address(astr), ASTR_REWARD);
        vm.stopPrank();
        
        // Both users should have equal claimable ASTR rewards
        uint256 user1Claimable = earnVault.getClaimableBoostReward(user1, address(astr));
        uint256 user2Claimable = earnVault.getClaimableBoostReward(user2, address(astr));
        
        assertEq(user1Claimable, ASTR_REWARD / 2); // 50 ASTR each
        assertEq(user2Claimable, ASTR_REWARD / 2); // 50 ASTR each
        assertEq(user1Claimable + user2Claimable, ASTR_REWARD);
    }

    function test_ProportionalBoostDistribution() public {
        // User1 deposits 1000 USDR, User2 deposits 2000 USDR
        vm.prank(user1);
        earnVault.deposit(1000e6);
        
        vm.prank(user2);
        earnVault.deposit(2000e6);
        
        // Admin distributes ASTR boost rewards
        vm.startPrank(admin);
        astr.approve(address(earnVault), ASTR_REWARD);
        astr.transfer(address(earnVault), ASTR_REWARD);
        earnVault.onBoostReward(address(astr), ASTR_REWARD);
        vm.stopPrank();
        
        // User1 should get 1/3, User2 should get 2/3
        uint256 user1Claimable = earnVault.getClaimableBoostReward(user1, address(astr));
        uint256 user2Claimable = earnVault.getClaimableBoostReward(user2, address(astr));
        
        // Allow for small rounding errors due to RAY precision
        assertApproxEqAbs(user1Claimable, ASTR_REWARD / 3, 1); // ~33.33 ASTR
        assertApproxEqAbs(user2Claimable, (ASTR_REWARD * 2) / 3, 1); // ~66.67 ASTR
        assertApproxEqAbs(user1Claimable + user2Claimable, ASTR_REWARD, 1); // Allow 1 wei rounding error
    }

    function test_UserClaimBoostRewards() public {
        // User deposits
        vm.prank(user1);
        earnVault.deposit(DEPOSIT_AMOUNT);
        
        // Admin distributes ASTR rewards
        vm.startPrank(admin);
        astr.approve(address(earnVault), ASTR_REWARD);
        astr.transfer(address(earnVault), ASTR_REWARD);
        earnVault.onBoostReward(address(astr), ASTR_REWARD);
        vm.stopPrank();
        
        // User claims ASTR rewards via unified claim()
        uint256 initialBalance = astr.balanceOf(user1);
        
        vm.prank(user1);
        earnVault.claim();
        
        uint256 finalBalance = astr.balanceOf(user1);
        assertEq(finalBalance - initialBalance, ASTR_REWARD);
    }

    function test_ClaimAutomaticallyClaimsAllRewards() public {
        // User deposits
        vm.prank(user1);
        earnVault.deposit(DEPOSIT_AMOUNT);
        
        // Admin distributes both USDR yield and ASTR boost rewards
        vm.startPrank(admin);
        usdr.approve(address(earnVault), 100e6);
        usdr.transfer(address(earnVault), 100e6);
        earnVault.onYield(100e6);
        
        astr.approve(address(earnVault), ASTR_REWARD);
        astr.transfer(address(earnVault), ASTR_REWARD);
        earnVault.onBoostReward(address(astr), ASTR_REWARD);
        vm.stopPrank();
        
        // User calls claim() - should get both USDR yield and ASTR boost rewards
        uint256 initialUSDR = usdr.balanceOf(user1);
        uint256 initialASTR = astr.balanceOf(user1);
        
        vm.prank(user1);
        earnVault.claim();
        
        uint256 finalUSDR = usdr.balanceOf(user1);
        uint256 finalASTR = astr.balanceOf(user1);
        
        // Should have received both USDR yield and ASTR boost rewards
        assertGt(finalUSDR, initialUSDR); // Received USDR yield
        assertGt(finalASTR, initialASTR); // Received ASTR boost rewards
    }

    function test_MultipleTokenBoostRewards() public {
        // User deposits
        vm.prank(user1);
        earnVault.deposit(DEPOSIT_AMOUNT);
        
        // Admin distributes both ASTR and DOT rewards
        vm.startPrank(admin);
        astr.approve(address(earnVault), ASTR_REWARD);
        astr.transfer(address(earnVault), ASTR_REWARD);
        earnVault.onBoostReward(address(astr), ASTR_REWARD);
        
        dot.approve(address(earnVault), DOT_REWARD);
        dot.transfer(address(earnVault), DOT_REWARD);
        earnVault.onBoostReward(address(dot), DOT_REWARD);
        vm.stopPrank();
        
        // User claims both rewards
        uint256 initialASTR = astr.balanceOf(user1);
        uint256 initialDOT = dot.balanceOf(user1);
        
        // User claims all boost rewards via unified claim()
        vm.prank(user1);
        earnVault.claim();
        
        uint256 finalASTR = astr.balanceOf(user1);
        uint256 finalDOT = dot.balanceOf(user1);
        
        assertEq(finalASTR - initialASTR, ASTR_REWARD);
        assertEq(finalDOT - initialDOT, DOT_REWARD);
    }

    function test_NoDepositsBoostRewardToTreasury() public {
        // No users have deposited, so boost rewards should go to treasury
        uint256 initialTreasuryBalance = astr.balanceOf(treasury);
        
        vm.startPrank(admin);
        astr.approve(address(earnVault), ASTR_REWARD);
        astr.transfer(address(earnVault), ASTR_REWARD);
        earnVault.onBoostReward(address(astr), ASTR_REWARD);
        vm.stopPrank();
        
        uint256 finalTreasuryBalance = astr.balanceOf(treasury);
        assertEq(finalTreasuryBalance - initialTreasuryBalance, ASTR_REWARD);
    }
}
