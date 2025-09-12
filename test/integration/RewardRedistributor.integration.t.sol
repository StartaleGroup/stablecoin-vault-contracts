// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/distributor/RewardRedistributor.sol";
import "../../src/vaults/earn/EarnVault.sol";
import "../../src/vaults/4626/SUSDRVault.sol";
import "../../src/interfaces/vaults/earn/IEarnVault.sol";
import "lib/evm-m-extensions/src/projects/yieldToOne/IMYieldToOne.sol";
import "../mocks/MockUSDR.sol";
import "../mocks/MockExtension.sol";

/// @title RewardRedistributor Integration Tests
/// @notice Tests RewardRedistributor with real EarnVault and SUSDRVault contracts
/// @dev Uses MockUSDR and MockExtension for yield simulation while testing real vault interactions
contract RewardRedistributorIntegrationTest is Test {
    // Contracts
    MockUSDR usdr;
    MockExtension ext;
    EarnVault earnVault;
    SUSDRVault susdrVault;
    RewardRedistributor rr;
    
    // Test addresses
    address admin = address(0x1234567890AbcdEF1234567890aBcdef12345678);
    address operator = address(0x0123456789abcDEF0123456789abCDef01234567);
    address startale = address(0x57a4700000000000000000000000000000000000);
    address treasury = address(0x7890123456789AbcdeF0123456789AbCDef01234);
    address pauser = address(0xabCDeF0123456789AbcdEf0123456789aBCDEF01);
    
    // Test users
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    address charlie = address(0xc4a12);
    
    function setUp() public {
        // Deploy MockUSDR
        usdr = new MockUSDR();
        
        // Deploy real vaults (use admin as temporary yieldRedistributor)
        earnVault = new EarnVault(
            address(usdr),
            admin,          // owner
            admin,          // yieldRedistributor (temporary, will be updated)
            treasury,       // treasury
            pauser          // pauser
        );
        
        susdrVault = new SUSDRVault(
            IERC20(address(usdr)),
            admin,          // admin
            pauser          // pauser
        );
        
        // Deploy MockExtension (will be set as yieldRecipient later)
        ext = new MockExtension(usdr, address(0));
        
        // Deploy RewardRedistributor
        rr = new RewardRedistributor(
            IERC20(address(usdr)),
            IMYieldToOne(address(ext)),
            startale,
            IEarnVault(address(earnVault)),
            IERC4626(address(susdrVault)),
            admin
        );
        
        // Set up roles and permissions
        vm.startPrank(admin);
        bytes32 operatorRole = rr.OPERATOR_ROLE();
        rr.grantRole(operatorRole, operator);
        
        // Set RewardRedistributor as yieldRedistributor in EarnVault
        earnVault.setYieldRedistributor(address(rr));
        vm.stopPrank();
        
        // Set RewardRedistributor as yieldRecipient in MockExtension
        ext.setYieldRecipient(address(rr));
        
        // Mint initial supply and distribute to test users
        usdr.mint(address(this), 100_000_000e6); // 100M USDR
        usdr.transfer(alice, 10_000_000e6);
        usdr.transfer(bob, 5_000_000e6);
        usdr.transfer(charlie, 2_000_000e6);
        
        // Set up initial vault states with user deposits
        _setupInitialVaultStates();
    }
    
    function _setupInitialVaultStates() internal {
        // Alice deposits in EarnVault
        vm.startPrank(alice);
        usdr.approve(address(earnVault), 1_000_000e6);
        earnVault.deposit(1_000_000e6);
        vm.stopPrank();
        
        // Bob deposits in SUSDRVault
        vm.startPrank(bob);
        usdr.approve(address(susdrVault), 1_000_000e6);
        susdrVault.deposit(1_000_000e6, bob);
        vm.stopPrank();
        
        // Charlie deposits in both vaults
        vm.startPrank(charlie);
        usdr.approve(address(earnVault), 500_000e6);
        usdr.approve(address(susdrVault), 500_000e6);
        earnVault.deposit(500_000e6);
        susdrVault.deposit(500_000e6, charlie);
        vm.stopPrank();
    }
    
    // ========== INTEGRATION INVARIANT TESTS ==========
    
    function testIntegration_ConservationWithRealVaults() public {
        ext.addPending(100_000e6);
        
        uint256 initialTotalSupply = usdr.totalSupply();
        uint256 initialStartaleBalance = usdr.balanceOf(startale);
        uint256 initialEarnBalance = usdr.balanceOf(address(earnVault));
        uint256 initialSUSDRBalance = usdr.balanceOf(address(susdrVault));
        
        vm.prank(operator);
        rr.distribute();
        
        uint256 finalTotalSupply = usdr.totalSupply();
        uint256 finalStartaleBalance = usdr.balanceOf(startale);
        uint256 finalEarnBalance = usdr.balanceOf(address(earnVault));
        uint256 finalSUSDRBalance = usdr.balanceOf(address(susdrVault));
        
        // Verify conservation
        uint256 minted = finalTotalSupply - initialTotalSupply;
        uint256 distributed = (finalStartaleBalance - initialStartaleBalance) + 
                              (finalEarnBalance - initialEarnBalance) + 
                              (finalSUSDRBalance - initialSUSDRBalance);
        
        assertEq(minted, distributed, "conservation: minted == distributed");
        assertEq(usdr.balanceOf(address(rr)), 0, "no dust left in redistributor");
    }
    
    function testIntegration_EarnVaultFundingInvariant() public {
        ext.addPending(50_000e6);
        
        uint256 claimReserveBefore = earnVault.claimReserve();
        uint256 earnBalanceBefore = usdr.balanceOf(address(earnVault));
        
        vm.prank(operator);
        rr.distribute();
        
        uint256 claimReserveAfter = earnVault.claimReserve();
        uint256 earnBalanceAfter = usdr.balanceOf(address(earnVault));
        
        // Verify funding invariant: balance >= claimReserve
        assertGe(earnBalanceAfter, claimReserveAfter, "funding invariant: balance >= claimReserve");
        
        // Verify claimReserve increased (yield was added)
        assertGt(claimReserveAfter, claimReserveBefore, "claimReserve increased");
        
        // Verify balance increased by at least the claimReserve increase
        uint256 claimReserveIncrease = claimReserveAfter - claimReserveBefore;
        uint256 balanceIncrease = earnBalanceAfter - earnBalanceBefore;
        assertGe(balanceIncrease, claimReserveIncrease, "balance increased at least as much as claimReserve");
    }
    
    function testIntegration_SUSDRVaultPPSMonotonic() public {
        // Record initial PPS
        uint256 initialAssets = susdrVault.totalAssets();
        uint256 initialSupply = susdrVault.totalSupply();
        uint256 initialPPS = initialSupply > 0 ? (initialAssets * 1e18) / initialSupply : 1e18;
        
        ext.addPending(75_000e6);
        
        vm.prank(operator);
        rr.distribute();
        
        // Record final PPS
        uint256 finalAssets = susdrVault.totalAssets();
        uint256 finalSupply = susdrVault.totalSupply();
        uint256 finalPPS = finalSupply > 0 ? (finalAssets * 1e18) / finalSupply : 1e18;
        
        // Verify PPS is non-decreasing
        assertGe(finalPPS, initialPPS, "PPS is non-decreasing");
        
        // Verify assets increased (yield was added)
        assertGt(finalAssets, initialAssets, "sUSDR assets increased");
    }
    
    // Note: Terminology currently means toYield = toOn = toERC4626
    // Todo: Keep appropriate and consistent later on once finalised.
    function testIntegration_ProportionalAllocationWithRealTVLs() public {
        ext.addPending(120_000e6);
        
        // Get real TVLs
        uint256 T_earn = earnVault.totalPrincipal();
        uint256 T_yield = susdrVault.totalAssets();
        uint256 S_base = usdr.totalSupply(); // Will be adjusted after minting
        
        (uint256 minted, uint256 feeToStartale, uint256 toEarn, uint256 toYield, uint256 toExtra, , , ) = rr.previewDistribute();
        
        S_base = S_base - minted; // Adjust for the minting that will happen
        uint256 net = minted - feeToStartale;
        
        // Verify proportional allocation (within rounding tolerance)
        if (S_base > 0 && T_earn > 0) {
            uint256 expectedToEarn = (net * T_earn) / S_base;
            assertApproxEqRel(toEarn, expectedToEarn, 0.01e18, "proportional toEarn allocation");
        }
        
        if (S_base > 0 && T_yield > 0) {
            uint256 expectedToYield = (net * T_yield) / S_base;
            assertApproxEqRel(toYield, expectedToYield, 0.01e18, "proportional toYield allocation");
        }
        
        vm.prank(operator);
        rr.distribute();
    }
    
    // ========== USER INTERACTION TESTS ==========
    
    function testIntegration_DepositsWithdrawalsAroundDistribution() public {
        // Initial state
        uint256 aliceEarnPrincipalBefore = earnVault.principal(alice);
        uint256 bobSUSDRSharesBefore = susdrVault.balanceOf(bob);
        
        // Add yield and distribute
        ext.addPending(60_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Verify users can claim/withdraw after distribution
        vm.startPrank(alice);
        uint256 aliceClaimable = earnVault.claimable(alice);
        assertGt(aliceClaimable, 0, "Alice has claimable yield");
        earnVault.claim();
        vm.stopPrank();
        
        // Bob can redeem some sUSDR shares
        vm.startPrank(bob);
        uint256 bobRedeemAmount = bobSUSDRSharesBefore / 4; // Redeem 25%
        uint256 assetsReceived = susdrVault.redeem(bobRedeemAmount, bob, bob);
        assertGt(assetsReceived, bobRedeemAmount, "Bob received more assets than shares (PPS > 1)");
        vm.stopPrank();
        
        // New user can deposit after distribution
        address dave = address(0xdaDE);
        usdr.mint(dave, 1_000_000e6);
        
        vm.startPrank(dave);
        usdr.approve(address(earnVault), 200_000e6);
        usdr.approve(address(susdrVault), 200_000e6);
        
        earnVault.deposit(200_000e6);
        uint256 daveShares = susdrVault.deposit(200_000e6, dave);
        assertGt(daveShares, 0, "Dave received sUSDR shares");
        vm.stopPrank();
        
        // Do another distribution with new user
        ext.addPending(40_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Verify Dave also gets yield
        uint256 daveClaimable = earnVault.claimable(dave);
        assertGt(daveClaimable, 0, "Dave has claimable yield after distribution");
    }
    
    function testIntegration_MultipleDistributionsWithVaryingTVL() public {
        uint256[] memory yields = new uint256[](5);
        yields[0] = 30_000e6;
        yields[1] = 45_000e6;
        yields[2] = 25_000e6;
        yields[3] = 60_000e6;
        yields[4] = 35_000e6;
        
        uint256 totalDistributed = 0;
        
        for (uint256 i = 0; i < yields.length; i++) {
            // Record state before distribution
            uint256 earnAssetsBefore = usdr.balanceOf(address(earnVault));
            uint256 susdrAssetsBefore = susdrVault.totalAssets();
            uint256 startaleBalanceBefore = usdr.balanceOf(startale);
            
            // Add yield and distribute
            ext.addPending(yields[i]);
            vm.prank(operator);
            rr.distribute();
            
            // Verify distribution occurred
            uint256 earnAssetsAfter = usdr.balanceOf(address(earnVault));
            uint256 susdrAssetsAfter = susdrVault.totalAssets();
            uint256 startaleBalanceAfter = usdr.balanceOf(startale);
            
            assertGt(earnAssetsAfter, earnAssetsBefore, "EarnVault assets increased");
            assertGt(susdrAssetsAfter, susdrAssetsBefore, "sUSDR assets increased");
            assertGt(startaleBalanceAfter, startaleBalanceBefore, "Startale balance increased");
            
            totalDistributed += yields[i];
            
            // Simulate user activity between distributions
            if (i % 2 == 0) {
                // Some users deposit more
                vm.startPrank(alice);
                usdr.approve(address(earnVault), 100_000e6);
                earnVault.deposit(100_000e6);
                vm.stopPrank();
            } else {
                // Some users withdraw
                vm.startPrank(bob);
                uint256 bobShares = susdrVault.balanceOf(bob);
                if (bobShares > 100e18) {
                    susdrVault.redeem(100e18, bob, bob);
                }
                vm.stopPrank();
            }
        }
        
        // Verify total conservation over all distributions
        assertEq(usdr.balanceOf(address(rr)), 0, "no dust accumulated");
    }
    
    // ========== USER WITHDRAWAL AND CLAIM TESTS ==========
    
    function testIntegration_EarnVaultWithdrawalsAfterDistribution() public {
        // Initial setup - users have deposited in setUp()
        uint256 aliceInitialPrincipal = earnVault.principal(alice);
        uint256 charlieInitialPrincipal = earnVault.principal(charlie);
        
        // Add yield and distribute
        ext.addPending(80_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Test 1: Alice claims only accrued yield (no principal withdrawal)
        vm.startPrank(alice);
        uint256 aliceClaimable = earnVault.claimable(alice);
        assertGt(aliceClaimable, 0, "Alice has claimable yield");
        
        uint256 aliceBalanceBefore = usdr.balanceOf(alice);
        earnVault.claim();
        uint256 aliceBalanceAfter = usdr.balanceOf(alice);
        
        assertEq(aliceBalanceAfter - aliceBalanceBefore, aliceClaimable, "Alice received exact claimable amount");
        assertEq(earnVault.principal(alice), aliceInitialPrincipal, "Alice principal unchanged after claim");
        assertEq(earnVault.claimable(alice), 0, "Alice has no remaining claimable yield");
        vm.stopPrank();
        
        // Test 2: Charlie does partial principal withdrawal
        vm.startPrank(charlie);
        uint256 charlieClaimableBefore = earnVault.claimable(charlie);
        uint256 charlieBalanceBefore = usdr.balanceOf(charlie);
        uint256 partialWithdrawAmount = charlieInitialPrincipal / 3; // Withdraw 1/3 of principal
        
        earnVault.withdraw(partialWithdrawAmount);
        
        uint256 charlieBalanceAfter = usdr.balanceOf(charlie);
        uint256 charlieNewPrincipal = earnVault.principal(charlie);
        uint256 charlieClaimableAfter = earnVault.claimable(charlie);
        
        // Verify partial withdrawal (EarnVault partial withdrawals do NOT auto-claim interest)
        assertEq(charlieNewPrincipal, charlieInitialPrincipal - partialWithdrawAmount, "Charlie principal reduced by withdrawal amount");
        assertEq(charlieBalanceAfter - charlieBalanceBefore, partialWithdrawAmount, "Charlie received only principal (partial withdrawal)");
        assertEq(charlieClaimableAfter, charlieClaimableBefore, "Charlie accrued yield unchanged after partial withdrawal");
        vm.stopPrank();
        
        // Test 3: Add more yield and test full withdrawal
        ext.addPending(40_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Charlie does full withdrawal (remaining principal + new accrued yield)
        vm.startPrank(charlie);
        uint256 charlieRemainingPrincipal = earnVault.principal(charlie);
        uint256 charlieNewClaimable = earnVault.claimable(charlie);
        uint256 charlieBalanceBeforeFullWithdraw = usdr.balanceOf(charlie);
        
        earnVault.withdraw(charlieRemainingPrincipal);
        
        uint256 charlieBalanceAfterFullWithdraw = usdr.balanceOf(charlie);
        
        assertEq(earnVault.principal(charlie), 0, "Charlie has no remaining principal");
        assertEq(earnVault.claimable(charlie), 0, "Charlie has no remaining claimable yield");
        assertEq(charlieBalanceAfterFullWithdraw - charlieBalanceBeforeFullWithdraw, 
                charlieRemainingPrincipal + charlieNewClaimable, "Charlie received remaining principal + yield");
        vm.stopPrank();
    }
    
    function testIntegration_SUSDRVaultRedemptionsAfterDistribution() public {
        // Get initial state
        uint256 bobInitialShares = susdrVault.balanceOf(bob);
        uint256 charlieInitialShares = susdrVault.balanceOf(charlie);
        uint256 initialPPS = susdrVault.totalSupply() > 0 ? 
            (susdrVault.totalAssets() * 1e18) / susdrVault.totalSupply() : 1e18;
        
        // Add yield and distribute
        ext.addPending(100_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Verify PPS increased
        uint256 newPPS = susdrVault.totalSupply() > 0 ? 
            (susdrVault.totalAssets() * 1e18) / susdrVault.totalSupply() : 1e18;
        assertGt(newPPS, initialPPS, "PPS increased after yield distribution");
        
        // Test 1: Bob redeems 25% of his shares
        vm.startPrank(bob);
        uint256 bobRedeemShares = bobInitialShares / 4;
        uint256 bobBalanceBefore = usdr.balanceOf(bob);
        
        uint256 assetsReceived = susdrVault.redeem(bobRedeemShares, bob, bob);
        
        uint256 bobBalanceAfter = usdr.balanceOf(bob);
        uint256 bobRemainingShares = susdrVault.balanceOf(bob);
        
        assertEq(bobBalanceAfter - bobBalanceBefore, assetsReceived, "Bob received expected assets");
        assertEq(bobRemainingShares, bobInitialShares - bobRedeemShares, "Bob shares reduced correctly");
        assertGt(assetsReceived, bobRedeemShares, "Bob received more assets than shares due to PPS > 1");
        vm.stopPrank();
        
        // Test 2: Charlie withdraws specific asset amount
        vm.startPrank(charlie);
        uint256 charlieTargetAssets = 200_000e6; // Withdraw 200k USDR worth
        uint256 charlieBalanceBefore = usdr.balanceOf(charlie);
        uint256 charlieSharesBefore = susdrVault.balanceOf(charlie);
        
        uint256 sharesBurned = susdrVault.withdraw(charlieTargetAssets, charlie, charlie);
        
        uint256 charlieBalanceAfter = usdr.balanceOf(charlie);
        uint256 charlieSharesAfter = susdrVault.balanceOf(charlie);
        
        assertEq(charlieBalanceAfter - charlieBalanceBefore, charlieTargetAssets, "Charlie received exact target assets");
        assertEq(charlieSharesAfter, charlieSharesBefore - sharesBurned, "Charlie shares reduced by burned amount");
        assertLt(sharesBurned, charlieTargetAssets, "Shares burned less than assets due to PPS > 1");
        vm.stopPrank();
        
        // Test 3: Full redemption
        vm.startPrank(bob);
        uint256 bobFinalShares = susdrVault.balanceOf(bob);
        uint256 bobFinalBalanceBefore = usdr.balanceOf(bob);
        
        uint256 finalAssetsReceived = susdrVault.redeem(bobFinalShares, bob, bob);
        
        uint256 bobFinalBalanceAfter = usdr.balanceOf(bob);
        
        assertEq(susdrVault.balanceOf(bob), 0, "Bob has no remaining shares");
        assertEq(bobFinalBalanceAfter - bobFinalBalanceBefore, finalAssetsReceived, "Bob received all remaining assets");
        assertGt(finalAssetsReceived, 0, "Bob received positive assets from final redemption");
        vm.stopPrank();
    }
    
    function testIntegration_MixedWithdrawalsAfterMultipleDistributions() public {
        // Test complex scenario: multiple distributions with withdrawals in between
        
        // Initial state
        uint256 aliceInitialEarnPrincipal = earnVault.principal(alice);
        uint256 bobInitialSUSDRShares = susdrVault.balanceOf(bob);
        
        // First distribution
        ext.addPending(60_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Alice claims yield but keeps principal
        vm.startPrank(alice);
        uint256 aliceFirstClaimable = earnVault.claimable(alice);
        earnVault.claim();
        vm.stopPrank();
        
        // Bob redeems half his shares
        vm.startPrank(bob);
        uint256 bobFirstRedemption = bobInitialSUSDRShares / 2;
        susdrVault.redeem(bobFirstRedemption, bob, bob);
        vm.stopPrank();
        
        // Second distribution (smaller TVL now due to Bob's redemption)
        ext.addPending(40_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Alice does partial withdrawal
        vm.startPrank(alice);
        uint256 aliceSecondClaimable = earnVault.claimable(alice);
        uint256 alicePartialWithdraw = aliceInitialEarnPrincipal / 4;
        uint256 aliceBalanceBefore = usdr.balanceOf(alice);
        
        earnVault.withdraw(alicePartialWithdraw);
        
        uint256 aliceBalanceAfter = usdr.balanceOf(alice);
        
        // Alice should receive only partial principal (partial withdrawal doesn't auto-claim)
        assertEq(aliceBalanceAfter - aliceBalanceBefore, alicePartialWithdraw, 
                "Alice received only partial principal (partial withdrawal)");
        assertEq(earnVault.principal(alice), aliceInitialEarnPrincipal - alicePartialWithdraw, 
                "Alice principal reduced correctly");
        vm.stopPrank();
        
        // Bob redeems remaining shares
        vm.startPrank(bob);
        uint256 bobRemainingShares = susdrVault.balanceOf(bob);
        uint256 bobFinalBalance = usdr.balanceOf(bob);
        
        uint256 bobFinalAssets = susdrVault.redeem(bobRemainingShares, bob, bob);
        
        // Verify Bob got yield benefit from second distribution
        assertGt(bobFinalAssets, bobRemainingShares, "Bob's final redemption benefited from yield");
        assertEq(susdrVault.balanceOf(bob), 0, "Bob fully exited sUSDR vault");
        vm.stopPrank();
        
        // Third distribution with reduced TVL
        ext.addPending(30_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Verify remaining users still get yield
        uint256 aliceFinalClaimable = earnVault.claimable(alice);
        assertGt(aliceFinalClaimable, 0, "Alice still earning yield on remaining principal");
        
        // Charlie (who didn't withdraw from sUSDR) should have higher PPS
        uint256 charlieShares = susdrVault.balanceOf(charlie);
        uint256 charlieAssetValue = susdrVault.convertToAssets(charlieShares);
        assertGt(charlieAssetValue, charlieShares, "Charlie's shares worth more than face value");
    }
    
    function testIntegration_WithdrawalOrderingAndInvariants() public {
        // Test that withdrawals don't break the system invariants
        
        ext.addPending(50_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Record pre-withdrawal state
        uint256 totalEarnPrincipalBefore = earnVault.totalPrincipal();
        uint256 totalSUSDRAssetsBefore = susdrVault.totalAssets();
        uint256 totalSUSDRSupplyBefore = susdrVault.totalSupply();
        
        // Multiple users withdraw simultaneously
        vm.startPrank(alice);
        uint256 aliceWithdrawAmount = earnVault.principal(alice) / 2;
        earnVault.withdraw(aliceWithdrawAmount);
        vm.stopPrank();
        
        vm.startPrank(bob);
        uint256 bobRedeemShares = susdrVault.balanceOf(bob) / 3;
        susdrVault.redeem(bobRedeemShares, bob, bob);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        uint256 charlieWithdrawAssets = 100_000e6;
        susdrVault.withdraw(charlieWithdrawAssets, charlie, charlie);
        vm.stopPrank();
        
        // Verify invariants still hold
        uint256 totalEarnPrincipalAfter = earnVault.totalPrincipal();
        uint256 totalSUSDRAssetsAfter = susdrVault.totalAssets();
        uint256 totalSUSDRSupplyAfter = susdrVault.totalSupply();
        
        assertEq(totalEarnPrincipalAfter, totalEarnPrincipalBefore - aliceWithdrawAmount, 
                "EarnVault total principal reduced correctly");
        
        // sUSDR vault should maintain proper asset/supply relationship
        if (totalSUSDRSupplyAfter > 0) {
            uint256 newPPS = (totalSUSDRAssetsAfter * 1e18) / totalSUSDRSupplyAfter;
            uint256 oldPPS = (totalSUSDRAssetsBefore * 1e18) / totalSUSDRSupplyBefore;
            assertGe(newPPS, oldPPS, "PPS maintained or increased after withdrawals");
        }
        
        // System should still be able to distribute more yield
        ext.addPending(25_000e6);
        vm.prank(operator);
        rr.distribute(); // Should not revert
        
        // Remaining users should still earn yield
        if (earnVault.principal(alice) > 0) {
            assertGt(earnVault.claimable(alice), 0, "Alice still earning on remaining principal");
        }
        if (susdrVault.balanceOf(charlie) > 0) {
            uint256 charlieCurrentValue = susdrVault.convertToAssets(susdrVault.balanceOf(charlie));
            // Charlie's remaining shares should have gained value
            assertGt(charlieCurrentValue, susdrVault.balanceOf(charlie), "Charlie's remaining shares gained value");
        }
    }

    // ========== EDGE CASE TESTS ==========
    
    function testIntegration_EmptyVaultScenarios() public {
        // Create new clean vaults with no deposits
        EarnVault emptyEarnVault = new EarnVault(
            address(usdr),
            admin,
            address(rr),
            treasury,
            pauser
        );
        
        SUSDRVault emptySUSDRVault = new SUSDRVault(
            IERC20(address(usdr)),
            admin,
            pauser
        );
        
        // Create new redistributor with empty vaults
        RewardRedistributor rrEmpty = new RewardRedistributor(
            IERC20(address(usdr)),
            IMYieldToOne(address(ext)),
            startale,
            IEarnVault(address(emptyEarnVault)),
            IERC4626(address(emptySUSDRVault)),
            admin
        );
        
        vm.startPrank(admin);
        bytes32 operatorRole = rrEmpty.OPERATOR_ROLE();
        rrEmpty.grantRole(operatorRole, operator);
        vm.stopPrank();
        
        // Set the new redistributor as yieldRecipient for this test
        address originalRecipient = ext.yieldRecipient();
        ext.setYieldRecipient(address(rrEmpty));
        
        // Distribute yield to empty vaults
        ext.addPending(50_000e6);
        
        uint256 startaleBalanceBefore = usdr.balanceOf(startale);
        
        vm.prank(operator);
        rrEmpty.distribute();
        
        uint256 startaleBalanceAfter = usdr.balanceOf(startale);
        
        // With empty vaults (TVL = 0), all yield should go to Startale
        assertEq(startaleBalanceAfter - startaleBalanceBefore, 50_000e6, "all yield goes to Startale when vaults empty");
        assertEq(usdr.balanceOf(address(emptyEarnVault)), 0, "empty EarnVault stays empty");
        assertEq(emptySUSDRVault.totalAssets(), 0, "empty sUSDR vault stays empty");
        
        // Restore original recipient
        ext.setYieldRecipient(originalRecipient);
    }
    
    function testIntegration_LargeScaleDistribution() public {
        // Add large amounts to vaults first
        usdr.mint(alice, 50_000_000e6);
        usdr.mint(bob, 30_000_000e6);
        
        vm.startPrank(alice);
        usdr.approve(address(earnVault), 50_000_000e6);
        earnVault.deposit(50_000_000e6);
        vm.stopPrank();
        
        vm.startPrank(bob);
        usdr.approve(address(susdrVault), 30_000_000e6);
        susdrVault.deposit(30_000_000e6, bob);
        vm.stopPrank();
        
        // Large yield distribution
        ext.addPending(10_000_000e6); // 10M yield
        
        uint256 totalSupplyBefore = usdr.totalSupply();
        
        vm.prank(operator);
        rr.distribute();
        
        uint256 totalSupplyAfter = usdr.totalSupply();
        
        // Verify large distribution worked correctly
        assertEq(totalSupplyAfter - totalSupplyBefore, 10_000_000e6, "10M USDR minted");
        assertEq(usdr.balanceOf(address(rr)), 0, "no dust from large distribution");
        
        // Verify proportional allocation still holds
        assertGt(usdr.balanceOf(address(earnVault)), 1_000_000e6, "EarnVault received significant yield");
        assertGt(susdrVault.totalAssets(), 30_000_000e6, "sUSDR vault received yield");
        assertGt(usdr.balanceOf(startale), 1_000_000e6, "Startale received significant amount");
    }
}
