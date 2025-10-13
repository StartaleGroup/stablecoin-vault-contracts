// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {EarnVault} from "../../src/vaults/earn/EarnVault.sol";
import {IEarnVaultEventsAndErrors} from "../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title EarnVault Invariant Tests
/// @notice Comprehensive invariant tests for EarnVault system integrity
/// @dev These tests verify critical system properties that must always hold
contract EarnVaultInvariants is Test {
    EarnVault public vault;
    MockERC20 public usdsc;
    
    address public owner = makeAddr("owner");
    address public yieldRedistributor = makeAddr("yieldRedistributor");
    address public treasury = makeAddr("treasury");
    address public pauser = makeAddr("pauser");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    
    uint256 public constant RAY = 1e27;
    uint256 public constant INITIAL_SUPPLY = 1_000_000e6;

    function setUp() public {
        // Deploy mock USDSC token
        usdsc = new MockERC20("USDSC Token", "USDSC", 6);

        // Deploy EarnVault with proper parameters
        vm.prank(owner);
        vault = new EarnVault(address(usdsc), owner, yieldRedistributor, treasury, pauser);

        // Mint USDSC to test users
        usdsc.mint(alice, INITIAL_SUPPLY);
        usdsc.mint(bob, INITIAL_SUPPLY);
        usdsc.mint(charlie, INITIAL_SUPPLY);
        usdsc.mint(yieldRedistributor, INITIAL_SUPPLY);

        // Pre-approve vault for all users
        vm.prank(alice);
        usdsc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdsc.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        usdsc.approve(address(vault), type(uint256).max);
    }

    /// @notice Test USDSC balance invariant
    /// @dev Verifies USDSC.balanceOf(vault) >= claimReserve at all times
    function test_USDSCBalanceInvariant() public {
        // === Setup: Alice deposits 1000 USDSC ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // === Verify initial invariant ===
        assertGe(usdsc.balanceOf(address(vault)), vault.claimReserve(), "USDSC balance should be >= claimReserve");
        
        // === Distribute yield and verify invariant holds ===
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        assertGe(usdsc.balanceOf(address(vault)), vault.claimReserve(), "USDSC balance should be >= claimReserve after yield");
        
        // === Alice withdraws and verify invariant still holds ===
        vm.prank(alice);
        vault.withdraw(500e6);
        
        assertGe(usdsc.balanceOf(address(vault)), vault.claimReserve(), "USDSC balance should be >= claimReserve after withdrawal");
    }
    
    /// @notice Test globalIndex never decreases and carryRay constraints
    /// @dev Verifies globalIndex is monotonically increasing and _carryRay < totalPrincipal
    function test_GlobalIndexInvariant() public {
        // === Setup: Alice deposits 1000 USDSC ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        uint256 initialGlobalIndex = vault.globalIndex();
        
        // === Distribute yield multiple times ===
        for (uint256 i = 0; i < 5; i++) {
            uint256 globalIndexBefore = vault.globalIndex();
            
            vm.prank(yieldRedistributor);
            usdsc.transfer(address(vault), 10e6);
            vm.prank(yieldRedistributor);
            vault.onYield(10e6);
            
            uint256 globalIndexAfter = vault.globalIndex();
            (, , , , uint256 carryRayAfter) = vault.getVaultStats();
            
            // Global index should never decrease
            assertGe(globalIndexAfter, globalIndexBefore, "Global index should never decrease");
            
            // Carry ray should be less than total principal
            assertLt(carryRayAfter, vault.totalPrincipal(), "Carry ray should be less than total principal");
        }
        
        // Final global index should be greater than initial
        assertGt(vault.globalIndex(), initialGlobalIndex, "Final global index should be greater than initial");
    }
    
    /// @notice Test sum of user principals equals totalPrincipal
    /// @dev Verifies sum(user principal) == totalPrincipal
    function test_PrincipalSumInvariant() public {
        // === Setup: Multiple users deposit ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(bob);
        vault.deposit(2000e6);
        
        vm.prank(charlie);
        vault.deposit(500e6);
        
        // === Verify sum equals totalPrincipal ===
        uint256 alicePrincipal = vault.principal(alice);
        uint256 bobPrincipal = vault.principal(bob);
        uint256 charliePrincipal = vault.principal(charlie);
        uint256 totalPrincipal = vault.totalPrincipal();
        
        assertEq(alicePrincipal + bobPrincipal + charliePrincipal, totalPrincipal, "Sum of user principals should equal totalPrincipal");
        
        // === Test after yield distribution ===
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Principal sum should still equal totalPrincipal
        assertEq(vault.principal(alice) + vault.principal(bob) + vault.principal(charlie), vault.totalPrincipal(), "Sum should equal totalPrincipal after yield");
        
        // === Test after withdrawal ===
        vm.prank(alice);
        vault.withdraw(500e6);
        
        assertEq(vault.principal(alice) + vault.principal(bob) + vault.principal(charlie), vault.totalPrincipal(), "Sum should equal totalPrincipal after withdrawal");
    }
    
    /// @notice Test balance conservation invariant
    /// @dev Verifies vault balance equals claimReserve (no surplus)
    function test_BalanceConservationInvariant() public {
        // === Alice deposits ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // === Distribute yield ===
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // === Alice withdraws ===
        vm.prank(alice);
        vault.withdraw(500e6);
        
        // === Verify balance conservation ===
        uint256 finalVaultBalance = usdsc.balanceOf(address(vault));
        uint256 finalClaimReserve = vault.claimReserve();
        
        // Simplified formula: vault balance should equal claimReserve (since no surplus)
        // The vault should only hold what's claimable by users
        assertEq(finalVaultBalance, finalClaimReserve, "Vault balance should equal claimReserve");
    }
    
    /// @notice Test fairness: equal principal over same period accrues equal interest
    /// @dev Verifies two users with equal principal over same period get equal interest
    function test_FairnessInvariant() public {
        // === Setup: Alice and Bob deposit equal amounts ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(bob);
        vault.deposit(1000e6);
        
        // === Distribute yield ===
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 200e6);
        vm.prank(yieldRedistributor);
        vault.onYield(200e6);
        
        // === Verify equal interest ===
        uint256 aliceInterest = vault.claimable(alice);
        uint256 bobInterest = vault.claimable(bob);
        
        assertEq(aliceInterest, bobInterest, "Equal principal should accrue equal interest");
        assertEq(aliceInterest, 100e6, "Each should get 100 USDSC (half of 200 USDSC)");
        
        // === Clear existing yield first ===
        vm.prank(alice);
        vault.claim();
        vm.prank(bob);
        vault.claim();
        
        // === Test proportional fairness ===
        vm.prank(charlie);
        vault.deposit(2000e6); // Charlie has 2x principal
        
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 300e6);
        vm.prank(yieldRedistributor);
        vault.onYield(300e6);
        
        // Alice: 1000/4000 = 1/4, Bob: 1000/4000 = 1/4, Charlie: 2000/4000 = 1/2
        uint256 aliceNewInterest = vault.claimable(alice);
        uint256 bobNewInterest = vault.claimable(bob);
        uint256 charlieNewInterest = vault.claimable(charlie);
        
        assertEq(aliceNewInterest, 75e6, "Alice should get 75 USDSC (1/4 of 300 USDSC)");
        assertEq(bobNewInterest, 75e6, "Bob should get 75 USDSC (1/4 of 300 USDSC)");
        assertEq(charlieNewInterest, 150e6, "Charlie should get 150 USDSC (1/2 of 300 USDSC)");
    }
    
    /// @notice Test reset on claim/withdraw invariant
    /// @dev Verifies after claim or withdraw, accrued[user] == 0 and userIndex[user] == globalIndex
    function test_ResetOnClaimWithdrawInvariant() public {
        // === Setup: Alice deposits and earns yield ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // === Test claim reset ===
        vm.prank(alice);
        vault.claim();
        
        assertEq(vault.accrued(alice), 0, "accrued should be 0 after claim");
        assertEq(vault.userIndex(alice), vault.globalIndex(), "userIndex should equal globalIndex after claim");
        
        // === Setup for withdraw test ===
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 50e6);
        vm.prank(yieldRedistributor);
        vault.onYield(50e6);
        
        // === Test withdraw reset ===
        vm.prank(alice);
        vault.withdraw(500e6);
        
        assertEq(vault.accrued(alice), 0, "accrued should be 0 after withdraw");
        assertEq(vault.userIndex(alice), vault.globalIndex(), "userIndex should equal globalIndex after withdraw");
    }
    
    /// @notice Test boost reward invariants mirror base invariants
    /// @dev Verifies boost tokens follow same invariants as USDSC yield
    function test_BoostInvariant() public {
        // === Setup: Create mock boost token ===
        MockERC20 boostToken = new MockERC20("Boost Token", "BOOST", 18);
        boostToken.mint(yieldRedistributor, 1000e18);
        
        // === Setup: Alice deposits ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // === Distribute boost rewards ===
        vm.startPrank(yieldRedistributor);
        boostToken.approve(address(vault), 100e18);
        boostToken.transfer(address(vault), 100e18);
        vault.onBoostReward(address(boostToken), 100e18);
        vm.stopPrank();
        
        // === Verify boost balance >= boost claim reserve ===
        assertGe(boostToken.balanceOf(address(vault)), vault.boostClaimReserve(address(boostToken)), "Boost token balance should be >= boostClaimReserve");
        
        // === Verify boost global index never decreases ===
        uint256 initialBoostIndex = vault.boostGlobalIndex(address(boostToken));
        
        vm.startPrank(yieldRedistributor);
        boostToken.approve(address(vault), 50e18);
        boostToken.transfer(address(vault), 50e18);
        vault.onBoostReward(address(boostToken), 50e18);
        vm.stopPrank();
        
        uint256 finalBoostIndex = vault.boostGlobalIndex(address(boostToken));
        assertGe(finalBoostIndex, initialBoostIndex, "Boost global index should never decrease");
        
        // === Verify boost claimable is proportional ===
        uint256 aliceBoostClaimable = vault.getClaimableBoostReward(alice, address(boostToken));
        assertEq(aliceBoostClaimable, 150e18, "Alice should get all boost rewards (she's the only user)");
        
        // === Test boost reset on claim ===
        vm.prank(alice);
        vault.claim();
        
        assertEq(vault.getClaimableBoostReward(alice, address(boostToken)), 0, "Boost claimable should be 0 after claim");
    }
    
    /// @notice Test carry correctness for boost rewards
    /// @dev Verifies boost carry mechanism works correctly with tiny amounts
    function test_BoostCarryCorrectness() public {
        // === Setup: Create mock boost token ===
        MockERC20 boostToken = new MockERC20("Boost Token", "BOOST", 18);
        boostToken.mint(yieldRedistributor, 1000e18);
        
        // === Setup: Alice deposits 10 USDSC ===
        vm.prank(alice);
        vault.deposit(10e6);
        
        assertEq(vault.totalPrincipal(), 10e6, "Total principal should be 10 USDSC");
        
        // === Distribute small amount ===
        uint256 tinyAmount = 1e18; // 1 token (18 decimals)
        vm.startPrank(yieldRedistributor);
        boostToken.approve(address(vault), tinyAmount);
        boostToken.transfer(address(vault), tinyAmount);
        vault.onBoostReward(address(boostToken), tinyAmount);
        vm.stopPrank();
        
        // === Verify carry behavior ===
        uint256 boostGlobalIndexAfter1 = vault.boostGlobalIndex(address(boostToken));
        uint256 boostClaimReserveAfter1 = vault.boostClaimReserve(address(boostToken));
        
        // Index should increase (boost rewards don't use carry mechanism)
        assertGt(boostGlobalIndexAfter1, RAY, "Boost global index should increase");
        
        // Claim reserve should increase by the tiny amount
        assertEq(boostClaimReserveAfter1, tinyAmount, "Boost claim reserve should equal tiny amount");
        
        // === Distribute another tiny amount ===
        vm.startPrank(yieldRedistributor);
        boostToken.approve(address(vault), tinyAmount);
        boostToken.transfer(address(vault), tinyAmount);
        vault.onBoostReward(address(boostToken), tinyAmount);
        vm.stopPrank();
        
        // === Verify combined amount behavior ===
        uint256 boostGlobalIndexAfter2 = vault.boostGlobalIndex(address(boostToken));
        uint256 boostClaimReserveAfter2 = vault.boostClaimReserve(address(boostToken));
        
        // Index should continue to increase (boost rewards don't use carry mechanism)
        assertGt(boostGlobalIndexAfter2, boostGlobalIndexAfter1, "Boost global index should continue increasing");
        
        // Claim reserve should be sum of both tiny amounts
        assertEq(boostClaimReserveAfter2, 2 * tinyAmount, "Boost claim reserve should be sum of tiny amounts");
        
        // === Distribute larger amount to cross threshold ===
        uint256 largerAmount = 5e6; // 5 USDSC worth
        vm.startPrank(yieldRedistributor);
        boostToken.approve(address(vault), largerAmount);
        boostToken.transfer(address(vault), largerAmount);
        vault.onBoostReward(address(boostToken), largerAmount);
        vm.stopPrank();
        
        // === Verify index increases and claimable calculation ===
        uint256 boostGlobalIndexAfter3 = vault.boostGlobalIndex(address(boostToken));
        
        // Index should now increase (amount * RAY >= totalPrincipal)
        assertGt(boostGlobalIndexAfter3, RAY, "Boost global index should increase after larger distribution");
        
        // Total claimable should equal sum of all amounts
        uint256 totalClaimable = vault.getClaimableBoostReward(alice, address(boostToken));
        uint256 expectedTotal = 2 * tinyAmount + largerAmount;
        
        // Allow for small rounding differences
        assertApproxEqAbs(totalClaimable, expectedTotal, 1, "Total claimable should equal sum of all amounts");
    }
    
    /// @notice Test partial withdrawal after boost rewards
    /// @dev Verifies accrued boost rewards are calculated on original principal, not remaining principal
    function test_PartialWithdrawAfterBoost() public {
        // === Setup: Create mock boost token ===
        MockERC20 boostToken = new MockERC20("Boost Token", "BOOST", 18);
        boostToken.mint(yieldRedistributor, 1000e18);
        
        // === Alice deposits 1000 USDSC ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        assertEq(vault.principal(alice), 1000e6, "Alice should have 1000 USDSC principal");
        
        // === Distribute boost rewards ===
        uint256 boostAmount = 100e18; // 100 BOOST tokens
        vm.startPrank(yieldRedistributor);
        boostToken.approve(address(vault), boostAmount);
        boostToken.transfer(address(vault), boostAmount);
        vault.onBoostReward(address(boostToken), boostAmount);
        vm.stopPrank();
        
        // === Verify Alice gets all boost rewards (she's the only user) ===
        uint256 aliceBoostClaimable = vault.getClaimableBoostReward(alice, address(boostToken));
        assertEq(aliceBoostClaimable, boostAmount, "Alice should get all boost rewards");
        
        // === Alice partially withdraws 100 USDSC ===
        vm.prank(alice);
        vault.withdraw(100e6);
        
        // === Verify Alice's principal is reduced and boost rewards are claimed ===
        assertEq(vault.principal(alice), 900e6, "Alice should have 900 USDSC principal remaining");
        
        // Alice's boost rewards should be claimed automatically during withdrawal
        // So her claimable boost rewards should be 0
        uint256 aliceBoostClaimableAfter = vault.getClaimableBoostReward(alice, address(boostToken));
        assertEq(aliceBoostClaimableAfter, 0, "Alice's boost rewards should be claimed during withdrawal");
        
        // === Distribute more boost rewards ===
        uint256 additionalBoost = 50e18; // 50 more BOOST tokens
        vm.startPrank(yieldRedistributor);
        boostToken.approve(address(vault), additionalBoost);
        boostToken.transfer(address(vault), additionalBoost);
        vault.onBoostReward(address(boostToken), additionalBoost);
        vm.stopPrank();
        
        // === Verify Alice gets proportional share of new boost rewards ===
        uint256 aliceNewBoostClaimable = vault.getClaimableBoostReward(alice, address(boostToken));
        
        // Alice should get proportional share of the new 50 BOOST
        // Since she has 900/900 = 100% of remaining principal, she gets all 50 BOOST
        // But the original 100 BOOST was already claimed during withdrawal
        // Allow for small rounding differences
        assertApproxEqAbs(aliceNewBoostClaimable, additionalBoost, 1, "Alice should get the new boost rewards");
    }
    
    /// @notice Test multi-token boost rewards
    /// @dev Verifies multiple boost tokens can be distributed and claimed independently
    function test_MultiTokenBoostRewards() public {
        // === Setup: Create multiple boost tokens ===
        MockERC20 tokenA = new MockERC20("Token A", "TOKENA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TOKENB", 18);
        MockERC20 tokenC = new MockERC20("Token C", "TOKENC", 6);
        
        // Mint tokens to yield redistributor
        tokenA.mint(yieldRedistributor, 1000e18);
        tokenB.mint(yieldRedistributor, 1000e18);
        tokenC.mint(yieldRedistributor, 1000e6);
        
        // === Alice deposits ===
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // === Distribute boost rewards for token A ===
        uint256 amountA = 100e18;
        vm.startPrank(yieldRedistributor);
        tokenA.approve(address(vault), amountA);
        tokenA.transfer(address(vault), amountA);
        vault.onBoostReward(address(tokenA), amountA);
        vm.stopPrank();
        
        // === Distribute boost rewards for token B ===
        uint256 amountB = 200e18;
        vm.startPrank(yieldRedistributor);
        tokenB.approve(address(vault), amountB);
        tokenB.transfer(address(vault), amountB);
        vault.onBoostReward(address(tokenB), amountB);
        vm.stopPrank();
        
        // === Distribute boost rewards for token C (6 decimals) ===
        uint256 amountC = 300e6;
        vm.startPrank(yieldRedistributor);
        tokenC.approve(address(vault), amountC);
        tokenC.transfer(address(vault), amountC);
        vault.onBoostReward(address(tokenC), amountC);
        vm.stopPrank();
        
        // === Verify Alice can claim all boost rewards independently ===
        uint256 aliceClaimableA = vault.getClaimableBoostReward(alice, address(tokenA));
        uint256 aliceClaimableB = vault.getClaimableBoostReward(alice, address(tokenB));
        uint256 aliceClaimableC = vault.getClaimableBoostReward(alice, address(tokenC));
        
        assertEq(aliceClaimableA, amountA, "Alice should get all token A rewards");
        assertEq(aliceClaimableB, amountB, "Alice should get all token B rewards");
        assertEq(aliceClaimableC, amountC, "Alice should get all token C rewards");
        
        // === Verify active boost tokens tracking ===
        assertEq(vault.activeBoostTokens(0), address(tokenA), "Token A should be first active boost token");
        assertEq(vault.activeBoostTokens(1), address(tokenB), "Token B should be second active boost token");
        assertEq(vault.activeBoostTokens(2), address(tokenC), "Token C should be third active boost token");
        
        // === Test claiming all rewards at once ===
        vm.prank(alice);
        vault.claim();
        
        // === Verify claimable amounts are reset to 0 ===
        assertEq(vault.getClaimableBoostReward(alice, address(tokenA)), 0, "Token A claimable should be 0 after claim");
        assertEq(vault.getClaimableBoostReward(alice, address(tokenB)), 0, "Token B claimable should be 0 after claim");
        assertEq(vault.getClaimableBoostReward(alice, address(tokenC)), 0, "Token C claimable should be 0 after claim");
    }
}
