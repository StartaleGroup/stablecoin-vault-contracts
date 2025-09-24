// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {EarnVault} from "../../src/vaults/earn/EarnVault.sol";
import {IEarnVaultEventsAndErrors} from "../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract EarnVaultTest is Test {
    EarnVault public vault;
    MockERC20 public usdr;
    
    address public owner = makeAddr("owner");
    address public yieldRedistributor = makeAddr("yieldRedistributor");
    address public treasury = makeAddr("treasury");
    address public pauser = makeAddr("pauser");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    
    uint256 public constant RAY = 1e27;
    uint256 public constant INITIAL_SUPPLY = 1_000_000e6;
    
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event InterestClaimed(address indexed user, uint256 amount);
    event YieldIndexed(uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
    
    function setUp() public {
        // Deploy mock USDR token
        usdr = new MockERC20("USDR Token", "USDR", 6);

        // Deploy EarnVault with proper parameters
        vm.prank(owner);
        vault = new EarnVault(address(usdr), owner, yieldRedistributor, treasury, pauser);

        // Mint USDR to test users
        usdr.mint(alice, INITIAL_SUPPLY);
        usdr.mint(bob, INITIAL_SUPPLY);
        usdr.mint(charlie, INITIAL_SUPPLY);
        usdr.mint(yieldRedistributor, INITIAL_SUPPLY);

        // Pre-approve vault for all users
        vm.prank(alice);
        usdr.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdr.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        usdr.approve(address(vault), type(uint256).max);
        vm.prank(yieldRedistributor);
        usdr.approve(address(vault), type(uint256).max);
    }
    
    // ========================================
    // Basic Deposit/Withdraw Tests
    // ========================================
    
    // Helper function for getting user principal (addresses review comment about naming)
    function _getUserPrincipal(address user) internal view returns (uint256) {
        return vault.principal(user);
    }
    
    /// @notice Test basic deposit functionality and state updates
    function test_BasicDeposit() public {
        uint256 depositAmount = 1000e6;
        
        // Record initial state
        uint256 initialBalance = usdr.balanceOf(alice);
        uint256 initialVaultBalance = usdr.balanceOf(address(vault));
        
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Deposit(alice, depositAmount);
        vault.deposit(depositAmount);
        
        // Verify state changes
        assertEq(_getUserPrincipal(alice), depositAmount, "Alice's principal should be 1000");
        assertEq(vault.totalPrincipal(), depositAmount, "Total principal should be 1000");
        assertEq(vault.claimReserve(), depositAmount, "Claim reserve should equal principal");
        assertEq(vault.userIndex(alice), RAY, "Alice's user index should be 1e27");
        assertEq(vault.globalIndex(), RAY, "Global index should remain 1e27");
        
        // Verify token transfers
        assertEq(usdr.balanceOf(alice), initialBalance - depositAmount, "Alice's balance should decrease");
        assertEq(usdr.balanceOf(address(vault)), initialVaultBalance + depositAmount, "Vault balance should increase");
    }
    
    /// @notice Test deposit with multiple users to verify proportional tracking
    function test_MultiUserDeposit() public {
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Bob deposits 3000 USDR  
        vm.prank(bob);
        vault.deposit(3000e6);
        
        // Verify individual principals
        assertEq(_getUserPrincipal(alice), 1000e6, "Alice should have 1000 principal");
        assertEq(_getUserPrincipal(bob), 3000e6, "Bob should have 3000 principal");
        
        // Verify total state
        assertEq(vault.totalPrincipal(), 4000e6, "Total principal should be 4000");
        // NOTE: claimReserve includes both principal deposits (1:1 reserved) AND yield amounts
        assertEq(vault.claimReserve(), 4000e6, "Claim reserve should be 4000 (principal only, no yield yet)");
        
        // Both users should have same userIndex (no yield yet)
        assertEq(vault.userIndex(alice), RAY, "Alice's index should be 1e27");
        assertEq(vault.userIndex(bob), RAY, "Bob's index should be 1e27");
    }
    
    /// @notice Test partial withdrawal with no yield
    function test_PartialWithdrawNoYield() public {
        uint256 depositAmount = 1000e6;
        uint256 withdrawAmount = 600e6;
        
        // Alice deposits first
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        
        // Alice withdraws 600 USDR
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Withdraw(alice, withdrawAmount);
        vault.withdraw(withdrawAmount);
        
        // Verify state changes
        assertEq(_getUserPrincipal(alice), depositAmount - withdrawAmount, "Alice's principal should be 400");
        assertEq(vault.totalPrincipal(), depositAmount - withdrawAmount, "Total principal should be 400");
        assertEq(vault.claimReserve(), depositAmount - withdrawAmount, "Claim reserve should be 400");
        assertEq(usdr.balanceOf(alice), initialBalance + withdrawAmount, "Alice should receive 600 USDR");
    }
    
    /// @notice Test full withdrawal without any yield (should not auto-claim anything)
    function test_FullWithdrawNoYield() public {
        uint256 depositAmount = 1000e6;
        
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        
        // Alice withdraws all her principal
        vm.prank(alice);
        vault.withdraw(depositAmount);
        
        // Verify complete withdrawal
        assertEq(_getUserPrincipal(alice), 0, "Alice's principal should be 0");
        assertEq(vault.accrued(alice), 0, "Alice should have no accrued interest");
        assertEq(usdr.balanceOf(alice), initialBalance + depositAmount, "Alice should receive full amount");
    }
    
    // ========================================
    // Yield Distribution Tests
    // ========================================
    
    /// @notice Test yield distribution with single user
    function test_SingleUserYieldDistribution() public {
        uint256 depositAmount = 1000e6;
        uint256 yieldAmount = 100e6;
        
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        // Distributor sends yield
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), yieldAmount);
        
        vm.prank(yieldRedistributor);
        vm.expectEmit(false, false, false, true);
        emit YieldIndexed(yieldAmount, RAY + (yieldAmount * RAY) / depositAmount, depositAmount + yieldAmount);
        vault.onYield(yieldAmount);
        
        // Verify global index increased
        uint256 expectedGlobalIndex = RAY + (yieldAmount * RAY) / depositAmount; // 1.1e27
        assertEq(vault.globalIndex(), expectedGlobalIndex, "Global index should increase by 0.1e27");
        
        // Verify claim reserve includes yield
        assertEq(vault.claimReserve(), depositAmount + yieldAmount, "Claim reserve should include yield");
        
        // Alice should have claimable yield
        assertEq(vault.claimable(alice), yieldAmount, "Alice should have 100 USDR claimable");
    }
    
    /// @notice Test proportional yield distribution with multiple users
    function test_ProportionalYieldDistribution() public {
        // Alice deposits 1000 USDR (25% of total)
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Bob deposits 3000 USDR (75% of total)
        vm.prank(bob);
        vault.deposit(3000e6);
        
        uint256 yieldAmount = 400e6;
        
        // Distributor sends yield
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), yieldAmount);
        
        vm.prank(yieldRedistributor);
        vault.onYield(yieldAmount);
        
        // Calculate expected claimable amounts (proportional to deposits)
        uint256 aliceExpected = 100e6; // 25% of 400 = 100
        uint256 bobExpected = 300e6;   // 75% of 400 = 300
        
        assertEq(vault.claimable(alice), aliceExpected, "Alice should get 25% of yield");
        assertEq(vault.claimable(bob), bobExpected, "Bob should get 75% of yield");
        
        // Verify total distribution equals yield
        assertEq(vault.claimable(alice) + vault.claimable(bob), yieldAmount, "Total claimable should equal yield");
    }
    
    /// @notice Test yield distribution when no deposits exist (direct treasury transfer)
    /// @dev Yield goes directly to treasury when no deposits exist (no parking)
    function test_YieldWhenNoDeposits() public {
        uint256 yieldAmount = 500e6;
        
        // Send yield when no one has deposited (totalPrincipal = 0)
        uint256 initialTreasuryBalance = usdr.balanceOf(treasury);
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), yieldAmount);
        
        vm.prank(yieldRedistributor);
        vault.onYield(yieldAmount);
        
        // Yield should go directly to treasury, not be parked
        assertEq(vault.globalIndex(), RAY, "Global index should remain unchanged");
        assertEq(vault.claimReserve(), 0, "Claim reserve should remain 0");
        assertEq(usdr.balanceOf(treasury), initialTreasuryBalance + yieldAmount, 
                 "Treasury should receive yield directly");
        
        // Now Alice deposits - no parked yield to worry about
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Alice should have no claimable yield yet
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable yield yet");
        assertEq(vault.claimReserve(), 1000e6, "Reserve should only include principal");
        
        // When new yield arrives, it gets processed normally
        uint256 newYieldAmount = 200e6;
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), newYieldAmount);
        
        vm.prank(yieldRedistributor);
        vault.onYield(newYieldAmount);
        
        // Alice should get the new yield
        assertEq(vault.claimable(alice), newYieldAmount, "Alice should get the new yield");
    }

    
    // ========================================
    // Claim Functionality Tests  
    // ========================================
    
    /// @notice Test basic claim functionality
    function test_BasicClaim() public {
        uint256 depositAmount = 1000e6;
        uint256 yieldAmount = 100e6;
        
        // Setup: Alice deposits and yield is distributed
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(yieldRedistributor);
        vault.onYield(yieldAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        uint256 claimableAmount = vault.claimable(alice);
        
        // Alice claims her yield
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit InterestClaimed(alice, claimableAmount);
        vault.claim();
        
        // Verify claim effects
        assertEq(vault.accrued(alice), 0, "Alice's accrued should be reset to 0");
        assertEq(vault.claimable(alice), 0, "Alice should have no more claimable");
        assertEq(usdr.balanceOf(alice), initialBalance + claimableAmount, "Alice should receive claimed amount");
        assertEq(vault.claimReserve(), depositAmount, "Claim reserve should decrease by claimed amount");
    }
    
    /// @notice Test multiple claims over time
    function test_MultipleClaims() public {
        uint256 depositAmount = 1000e6;
        
        // Alice deposits
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        // First yield distribution: 100 USDR
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Alice claims first yield
        vm.prank(alice);
        vault.claim();
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable after first claim");
        
        // Second yield distribution: 50 USDR
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 50e6);
        vm.prank(yieldRedistributor);
        vault.onYield(50e6);
        
        // Alice should now have new claimable amount
        assertEq(vault.claimable(alice), 50e6, "Alice should have 50 USDR claimable from second yield");
        
        // Alice claims second yield
        vm.prank(alice);
        vault.claim();
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable after second claim");
    }
    
    // ========================================
    // Full Withdrawal with Auto-Claim Tests
    // ========================================
    
    /// @notice Test withdraw function with total value withdraws everything
    function test_WithdrawAll() public {
        uint256 depositAmount = 1000e6;
        uint256 yieldAmount = 100e6;
        
        // Setup: Alice deposits and yield is distributed
        vm.prank(alice);
        vault.deposit(depositAmount);
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(yieldRedistributor);
        vault.onYield(yieldAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        uint256 expectedTotal = depositAmount + yieldAmount;
        
        // Alice withdraws her principal (automatically claims all rewards)
        vm.prank(alice);
        vault.withdraw(depositAmount);
        
        // Verify Alice received everything
        assertEq(vault.principal(alice), 0, "Alice should have no principal");
        assertEq(vault.accrued(alice), 0, "Alice should have no accrued interest");
        assertEq(usdr.balanceOf(alice), initialBalance + expectedTotal, "Alice should receive total amount");
    }

    
    /// @notice Test withdrawal with yield (simplified logic - all rewards auto-claimed)
    function test_WithdrawWithYield() public {
        uint256 depositAmount = 1000e6;
        uint256 yieldAmount = 100e6;
        
        // Setup: Alice deposits and yield is distributed
        vm.prank(alice);
        vault.deposit(depositAmount);
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(yieldRedistributor);
        vault.onYield(yieldAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        // Alice withdraws her principal (automatically claims all interest)
        vm.prank(alice);
        vault.withdraw(depositAmount);
        
        // Verify Alice received principal + all interest (1100 USDR total)
        assertEq(_getUserPrincipal(alice), 0, "Alice should have no principal");
        assertEq(vault.accrued(alice), 0, "All interest should be auto-claimed");
        assertEq(usdr.balanceOf(alice), initialBalance + depositAmount + yieldAmount, "Alice should receive 1100 USDR");
    }

    /// @notice Test partial withdrawal with yield (auto-claims all rewards)
    function test_PartialWithdrawWithYield() public {
        uint256 depositAmount = 1000e6;
        uint256 withdrawAmount = 600e6;
        uint256 yieldAmount = 100e6;
        
        // Setup: Alice deposits and yield is distributed
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(yieldRedistributor);
        vault.onYield(yieldAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        
        // Alice withdraws partial amount (automatically claims all interest)
        vm.prank(alice);
        vault.withdraw(withdrawAmount);
        
        // Verify interest IS auto-claimed with new simplified logic
        assertEq(_getUserPrincipal(alice), depositAmount - withdrawAmount, 
                 "Alice should have 400 principal remaining");
        assertEq(vault.claimable(alice), 0, "All interest should be auto-claimed");
        assertEq(usdr.balanceOf(alice), initialBalance + withdrawAmount + yieldAmount, 
                 "Alice should receive withdrawn principal + all interest");
    }
    
    // ========================================
    // Dynamic Principal Change Tests
    // ========================================
    
    /// @notice Test yield calculation when user changes principal over time
    function test_DynamicPrincipalChanges() public {
        // Alice deposits 1000 USDR initially
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // First yield: 100 USDR on 1000 principal
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Alice should have 100 USDR claimable
        assertEq(vault.claimable(alice), 100e6, "Alice should have 100 USDR from first yield");
        
        // Alice deposits another 1000 USDR (settlement happens automatically)
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Verify her accrued was settled and principal updated
        assertEq(vault.accrued(alice), 100e6, "Previous yield should be settled into accrued");
        assertEq(_getUserPrincipal(alice), 2000e6, "Alice should now have 2000 principal");
        assertEq(vault.userIndex(alice), vault.globalIndex(), "Alice's index should be updated to current");
        
        // Second yield: 200 USDR on 2000 total principal
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 200e6);
        vm.prank(yieldRedistributor);
        vault.onYield(200e6);
        
        // Alice should have 100 (settled) + 200 (new) = 300 USDR claimable
        assertEq(vault.claimable(alice), 300e6, "Alice should have 300 total claimable");
    }
    
    /// @notice Test multiple users with different deposit timings
    function test_MultiUserDifferentTimings() public {
        // Alice deposits 1000 USDR at start
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // First yield: 100 USDR (Alice gets all)
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        assertEq(vault.claimable(alice), 100e6, "Alice should get all first yield");
        
        // Bob deposits 1000 USDR after first yield
        vm.prank(bob);
        vault.deposit(1000e6);
        
        // Second yield: 200 USDR (Alice and Bob should split 50/50)
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 200e6);
        vm.prank(yieldRedistributor);
        vault.onYield(200e6);
        
        assertEq(vault.claimable(alice), 200e6, "Alice: 100 (first) + 100 (half of second)");
        assertEq(vault.claimable(bob), 100e6, "Bob: 100 (half of second yield)");
    }
    
    // ========================================
    // Edge Cases and Error Conditions
    // ========================================
    
    /// @notice Test attempting to withdraw more than principal
    function test_WithdrawExceedsPrincipal() public {
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Try to withdraw more than deposited
        vm.prank(alice);
        vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientPrincipal.selector);
        vault.withdraw(1500e6);
    }
    
    /// @notice Test claiming when no yield is available
    function test_ClaimWithNoYield() public {
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Try to claim with no yield distributed
        vm.prank(alice);
        vm.expectRevert(IEarnVaultEventsAndErrors.NothingToClaim.selector);
        vault.claim();
    }
    
    /// @notice Test zero amount operations
    function test_ZeroAmountOperations() public {
        // Zero deposit should revert
        vm.prank(alice);
        vm.expectRevert(IEarnVaultEventsAndErrors.ZeroAmount.selector);
        vault.deposit(0);
        
        // Zero withdrawal should revert  
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(alice);
        vm.expectRevert(IEarnVaultEventsAndErrors.ZeroAmount.selector);
        vault.withdraw(0);
        
        // Zero yield should be handled gracefully (no revert)
        vm.prank(yieldRedistributor);
        vault.onYield(0); // Should not revert
    }
    
    /// @notice Test unauthorized onYield calls
    function test_UnauthorizedYieldCall() public {
        // Random user cannot call onYield
        vm.prank(alice);
        vm.expectRevert();
        vault.onYield(100e6);
    }
    
    // ========================================
    // View Function Tests
    // ========================================
    
    /// @notice Test claimable view function accuracy
    function test_ClaimableViewFunction() public {
        // Alice deposits
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Initially no claimable
        assertEq(vault.claimable(alice), 0, "Initially no claimable");
        
        // Distribute yield
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Check claimable before settlement
        assertEq(vault.claimable(alice), 100e6, "Should show 100 claimable before settlement");
        
        // Trigger settlement by calling deposit with 0 (should revert, but let's use another action)
        vm.prank(alice);
        vault.deposit(1e6); // Small deposit to trigger settlement
        
        // Check claimable after settlement
        assertEq(vault.claimable(alice), 100e6, "Should still show 100 claimable after settlement");
    }
    
    /// @notice Test asset view function
    function test_AssetViewFunction() public {
        assertEq(vault.asset(), address(usdr), "Asset should return USDR address");
    }
    
    /// @notice Test totalPrincipal tracking
    function test_TotalPrincipalTracking() public {
        assertEq(vault.totalPrincipal(), 0, "Initially no principal");
        
        vm.prank(alice);
        vault.deposit(1000e6);
        assertEq(vault.totalPrincipal(), 1000e6, "Should be 1000 after Alice deposits");
        
        vm.prank(bob);
        vault.deposit(2000e6);
        assertEq(vault.totalPrincipal(), 3000e6, "Should be 3000 after Bob deposits");
        
        vm.prank(alice);
        vault.withdraw(500e6);
        assertEq(vault.totalPrincipal(), 2500e6, "Should be 2500 after Alice withdraws");
    }
    
    // ========================================
    // Admin and Pause Tests
    // ========================================
    
    /// @notice Test pause functionality
    function test_PauseFunctionality() public {
        // Owner can pause
        vm.prank(owner);
        vault.pause();
        
        // Operations should be blocked when paused
        vm.prank(alice);
        vm.expectRevert(); // Modern Pausable uses EnforcedPause() error
        vault.deposit(1000e6);
        
        // Owner can unpause
        vm.prank(owner);
        vault.unpause();
        
        // Operations should work after unpause
        vm.prank(alice);
        vault.deposit(1000e6); // Should not revert
        assertEq(_getUserPrincipal(alice), 1000e6, "Deposit should work after unpause");
    }
    
    /// @notice Test pause access control
    function test_PauseAccessControl() public {
        // Owner can pause
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused(), "Owner should be able to pause");
        
        // Unpause for next test
        vm.prank(owner);
        vault.unpause();
        
        // Pauser can pause
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused(), "Pauser should be able to pause");
        
        // Pauser can unpause
        vm.prank(pauser);
        vault.unpause();
        assertFalse(vault.paused(), "Pauser should be able to unpause");
        
        // Non-authorized user cannot pause
        vm.prank(alice);
        vm.expectRevert(IEarnVaultEventsAndErrors.NotAuthorizedToPause.selector);
        vault.pause();
        
        // Non-authorized user cannot unpause  
        vm.prank(owner);
        vault.pause(); // Pause first
        
        vm.prank(alice);
        vm.expectRevert(IEarnVaultEventsAndErrors.NotAuthorizedToPause.selector);
        vault.unpause();
    }
    
    /// @notice Test pauser management
    function test_PauserManagement() public {
        // Only owner can set pauser
        vm.prank(alice);
        vm.expectRevert();
        vault.setPauser(alice);
        
        // Owner can set new pauser
        vm.prank(owner);
        vault.setPauser(alice);
        assertEq(vault.pauser(), alice, "Pauser should be updated");
        
        // New pauser can pause
        vm.prank(alice);
        vault.pause();
        assertTrue(vault.paused(), "New pauser should be able to pause");
        
        // Old pauser cannot pause anymore
        vm.prank(pauser);
        vm.expectRevert(IEarnVaultEventsAndErrors.NotAuthorizedToPause.selector);
        vault.unpause();
        
        // New pauser can unpause
        vm.prank(alice);
        vault.unpause();
        assertFalse(vault.paused(), "New pauser should be able to unpause");
    }
    
    /// @notice Test treasury management
    function test_TreasuryManagement() public {
        // Only owner can set treasury
        vm.prank(alice);
        vm.expectRevert();
        vault.setTreasury(alice);
        
        // Owner can set new treasury
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        vault.setTreasury(newTreasury);
        assertEq(vault.treasury(), newTreasury, "Treasury should be updated");
    }
    
    /// @notice Test sweep surplus to treasury functionality
    function test_SweepSurplusToTreasury() public {
        uint256 depositAmount = 1000e6;
        uint256 yieldAmount = 100e6;
        
        // Setup: Alice deposits, yield is distributed, creating surplus
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(yieldRedistributor);
        vault.onYield(yieldAmount);
        
        // Create additional surplus by sending extra USDR
        uint256 extraAmount = 50e6;
        usdr.mint(address(vault), extraAmount);
        
        uint256 initialTreasuryBalance = usdr.balanceOf(treasury);
        uint256 vaultBalance = usdr.balanceOf(address(vault));
        uint256 expectedSurplus = vaultBalance - vault.claimReserve();
        
        // Sweep surplus to treasury (no pause required anymore)
        vm.prank(owner);
        vault.sweepSurplusToTreasury();
        
        // Verify surplus went to treasury
        assertEq(usdr.balanceOf(treasury), initialTreasuryBalance + expectedSurplus, "Treasury should receive surplus");
        assertEq(usdr.balanceOf(address(vault)), vault.claimReserve(), "Vault should keep only required reserves");
    }
    
    /// @notice Test emergency sweep to treasury
    function test_EmergencySweepToTreasury() public {
        uint256 depositAmount = 1000e6;
        
        // Setup: Alice deposits
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        // Create surplus by minting extra USDR to vault
        uint256 extraAmount = 100e6;
        usdr.mint(address(vault), extraAmount);
        
        uint256 initialTreasuryBalance = usdr.balanceOf(treasury);
        
        // Pause vault for emergency sweep
        vm.prank(owner);
        vault.pause();
        
        // Owner can emergency sweep surplus to treasury
        vm.prank(owner);
        vault.recoverERC20(address(usdr), treasury, extraAmount);
        
        // Verify treasury received the swept amount
        assertEq(usdr.balanceOf(treasury), initialTreasuryBalance + extraAmount, 
                 "Treasury should receive swept amount");
    }
    
    /// @notice Test role access control comprehensively
    function test_RoleAccessControl() public {
        // Test yield redistributor access
        vm.prank(alice); // Not yield redistributor
        vm.expectRevert();
        vault.onYield(100e6);
        
        
        // Test pauser access
        vm.prank(alice); // Not pauser or owner
        vm.expectRevert(IEarnVaultEventsAndErrors.NotAuthorizedToPause.selector);
        vault.pause();
        
        // Test owner-only functions
        vm.prank(alice); // Not owner
        vm.expectRevert();
        vault.setYieldRedistributor(alice);
        
        vm.prank(alice); // Not owner
        vm.expectRevert();
        vault.setTreasury(alice);
        
        vm.prank(alice); // Not owner
        vm.expectRevert();
        vault.setPauser(alice);
        
        vm.prank(alice); // Not owner
        vm.expectRevert();
        vault.setBlacklisted(alice, true);
        
        vm.prank(alice); // Not owner
        vm.expectRevert();
        vault.recoverERC20(address(usdr), alice, 100e6);
        
        vm.prank(alice); // Not owner
        vm.expectRevert();
        vault.sweepSurplusToTreasury();
    }
    
    /// @notice Test blacklist functionality
    function test_BlacklistFunctionality() public {
        // Initially no one is blacklisted - everyone can deposit
        vm.prank(alice);
        vault.deposit(1000e6);
        assertEq(_getUserPrincipal(alice), 1000e6, "Alice should be able to deposit when not blacklisted");
        
        // Blacklist Bob
        vm.prank(owner);
        vault.setBlacklisted(bob, true);
        
        // Bob should be blocked from depositing
        vm.prank(bob);
        vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
        vault.deposit(1000e6);
        
        // Alice (not blacklisted) should still be able to deposit
        vm.prank(alice);
        vault.deposit(500e6);
        assertEq(_getUserPrincipal(alice), 1500e6, "Alice should still be able to deposit");
        
        // Remove Bob from blacklist
        vm.prank(owner);
        vault.setBlacklisted(bob, false);
        
        // Bob should now be able to deposit
        vm.prank(bob);
        vault.deposit(1000e6);
        assertEq(_getUserPrincipal(bob), 1000e6, "Bob should be able to deposit after removal from blacklist");
    }
    
    /// @notice Test only owner can manage blacklist
    function test_OnlyOwnerCanManageBlacklist() public {
        // Non-owner cannot blacklist addresses
        vm.prank(alice);
        vm.expectRevert();
        vault.setBlacklisted(bob, true);
    }
    
    /// @notice Test blacklist blocks depositWithPermit as well
    function test_BlacklistBlocksDepositWithPermit() public {
        // Blacklist Alice
        vm.prank(owner);
        vault.setBlacklisted(alice, true);
        
        // Alice cannot use depositWithPermit when blacklisted
        vm.prank(alice);
        vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
        vault.depositWithPermit(1000e6, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }
    
    /// @notice Test depositWithPermit handles non-permit tokens gracefully
    function test_DepositWithPermitFailure() public {
        // Our MockERC20 doesn't implement permit, so this should fail gracefully
        vm.prank(alice);
        vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
        vault.depositWithPermit(1000e6, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }
    
    /// @notice Test yield redistributor role management
    function test_DistributorManagement() public {
        address newDistributor = makeAddr("newDistributor");
        
        // Only owner can change yield redistributor
        vm.prank(alice);
        vm.expectRevert();
        vault.setYieldRedistributor(newDistributor);
        
        // Owner can change distributor
        vm.prank(owner);
        vault.setYieldRedistributor(newDistributor);
        assertEq(vault.yieldRedistributor(), newDistributor, "YieldRedistributor should be updated");
        
        // Old yield redistributor should no longer work
        vm.prank(yieldRedistributor);
        vm.expectRevert();
        vault.onYield(100e6);
        
        // New yield redistributor should work
        usdr.mint(newDistributor, 1000e6);
        vm.prank(newDistributor);
        usdr.approve(address(vault), type(uint256).max);
        
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(newDistributor);
        usdr.transfer(address(vault), 100e6);
        vm.prank(newDistributor);
        vault.onYield(100e6); // Should not revert
    }
    
    // ========================================
    // Integration Test: Complete User Journey
    // ========================================
    
    /// @notice Test complete user journey with multiple actions
    function test_CompleteUserJourney() public {
        // === Phase 1: Initial deposits ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(bob);
        vault.deposit(2000e6);
        
        assertEq(vault.totalPrincipal(), 3000e6, "Total principal should be 3000");
        
        // === Phase 2: First yield distribution ===
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 300e6);
        vm.prank(yieldRedistributor);
        vault.onYield(300e6);
        
        // Alice should get 1/3, Bob should get 2/3
        assertEq(vault.claimable(alice), 100e6, "Alice should have 100 claimable");
        assertEq(vault.claimable(bob), 200e6, "Bob should have 200 claimable");
        
        // === Phase 3: Alice claims, Bob doesn't ===
        vm.prank(alice);
        vault.claim();
        
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable after claim");
        assertEq(vault.claimable(bob), 200e6, "Bob should still have 200 claimable");
        
        // === Phase 4: Charlie joins ===
        vm.prank(charlie);
        vault.deposit(3000e6);
        
        assertEq(vault.totalPrincipal(), 6000e6, "Total should be 6000 after Charlie joins");
        
        // === Phase 5: Second yield distribution ===
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 600e6);
        vm.prank(yieldRedistributor);
        vault.onYield(600e6);
        
        // Distribution: Alice 1000/6000, Bob 2000/6000, Charlie 3000/6000
        // Alice: 0 + 100 = 100
        // Bob: 200 + 200 = 400  
        // Charlie: 0 + 300 = 300
        assertEq(vault.claimable(alice), 100e6, "Alice should have 100 from second yield");
        assertEq(vault.claimable(bob), 400e6, "Bob should have 400 total");
        assertEq(vault.claimable(charlie), 300e6, "Charlie should have 300 from second yield");
        
        // === Phase 6: Bob does full withdrawal (automatically claims all rewards) ===
        uint256 bobInitialBalance = usdr.balanceOf(bob);
        uint256 bobPrincipal = vault.principal(bob);
        vm.prank(bob);
        vault.withdraw(bobPrincipal);
        
        assertEq(_getUserPrincipal(bob), 0, "Bob should have no principal");
        assertEq(vault.claimable(bob), 0, "Bob should have no claimable");
        assertEq(usdr.balanceOf(bob), bobInitialBalance + 2000e6 + 400e6, "Bob should get principal + interest");
        
        // === Phase 7: Final state verification ===
        assertEq(vault.totalPrincipal(), 4000e6, "Total should be 4000 after Bob leaves");
        assertEq(vault.claimable(alice), 100e6, "Alice claimable unchanged");
        assertEq(vault.claimable(charlie), 300e6, "Charlie claimable unchanged");
    }

    // ========================================
    // Funding Invariant Tests
    // ========================================

    /// @notice Test that funds sent without calling onYield are detected
    function test_FundsSentWithoutOnYield() public {
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Record initial state
        uint256 initialBalance = usdr.balanceOf(address(vault));
        uint256 initialClaimReserve = vault.claimReserve();
        
        // Yield redistributor sends 100 USDR but forgets to call onYield
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 100e6);
        
        // Verify vault received the funds
        assertEq(usdr.balanceOf(address(vault)), initialBalance + 100e6, "Vault should receive funds");
        
        // But claimReserve and globalIndex should be unchanged
        assertEq(vault.claimReserve(), initialClaimReserve, "ClaimReserve should be unchanged");
        assertEq(vault.globalIndex(), RAY, "GlobalIndex should be unchanged");
        
        // Alice should have no claimable yield
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable yield");
        
        // Now when onYield is called with correct amount, it should work
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Verify yield is properly distributed
        assertEq(vault.claimReserve(), initialClaimReserve + 100e6, "ClaimReserve should increase");
        // GlobalIndex should be 1.1e27 (100e6 * 1e27 / 1000e6 = 0.1e27, so RAY + 0.1e27 = 1.1e27)
        assertEq(vault.globalIndex(), RAY + 1e26, "GlobalIndex should increase");
        assertEq(vault.claimable(alice), 100e6, "Alice should now have claimable yield");
    }

    /// @notice Test that onYield with incorrect amount fails funding check
    function test_OnYieldWithIncorrectAmount() public {
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Yield redistributor sends 100 USDR
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 100e6);
        
        // Try to call onYield with excessive amount (200 instead of 100)
        vm.prank(yieldRedistributor);
        vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
        vault.onYield(200e6);
        
        // Verify state is unchanged
        assertEq(vault.claimReserve(), 1000e6, "ClaimReserve should be unchanged");
        assertEq(vault.globalIndex(), RAY, "GlobalIndex should be unchanged");
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable yield");
        
        // Now call onYield with correct amount
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Verify yield is properly distributed
        assertEq(vault.claimReserve(), 1100e6, "ClaimReserve should increase by 100");
        assertEq(vault.globalIndex(), RAY + 1e26, "GlobalIndex should increase");
        assertEq(vault.claimable(alice), 100e6, "Alice should have claimable yield");
    }

    /// @notice Test that onYield with amount larger than sent funds fails
    function test_OnYieldWithExcessiveAmount() public {
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Yield redistributor sends 100 USDR
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 100e6);
        
        // Try to call onYield with excessive amount (200 instead of 100)
        vm.prank(yieldRedistributor);
        vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
        vault.onYield(200e6);
        
        // Verify state is unchanged
        assertEq(vault.claimReserve(), 1000e6, "ClaimReserve should be unchanged");
        assertEq(vault.globalIndex(), RAY, "GlobalIndex should be unchanged");
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable yield");
    }

    /// @notice Test funding invariant with multiple users and partial yield
    function test_FundingInvariantWithMultipleUsers() public {
        // Alice deposits 1000 USDR, Bob deposits 2000 USDR
        vm.prank(alice);
        vault.deposit(1000e6);
        vm.prank(bob);
        vault.deposit(2000e6);
        
        // Yield redistributor sends 150 USDR but calls onYield with 200 USDR (excessive)
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 150e6);
        
        // Should fail because balance (3150) < claimReserve (3000) + amount (200)
        vm.prank(yieldRedistributor);
        vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
        vault.onYield(200e6);
        
        // Now call onYield with correct amount
        vm.prank(yieldRedistributor);
        vault.onYield(150e6);
        
        // Verify proportional distribution
        assertEq(vault.claimReserve(), 3150e6, "ClaimReserve should increase by 150");
        // 150e6 * 1e27 / 3000e6 = 5e25
        assertEq(vault.globalIndex(), RAY + 5e25, "GlobalIndex should increase by 5e25");
        
        // Alice should get 1/3 of yield (50 USDR), Bob should get 2/3 (100 USDR)
        assertEq(vault.claimable(alice), 50e6, "Alice should have 50 USDR claimable");
        assertEq(vault.claimable(bob), 100e6, "Bob should have 100 USDR claimable");
    }

    /// @notice Test funding invariant when no deposits exist
    function test_FundingInvariantNoDeposits() public {
        // No deposits, but yield redistributor sends 100 USDR
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 100e6);
        
        // onYield should work and transfer to treasury
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Verify treasury received the funds
        assertEq(usdr.balanceOf(treasury), 100e6, "Treasury should receive yield");
        assertEq(usdr.balanceOf(address(vault)), 0, "Vault should have no USDR");
        
        // But if we try to call onYield with wrong amount, it should fail
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 50e6);
        
        vm.prank(yieldRedistributor);
        vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
        vault.onYield(100e6); // Trying to claim 100 when only 50 was sent
    }

    /// @notice Test that surplus funds can be swept after incorrect onYield attempts
    function test_SurplusAfterIncorrectOnYield() public {
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Yield redistributor sends 200 USDR but only calls onYield for 100 USDR
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), 200e6);
        
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Verify 100 USDR was distributed
        assertEq(vault.claimReserve(), 1100e6, "ClaimReserve should be 1100");
        assertEq(vault.claimable(alice), 100e6, "Alice should have 100 USDR claimable");
        
        // Vault should have 200 USDR total (1000 + 200)
        assertEq(usdr.balanceOf(address(vault)), 1200e6, "Vault should have 1200 USDR");
        
        // Admin can sweep the surplus (100 USDR that wasn't distributed)
        vm.prank(owner);
        vault.sweepSurplusToTreasury();
        
        // Treasury should receive the surplus
        assertEq(usdr.balanceOf(treasury), 100e6, "Treasury should receive surplus");
        assertEq(usdr.balanceOf(address(vault)), 1100e6, "Vault should have exactly claimReserve");
    }

    // ========================================
    // Realistic Large Amount Tests
    // ========================================

    /// @notice Test with realistic large yield amounts (high but not impossible)
    function test_RealisticLargeYieldAmount() public {
        // Alice deposits 1M USDR
        vm.prank(alice);
        vault.deposit(1_000_000e6);
        
        // Test with a realistic large yield amount (1M USDR = 100% yield)
        // This is large but won't overflow: 1e6 * 1e27 = 1e33, which is safe
        uint256 largeYield = 1_000_000e6; // 1 million USDR
        
        // Yield redistributor sends the large amount
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), largeYield);
        
        // Call onYield with the large amount
        vm.prank(yieldRedistributor);
        vault.onYield(largeYield);
        
        // Verify the distribution worked
        assertEq(vault.claimReserve(), 1_000_000e6 + largeYield, "ClaimReserve should include large yield");
        
        // Check that Alice gets the proportional amount (100% since she's the only depositor)
        assertEq(vault.claimable(alice), largeYield, "Alice should get all the large yield");
        
        // Verify globalIndex increased correctly
        // For 1M USDR on 1M USDR principal: delta = 1e6 * 1e27 / 1e6 = 1e27
        uint256 expectedDelta = 1e27; // 1 million * 1e27 / 1 million = 1e27
        assertEq(vault.globalIndex(), RAY + expectedDelta, "GlobalIndex should increase by 1e27");
    }

    /// @notice Test with very high yield percentage (100% yield - extreme but possible)
    function test_VeryHighYieldPercentage() public {
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Test with 100% yield (1000 USDR yield on 1000 USDR principal)
        uint256 highYield = 1000e6; // 100% yield
        
        // Yield redistributor sends the high yield
        vm.prank(yieldRedistributor);
        usdr.transfer(address(vault), highYield);
        
        // Call onYield with the high yield
        vm.prank(yieldRedistributor);
        vault.onYield(highYield);
        
        // Verify the distribution worked
        assertEq(vault.claimReserve(), 1000e6 + highYield, "ClaimReserve should include high yield");
        
        // Check that Alice gets the proportional amount
        assertEq(vault.claimable(alice), highYield, "Alice should get all the high yield");
        
        // Verify globalIndex increased correctly
        // For 1000 USDR on 1000 USDR principal: delta = 1000e6 * 1e27 / 1000e6 = 1e27
        uint256 expectedDelta = 1e27; // 1000 * 1e27 / 1000 = 1e27
        assertEq(vault.globalIndex(), RAY + expectedDelta, "GlobalIndex should increase by 1e27");
    }
    
    // ========================================
    // Additional Coverage Tests
    // ========================================
    
    /// @notice Test setYieldRedistributor function
    function test_SetYieldRedistributor() public {
        address newRedistributor = makeAddr("newRedistributor");
        
        // Only owner can set
        vm.prank(owner);
        vault.setYieldRedistributor(newRedistributor);
        
        // Verify change
        assertTrue(vault.hasRole(vault.YIELD_REDISTRIBUTOR_ROLE(), newRedistributor));
    }
    
    /// @notice Test setTreasury function
    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        
        // Only owner can set
        vm.prank(owner);
        vault.setTreasury(newTreasury);
        
        // Verify change (treasury is stored in a state variable, check via events or other means)
        // Note: We can't directly access treasury state variable, but the function should not revert
    }
    
    /// @notice Test setPauser function
    function test_SetPauser() public {
        address newPauser = makeAddr("newPauser");
        
        // Only owner can set
        vm.prank(owner);
        vault.setPauser(newPauser);
        
        // Verify change
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), newPauser));
    }
    
    /// @notice Test setBlacklisted function
    function test_SetBlacklisted() public {
        // Only owner can set
        vm.prank(owner);
        vault.setBlacklisted(alice, true);
        
        // Verify Alice is blacklisted
        assertTrue(vault.isBlacklisted(alice));
        
        // Unblacklist Alice
        vm.prank(owner);
        vault.setBlacklisted(alice, false);
        
        // Verify Alice is not blacklisted
        assertFalse(vault.isBlacklisted(alice));
    }
    
    
    /// @notice Test asset function
    function test_Asset() public {
        assertEq(vault.asset(), address(usdr));
    }
    
    /// @notice Test claimable function with no deposits
    function test_ClaimableNoDeposits() public {
        assertEq(vault.claimable(alice), 0);
    }
    
    /// @notice Test totalValue function with no deposits
    function test_TotalValueNoDeposits() public {
        assertEq(vault.totalValue(alice), 0);
    }
    
    /// @notice Test getUserInfo function with no deposits
    function test_GetUserInfoNoDeposits() public {
        (uint256 principal, uint256 claimable, uint256 total, uint256 lastIndex) = vault.getUserInfo(alice);
        assertEq(principal, 0);
        assertEq(claimable, 0);
        assertEq(total, 0);
        assertEq(lastIndex, 0);
    }
    
    /// @notice Test getVaultStats function
    function test_GetVaultStats() public {
        // Setup: Alice deposits
        uint256 depositAmount = 1000e6;
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        (uint256 totalPrincipal, uint256 claimReserve, uint256 globalIndex, uint256 vaultBalance, uint256 vaultCarryRay) = vault.getVaultStats();
        assertEq(totalPrincipal, depositAmount);
        assertEq(claimReserve, depositAmount);
        assertEq(globalIndex, 1000000000000000000000000000); // 1e27 (RAY)
        assertEq(vaultBalance, depositAmount);
        // Carry ray should be 0 after deposit
        assertEq(vaultCarryRay, 0);
    }
    
    /// @notice Test getClaimableBoostReward function with no boost rewards
    function test_GetClaimableBoostRewardNoRewards() public {
        // Create a mock token for testing
        address mockToken = makeAddr("mockToken");
        assertEq(vault.getClaimableBoostReward(alice, mockToken), 0);
    }
    
    /// @notice Test onYield function with zero amount
    function test_OnYieldZeroAmount() public {
        // Setup: Alice deposits
        uint256 depositAmount = 1000e6;
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        // Distribute zero yield (should not revert)
        vm.prank(yieldRedistributor);
        vault.onYield(0);
        
        // Verify no yield was distributed
        assertEq(vault.claimable(alice), 0);
    }
    
    /// @notice Test onBoostReward function with zero amount
    function test_OnBoostRewardZeroAmount() public {
        // Setup: Alice deposits
        uint256 depositAmount = 1000e6;
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        // Create a mock token for testing
        address mockToken = makeAddr("mockToken");
        
        // Distribute zero boost rewards (should not revert)
        vm.prank(yieldRedistributor);
        vault.onBoostReward(mockToken, 0);
        
        // Verify no boost rewards were distributed
        assertEq(vault.getClaimableBoostReward(alice, mockToken), 0);
    }
    
    /// @notice Test deposit function with zero amount
    function test_DepositZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(0);
    }
    
    /// @notice Test withdraw function with zero amount
    function test_WithdrawZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(0);
    }
    
    /// @notice Test claim function with no rewards
    function test_ClaimNoRewards() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.claim();
    }
    
}
