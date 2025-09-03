// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {EarnVault} from "../../src/vaults/earn/EarnVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract EarnVaultTest is Test {
    EarnVault public vault;
    MockERC20 public usdr;
    
    address public owner = makeAddr("owner");
    address public distributor = makeAddr("distributor");
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    
    uint256 public constant PRECISION = 1e18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event InterestClaimed(address indexed user, uint256 amount);
    event YieldIndexed(uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
    
    function setUp() public {
        // Deploy mock USDR token
        usdr = new MockERC20("USDR Token", "USDR", 18);
        
        // Deploy EarnVault with proper parameters
        vm.prank(owner);
        vault = new EarnVault(address(usdr), owner, distributor, treasury);
        
        // Mint USDR to test users
        usdr.mint(alice, INITIAL_SUPPLY);
        usdr.mint(bob, INITIAL_SUPPLY);
        usdr.mint(charlie, INITIAL_SUPPLY);
        usdr.mint(distributor, INITIAL_SUPPLY);
        
        // Pre-approve vault for all users
        vm.prank(alice);
        usdr.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdr.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        usdr.approve(address(vault), type(uint256).max);
        vm.prank(distributor);
        usdr.approve(address(vault), type(uint256).max);
    }
    
    // ========================================
    // Basic Deposit/Withdraw Tests
    // ========================================
    
    /// @notice Test basic deposit functionality and state updates
    function test_BasicDeposit() public {
        uint256 depositAmount = 1000e18;
        
        // Record initial state
        uint256 initialBalance = usdr.balanceOf(alice);
        uint256 initialVaultBalance = usdr.balanceOf(address(vault));
        
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Deposit(alice, depositAmount);
        vault.deposit(depositAmount);
        
        // Verify state changes
        assertEq(vault.principal(alice), depositAmount, "Alice's principal should be 1000");
        assertEq(vault.totalPrincipal(), depositAmount, "Total principal should be 1000");
        assertEq(vault.claimReserve(), depositAmount, "Claim reserve should equal principal");
        assertEq(vault.userIndex(alice), PRECISION, "Alice's user index should be 1e18");
        assertEq(vault.globalIndex(), PRECISION, "Global index should remain 1e18");
        
        // Verify token transfers
        assertEq(usdr.balanceOf(alice), initialBalance - depositAmount, "Alice's balance should decrease");
        assertEq(usdr.balanceOf(address(vault)), initialVaultBalance + depositAmount, "Vault balance should increase");
    }
    
    /// @notice Test deposit with multiple users to verify proportional tracking
    function test_MultiUserDeposit() public {
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(1000e18);
        
        // Bob deposits 3000 USDR  
        vm.prank(bob);
        vault.deposit(3000e18);
        
        // Verify individual principals
        assertEq(vault.principal(alice), 1000e18, "Alice should have 1000 principal");
        assertEq(vault.principal(bob), 3000e18, "Bob should have 3000 principal");
        
        // Verify total state
        assertEq(vault.totalPrincipal(), 4000e18, "Total principal should be 4000");
        assertEq(vault.claimReserve(), 4000e18, "Claim reserve should be 4000");
        
        // Both users should have same userIndex (no yield yet)
        assertEq(vault.userIndex(alice), PRECISION, "Alice's index should be 1e18");
        assertEq(vault.userIndex(bob), PRECISION, "Bob's index should be 1e18");
    }
    
    /// @notice Test basic withdrawal functionality
    function test_BasicWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 600e18;
        
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
        assertEq(vault.principal(alice), depositAmount - withdrawAmount, "Alice's principal should be 400");
        assertEq(vault.totalPrincipal(), depositAmount - withdrawAmount, "Total principal should be 400");
        assertEq(vault.claimReserve(), depositAmount - withdrawAmount, "Claim reserve should be 400");
        assertEq(usdr.balanceOf(alice), initialBalance + withdrawAmount, "Alice should receive 600 USDR");
    }
    
    /// @notice Test full withdrawal without any yield (should not auto-claim anything)
    function test_FullWithdrawNoYield() public {
        uint256 depositAmount = 1000e18;
        
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        
        // Alice withdraws all her principal
        vm.prank(alice);
        vault.withdraw(depositAmount);
        
        // Verify complete withdrawal
        assertEq(vault.principal(alice), 0, "Alice's principal should be 0");
        assertEq(vault.accrued(alice), 0, "Alice should have no accrued interest");
        assertEq(usdr.balanceOf(alice), initialBalance + depositAmount, "Alice should receive full amount");
    }
    
    // ========================================
    // Yield Distribution Tests
    // ========================================
    
    /// @notice Test yield distribution with single user
    function test_SingleUserYieldDistribution() public {
        uint256 depositAmount = 1000e18;
        uint256 yieldAmount = 100e18;
        
        // Alice deposits 1000 USDR
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        // Distributor sends yield
        vm.prank(distributor);
        usdr.transfer(address(vault), yieldAmount);
        
        vm.prank(distributor);
        vm.expectEmit(false, false, false, true);
        emit YieldIndexed(yieldAmount, PRECISION + (yieldAmount * PRECISION) / depositAmount, depositAmount + yieldAmount);
        vault.onYield(yieldAmount);
        
        // Verify global index increased
        uint256 expectedGlobalIndex = PRECISION + (yieldAmount * PRECISION) / depositAmount; // 1.1e18
        assertEq(vault.globalIndex(), expectedGlobalIndex, "Global index should increase by 0.1e18");
        
        // Verify claim reserve includes yield
        assertEq(vault.claimReserve(), depositAmount + yieldAmount, "Claim reserve should include yield");
        
        // Alice should have claimable yield
        assertEq(vault.claimable(alice), yieldAmount, "Alice should have 100 USDR claimable");
    }
    
    /// @notice Test proportional yield distribution with multiple users
    function test_ProportionalYieldDistribution() public {
        // Alice deposits 1000 USDR (25% of total)
        vm.prank(alice);
        vault.deposit(1000e18);
        
        // Bob deposits 3000 USDR (75% of total)
        vm.prank(bob);
        vault.deposit(3000e18);
        
        uint256 yieldAmount = 400e18;
        
        // Distributor sends yield
        vm.prank(distributor);
        usdr.transfer(address(vault), yieldAmount);
        
        vm.prank(distributor);
        vault.onYield(yieldAmount);
        
        // Calculate expected claimable amounts (proportional to deposits)
        uint256 aliceExpected = 100e18; // 25% of 400 = 100
        uint256 bobExpected = 300e18;   // 75% of 400 = 300
        
        assertEq(vault.claimable(alice), aliceExpected, "Alice should get 25% of yield");
        assertEq(vault.claimable(bob), bobExpected, "Bob should get 75% of yield");
        
        // Verify total distribution equals yield
        assertEq(vault.claimable(alice) + vault.claimable(bob), yieldAmount, "Total claimable should equal yield");
    }
    
    /// @notice Test yield distribution when no deposits exist (parking mechanism)
    function test_YieldParkingWhenNoDeposits() public {
        uint256 yieldAmount = 500e18;
        
        // Send yield when no one has deposited (totalPrincipal = 0)
        vm.prank(distributor);
        usdr.transfer(address(vault), yieldAmount);
        
        vm.prank(distributor);
        vault.onYield(yieldAmount);
        
        // Yield should be parked, not indexed
        assertEq(vault.globalIndex(), PRECISION, "Global index should remain unchanged");
        assertEq(vault.claimReserve(), yieldAmount, "Yield should be added to claim reserve");
        
        // Now Alice deposits - she shouldn't get the parked yield automatically
        vm.prank(alice);
        vault.deposit(1000e18);
        
        assertEq(vault.claimable(alice), 0, "Alice shouldn't get parked yield automatically");
        assertEq(vault.claimReserve(), yieldAmount + 1000e18, "Reserve should include both yield and principal");
    }
    
    // ========================================
    // Claim Functionality Tests  
    // ========================================
    
    /// @notice Test basic claim functionality
    function test_BasicClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 yieldAmount = 100e18;
        
        // Setup: Alice deposits and yield is distributed
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        vm.prank(distributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(distributor);
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
    
    /// @notice Test claimTo functionality (claiming to different address)
    function test_ClaimTo() public {
        uint256 depositAmount = 1000e18;
        uint256 yieldAmount = 100e18;
        address recipient = makeAddr("recipient");
        
        // Setup: Alice deposits and yield is distributed
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        vm.prank(distributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(distributor);
        vault.onYield(yieldAmount);
        
        uint256 initialRecipientBalance = usdr.balanceOf(recipient);
        uint256 claimableAmount = vault.claimable(alice);
        
        // Alice claims to recipient
        vm.prank(alice);
        vault.claimTo(recipient);
        
        // Verify claim went to recipient
        assertEq(vault.accrued(alice), 0, "Alice's accrued should be reset");
        assertEq(usdr.balanceOf(recipient), initialRecipientBalance + claimableAmount, "Recipient should receive yield");
    }
    
    /// @notice Test multiple claims over time
    function test_MultipleClaims() public {
        uint256 depositAmount = 1000e18;
        
        // Alice deposits
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        // First yield distribution: 100 USDR
        vm.prank(distributor);
        usdr.transfer(address(vault), 100e18);
        vm.prank(distributor);
        vault.onYield(100e18);
        
        // Alice claims first yield
        vm.prank(alice);
        vault.claim();
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable after first claim");
        
        // Second yield distribution: 50 USDR
        vm.prank(distributor);
        usdr.transfer(address(vault), 50e18);
        vm.prank(distributor);
        vault.onYield(50e18);
        
        // Alice should now have new claimable amount
        assertEq(vault.claimable(alice), 50e18, "Alice should have 50 USDR claimable from second yield");
        
        // Alice claims second yield
        vm.prank(alice);
        vault.claim();
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable after second claim");
    }
    
    // ========================================
    // Full Withdrawal with Auto-Claim Tests
    // ========================================
    
    /// @notice Test full withdrawal automatically claims accrued interest
    function test_FullWithdrawAutoClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 yieldAmount = 100e18;
        
        // Setup: Alice deposits and yield is distributed
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        vm.prank(distributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(distributor);
        vault.onYield(yieldAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        uint256 claimableAmount = vault.claimable(alice);
        
        // Alice withdraws all principal (should auto-claim interest)
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Withdraw(alice, depositAmount);
        vm.expectEmit(true, false, false, true);
        emit InterestClaimed(alice, claimableAmount);
        vault.withdraw(depositAmount);
        
        // Verify Alice received both principal and interest
        assertEq(vault.principal(alice), 0, "Alice's principal should be 0");
        assertEq(vault.accrued(alice), 0, "Alice's accrued should be 0");
        assertEq(usdr.balanceOf(alice), initialBalance + depositAmount + claimableAmount, "Alice should receive principal + interest");
    }
    
    /// @notice Test partial withdrawal does not auto-claim interest
    function test_PartialWithdrawNoAutoClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 600e18;
        uint256 yieldAmount = 100e18;
        
        // Setup: Alice deposits and yield is distributed
        vm.prank(alice);
        vault.deposit(depositAmount);
        
        vm.prank(distributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.prank(distributor);
        vault.onYield(yieldAmount);
        
        uint256 initialBalance = usdr.balanceOf(alice);
        uint256 claimableBefore = vault.claimable(alice);
        
        // Alice withdraws partial amount
        vm.prank(alice);
        vault.withdraw(withdrawAmount);
        
        // Verify interest is NOT auto-claimed
        assertEq(vault.principal(alice), depositAmount - withdrawAmount, "Alice should have 400 principal remaining");
        assertEq(vault.claimable(alice), claimableBefore, "Claimable amount should remain unchanged");
        assertEq(usdr.balanceOf(alice), initialBalance + withdrawAmount, "Alice should only receive withdrawn principal");
    }
    
    // ========================================
    // Dynamic Principal Change Tests
    // ========================================
    
    /// @notice Test yield calculation when user changes principal over time
    function test_DynamicPrincipalChanges() public {
        // Alice deposits 1000 USDR initially
        vm.prank(alice);
        vault.deposit(1000e18);
        
        // First yield: 100 USDR on 1000 principal
        vm.prank(distributor);
        usdr.transfer(address(vault), 100e18);
        vm.prank(distributor);
        vault.onYield(100e18);
        
        // Alice should have 100 USDR claimable
        assertEq(vault.claimable(alice), 100e18, "Alice should have 100 USDR from first yield");
        
        // Alice deposits another 1000 USDR (settlement happens automatically)
        vm.prank(alice);
        vault.deposit(1000e18);
        
        // Verify her accrued was settled and principal updated
        assertEq(vault.accrued(alice), 100e18, "Previous yield should be settled into accrued");
        assertEq(vault.principal(alice), 2000e18, "Alice should now have 2000 principal");
        assertEq(vault.userIndex(alice), vault.globalIndex(), "Alice's index should be updated to current");
        
        // Second yield: 200 USDR on 2000 total principal
        vm.prank(distributor);
        usdr.transfer(address(vault), 200e18);
        vm.prank(distributor);
        vault.onYield(200e18);
        
        // Alice should have 100 (settled) + 200 (new) = 300 USDR claimable
        assertEq(vault.claimable(alice), 300e18, "Alice should have 300 total claimable");
    }
    
    /// @notice Test multiple users with different deposit timings
    function test_MultiUserDifferentTimings() public {
        // Alice deposits 1000 USDR at start
        vm.prank(alice);
        vault.deposit(1000e18);
        
        // First yield: 100 USDR (Alice gets all)
        vm.prank(distributor);
        usdr.transfer(address(vault), 100e18);
        vm.prank(distributor);
        vault.onYield(100e18);
        
        assertEq(vault.claimable(alice), 100e18, "Alice should get all first yield");
        
        // Bob deposits 1000 USDR after first yield
        vm.prank(bob);
        vault.deposit(1000e18);
        
        // Second yield: 200 USDR (Alice and Bob should split 50/50)
        vm.prank(distributor);
        usdr.transfer(address(vault), 200e18);
        vm.prank(distributor);
        vault.onYield(200e18);
        
        assertEq(vault.claimable(alice), 200e18, "Alice: 100 (first) + 100 (half of second)");
        assertEq(vault.claimable(bob), 100e18, "Bob: 100 (half of second yield)");
    }
    
    // ========================================
    // Edge Cases and Error Conditions
    // ========================================
    
    /// @notice Test attempting to withdraw more than principal
    function test_WithdrawExceedsPrincipal() public {
        vm.prank(alice);
        vault.deposit(1000e18);
        
        // Try to withdraw more than deposited
        vm.prank(alice);
        vm.expectRevert(EarnVault.InsufficientPrincipal.selector);
        vault.withdraw(1500e18);
    }
    
    /// @notice Test claiming when no yield is available
    function test_ClaimWithNoYield() public {
        vm.prank(alice);
        vault.deposit(1000e18);
        
        // Try to claim with no yield distributed
        vm.prank(alice);
        vm.expectRevert(EarnVault.NothingToClaim.selector);
        vault.claim();
    }
    
    /// @notice Test zero amount operations
    function test_ZeroAmountOperations() public {
        // Zero deposit should revert
        vm.prank(alice);
        vm.expectRevert(EarnVault.ZeroAmount.selector);
        vault.deposit(0);
        
        // Zero withdrawal should revert  
        vm.prank(alice);
        vault.deposit(1000e18);
        
        vm.prank(alice);
        vm.expectRevert(EarnVault.ZeroAmount.selector);
        vault.withdraw(0);
        
        // Zero yield should be handled gracefully (no revert)
        vm.prank(distributor);
        vault.onYield(0); // Should not revert
    }
    
    /// @notice Test unauthorized onYield calls
    function test_UnauthorizedYieldCall() public {
        // Random user cannot call onYield
        vm.prank(alice);
        vm.expectRevert(EarnVault.NotDistributor.selector);
        vault.onYield(100e18);
    }
    
    // ========================================
    // View Function Tests
    // ========================================
    
    /// @notice Test claimable view function accuracy
    function test_ClaimableViewFunction() public {
        // Alice deposits
        vm.prank(alice);
        vault.deposit(1000e18);
        
        // Initially no claimable
        assertEq(vault.claimable(alice), 0, "Initially no claimable");
        
        // Distribute yield
        vm.prank(distributor);
        usdr.transfer(address(vault), 100e18);
        vm.prank(distributor);
        vault.onYield(100e18);
        
        // Check claimable before settlement
        assertEq(vault.claimable(alice), 100e18, "Should show 100 claimable before settlement");
        
        // Trigger settlement by calling deposit with 0 (should revert, but let's use another action)
        vm.prank(alice);
        vault.deposit(1e18); // Small deposit to trigger settlement
        
        // Check claimable after settlement
        assertEq(vault.claimable(alice), 100e18, "Should still show 100 claimable after settlement");
    }
    
    /// @notice Test asset view function
    function test_AssetViewFunction() public {
        assertEq(vault.asset(), address(usdr), "Asset should return USDR address");
    }
    
    /// @notice Test totalPrincipal tracking
    function test_TotalPrincipalTracking() public {
        assertEq(vault.totalPrincipal(), 0, "Initially no principal");
        
        vm.prank(alice);
        vault.deposit(1000e18);
        assertEq(vault.totalPrincipal(), 1000e18, "Should be 1000 after Alice deposits");
        
        vm.prank(bob);
        vault.deposit(2000e18);
        assertEq(vault.totalPrincipal(), 3000e18, "Should be 3000 after Bob deposits");
        
        vm.prank(alice);
        vault.withdraw(500e18);
        assertEq(vault.totalPrincipal(), 2500e18, "Should be 2500 after Alice withdraws");
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
        vault.deposit(1000e18);
        
        // Owner can unpause
        vm.prank(owner);
        vault.unpause();
        
        // Operations should work after unpause
        vm.prank(alice);
        vault.deposit(1000e18); // Should not revert
        assertEq(vault.principal(alice), 1000e18, "Deposit should work after unpause");
    }
    
    /// @notice Test only owner can pause
    function test_OnlyOwnerCanPause() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }
    
    /// @notice Test blacklist functionality
    function test_BlacklistFunctionality() public {
        // Initially blacklist is disabled - everyone can deposit
        vm.prank(alice);
        vault.deposit(1000e18);
        assertEq(vault.principal(alice), 1000e18, "Alice should be able to deposit when blacklist disabled");
        
        // Owner enables blacklist mode
        vm.prank(owner);
        vault.setBlacklistMode(true);
        
        // Blacklist Bob
        vm.prank(owner);
        vault.setBlacklisted(bob, true);
        
        // Bob should be blocked from depositing
        vm.prank(bob);
        vm.expectRevert(EarnVault.AddressBlacklisted.selector);
        vault.deposit(1000e18);
        
        // Alice (not blacklisted) should still be able to deposit
        vm.prank(alice);
        vault.deposit(500e18);
        assertEq(vault.principal(alice), 1500e18, "Alice should still be able to deposit");
        
        // Remove Bob from blacklist
        vm.prank(owner);
        vault.setBlacklisted(bob, false);
        
        // Bob should now be able to deposit
        vm.prank(bob);
        vault.deposit(1000e18);
        assertEq(vault.principal(bob), 1000e18, "Bob should be able to deposit after removal from blacklist");
    }
    
    /// @notice Test only owner can manage blacklist
    function test_OnlyOwnerCanManageBlacklist() public {
        // Non-owner cannot enable blacklist
        vm.prank(alice);
        vm.expectRevert();
        vault.setBlacklistMode(true);
        
        // Non-owner cannot blacklist addresses
        vm.prank(alice);
        vm.expectRevert();
        vault.setBlacklisted(bob, true);
    }
    
    /// @notice Test blacklist blocks depositWithPermit as well
    function test_BlacklistBlocksDepositWithPermit() public {
        // Enable blacklist and blacklist Alice
        vm.prank(owner);
        vault.setBlacklistMode(true);
        vm.prank(owner);
        vault.setBlacklisted(alice, true);
        
        // Alice cannot use depositWithPermit when blacklisted
        vm.prank(alice);
        vm.expectRevert(EarnVault.AddressBlacklisted.selector);
        vault.depositWithPermit(1000e18, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }
    
    /// @notice Test distributor role management
    function test_DistributorManagement() public {
        address newDistributor = makeAddr("newDistributor");
        
        // Only owner can change distributor
        vm.prank(alice);
        vm.expectRevert();
        vault.setDistributor(newDistributor);
        
        // Owner can change distributor
        vm.prank(owner);
        vault.setDistributor(newDistributor);
        assertEq(vault.distributor(), newDistributor, "Distributor should be updated");
        
        // Old distributor should no longer work
        vm.prank(distributor);
        vm.expectRevert(EarnVault.NotDistributor.selector);
        vault.onYield(100e18);
        
        // New distributor should work
        usdr.mint(newDistributor, 1000e18);
        vm.prank(newDistributor);
        usdr.approve(address(vault), type(uint256).max);
        
        vm.prank(alice);
        vault.deposit(1000e18);
        
        vm.prank(newDistributor);
        usdr.transfer(address(vault), 100e18);
        vm.prank(newDistributor);
        vault.onYield(100e18); // Should not revert
    }
    
    // ========================================
    // Integration Test: Complete User Journey
    // ========================================
    
    /// @notice Test complete user journey with multiple actions
    function test_CompleteUserJourney() public {
        // === Phase 1: Initial deposits ===
        vm.prank(alice);
        vault.deposit(1000e18);
        
        vm.prank(bob);
        vault.deposit(2000e18);
        
        assertEq(vault.totalPrincipal(), 3000e18, "Total principal should be 3000");
        
        // === Phase 2: First yield distribution ===
        vm.prank(distributor);
        usdr.transfer(address(vault), 300e18);
        vm.prank(distributor);
        vault.onYield(300e18);
        
        // Alice should get 1/3, Bob should get 2/3
        assertEq(vault.claimable(alice), 100e18, "Alice should have 100 claimable");
        assertEq(vault.claimable(bob), 200e18, "Bob should have 200 claimable");
        
        // === Phase 3: Alice claims, Bob doesn't ===
        vm.prank(alice);
        vault.claim();
        
        assertEq(vault.claimable(alice), 0, "Alice should have no claimable after claim");
        assertEq(vault.claimable(bob), 200e18, "Bob should still have 200 claimable");
        
        // === Phase 4: Charlie joins ===
        vm.prank(charlie);
        vault.deposit(3000e18);
        
        assertEq(vault.totalPrincipal(), 6000e18, "Total should be 6000 after Charlie joins");
        
        // === Phase 5: Second yield distribution ===
        vm.prank(distributor);
        usdr.transfer(address(vault), 600e18);
        vm.prank(distributor);
        vault.onYield(600e18);
        
        // Distribution: Alice 1000/6000, Bob 2000/6000, Charlie 3000/6000
        // Alice: 0 + 100 = 100
        // Bob: 200 + 200 = 400  
        // Charlie: 0 + 300 = 300
        assertEq(vault.claimable(alice), 100e18, "Alice should have 100 from second yield");
        assertEq(vault.claimable(bob), 400e18, "Bob should have 400 total");
        assertEq(vault.claimable(charlie), 300e18, "Charlie should have 300 from second yield");
        
        // === Phase 6: Bob does full withdrawal (auto-claim) ===
        uint256 bobInitialBalance = usdr.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(2000e18);
        
        assertEq(vault.principal(bob), 0, "Bob should have no principal");
        assertEq(vault.claimable(bob), 0, "Bob should have no claimable");
        assertEq(usdr.balanceOf(bob), bobInitialBalance + 2000e18 + 400e18, "Bob should get principal + interest");
        
        // === Phase 7: Final state verification ===
        assertEq(vault.totalPrincipal(), 4000e18, "Total should be 4000 after Bob leaves");
        assertEq(vault.claimable(alice), 100e18, "Alice claimable unchanged");
        assertEq(vault.claimable(charlie), 300e18, "Charlie claimable unchanged");
    }
}
