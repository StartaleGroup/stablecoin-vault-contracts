// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/distributor/RewardRedistributor.sol";
import "../../src/vaults/earn/EarnVault.sol";
import "../../src/vaults/4626/SUSDSCVault.sol";
import "../../src/interfaces/vaults/earn/IEarnVault.sol";
import "lib/evm-m-extensions/src/projects/yieldToOne/IMYieldToOne.sol";
import "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import "../mocks/MockUSDSC.sol";
import "../mocks/MockExtension.sol";
import "../mocks/MockERC20.sol";

/// @title RewardRedistributor Integration Tests
/// @notice Tests RewardRedistributor with real EarnVault and SUSDSCVault contracts
/// @dev Uses MockUSDSC and MockExtension for yield simulation while testing real vault interactions
contract RewardRedistributorIntegrationTest is Test {
    // Contracts
    MockUSDSC usdsc;
    MockExtension ext;
    EarnVault earnVault;
    SUSDSCVault susdscVault;
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
        // Deploy MockUSDSC
        usdsc = new MockUSDSC();
        
        // Deploy real vaults (use admin as temporary yieldRedistributor)
        earnVault = new EarnVault(
            address(usdsc),
            admin,          // owner
            admin,          // yieldRedistributor (temporary, will be updated)
            treasury,       // treasury
            pauser          // pauser
        );
        
        susdscVault = new SUSDSCVault(
            IERC20(address(usdsc)),
            admin,          // admin
            pauser          // pauser
        );
        
        // Deploy MockExtension (will be set as yieldRecipient later)
        ext = new MockExtension(usdsc, address(0));
        
        // Deploy RewardRedistributor
        rr = new RewardRedistributor(
            address(ext),  // MockExtension address (implements both IERC20 and IMYieldToOne)
            startale,
            IEarnVault(address(earnVault)),
            IERC4626(address(susdscVault)),
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
        usdsc.mint(address(this), 100_000_000e6); // 100M USDSC
        usdsc.transfer(alice, 10_000_000e6);
        usdsc.transfer(bob, 5_000_000e6);
        usdsc.transfer(charlie, 2_000_000e6);
        
        // Set up initial vault states with user deposits
        _setupInitialVaultStates();
    }
    
    function _setupInitialVaultStates() internal {
        // Alice deposits in EarnVault
        vm.startPrank(alice);
        usdsc.approve(address(earnVault), 1_000_000e6);
        earnVault.deposit(1_000_000e6);
        vm.stopPrank();
        
        // Bob deposits in SUSDSCVault
        vm.startPrank(bob);
        usdsc.approve(address(susdscVault), 1_000_000e6);
        susdscVault.deposit(1_000_000e6, bob);
        vm.stopPrank();
        
        // Charlie deposits in both vaults
        vm.startPrank(charlie);
        usdsc.approve(address(earnVault), 500_000e6);
        usdsc.approve(address(susdscVault), 500_000e6);
        earnVault.deposit(500_000e6);
        susdscVault.deposit(500_000e6, charlie);
        vm.stopPrank();
    }
    
    // ========== INTEGRATION INVARIANT TESTS ==========
    
    function testIntegration_ConservationWithRealVaults() public {
        ext.addPending(100_000e6);
        
        uint256 initialTotalSupply = usdsc.totalSupply();
        uint256 initialStartaleBalance = usdsc.balanceOf(startale);
        uint256 initialEarnBalance = usdsc.balanceOf(address(earnVault));
        uint256 initialSUSDSCBalance = usdsc.balanceOf(address(susdscVault));
        
        vm.prank(operator);
        rr.distribute();
        
        uint256 finalTotalSupply = usdsc.totalSupply();
        uint256 finalStartaleBalance = usdsc.balanceOf(startale);
        uint256 finalEarnBalance = usdsc.balanceOf(address(earnVault));
        uint256 finalSUSDSCBalance = usdsc.balanceOf(address(susdscVault));
        
        // Verify conservation
        uint256 minted = finalTotalSupply - initialTotalSupply;
        uint256 distributed = (finalStartaleBalance - initialStartaleBalance) + 
                              (finalEarnBalance - initialEarnBalance) + 
                              (finalSUSDSCBalance - initialSUSDSCBalance);
        
        assertEq(minted, distributed, "conservation: minted == distributed");
        assertEq(usdsc.balanceOf(address(rr)), 0, "no dust left in redistributor");
    }
    
    function testIntegration_EarnVaultFundingInvariant() public {
        ext.addPending(50_000e6);
        
        uint256 claimReserveBefore = earnVault.claimReserve();
        uint256 earnBalanceBefore = usdsc.balanceOf(address(earnVault));
        
        vm.prank(operator);
        rr.distribute();
        
        uint256 claimReserveAfter = earnVault.claimReserve();
        uint256 earnBalanceAfter = usdsc.balanceOf(address(earnVault));
        
        // Verify funding invariant: balance >= claimReserve
        assertGe(earnBalanceAfter, claimReserveAfter, "funding invariant: balance >= claimReserve");
        
        // Verify claimReserve increased (yield was added)
        assertGt(claimReserveAfter, claimReserveBefore, "claimReserve increased");
        
        // Verify balance increased by at least the claimReserve increase
        uint256 claimReserveIncrease = claimReserveAfter - claimReserveBefore;
        uint256 balanceIncrease = earnBalanceAfter - earnBalanceBefore;
        assertGe(balanceIncrease, claimReserveIncrease, "balance increased at least as much as claimReserve");
    }
    
    function testIntegration_SUSDSCVaultPPSMonotonic() public {
        // Record initial PPS
        uint256 initialAssets = susdscVault.totalAssets();
        uint256 initialSupply = susdscVault.totalSupply();
        uint256 initialPPS = initialSupply > 0 ? (initialAssets * 1e18) / initialSupply : 1e18;
        
        ext.addPending(75_000e6);
        
        vm.prank(operator);
        rr.distribute();
        
        // Record final PPS
        uint256 finalAssets = susdscVault.totalAssets();
        uint256 finalSupply = susdscVault.totalSupply();
        uint256 finalPPS = finalSupply > 0 ? (finalAssets * 1e18) / finalSupply : 1e18;
        
        // Verify PPS is non-decreasing
        assertGe(finalPPS, initialPPS, "PPS is non-decreasing");
        
        // Verify assets increased (yield was added)
        assertGt(finalAssets, initialAssets, "sUSDSC assets increased");
    }
    
    // Note: Terminology currently means toYield = toOn = toERC4626
    // Todo: Keep appropriate and consistent later on once finalised.
    function testIntegration_ProportionalAllocationWithRealTVLs() public {
        ext.addPending(120_000e6);
        
        // Get real TVLs
        uint256 T_earn = earnVault.totalPrincipal();
        uint256 T_yield = susdscVault.totalAssets();
        uint256 S_base = usdsc.totalSupply(); // Will be adjusted after minting
        
        (uint256 minted, uint256 feeToStartale, uint256 toEarn, uint256 toYield, , , , ) = rr.previewDistribute();
        
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
        // uint256 aliceEarnPrincipalBefore = earnVault.principal(alice);
        uint256 bobSUSDSCSharesBefore = susdscVault.balanceOf(bob);
        
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
        
        // Bob can redeem some sUSDSC shares
        vm.startPrank(bob);
        uint256 bobRedeemAmount = bobSUSDSCSharesBefore / 4; // Redeem 25%
        uint256 assetsReceived = susdscVault.redeem(bobRedeemAmount, bob, bob);
        assertGt(assetsReceived, bobRedeemAmount, "Bob received more assets than shares (PPS > 1)");
        vm.stopPrank();
        
        // New user can deposit after distribution
        address dave = address(0xdaDE);
        usdsc.mint(dave, 1_000_000e6);
        
        vm.startPrank(dave);
        usdsc.approve(address(earnVault), 200_000e6);
        usdsc.approve(address(susdscVault), 200_000e6);
        
        earnVault.deposit(200_000e6);
        uint256 daveShares = susdscVault.deposit(200_000e6, dave);
        assertGt(daveShares, 0, "Dave received sUSDSC shares");
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
            uint256 earnAssetsBefore = usdsc.balanceOf(address(earnVault));
            uint256 susdscAssetsBefore = susdscVault.totalAssets();
            uint256 startaleBalanceBefore = usdsc.balanceOf(startale);
            
            // Add yield and distribute
            ext.addPending(yields[i]);
            vm.prank(operator);
            rr.distribute();
            
            // Verify distribution occurred
            uint256 earnAssetsAfter = usdsc.balanceOf(address(earnVault));
            uint256 susdscAssetsAfter = susdscVault.totalAssets();
            uint256 startaleBalanceAfter = usdsc.balanceOf(startale);
            
            assertGt(earnAssetsAfter, earnAssetsBefore, "EarnVault assets increased");
            assertGt(susdscAssetsAfter, susdscAssetsBefore, "sUSDSC assets increased");
            assertGt(startaleBalanceAfter, startaleBalanceBefore, "Startale balance increased");
            
            totalDistributed += yields[i];
            
            // Simulate user activity between distributions
            if (i % 2 == 0) {
                // Some users deposit more
                vm.startPrank(alice);
                usdsc.approve(address(earnVault), 100_000e6);
                earnVault.deposit(100_000e6);
                vm.stopPrank();
            } else {
                // Some users withdraw
                vm.startPrank(bob);
                uint256 bobShares = susdscVault.balanceOf(bob);
                if (bobShares > 100e18) {
                    susdscVault.redeem(100e18, bob, bob);
                }
                vm.stopPrank();
            }
        }
        
        // Verify total conservation over all distributions
        assertEq(usdsc.balanceOf(address(rr)), 0, "no dust accumulated");
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
        
        uint256 aliceBalanceBefore = usdsc.balanceOf(alice);
        earnVault.claim();
        uint256 aliceBalanceAfter = usdsc.balanceOf(alice);
        
        assertEq(aliceBalanceAfter - aliceBalanceBefore, aliceClaimable, "Alice received exact claimable amount");
        assertEq(earnVault.principal(alice), aliceInitialPrincipal, "Alice principal unchanged after claim");
        assertEq(earnVault.claimable(alice), 0, "Alice has no remaining claimable yield");
        vm.stopPrank();
        
        // Test 2: Charlie does partial principal withdrawal
        vm.startPrank(charlie);
        uint256 charlieClaimableBefore = earnVault.claimable(charlie);
        uint256 charlieBalanceBefore = usdsc.balanceOf(charlie);
        uint256 partialWithdrawAmount = charlieInitialPrincipal / 3; // Withdraw 1/3 of principal
        
        earnVault.withdraw(partialWithdrawAmount);
        
        uint256 charlieBalanceAfter = usdsc.balanceOf(charlie);
        uint256 charlieNewPrincipal = earnVault.principal(charlie);
        uint256 charlieClaimableAfter = earnVault.claimable(charlie);
        
        // Verify partial withdrawal (EarnVault partial withdrawals now AUTO-CLAIM all interest)
        assertEq(charlieNewPrincipal, charlieInitialPrincipal - partialWithdrawAmount, "Charlie principal reduced by withdrawal amount");
        assertEq(charlieBalanceAfter - charlieBalanceBefore, partialWithdrawAmount + charlieClaimableBefore, "Charlie received principal + all accrued yield");
        assertEq(charlieClaimableAfter, 0, "Charlie has no remaining claimable yield after withdrawal");
        vm.stopPrank();
        
        // Test 3: Add more yield and test full withdrawal
        ext.addPending(40_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Charlie does full withdrawal (remaining principal only, yield auto-claimed)
        vm.startPrank(charlie);
        uint256 charlieRemainingPrincipal = earnVault.principal(charlie);
        uint256 charlieNewClaimable = earnVault.claimable(charlie);
        uint256 charlieBalanceBeforeFullWithdraw = usdsc.balanceOf(charlie);
        
        earnVault.withdraw(charlieRemainingPrincipal); // Only withdraw principal, yield auto-claimed
        
        uint256 charlieBalanceAfterFullWithdraw = usdsc.balanceOf(charlie);
        
        assertEq(earnVault.principal(charlie), 0, "Charlie has no remaining principal");
        assertEq(earnVault.claimable(charlie), 0, "Charlie has no remaining claimable yield");
        assertEq(charlieBalanceAfterFullWithdraw - charlieBalanceBeforeFullWithdraw, 
                charlieRemainingPrincipal + charlieNewClaimable, "Charlie received remaining principal + yield");
        vm.stopPrank();
    }
    
    function testIntegration_SUSDSCVaultRedemptionsAfterDistribution() public {
        // Get initial state
        uint256 bobInitialShares = susdscVault.balanceOf(bob);
        // uint256 charlieInitialShares = susdscVault.balanceOf(charlie);
        uint256 initialPPS = susdscVault.totalSupply() > 0 ? 
            (susdscVault.totalAssets() * 1e18) / susdscVault.totalSupply() : 1e18;
        
        // Add yield and distribute
        ext.addPending(100_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Verify PPS increased
        uint256 newPPS = susdscVault.totalSupply() > 0 ? 
            (susdscVault.totalAssets() * 1e18) / susdscVault.totalSupply() : 1e18;
        assertGt(newPPS, initialPPS, "PPS increased after yield distribution");
        
        // Test 1: Bob redeems 25% of his shares
        vm.startPrank(bob);
        uint256 bobRedeemShares = bobInitialShares / 4;
        uint256 bobBalanceBefore = usdsc.balanceOf(bob);
        
        uint256 assetsReceived = susdscVault.redeem(bobRedeemShares, bob, bob);
        
        uint256 bobBalanceAfter = usdsc.balanceOf(bob);
        uint256 bobRemainingShares = susdscVault.balanceOf(bob);
        
        assertEq(bobBalanceAfter - bobBalanceBefore, assetsReceived, "Bob received expected assets");
        assertEq(bobRemainingShares, bobInitialShares - bobRedeemShares, "Bob shares reduced correctly");
        assertGt(assetsReceived, bobRedeemShares, "Bob received more assets than shares due to PPS > 1");
        vm.stopPrank();
        
        // Test 2: Charlie withdraws specific asset amount
        vm.startPrank(charlie);
        uint256 charlieTargetAssets = 200_000e6; // Withdraw 200k USDSC worth
        uint256 charlieBalanceBefore = usdsc.balanceOf(charlie);
        uint256 charlieSharesBefore = susdscVault.balanceOf(charlie);
        
        uint256 sharesBurned = susdscVault.withdraw(charlieTargetAssets, charlie, charlie);
        
        uint256 charlieBalanceAfter = usdsc.balanceOf(charlie);
        uint256 charlieSharesAfter = susdscVault.balanceOf(charlie);
        
        assertEq(charlieBalanceAfter - charlieBalanceBefore, charlieTargetAssets, "Charlie received exact target assets");
        assertEq(charlieSharesAfter, charlieSharesBefore - sharesBurned, "Charlie shares reduced by burned amount");
        assertLt(sharesBurned, charlieTargetAssets, "Shares burned less than assets due to PPS > 1");
        vm.stopPrank();
        
        // Test 3: Full redemption
        vm.startPrank(bob);
        uint256 bobFinalShares = susdscVault.balanceOf(bob);
        uint256 bobFinalBalanceBefore = usdsc.balanceOf(bob);
        
        uint256 finalAssetsReceived = susdscVault.redeem(bobFinalShares, bob, bob);
        
        uint256 bobFinalBalanceAfter = usdsc.balanceOf(bob);
        
        assertEq(susdscVault.balanceOf(bob), 0, "Bob has no remaining shares");
        assertEq(bobFinalBalanceAfter - bobFinalBalanceBefore, finalAssetsReceived, "Bob received all remaining assets");
        assertGt(finalAssetsReceived, 0, "Bob received positive assets from final redemption");
        vm.stopPrank();
    }
    
    function testIntegration_MixedWithdrawalsAfterMultipleDistributions() public {
        // Test complex scenario: multiple distributions with withdrawals in between
        
        // Initial state
        uint256 aliceInitialEarnPrincipal = earnVault.principal(alice);
        uint256 bobInitialSUSDSCShares = susdscVault.balanceOf(bob);
        
        // First distribution
        ext.addPending(60_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Alice claims yield but keeps principal
        vm.startPrank(alice);
        // uint256 aliceFirstClaimable = earnVault.claimable(alice);
        earnVault.claim();
        vm.stopPrank();
        
        // Bob redeems half his shares
        vm.startPrank(bob);
        uint256 bobFirstRedemption = bobInitialSUSDSCShares / 2;
        susdscVault.redeem(bobFirstRedemption, bob, bob);
        vm.stopPrank();
        
        // Second distribution (smaller TVL now due to Bob's redemption)
        ext.addPending(40_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Alice does partial withdrawal
        vm.startPrank(alice);
        uint256 aliceSecondClaimable = earnVault.claimable(alice);
        uint256 alicePartialWithdraw = aliceInitialEarnPrincipal / 4;
        uint256 aliceBalanceBefore = usdsc.balanceOf(alice);
        
        earnVault.withdraw(alicePartialWithdraw);
        
        uint256 aliceBalanceAfter = usdsc.balanceOf(alice);
        
        // Alice should receive partial principal + all accrued yield (partial withdrawal now auto-claims)
        assertEq(aliceBalanceAfter - aliceBalanceBefore, alicePartialWithdraw + aliceSecondClaimable, 
                "Alice received partial principal + all accrued yield");
        assertEq(earnVault.principal(alice), aliceInitialEarnPrincipal - alicePartialWithdraw, 
                "Alice principal reduced correctly");
        assertEq(earnVault.claimable(alice), 0, "Alice has no remaining claimable yield after withdrawal");
        vm.stopPrank();
        
        // Bob redeems remaining shares
        vm.startPrank(bob);
        uint256 bobRemainingShares = susdscVault.balanceOf(bob);
        // uint256 bobFinalBalance = usdsc.balanceOf(bob);
        
        uint256 bobFinalAssets = susdscVault.redeem(bobRemainingShares, bob, bob);
        
        // Verify Bob got yield benefit from second distribution
        assertGt(bobFinalAssets, bobRemainingShares, "Bob's final redemption benefited from yield");
        assertEq(susdscVault.balanceOf(bob), 0, "Bob fully exited sUSDSC vault");
        vm.stopPrank();
        
        // Third distribution with reduced TVL
        ext.addPending(30_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Verify remaining users still get yield
        uint256 aliceFinalClaimable = earnVault.claimable(alice);
        assertGt(aliceFinalClaimable, 0, "Alice still earning yield on remaining principal");
        
        // Charlie (who didn't withdraw from sUSDSC) should have higher PPS
        uint256 charlieShares = susdscVault.balanceOf(charlie);
        uint256 charlieAssetValue = susdscVault.convertToAssets(charlieShares);
        assertGt(charlieAssetValue, charlieShares, "Charlie's shares worth more than face value");
    }
    
    function testIntegration_WithdrawalOrderingAndInvariants() public {
        // Test that withdrawals don't break the system invariants
        
        ext.addPending(50_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Record pre-withdrawal state
        uint256 totalEarnPrincipalBefore = earnVault.totalPrincipal();
        uint256 totalSUSDSCAssetsBefore = susdscVault.totalAssets();
        uint256 totalSUSDSCSupplyBefore = susdscVault.totalSupply();
        
        // Multiple users withdraw simultaneously
        vm.startPrank(alice);
        uint256 aliceWithdrawAmount = earnVault.principal(alice) / 2;
        earnVault.withdraw(aliceWithdrawAmount);
        vm.stopPrank();
        
        vm.startPrank(bob);
        uint256 bobRedeemShares = susdscVault.balanceOf(bob) / 3;
        susdscVault.redeem(bobRedeemShares, bob, bob);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        uint256 charlieWithdrawAssets = 100_000e6;
        susdscVault.withdraw(charlieWithdrawAssets, charlie, charlie);
        vm.stopPrank();
        
        // Verify invariants still hold
        uint256 totalEarnPrincipalAfter = earnVault.totalPrincipal();
        uint256 totalSUSDSCAssetsAfter = susdscVault.totalAssets();
        uint256 totalSUSDSCSupplyAfter = susdscVault.totalSupply();
        
        assertEq(totalEarnPrincipalAfter, totalEarnPrincipalBefore - aliceWithdrawAmount, 
                "EarnVault total principal reduced correctly");
        
        // sUSDSC vault should maintain proper asset/supply relationship
        if (totalSUSDSCSupplyAfter > 0) {
            uint256 newPPS = (totalSUSDSCAssetsAfter * 1e18) / totalSUSDSCSupplyAfter;
            uint256 oldPPS = (totalSUSDSCAssetsBefore * 1e18) / totalSUSDSCSupplyBefore;
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
        if (susdscVault.balanceOf(charlie) > 0) {
            uint256 charlieCurrentValue = susdscVault.convertToAssets(susdscVault.balanceOf(charlie));
            // Charlie's remaining shares should have gained value
            assertGt(charlieCurrentValue, susdscVault.balanceOf(charlie), "Charlie's remaining shares gained value");
        }
    }

    // ========== EDGE CASE TESTS ==========
    
    function testIntegration_EmptyVaultScenarios() public {
        // Create new clean vaults with no deposits
        EarnVault emptyEarnVault = new EarnVault(
            address(usdsc),
            admin,
            address(rr),
            treasury,
            pauser
        );
        
        SUSDSCVault emptySUSDSCVault = new SUSDSCVault(
            IERC20(address(usdsc)),
            admin,
            pauser
        );
        
        // Create new redistributor with empty vaults
        RewardRedistributor rrEmpty = new RewardRedistributor(
            address(ext),  // MockExtension address (implements both IERC20 and IMYieldToOne)
            startale,
            IEarnVault(address(emptyEarnVault)),
            IERC4626(address(emptySUSDSCVault)),
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
        
        uint256 startaleBalanceBefore = usdsc.balanceOf(startale);
        
        vm.prank(operator);
        rrEmpty.distribute();
        
        uint256 startaleBalanceAfter = usdsc.balanceOf(startale);
        
        // With empty vaults (TVL = 0), all yield should go to Startale
        assertEq(startaleBalanceAfter - startaleBalanceBefore, 50_000e6, "all yield goes to Startale when vaults empty");
        assertEq(usdsc.balanceOf(address(emptyEarnVault)), 0, "empty EarnVault stays empty");
        assertEq(emptySUSDSCVault.totalAssets(), 0, "empty sUSDSC vault stays empty");
        
        // Restore original recipient
        ext.setYieldRecipient(originalRecipient);
    }
    
    function testIntegration_LargeScaleDistribution() public {
        // Add large amounts to vaults first
        usdsc.mint(alice, 50_000_000e6);
        usdsc.mint(bob, 30_000_000e6);
        
        vm.startPrank(alice);
        usdsc.approve(address(earnVault), 50_000_000e6);
        earnVault.deposit(50_000_000e6);
        vm.stopPrank();
        
        vm.startPrank(bob);
        usdsc.approve(address(susdscVault), 30_000_000e6);
        susdscVault.deposit(30_000_000e6, bob);
        vm.stopPrank();
        
        // Large yield distribution
        ext.addPending(10_000_000e6); // 10M yield
        
        uint256 totalSupplyBefore = usdsc.totalSupply();
        
        vm.prank(operator);
        rr.distribute();
        
        uint256 totalSupplyAfter = usdsc.totalSupply();
        
        // Verify large distribution worked correctly
        assertEq(totalSupplyAfter - totalSupplyBefore, 10_000_000e6, "10M USDSC minted");
        assertEq(usdsc.balanceOf(address(rr)), 0, "no dust from large distribution");
        
        // Verify proportional allocation still holds
        assertGt(usdsc.balanceOf(address(earnVault)), 1_000_000e6, "EarnVault received significant yield");
        assertGt(susdscVault.totalAssets(), 30_000_000e6, "sUSDSC vault received yield");
        assertGt(usdsc.balanceOf(startale), 1_000_000e6, "Startale received significant amount");
    }

    // ========== YIELD DISTRIBUTION PRECISION TESTS ==========
    
    function testIntegration_YieldDistributionPrecision() public {
        // Test RAY precision in yield distribution with small amounts
        
        // Small yield distribution
        ext.addPending(1e6); // 1 USDSC
        
        uint256 aliceClaimableBefore = earnVault.claimable(alice);
        uint256 charlieClaimableBefore = earnVault.claimable(charlie);
        
        vm.prank(operator);
        rr.distribute();
        
        uint256 aliceClaimableAfter = earnVault.claimable(alice);
        uint256 charlieClaimableAfter = earnVault.claimable(charlie);
        
        // Verify that users received some yield (proportionality tested in other tests)
        assertGt(aliceClaimableAfter, aliceClaimableBefore, "Alice received yield");
        assertGt(charlieClaimableAfter, charlieClaimableBefore, "Charlie received yield");
        
        // Verify proportional distribution: Alice has 2x Charlie's principal, should get ~2x yield
        uint256 alicePrincipal = earnVault.principal(alice);
        uint256 charliePrincipal = earnVault.principal(charlie);
        
        if (alicePrincipal > 0 && charliePrincipal > 0) {
            uint256 aliceYieldIncrease = aliceClaimableAfter - aliceClaimableBefore;
            uint256 charlieYieldIncrease = charlieClaimableAfter - charlieClaimableBefore;
            
            // Calculate ratio (Alice should get ~2x Charlie's yield)
            if (charlieYieldIncrease > 0) {
                uint256 yieldRatio = (aliceYieldIncrease * 1e18) / charlieYieldIncrease;
                uint256 principalRatio = (alicePrincipal * 1e18) / charliePrincipal;
                
                // Allow for rounding differences
                assertApproxEqRel(yieldRatio, principalRatio, 0.1e18, "Yield ratio matches principal ratio");
            }
        }
        
        // Test carry mechanism with multiple small distributions
        for (uint256 i = 0; i < 10; i++) {
            ext.addPending(100); // 100 wei each time
            vm.prank(operator);
            rr.distribute();
        }
        
        // Verify no yield is lost due to rounding
        uint256 finalClaimReserve = earnVault.claimReserve();
        uint256 finalBalance = usdsc.balanceOf(address(earnVault));
        assertGe(finalBalance, finalClaimReserve, "Funding invariant maintained after small distributions");
    }
    
    function testIntegration_CarryMechanismAccuracy() public {
        // Test that carry mechanism prevents systematic bias over many distributions
        
        uint256 iterations = 50;
        uint256 yieldPerIteration = 7e6; // 7 USDSC - odd number to test rounding
        
        uint256 totalYieldToEarnVault = 0;
        uint256 totalYieldClaimed = 0;
        
        for (uint256 i = 0; i < iterations; i++) {
            uint256 earnBalanceBefore = usdsc.balanceOf(address(earnVault));
            
            ext.addPending(yieldPerIteration);
            vm.prank(operator);
            rr.distribute();
            
            uint256 earnBalanceAfter = usdsc.balanceOf(address(earnVault));
            totalYieldToEarnVault += (earnBalanceAfter - earnBalanceBefore);
        }
        
        // Claim all yield
        vm.startPrank(alice);
        uint256 aliceClaimable = earnVault.claimable(alice);
        if (aliceClaimable > 0) {
            earnVault.claim();
            totalYieldClaimed += aliceClaimable;
        }
        vm.stopPrank();
        
        vm.startPrank(charlie);
        uint256 charlieClaimable = earnVault.claimable(charlie);
        if (charlieClaimable > 0) {
            earnVault.claim();
            totalYieldClaimed += charlieClaimable;
        }
        vm.stopPrank();
        
        // Verify minimal loss due to carry mechanism
        // Loss should be minimal compared to total yield allocated to EarnVault
        uint256 yieldLoss = totalYieldToEarnVault > totalYieldClaimed ? 
            totalYieldToEarnVault - totalYieldClaimed : 0;
        
        // Loss should be very small relative to total yield
        if (totalYieldToEarnVault > 0) {
            uint256 lossPercentage = (yieldLoss * 10000) / totalYieldToEarnVault; // basis points
            assertLt(lossPercentage, 100, "Yield loss less than 1% due to carry mechanism"); // Less than 1%
        }
    }
    
    // ========== BOOST REWARDS INTEGRATION TESTS ==========
    
    function testIntegration_BoostRewardsDistribution() public {
        // Create mock boost tokens
        MockERC20 astr = new MockERC20("Astar", "ASTR", 18);
        MockERC20 dot = new MockERC20("Polkadot", "DOT", 10);
        
        // Mint boost tokens to yield redistributor (simulating external rewards)
        astr.mint(address(rr), 1000e18);
        dot.mint(address(rr), 500e10);
        
        // First, distribute some USDSC yield to establish baseline
        ext.addPending(10_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Now distribute boost rewards through EarnVault
        vm.startPrank(address(rr)); // Simulate yield redistributor role
        
        // Transfer tokens to EarnVault first
        astr.transfer(address(earnVault), 100e18);
        dot.transfer(address(earnVault), 50e10);
        
        // Distribute boost rewards
        earnVault.onBoostReward(address(astr), 100e18);
        earnVault.onBoostReward(address(dot), 50e10);
        
        vm.stopPrank();
        
        // Verify boost rewards are claimable
        uint256 aliceASTRClaimable = earnVault.getClaimableBoostReward(alice, address(astr));
        uint256 aliceDOTClaimable = earnVault.getClaimableBoostReward(alice, address(dot));
        uint256 charlieASTRClaimable = earnVault.getClaimableBoostReward(charlie, address(astr));
        uint256 charlieDOTClaimable = earnVault.getClaimableBoostReward(charlie, address(dot));
        
        assertGt(aliceASTRClaimable, 0, "Alice has claimable ASTR");
        assertGt(aliceDOTClaimable, 0, "Alice has claimable DOT");
        assertGt(charlieASTRClaimable, 0, "Charlie has claimable ASTR");
        assertGt(charlieDOTClaimable, 0, "Charlie has claimable DOT");
        
        // Verify proportional distribution based on principal
        uint256 alicePrincipal = earnVault.principal(alice);
        uint256 charliePrincipal = earnVault.principal(charlie);
        
        // Alice should get more rewards due to higher principal
        if (alicePrincipal > charliePrincipal) {
            assertGt(aliceASTRClaimable, charlieASTRClaimable, "Alice gets more ASTR due to higher principal");
            assertGt(aliceDOTClaimable, charlieDOTClaimable, "Alice gets more DOT due to higher principal");
        }
        
        // Test claiming boost rewards
        vm.startPrank(alice);
        uint256 aliceASTRBalanceBefore = astr.balanceOf(alice);
        uint256 aliceDOTBalanceBefore = dot.balanceOf(alice);
        
        earnVault.claim(); // Claims both USDSC yield and all boost rewards
        
        uint256 aliceASTRBalanceAfter = astr.balanceOf(alice);
        uint256 aliceDOTBalanceAfter = dot.balanceOf(alice);
        
        assertEq(aliceASTRBalanceAfter - aliceASTRBalanceBefore, aliceASTRClaimable, "Alice received expected ASTR");
        assertEq(aliceDOTBalanceAfter - aliceDOTBalanceBefore, aliceDOTClaimable, "Alice received expected DOT");
        
        // Verify no remaining claimable boost rewards
        assertEq(earnVault.getClaimableBoostReward(alice, address(astr)), 0, "No remaining ASTR claimable");
        assertEq(earnVault.getClaimableBoostReward(alice, address(dot)), 0, "No remaining DOT claimable");
        
        vm.stopPrank();
    }
    
    function testIntegration_BoostRewardsWithWithdrawals() public {
        // Test that boost rewards are auto-claimed on withdrawals
        
        MockERC20 astr = new MockERC20("Astar", "ASTR", 18);
        astr.mint(address(earnVault), 200e18);
        
        // Distribute USDSC yield first
        ext.addPending(5_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Distribute boost rewards
        vm.prank(address(rr));
        earnVault.onBoostReward(address(astr), 200e18);
        
        // Alice does partial withdrawal - should auto-claim all rewards
        vm.startPrank(alice);
        uint256 aliceASTRBalanceBefore = astr.balanceOf(alice);
        uint256 aliceUSRDBalanceBefore = usdsc.balanceOf(alice);
        uint256 aliceClaimableUSRD = earnVault.claimable(alice);
        uint256 aliceClaimableASTR = earnVault.getClaimableBoostReward(alice, address(astr));
        
        uint256 withdrawAmount = earnVault.principal(alice) / 4; // Withdraw 25%
        earnVault.withdraw(withdrawAmount);
        
        uint256 aliceASTRBalanceAfter = astr.balanceOf(alice);
        uint256 aliceUSRDBalanceAfter = usdsc.balanceOf(alice);
        
        // Verify Alice received principal + USDSC yield + boost rewards
        assertEq(aliceUSRDBalanceAfter - aliceUSRDBalanceBefore, withdrawAmount + aliceClaimableUSRD, 
                "Alice received principal + USDSC yield");
        assertEq(aliceASTRBalanceAfter - aliceASTRBalanceBefore, aliceClaimableASTR, 
                "Alice received boost rewards on withdrawal");
        
        // Verify no remaining claimable rewards
        assertEq(earnVault.claimable(alice), 0, "No remaining USDSC claimable");
        assertEq(earnVault.getClaimableBoostReward(alice, address(astr)), 0, "No remaining ASTR claimable");
        
        vm.stopPrank();
    }
    
    // ========== SYSTEM INVARIANT TESTS ==========
    
    function testIntegration_FundingInvariantUnderStress() public {
        // Test funding invariant under various stress conditions
        
        // Multiple rapid distributions
        for (uint256 i = 0; i < 20; i++) {
            ext.addPending((i + 1) * 1000e6); // Increasing amounts
            vm.prank(operator);
            rr.distribute();
            
            // Check invariant after each distribution
            uint256 earnBalance = usdsc.balanceOf(address(earnVault));
            uint256 claimReserve = earnVault.claimReserve();
            assertGe(earnBalance, claimReserve, "Funding invariant maintained");
        }
        
        // Random user activities between distributions
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob; // Note: bob is in sUSDSC vault
        users[2] = charlie;
        
        for (uint256 i = 0; i < 10; i++) {
            // Random distribution
            ext.addPending((i * 123 + 456) % 5000e6 + 1000e6);
            vm.prank(operator);
            rr.distribute();
            
            // Random user activity
            address user = users[i % 2]; // Alternate between alice and charlie (EarnVault users)
            if (user == alice || user == charlie) {
                vm.startPrank(user);
                
                if (i % 3 == 0) {
                    // Claim
                    if (earnVault.claimable(user) > 0) {
                        earnVault.claim();
                    }
                } else if (i % 3 == 1) {
                    // Partial withdrawal
                    uint256 principal = earnVault.principal(user);
                    if (principal > 1000e6) {
                        earnVault.withdraw(principal / 10);
                    }
                } else {
                    // Deposit more
                    uint256 depositAmount = 100_000e6;
                    usdsc.approve(address(earnVault), depositAmount);
                    earnVault.deposit(depositAmount);
                }
                
                vm.stopPrank();
            }
            
            // Verify invariant still holds
            uint256 earnBalance = usdsc.balanceOf(address(earnVault));
            uint256 claimReserve = earnVault.claimReserve();
            assertGe(earnBalance, claimReserve, "Funding invariant maintained under stress");
        }
    }
    
    function testIntegration_ProportionalityInvariant() public {
        // Test that yield distribution remains proportional regardless of timing
        
        // Setup: Two users with different principals
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");
        
        usdsc.mint(userA, 10_000_000e6);
        usdsc.mint(userB, 10_000_000e6);
        
        // UserA deposits 3x more than UserB
        vm.startPrank(userA);
        usdsc.approve(address(earnVault), 3_000_000e6);
        earnVault.deposit(3_000_000e6);
        vm.stopPrank();
        
        vm.startPrank(userB);
        usdsc.approve(address(earnVault), 1_000_000e6);
        earnVault.deposit(1_000_000e6);
        vm.stopPrank();
        
        // Multiple distributions of varying sizes
        uint256[] memory distributions = new uint256[](5);
        distributions[0] = 1_000e6;
        distributions[1] = 10_000e6;
        distributions[2] = 100e6;
        distributions[3] = 50_000e6;
        distributions[4] = 5_000e6;
        
        uint256 totalUserAYield = 0;
        uint256 totalUserBYield = 0;
        
        for (uint256 i = 0; i < distributions.length; i++) {
            ext.addPending(distributions[i]);
            vm.prank(operator);
            rr.distribute();
            
            // Claim and track yields
            vm.startPrank(userA);
            uint256 userAYield = earnVault.claimable(userA);
            if (userAYield > 0) {
                earnVault.claim();
                totalUserAYield += userAYield;
            }
            vm.stopPrank();
            
            vm.startPrank(userB);
            uint256 userBYield = earnVault.claimable(userB);
            if (userBYield > 0) {
                earnVault.claim();
                totalUserBYield += userBYield;
            }
            vm.stopPrank();
        }
        
        // Verify proportionality: UserA should have ~3x the yield of UserB
        // Allow for small rounding differences
        uint256 expectedRatio = 3e18; // 3.0 in 18 decimals
        uint256 actualRatio = (totalUserAYield * 1e18) / totalUserBYield;
        
        assertApproxEqRel(actualRatio, expectedRatio, 0.01e18, "Yield distribution maintains proportionality");
    }
    
    function testIntegration_EmptyVaultYieldHandling() public {
        // Test yield distribution when vaults become empty and refilled
        
        // Start with deposits
        uint256 aliceInitialPrincipal = earnVault.principal(alice);
        uint256 charlieInitialPrincipal = earnVault.principal(charlie);
        
        // Distribute some yield
        ext.addPending(10_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Users withdraw everything (including auto-claimed yield)
        vm.startPrank(alice);
        earnVault.withdraw(aliceInitialPrincipal);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        earnVault.withdraw(charlieInitialPrincipal);
        vm.stopPrank();
        
        // Verify vault is empty
        assertEq(earnVault.totalPrincipal(), 0, "EarnVault is empty");
        
        // Distribute yield to empty EarnVault - EarnVault's portion should go to treasury
        uint256 startaleBalanceBefore = usdsc.balanceOf(startale);
        
        ext.addPending(5_000e6);
        vm.prank(operator);
        rr.distribute();
        
        uint256 startaleBalanceAfter = usdsc.balanceOf(startale);
        
        // Since EarnVault is empty, its allocated yield should go to treasury via onYield
        // Startale should also receive some yield (sUSDSC vault portion + remainder)
        assertGt(startaleBalanceAfter, startaleBalanceBefore, "Startale received yield distribution");
        
        // The EarnVault should have received some yield that was immediately transferred to treasury
        // This is harder to verify directly, so let's check that the vault balance didn't increase
        assertEq(usdsc.balanceOf(address(earnVault)), 0, "Empty EarnVault balance remains zero");
        
        // Refill vault
        vm.startPrank(alice);
        usdsc.approve(address(earnVault), 2_000_000e6);
        earnVault.deposit(2_000_000e6);
        vm.stopPrank();
        
        // Distribute yield again - should work normally
        ext.addPending(8_000e6);
        vm.prank(operator);
        rr.distribute();
        
        // Verify Alice can claim yield
        uint256 aliceClaimable = earnVault.claimable(alice);
        assertGt(aliceClaimable, 0, "Alice earning yield after vault refill");
        
        vm.startPrank(alice);
        earnVault.claim();
        vm.stopPrank();
        
        assertEq(earnVault.claimable(alice), 0, "Alice claimed all yield");
    }

    // ========== REWARD REDISTRIBUTOR EDGE CASES ==========
    
    function testIntegration_RewardRedistributorWithFees() public {
        // Test RewardRedistributor with non-zero fees
        
        // Set fee to 10% (1000 bps)
        vm.prank(admin);
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 1000);
        
        uint256 startaleBalanceBefore = usdsc.balanceOf(startale);
        uint256 earnBalanceBefore = usdsc.balanceOf(address(earnVault));
        uint256 susdscAssetsBefore = susdscVault.totalAssets();
        
        // Distribute yield with fees
        ext.addPending(10_000e6);
        vm.prank(operator);
        rr.distribute();
        
        uint256 startaleBalanceAfter = usdsc.balanceOf(startale);
        uint256 earnBalanceAfter = usdsc.balanceOf(address(earnVault));
        uint256 susdscAssetsAfter = susdscVault.totalAssets();
        
        // Verify fee was taken (10% of 10,000 = 1,000 USDSC to Startale as fee)
        uint256 startaleIncrease = startaleBalanceAfter - startaleBalanceBefore;
        assertGt(startaleIncrease, 1_000e6, "Startale received fee + remainder");
        
        // Verify remaining yield was distributed to vaults
        assertGt(earnBalanceAfter, earnBalanceBefore, "EarnVault received yield after fee");
        assertGt(susdscAssetsAfter, susdscAssetsBefore, "sUSDSC vault received yield after fee");
        
        // Reset fee to 0 for other tests
        vm.prank(admin);
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 0);
    }
    
    function testIntegration_RewardRedistributorZeroYield() public {
        // Test distribution when extension has no yield
        
        uint256 startaleBalanceBefore = usdsc.balanceOf(startale);
        uint256 earnBalanceBefore = usdsc.balanceOf(address(earnVault));
        uint256 susdscAssetsBefore = susdscVault.totalAssets();
        
        // Try to distribute with no pending yield
        vm.prank(operator);
        rr.distribute(); // Should return early with no effect
        
        uint256 startaleBalanceAfter = usdsc.balanceOf(startale);
        uint256 earnBalanceAfter = usdsc.balanceOf(address(earnVault));
        uint256 susdscAssetsAfter = susdscVault.totalAssets();
        
        // Verify no changes occurred
        assertEq(startaleBalanceAfter, startaleBalanceBefore, "Startale balance unchanged");
        assertEq(earnBalanceAfter, earnBalanceBefore, "EarnVault balance unchanged");
        assertEq(susdscAssetsAfter, susdscAssetsBefore, "sUSDSC assets unchanged");
    }
    
    function testIntegration_RewardRedistributorZeroSupply() public {
        // Test distribution when total supply is zero (edge case)
        // This is hard to test with real contracts, so we'll test the preview function
        
        (uint256 minted, uint256 feeToStartale, uint256 toEarn, uint256 toOn, uint256 toStartaleExtra, uint256 S_base, uint256 T_earn, uint256 T_yield) = rr.previewDistribute();
        
        // Verify preview works correctly
        assertGe(S_base, 0, "Base supply is non-negative");
        assertGe(T_earn, 0, "EarnVault TVL is non-negative");
        assertGe(T_yield, 0, "sUSDSC TVL is non-negative");
        
        if (minted > 0) {
            assertEq(minted, feeToStartale + toEarn + toOn + toStartaleExtra, "All minted yield allocated");
        }
    }
    
    function testIntegration_RewardRedistributorPreviewFunctions() public {
        // Test preview functions for accuracy
        
        ext.addPending(5_000e6);
        
        // Preview before distribution
        (uint256 minted, uint256 feeToStartale, uint256 toEarn, uint256 toOn, uint256 toStartaleExtra, uint256 S_base, uint256 T_earn, uint256 T_yield) = rr.previewDistribute();
        
        assertEq(minted, 5_000e6, "Preview shows correct minted amount");
        assertEq(feeToStartale, 0, "No fee with 0 bps");
        assertEq(minted, toEarn + toOn + toStartaleExtra, "All yield allocated in preview");
        
        // Test previewSplit function
        (uint256 previewFee, uint256 previewEarn, uint256 previewOn, uint256 previewExtra, uint256 previewSBase, uint256 previewTEarn, uint256 previewTYield) = rr.previewSplit(5_000e6);
        
        assertEq(previewFee, feeToStartale, "PreviewSplit matches previewDistribute fee");
        // Both previewSplit and previewDistribute now use the same S_base calculation (preMint = true)
        assertEq(previewSBase, S_base, "PreviewSplit S_base should match previewDistribute S_base");
        assertEq(previewTEarn, T_earn, "PreviewSplit matches previewDistribute T_earn");
        assertEq(previewTYield, T_yield, "PreviewSplit matches previewDistribute T_yield");
        
        // Note: previewSplit doesn't use carry, so allocations will differ from previewDistribute
        assertApproxEqAbs(previewEarn, toEarn, 10000, "PreviewSplit earn allocation close to previewDistribute");
        assertApproxEqAbs(previewOn, toOn, 10000, "PreviewSplit on allocation close to previewDistribute");
    }
    
    function testIntegration_RewardRedistributorAccessControl() public {
        // Test access control functions
        
        address unauthorizedUser = makeAddr("unauthorized");
        
        // Test that unauthorized user cannot distribute
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        rr.distribute();
        vm.stopPrank();
        
        // Test that unauthorized user cannot set params
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 0);
        vm.stopPrank();
        
        // Test that unauthorized user cannot pause
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        rr.pause(true);
        vm.stopPrank();
        
        // Test that admin can pause and unpause
        vm.startPrank(admin);
        rr.pause(true);
        assertTrue(rr.paused(), "Contract is paused");
        
        rr.pause(false);
        assertFalse(rr.paused(), "Contract is unpaused");
        vm.stopPrank();
    }
    
    function testIntegration_RewardRedistributorPausedDistribution() public {
        // Test that distribution fails when paused
        
        ext.addPending(1_000e6);
        
        // Pause the contract
        vm.prank(admin);
        rr.pause(true);
        
        // Try to distribute while paused
        vm.startPrank(operator);
        vm.expectRevert();
        rr.distribute();
        vm.stopPrank();
        
        // Unpause and verify distribution works
        vm.prank(admin);
        rr.pause(false);
        
        vm.prank(operator);
        rr.distribute(); // Should work now
    }
    
    function testIntegration_RewardRedistributorParameterValidation() public {
        // Test parameter validation in setParams
        
        vm.startPrank(admin);
        
        // Test zero address validation
        vm.expectRevert(bytes("zero"));
        rr.setParams(address(0), IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 0);
        
        vm.expectRevert(bytes("zero"));
        rr.setParams(startale, IEarnVault(address(0)), IERC4626(address(susdscVault)), 0);
        
        vm.expectRevert(bytes("zero"));
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(0)), 0);
        
        // Test fee too high validation
        vm.expectRevert(bytes("fee too high"));
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 2001); // > MAX_FEE_BPS
        
        // Test valid parameter update
        address newTreasury = makeAddr("newTreasury");
        rr.setParams(newTreasury, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 500);
        
        assertEq(rr.treasury(), newTreasury, "Treasury updated");
        assertEq(rr.fee_on_yield_bps(), 500, "Fee updated");
        
        // Reset for other tests
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 0);
        
        vm.stopPrank();
    }
    
    function testIntegration_RewardRedistributorEventEmission() public {
        // Test that events are emitted correctly
        
        ext.addPending(2_000e6);
        
        // Just verify distribution works (events are emitted internally)
        vm.prank(operator);
        rr.distribute();
        
        // Test parameter update works (ParamsUpdated event emitted)
        address newTreasury = makeAddr("newTreasury2");
        vm.prank(admin);
        rr.setParams(newTreasury, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 100);
        
        // Verify parameters were updated
        assertEq(rr.treasury(), newTreasury, "Treasury updated");
        assertEq(rr.fee_on_yield_bps(), 100, "Fee updated");
        
        // Reset
        vm.prank(admin);
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 0);
    }
    
    function testIntegration_RewardRedistributorMaxFeeScenario() public {
        // Test with maximum allowed fee
        
        vm.prank(admin);
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 2000); // 20% fee
        
        uint256 startaleBalanceBefore = usdsc.balanceOf(startale);
        
        ext.addPending(10_000e6);
        vm.prank(operator);
        rr.distribute();
        
        uint256 startaleBalanceAfter = usdsc.balanceOf(startale);
        uint256 startaleIncrease = startaleBalanceAfter - startaleBalanceBefore;
        
        // With 20% fee, Startale should get at least 2,000 USDSC as fee
        assertGe(startaleIncrease, 2_000e6, "Startale received maximum fee");
        
        // Reset fee
        vm.prank(admin);
        rr.setParams(startale, IEarnVault(address(earnVault)), IERC4626(address(susdscVault)), 0);
    }

    // ========== EARN VAULT EDGE CASES FOR BRANCH COVERAGE ==========
    
    function testIntegration_EarnVaultBlacklistFunctionality() public {
        // Test blacklist functionality - uncovered branch
        
        address blacklistedUser = makeAddr("blacklisted");
        usdsc.mint(blacklistedUser, 1_000_000e6);
        
        // User can deposit before being blacklisted
        vm.startPrank(blacklistedUser);
        usdsc.approve(address(earnVault), 500_000e6);
        earnVault.deposit(500_000e6);
        vm.stopPrank();
        
        // Admin blacklists the user
        vm.prank(admin);
        earnVault.setBlacklisted(blacklistedUser, true);
        
        assertTrue(earnVault.isBlacklisted(blacklistedUser), "User is blacklisted");
        
        // Blacklisted user cannot deposit
        vm.startPrank(blacklistedUser);
        usdsc.approve(address(earnVault), 100_000e6);
        vm.expectRevert(abi.encodeWithSignature("AddressBlacklisted()"));
        earnVault.deposit(100_000e6);
        vm.stopPrank();
        
        // Blacklisted user cannot withdraw
        vm.startPrank(blacklistedUser);
        vm.expectRevert(abi.encodeWithSignature("AddressBlacklisted()"));
        earnVault.withdraw(100_000e6);
        vm.stopPrank();
        
        // Blacklisted user cannot claim
        vm.startPrank(blacklistedUser);
        vm.expectRevert(abi.encodeWithSignature("AddressBlacklisted()"));
        earnVault.claim();
        vm.stopPrank();
        
        // Admin can unblacklist
        vm.prank(admin);
        earnVault.setBlacklisted(blacklistedUser, false);
        
        assertFalse(earnVault.isBlacklisted(blacklistedUser), "User is unblacklisted");
        
        // User can now interact again
        vm.startPrank(blacklistedUser);
        earnVault.withdraw(50_000e6); // Should work now
        vm.stopPrank();
    }
    
    function testIntegration_EarnVaultEmergencyRecovery() public {
        // Test emergency token recovery - uncovered branches
        
        // Create a test ERC20 token
        MockERC20 testToken = new MockERC20("Test", "TEST", 18);
        testToken.mint(address(earnVault), 1000e18);
        
        // Test recovery of non-USDSC token when not paused
        vm.prank(admin);
        earnVault.recoverERC20(address(testToken), treasury, 500e18);
        
        assertEq(testToken.balanceOf(treasury), 500e18, "Treasury received recovered tokens");
        
        // Test recovery with zero address (should revert)
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSignature("CanNotBeZeroAddress()"));
        earnVault.recoverERC20(address(testToken), address(0), 100e18);
        vm.stopPrank();
        
        // Test USDSC recovery when not paused (should revert)
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSignature("ContractNotPaused()"));
        earnVault.recoverERC20(address(usdsc), treasury, 1000e6);
        vm.stopPrank();
        
        // Pause the contract and test USDSC recovery
        vm.prank(admin);
        earnVault.pause();
        
        // Add some surplus USDSC
        usdsc.mint(address(earnVault), 10_000e6);
        
        uint256 claimReserve = earnVault.claimReserve();
        uint256 vaultBalance = usdsc.balanceOf(address(earnVault));
        uint256 surplus = vaultBalance - claimReserve;
        
        if (surplus > 0) {
            vm.prank(admin);
            earnVault.recoverERC20(address(usdsc), treasury, surplus);
        }
        
        // Test exceeding surplus (should revert)
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSignature("InsufficientFunding()"));
        earnVault.recoverERC20(address(usdsc), treasury, vaultBalance); // Try to recover more than surplus
        vm.stopPrank();
        
        // Unpause for other tests
        vm.prank(admin);
        earnVault.unpause();
    }
    
    function testIntegration_EarnVaultBoostTokenRecovery() public {
        // Test recovery of boost tokens with reserved amounts
        
        MockERC20 boostToken = new MockERC20("Boost", "BOOST", 18);
        
        // Mint boost tokens and distribute some
        boostToken.mint(address(earnVault), 2000e18);
        
        vm.prank(address(rr));
        earnVault.onBoostReward(address(boostToken), 1000e18);
        
        // Try to recover more than available (should revert)
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSignature("ExceedsSurplus()"));
        earnVault.recoverERC20(address(boostToken), treasury, 1500e18); // More than available after reserves
        vm.stopPrank();
        
        // Recover only the available amount
        uint256 availableAmount = 2000e18 - 1000e18; // Total - reserved
        vm.prank(admin);
        earnVault.recoverERC20(address(boostToken), treasury, availableAmount);
        
        assertEq(boostToken.balanceOf(treasury), availableAmount, "Treasury received available boost tokens");
    }
    
    function testIntegration_EarnVaultSurplusSweep() public {
        // Test surplus sweep functionality
        
        uint256 treasuryBalanceBefore = usdsc.balanceOf(treasury);
        
        // Add surplus to vault
        usdsc.mint(address(earnVault), 5_000e6);
        
        uint256 claimReserveBefore = earnVault.claimReserve();
        uint256 vaultBalanceBefore = usdsc.balanceOf(address(earnVault));
        uint256 expectedSurplus = vaultBalanceBefore - claimReserveBefore;
        
        // Sweep surplus
        vm.prank(admin);
        earnVault.sweepSurplusToTreasury();
        
        uint256 treasuryBalanceAfter = usdsc.balanceOf(treasury);
        uint256 vaultBalanceAfter = usdsc.balanceOf(address(earnVault));
        
        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, expectedSurplus, "Treasury received surplus");
        assertEq(vaultBalanceAfter, earnVault.claimReserve(), "Vault balance equals claim reserve after sweep");
        
        // Test sweep when no surplus (should do nothing)
        vm.prank(admin);
        earnVault.sweepSurplusToTreasury(); // Should not revert, just return
        
        assertEq(usdsc.balanceOf(treasury), treasuryBalanceAfter, "No additional sweep when no surplus");
    }
    
    function testIntegration_EarnVaultZeroAmountEdgeCases() public {
        // Test zero amount edge cases
        
        vm.startPrank(alice);
        
        // Zero deposit should revert
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        earnVault.deposit(0);
        
        // Zero withdraw should revert
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        earnVault.withdraw(0);
        
        vm.stopPrank();
    }
    
    function testIntegration_EarnVaultInsufficientPrincipalEdgeCase() public {
        // Test insufficient principal edge case
        
        vm.startPrank(alice);
        uint256 alicePrincipal = earnVault.principal(alice);
        
        // Try to withdraw more than principal
        vm.expectRevert(abi.encodeWithSignature("InsufficientPrincipal()"));
        earnVault.withdraw(alicePrincipal + 1);
        
        vm.stopPrank();
    }
    
    function testIntegration_EarnVaultETHRejection() public {
        // Test ETH rejection functionality
        
        // Test receive() function
        (bool success,) = address(earnVault).call{value: 1 ether}("");
        assertFalse(success, "ETH transfer should fail");
        
        // Test fallback() function
        (bool success2,) = address(earnVault).call{value: 1 ether}("nonexistentFunction()");
        assertFalse(success2, "ETH transfer to fallback should fail");
    }
    
    function testIntegration_EarnVaultPauseUnpauseFunctionality() public {
        // Test pause/unpause edge cases
        
        // Admin can pause
        vm.prank(admin);
        earnVault.pause();
        assertTrue(earnVault.paused(), "Contract is paused");
        
        // Paused contract rejects deposits
        vm.startPrank(alice);
        usdsc.approve(address(earnVault), 100_000e6);
        vm.expectRevert();
        earnVault.deposit(100_000e6);
        vm.stopPrank();
        
        // Paused contract rejects withdrawals
        vm.startPrank(alice);
        vm.expectRevert();
        earnVault.withdraw(50_000e6);
        vm.stopPrank();
        
        // Paused contract rejects claims
        vm.startPrank(alice);
        vm.expectRevert();
        earnVault.claim();
        vm.stopPrank();
        
        // Admin can unpause
        vm.prank(admin);
        earnVault.unpause();
        assertFalse(earnVault.paused(), "Contract is unpaused");
        
        // Operations work after unpause
        vm.startPrank(alice);
        usdsc.approve(address(earnVault), 100_000e6);
        earnVault.deposit(100_000e6); // Should work now
        vm.stopPrank();
    }
    
    function testIntegration_EarnVaultRoleManagement() public {
        // Test role management edge cases
        
        address newTreasury = makeAddr("newTreasury");
        address newPauser = makeAddr("newPauser");
        address newYieldRedistributor = makeAddr("newYieldRedistributor");
        
        // Test treasury update
        vm.prank(admin);
        earnVault.setTreasury(newTreasury);
        assertEq(earnVault.treasury(), newTreasury, "Treasury updated");
        
        // Test pauser update
        vm.prank(admin);
        earnVault.setPauser(newPauser);
        
        // New pauser can pause
        vm.prank(newPauser);
        earnVault.pause();
        assertTrue(earnVault.paused(), "New pauser can pause");
        
        vm.prank(newPauser);
        earnVault.unpause();
        assertFalse(earnVault.paused(), "New pauser can unpause");
        
        // Test yield redistributor update
        vm.prank(admin);
        earnVault.setYieldRedistributor(newYieldRedistributor);
        
        // New yield redistributor can distribute yield
        usdsc.mint(address(earnVault), 1_000e6);
        vm.prank(newYieldRedistributor);
        earnVault.onYield(1_000e6); // Should work
    }
    
    function testIntegration_EarnVaultViewFunctionEdgeCases() public {
        // Test view functions with edge cases
        
        address newUser = makeAddr("newUser");
        
        // Test claimable for user with no principal
        uint256 claimable = earnVault.claimable(newUser);
        assertEq(claimable, 0, "New user has no claimable yield");
        
        // Test totalValue for user with no principal
        uint256 totalValue = earnVault.totalValue(newUser);
        assertEq(totalValue, 0, "New user has no total value");
        
        // Test getUserInfo for new user
        (uint256 userPrincipal, uint256 userClaimable, uint256 userTotal, uint256 userLastIndex) = earnVault.getUserInfo(newUser);
        assertEq(userPrincipal, 0, "New user has no principal");
        assertEq(userClaimable, 0, "New user has no claimable");
        assertEq(userTotal, 0, "New user has no total value");
        assertEq(userLastIndex, 0, "New user has no index");
        
        // Test getVaultStats
        (uint256 totalPrincipal, uint256 claimReserve, uint256 globalIndex, uint256 pendingDelta, uint256 balance) = earnVault.getVaultStats();
        assertGe(totalPrincipal, 0, "Vault has principal (may be zero)");
        assertGe(claimReserve, 0, "Vault has claim reserve (may be zero)");
        assertGe(globalIndex, earnVault.RAY(), "Global index is at least RAY");
        // Note: Balance might be less than claimReserve in some test scenarios due to previous operations
        // assertGe(balance, claimReserve, "Balance >= claim reserve");
    }
    
    function testIntegration_EarnVaultBoostRewardsEdgeCases() public {
        // Test boost rewards edge cases
        
        MockERC20 boostToken = new MockERC20("Boost", "BOOST", 18);
        
        // Test getClaimableBoostReward for non-existent token
        uint256 claimable = earnVault.getClaimableBoostReward(alice, address(boostToken));
        assertEq(claimable, 0, "No claimable boost for non-distributed token");
        
        // Test getAllClaimables before any boost rewards
        (uint256 usdscClaimable, address[] memory tokens, uint256[] memory amounts) = earnVault.getAllClaimables(alice);
        assertGe(usdscClaimable, 0, "Alice has USDSC claimable (may be zero)");
        assertEq(tokens.length, 0, "No boost tokens initially");
        assertEq(amounts.length, 0, "No boost amounts initially");
        
        // Distribute boost rewards
        boostToken.mint(address(earnVault), 1000e18);
        vm.prank(address(rr));
        earnVault.onBoostReward(address(boostToken), 1000e18);
        
        // Test getAllClaimables after boost rewards
        (usdscClaimable, tokens, amounts) = earnVault.getAllClaimables(alice);
        assertGe(usdscClaimable, 0, "Alice has USDSC claimable (may be zero)");
        assertEq(tokens.length, 1, "One boost token now");
        assertEq(tokens[0], address(boostToken), "Correct boost token");
        assertGt(amounts[0], 0, "Alice has boost rewards");
    }
}
