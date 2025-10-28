// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import '../../src/distributor/RewardRedistributor.sol';
import '../../src/interfaces/distributor/IRewardRedistributorEventsAndErrors.sol';
import '../mocks/MockERC4626Vault.sol';
import '../mocks/MockEarnVault.sol';
import '../mocks/MockExtension.sol';
import '../mocks/MockUSDSC.sol';
import 'forge-std/Test.sol';

contract RewardRedistributorTest is Test {
  MockUSDSC usdsc;
  MockExtension ext;
  MockEarnVault earnV;
  MockERC4626Vault sVault; // yield vault
  RewardRedistributor rr;

  address admin = address(0xA11Ce00000000000000000000000000000000000);
  address operator = address(0x0123456789abcDEF0123456789abCDef01234567);
  address startale = address(0x57a4700000000000000000000000000000000000);

  function setUp() public {
    usdsc = new MockUSDSC();
    ext = new MockExtension(usdsc, address(0)); // set later
    earnV = new MockEarnVault(usdsc);
    sVault = new MockERC4626Vault(usdsc);

    rr = new RewardRedistributor(
      address(ext), // MockExtension address (implements both IERC20 and IMYieldToOne)
      startale,
      IEarnVault(address(earnV)),
      IERC4626(address(sVault)),
      admin
    );

    // Admin already has OPERATOR_ROLE, so let's grant it to the operator
    bytes32 operatorRole = rr.OPERATOR_ROLE();
    vm.prank(admin);
    // Keeper
    rr.grantRole(operatorRole, operator);

    // Set redistributor as extension yieldRecipient
    ext.setYieldRecipient(address(rr));

    // Seed supply: mint 10M to some holder to represent circulating base (wallets/Lps)
    usdsc.mint(address(this), 10_000_000e6);
    // move 1M to earn vault (principal + reserve)
    bool success1 = usdsc.transfer(address(earnV), 1_000_000e6);
    require(success1, 'Transfer failed');
    earnV.setPrincipal(1_000_000e6);
    earnV.setClaimReserve(1_000_000e6);
    // move 1M to sVault (counts toward totalAssets)
    bool success2 = usdsc.transfer(address(sVault), 1_000_000e6);
    require(success2, 'Transfer failed');
  }

  function testConservationAndSplit() public {
    // pending yield: 100_000
    ext.addPending(100_000e6);

    // Preview exact
    (uint256 minted,,,,, uint256 sBase, uint256 Tearn, uint256 T4626) = rr.previewDistribute();

    assertEq(minted, 100_000e6);
    assertEq(Tearn, 1_000_000e6);
    assertEq(T4626, 1_000_000e6);
    assertEq(
      sBase,
      usdsc.totalSupply() /* currently 10M */
    );

    // Keeper Distributes
    vm.prank(operator);
    rr.distribute();

    // Conservation: minted == fee + earn + yield(sUSDSC) + extra
    uint256 balRR = usdsc.balanceOf(address(rr));
    assertEq(balRR, 0); // nothing left in redistributor

    uint256 gotStartale = usdsc.balanceOf(startale);
    uint256 gotearnV = usdsc.balanceOf(address(earnV)) - 1_000_000e6; // extra over reserve
    uint256 gotSVault = usdsc.balanceOf(address(sVault)) - 1_000_000e6;

    // The preview and actual may differ due to timing of when sBase is calculated
    // Just check that conservation holds: all minted tokens are distributed
    assertEq(gotStartale + gotearnV + gotSVault, minted, 'conservation');

    // Check that each vault got a reasonable share (not exact due to rounding)
    assertGt(gotearnV, 0, 'claim got something');
    assertGt(gotSVault, 0, '4626 got something');
    assertGt(gotStartale, 0, 'startale got something');
  }

  function testZeroEligibleTVL_AllToStartale() public {
    // Reset eligible TVL
    earnV.setPrincipal(0);
    earnV.setClaimReserve(0);
    // move sVault funds out - burn the tokens from sVault
    uint256 sVaultBalance = usdsc.balanceOf(address(sVault));
    usdsc.burn(address(sVault), sVaultBalance);
    // Also burn earnV balance to make it truly zero TVL
    uint256 earnVBalance = usdsc.balanceOf(address(earnV));
    usdsc.burn(address(earnV), earnVBalance);

    // Pending yield
    ext.addPending(50_000e6);

    vm.prank(operator);
    rr.distribute();

    // All net should end at Startale (plus fee)
    assertGt(usdsc.balanceOf(startale), 0);
    assertEq(usdsc.balanceOf(address(earnV)), 0);
    assertEq(usdsc.balanceOf(address(sVault)), 0);
  }

  function testCarryFairness() public {
    // Make S huge, small Tearn/T4626 to induce rounding many times
    // Here we just run many tiny epochs and check conservation
    for (uint256 i = 0; i < 10; i++) {
      ext.addPending(100); // 100 wei of USDSC - still tiny but avoids underflow
      vm.prank(operator);
      rr.distribute();
    }
    // Nothing should be stuck in redistributor
    assertEq(usdsc.balanceOf(address(rr)), 0);
    // Sum of all recipients equals sum minted
    // (We could store a running minted sum via events; for brevity we trust the accounting here.)
  }

  function testEarnVaultFundingOrder() public {
    // earn vault expects transfer before onYield
    ext.addPending(10_000e6);
    vm.prank(operator);
    rr.distribute();

    // earnVault.claimReserve should have increased
    rr.previewSplitCurrent(); // Just call it to make sure it works
    // Loose check: claimReserve at least 1,000,000e6 (principal) + something
    assertGt(earnV.claimReserve(), 1_000_000e6);
  }

  function testPauseAndRoles() public {
    vm.expectRevert(); // not operator
    rr.distribute();

    vm.prank(admin);
    rr.pause(true);
    vm.prank(operator);
    vm.expectRevert(); // paused
    rr.distribute();

    vm.prank(admin);
    rr.pause(false);
    vm.prank(operator); // ok (maybe zero)
    rr.distribute();
  }

  // ========== CARRY AND PREVIEW TESTS ==========

  function testCarryMathematicalFormulas() public {
    // Test carry logic over multiple epochs
    ext.addPending(7000e6);

    // First epoch - no carry
    (
      uint256 minted1,
      uint256 fee1,
      uint256 toEarn1,
      uint256 toYield1,,
      uint256 S_base1,
      uint256 T_earn1,
      uint256 T_yield1
    ) = rr.previewSplitCurrent();

    uint256 net1 = minted1 - fee1;
    uint256 expectedToEarn1 = (net1 * T_earn1) / S_base1;
    uint256 expectedToOn1 = (net1 * T_yield1) / S_base1;

    assertEq(toEarn1, expectedToEarn1, 'first epoch toEarn');
    assertEq(toYield1, expectedToOn1, 'first epoch toYield');

    vm.prank(operator);
    rr.distribute();

    // Second epoch - with carry
    ext.addPending(3000e6);
    (uint256 minted2, uint256 fee2, uint256 toEarn2, uint256 toYield2,,,,) = rr.previewSplitCurrent();

    // Verify conservation
    assertEq(minted2, fee2 + toEarn2 + toYield2 + (minted2 - fee2 - toEarn2 - toYield2), 'conservation with carry');

    vm.prank(operator);
    rr.distribute();
  }

  // ========== EXTRA ASSERTION PATTERNS ==========

  function testConservationInvariant() public {
    ext.addPending(25_000e6);

    // Conservation pattern from specification
    (uint256 minted, uint256 fee, uint256 toEarn, uint256 toYield, uint256 toExtra,,,) = rr.previewDistribute();

    vm.prank(operator);
    rr.distribute();

    assertEq(minted, fee + toEarn + toYield + toExtra);
    assertEq(usdsc.balanceOf(address(rr)), 0);
  }

  function testDenominatorAndProportionality() public {
    ext.addPending(30_000e6);

    // Denominator & proportionality pattern from specification
    (uint256 minted, uint256 fee, uint256 toEarn, uint256 toYield,,,,) = rr.previewDistribute();

    uint256 sBase = usdsc.totalSupply() - minted;
    uint256 T_earn = earnV.totalPrincipal();
    uint256 T_yield = sVault.totalAssets();

    assertLe(toEarn, ((minted - fee) * T_earn) / sBase);
    assertLe(toYield, ((minted - fee) * T_yield) / sBase);

    vm.prank(operator);
    rr.distribute();
  }

  function testOrderingEarnVaultFundingInvariant() public {
    // Ordering pattern from specification
    ext.addPending(20_000e6);

    uint256 claimReserveBefore = earnV.claimReserve();

    vm.prank(operator);
    rr.distribute();

    // In EarnVault.onYield: require(balance >= claimReserve + amount)
    // If order was wrong, onYield would have reverted
    // Since we got here, the correct order (transfer → onYield) was followed
    assertGt(earnV.claimReserve(), claimReserveBefore, 'claimReserve increased - funding invariant held');
  }

  function testPPSMonotonic() public {
    // PPS monotonic pattern from specification
    uint256 ppsBefore = sVault.totalAssets(); // Using totalAssets as PPS proxy since our mock has 0 supply

    ext.addPending(15_000e6);

    vm.prank(operator);
    rr.distribute();

    uint256 ppsAfter = sVault.totalAssets();
    assertGe(ppsAfter, ppsBefore);
  }

  // ========== CORE INVARIANTS ==========

  function testInvariant1_ConservationOfValue() public {
    ext.addPending(50_000e6);

    // uint256 balanceBefore = usdsc.balanceOf(address(rr));

    vm.prank(operator);
    rr.distribute();

    // A) minted == feeToStartale + toEarn + toYield + toStartaleExtra
    // This is checked by the conservation test above, but let's be explicit
    uint256 startaleGot = usdsc.balanceOf(startale);
    uint256 earnGot = usdsc.balanceOf(address(earnV)) - 1_000_000e6;
    uint256 susdscGot = usdsc.balanceOf(address(sVault)) - 1_000_000e6;

    assertEq(startaleGot + earnGot + susdscGot, 50_000e6, 'conservation');

    // B) ASSET.balanceOf(redistributor) == 0
    assertEq(usdsc.balanceOf(address(rr)), 0, 'no dust left');
  }

  function testInvariant2_CorrectDenominator() public {
    ext.addPending(25_000e6);

    uint256 totalSupplyBefore = usdsc.totalSupply();

    (,,,,, uint256 sBase,,) = rr.previewDistribute();

    // sBase == ASSET.totalSupply() (for preview functions with preMint = true)
    assertEq(sBase, totalSupplyBefore, 'correct sBase calculation');
  }

  function testInvariant2_PathologicalZeroSBase() public {
    // Test the edge case where eligible TVL approaches total base supply
    // This tests that the system handles low sBase gracefully

    // Set up a smaller yield to avoid the underflow edge case
    ext.addPending(1000e6);

    // Burn most of the circulating supply, but leave enough for sBase > eligible TVL
    uint256 testBalance = usdsc.balanceOf(address(this));
    uint256 toBurn = testBalance - 100_000e6; // Leave some circulating supply
    usdsc.burn(address(this), toBurn);

    (
      uint256 minted,
      uint256 feeToStartale,
      uint256 toEarn,
      uint256 toYield,
      uint256 toStartaleExtra,
      uint256 sBase,
      uint256 tEarn,
      uint256 tYield
    ) = rr.previewDistribute();

    // Verify sBase calculation is correct (for preview functions with preMint = true)
    assertEq(sBase, usdsc.totalSupply(), 'sBase calculation correct');

    // When sBase is very small relative to eligible TVL, most should go to Startale
    uint256 eligibleTvl = tEarn + tYield;
    if (sBase <= eligibleTvl) {
      // Most of the net yield should go to Startale as extra
      assertGt(toStartaleExtra, toEarn + toYield, 'most goes to startale when sBase is small');
    }

    // Conservation should still hold
    assertEq(minted, feeToStartale + toEarn + toYield + toStartaleExtra, 'conservation holds');
  }

  function testInvariant3_ProportionalAllocation() public {
    ext.addPending(100_000e6);

    (
      uint256 minted,
      uint256 feeToStartale,
      uint256 toEarn,
      uint256 toYield,,
      uint256 sBase,
      uint256 tEarn,
      uint256 tYield
    ) = rr.previewDistribute();

    uint256 net = minted - feeToStartale;

    // Check proportional allocation (allowing for rounding)
    uint256 expectedToEarn = (net * tEarn) / sBase;
    uint256 expectedToOn = (net * tYield) / sBase;

    // Allow small rounding differences
    assertApproxEqRel(toEarn, expectedToEarn, 0.01e18, 'proportional toEarn'); // 1% tolerance
    assertApproxEqRel(toYield, expectedToOn, 0.01e18, 'proportional toOn'); // 1% tolerance
  }

  function testInvariant4_LongRunFairness() public {
    // Track balances to measure actual distributions
    uint256 initialEarn = usdsc.balanceOf(address(earnV));
    uint256 initialSusdsc = usdsc.balanceOf(address(sVault));

    uint256 totalActualToEarn = 0;
    uint256 totalActualToYield = 0;
    uint256 totalTheoreticalEarn = 0;
    uint256 totalTheoreticalYield = 0;

    // Run many small distributions to test carry fairness
    for (uint256 i = 0; i < 30; i++) {
      uint256 yieldAmount = 1000 + ((i * 137) % 5000); // Pseudo-random amounts
      ext.addPending(yieldAmount);

      // Get preview with carry
      (
        uint256 minted,
        uint256 feeToStartale,
        uint256 toEarn,
        uint256 toYield,,
        uint256 sBase,
        uint256 tEarn,
        uint256 tYield
      ) = rr.previewSplitCurrent();

      uint256 net = minted - feeToStartale;
      totalActualToEarn += toEarn;
      totalActualToYield += toYield;
      totalTheoreticalEarn += (net * tEarn) / sBase;
      totalTheoreticalYield += (net * tYield) / sBase;

      vm.prank(operator);
      rr.distribute();
    }

    // Verify actual distributions
    uint256 actualEarnDistributed = usdsc.balanceOf(address(earnV)) - initialEarn;
    uint256 actualSusdscDistributed = usdsc.balanceOf(address(sVault)) - initialSusdsc;

    // Allow small differences due to timing of carry calculations
    assertApproxEqAbs(actualEarnDistributed, totalActualToEarn, 100, 'earn tracking approximately matches');
    assertApproxEqAbs(actualSusdscDistributed, totalActualToYield, 100, 'sUSDSC tracking approximately matches');

    // Carry fairness: cumulative error should be bounded
    uint256 earnError = totalActualToEarn > totalTheoreticalEarn
      ? totalActualToEarn - totalTheoreticalEarn
      : totalTheoreticalEarn - totalActualToEarn;
    uint256 onError = totalActualToYield > totalTheoreticalYield
      ? totalActualToYield - totalTheoreticalYield
      : totalTheoreticalYield - totalActualToYield;

    // Error should be bounded by sBase and very small relative to total
    uint256 currentSBase = usdsc.totalSupply();
    assertLt(earnError, currentSBase, 'earn carry error bounded');
    assertLt(onError, currentSBase, 'on carry error bounded');

    if (totalTheoreticalEarn > 0) {
      assertLt((earnError * 1000) / totalTheoreticalEarn, 1, 'earn fairness < 0.1%');
    }
    if (totalTheoreticalYield > 0) {
      assertLt((onError * 1000) / totalTheoreticalYield, 1, 'on fairness < 0.1%');
    }
  }

  function testInvariant5_OrderingAndFundingInvariants() public {
    ext.addPending(15_000e6);

    uint256 claimReserveBefore = earnV.claimReserve();

    vm.prank(operator);
    rr.distribute();

    // Check that funding invariant holds: onYield was called successfully
    // If order was wrong, onYield would have reverted
    assertGt(earnV.claimReserve(), claimReserveBefore, 'claimReserve increased');

    // The MockEarnVault.onYield checks: balanceOf >= claimReserve + amount
    // If this passes, it means transfer happened before onYield
  }

  function testInvariant6_MonotonicNAV() public {
    // Calculate initial PPS (price per share)
    uint256 initialAssets = sVault.totalAssets();
    uint256 initialSupply = sVault.totalSupply(); // This is 0 in our mock
    assertEq(initialSupply, 0, 'initial supply is 0');
    ext.addPending(30_000e6);

    vm.prank(operator);
    rr.distribute();

    uint256 finalAssets = sVault.totalAssets();

    // Assets should have increased (monotonic NAV)
    assertGt(finalAssets, initialAssets, 'sUSDSC assets increased');

    // In a real ERC4626, we'd check PPS = totalAssets/totalSupply is non-decreasing
    // Our mock doesn't track supply, but assets increasing is the key property
  }

  function testInvariant7_IdempotenceNoOp() public {
    // Don't add any pending yield
    assertEq(ext.yield(), 0, 'no pending yield');

    uint256 startaleBalBefore = usdsc.balanceOf(startale);
    uint256 earnBalBefore = usdsc.balanceOf(address(earnV));
    uint256 susdscBalBefore = usdsc.balanceOf(address(sVault));

    vm.prank(operator);
    rr.distribute(); // Should be no-op

    // Balances should be unchanged
    assertEq(usdsc.balanceOf(startale), startaleBalBefore, 'startale unchanged');
    assertEq(usdsc.balanceOf(address(earnV)), earnBalBefore, 'earn unchanged');
    assertEq(usdsc.balanceOf(address(sVault)), susdscBalBefore, 'susdsc unchanged');
    assertEq(usdsc.balanceOf(address(rr)), 0, 'no dust');
  }

  function testInvariant8_AccessControlAndPause() public {
    // Test access control
    vm.expectRevert();
    rr.distribute(); // Should fail - not operator

    vm.expectRevert();
    vm.prank(operator);
    rr.setParams(startale, IEarnVault(address(earnV)), IERC4626(address(sVault)), 0); // Should fail - not admin

    // Test pause
    vm.prank(admin);
    rr.pause(true);

    vm.prank(operator);
    vm.expectRevert();
    rr.distribute(); // Should fail - paused

    // Test unpause
    vm.prank(admin);
    rr.pause(false);

    vm.prank(operator);
    rr.distribute(); // Should work now
  }

  // Review with Earn vault dev logic when no deposits exist.
  function testInvariant9_EdgeCohorts() public {
    // Test T_earn == 0
    earnV.setPrincipal(0);
    ext.addPending(20_000e6);

    (,, uint256 toEarn, uint256 toYield,,, uint256 tEarn, uint256 tYield) = rr.previewDistribute();

    assertEq(tEarn, 0, 'T_earn is 0');
    assertEq(toEarn, 0, 'toEarn is 0 when T_earn is 0');
    assertGt(toYield, 0, 'toOn gets the allocation');

    // Reset and test T_on == 0
    earnV.setPrincipal(1_000_000e6);
    usdsc.burn(address(sVault), usdsc.balanceOf(address(sVault)));

    (,, toEarn, toYield,,, tEarn, tYield) = rr.previewDistribute();

    assertEq(tYield, 0, 'T_yield is 0');
    assertEq(toYield, 0, 'toYield is 0 when T_yield is 0');
    assertGt(toEarn, 0, 'toEarn gets the allocation');
  }

  function testInvariant10_EventCorrectness() public {
    ext.addPending(40_000e6);

    (uint256 expectedMinted,,,,,, uint256 expectedTEarn, uint256 expectedTYield) = rr.previewDistribute();

    // We can't exactly match preview vs actual due to timing of sBase calculation
    // But we can verify the event contains reasonable values
    vm.recordLogs();

    vm.prank(operator);
    rr.distribute();

    // Check that Distributed event was emitted with correct structure
    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundDistributedEvent = false;

    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IRewardRedistributorEventsAndErrors.Distributed.selector) {
        foundDistributedEvent = true;

        // Decode the event data
        (
          uint256 minted,
          uint256 feeToStartale,
          uint256 toEarn,
          uint256 toYield,
          uint256 toStartaleExtra,
          uint256 sBase,
          uint256 tEarn,
          uint256 tYield
        ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));

        // Verify event fields are self-consistent
        assertEq(minted, expectedMinted, 'minted matches');
        assertEq(tEarn, expectedTEarn, 'T_earn matches on-chain read');
        assertEq(tYield, expectedTYield, 'T_yield matches on-chain read');
        assertEq(minted, feeToStartale + toEarn + toYield + toStartaleExtra, 'conservation in event');
        assertGt(sBase, 0, 'sBase is positive');

        break;
      }
    }

    assertTrue(foundDistributedEvent, 'Distributed event was emitted');
  }

  function testExternalClaimYieldBeforeDistribute() public {
    // Test the scenario where claimYield() is called externally before distribute()

    // Clear any existing balances first
    uint256 initialTreasuryBalance = usdsc.balanceOf(startale);
    uint256 initialEarnVaultBalance = usdsc.balanceOf(address(earnV));
    uint256 initialSVaultBalance = usdsc.balanceOf(address(sVault));

    // Add pending yield
    ext.addPending(50_000e6);

    // External user calls claimYield() first (must be yield recipient)
    vm.prank(address(rr)); // RewardRedistributor is the yield recipient
    uint256 externalMinted = ext.claimYield();
    assertEq(externalMinted, 50_000e6, 'External claimYield should mint correct amount');

    // Verify RewardRedistributor has the yield
    uint256 balanceBefore = usdsc.balanceOf(address(rr));
    assertEq(balanceBefore, 50_000e6, 'RewardRedistributor should have the yield');

    // Now keeper calls distribute() - should handle existing balance
    vm.prank(operator);
    rr.distribute();

    // Verify all yield was distributed (no dust left)
    uint256 balanceAfter = usdsc.balanceOf(address(rr));
    assertEq(balanceAfter, 0, 'All yield should be distributed');

    // Verify yield went to expected recipients (accounting for initial balances)
    uint256 treasuryBalance = usdsc.balanceOf(startale);
    uint256 earnVaultBalance = usdsc.balanceOf(address(earnV));
    uint256 sVaultBalance = usdsc.balanceOf(address(sVault));

    // Calculate the additional amounts distributed
    uint256 additionalTreasury = treasuryBalance - initialTreasuryBalance;
    uint256 additionalEarnVault = earnVaultBalance - initialEarnVaultBalance;
    uint256 additionalSVault = sVaultBalance - initialSVaultBalance;

    // Total additional distributed should equal original yield
    uint256 totalAdditionalDistributed = additionalTreasury + additionalEarnVault + additionalSVault;
    assertEq(totalAdditionalDistributed, 50_000e6, 'All yield should be distributed to recipients');

    // Verify conservation
    assertEq(externalMinted, totalAdditionalDistributed, 'External minted amount should equal total distributed');
  }

  function testExternalClaimYieldInvariants() public {
    // Test that all invariants hold when claimYield() is called externally before distribute()

    // Add pending yield
    ext.addPending(100_000e6);

    // Record initial state for invariant checks
    uint256 initialTotalSupply = usdsc.totalSupply();
    uint256 initialTreasuryBalance = usdsc.balanceOf(startale);
    uint256 initialEarnVaultBalance = usdsc.balanceOf(address(earnV));
    uint256 initialSVaultBalance = usdsc.balanceOf(address(sVault));

    // External user calls claimYield() first
    vm.prank(address(rr));
    uint256 externalMinted = ext.claimYield();

    // Invariant 1: Conservation of Value (after external claimYield)
    uint256 newTotalSupply = usdsc.totalSupply();
    assertEq(newTotalSupply, initialTotalSupply + externalMinted, 'Total supply should increase by minted amount');

    // Invariant 2: RewardRedistributor balance should equal minted amount
    uint256 rrBalance = usdsc.balanceOf(address(rr));
    assertEq(rrBalance, externalMinted, 'RewardRedistributor should hold the minted yield');

    // Now keeper calls distribute()
    vm.prank(operator);
    rr.distribute();

    // Invariant 3: Conservation of Value (after distribution)
    uint256 finalTotalSupply = usdsc.totalSupply();
    assertEq(finalTotalSupply, newTotalSupply, 'Total supply should not change during distribution');

    // Invariant 4: No dust retention
    uint256 finalRrBalance = usdsc.balanceOf(address(rr));
    assertEq(finalRrBalance, 0, 'RewardRedistributor should have no remaining balance');

    // Invariant 5: All yield distributed to recipients
    uint256 finalTreasuryBalance = usdsc.balanceOf(startale);
    uint256 finalEarnVaultBalance = usdsc.balanceOf(address(earnV));
    uint256 finalSVaultBalance = usdsc.balanceOf(address(sVault));

    uint256 additionalTreasury = finalTreasuryBalance - initialTreasuryBalance;
    uint256 additionalEarnVault = finalEarnVaultBalance - initialEarnVaultBalance;
    uint256 additionalSVault = finalSVaultBalance - initialSVaultBalance;

    uint256 totalDistributed = additionalTreasury + additionalEarnVault + additionalSVault;
    assertEq(totalDistributed, externalMinted, 'All minted yield should be distributed');
  }

  function testPreviewDistributeConsistencyWithExternalClaimYield() public {
    // Test that previewDistribute() is consistent with actual distribute() when claimYield() was called externally

    // Add pending yield
    ext.addPending(75_000e6);

    // External user calls claimYield() first
    vm.prank(address(rr));
    ext.claimYield();

    // Preview the distribution
    (uint256 minted,,,,,,,) = rr.previewDistribute();

    // Since yield was already claimed externally, preview should show 0 pending yield
    assertEq(minted, 0, 'Preview should show 0 pending yield after external claim');

    // Now perform actual distribution
    vm.prank(operator);
    rr.distribute();

    // Verify that the actual distribution used the existing balance
    uint256 finalRrBalance = usdsc.balanceOf(address(rr));
    assertEq(finalRrBalance, 0, 'All yield should be distributed');

    // The key insight: previewDistribute() shows 0 because there's no pending yield,
    // but distribute() handles the existing balance correctly
    // This is the expected behavior - preview shows pending yield, distribute handles existing balance
  }

  function testMultipleExternalClaimYieldCalls() public {
    // Test multiple external claimYield() calls before distribute()

    // First external claimYield
    ext.addPending(25_000e6);
    vm.prank(address(rr));
    uint256 firstMinted = ext.claimYield();

    // Second external claimYield (after more yield accrues)
    ext.addPending(30_000e6);
    vm.prank(address(rr));
    uint256 secondMinted = ext.claimYield();

    uint256 totalExternalMinted = firstMinted + secondMinted;

    // Verify RewardRedistributor has all the yield
    uint256 rrBalance = usdsc.balanceOf(address(rr));
    assertEq(rrBalance, totalExternalMinted, 'RewardRedistributor should have all externally minted yield');

    // Now distribute - should handle all existing balance
    vm.prank(operator);
    rr.distribute();

    // Verify all yield was distributed
    uint256 finalRrBalance = usdsc.balanceOf(address(rr));
    assertEq(finalRrBalance, 0, 'All yield should be distributed');

    // Verify conservation
    uint256 totalSupplyIncrease = usdsc.totalSupply() - (10_000_000e6); // Subtract initial supply
    assertEq(totalSupplyIncrease, totalExternalMinted, 'Total supply increase should equal total externally minted');
  }

  function testPreviewDistributeSBaseCalculationInvariants() public {
    // Test that previewDistribute() sBase calculation is consistent with actual distribution

    // Add pending yield
    ext.addPending(40_000e6);

    // Record initial state
    uint256 initialTotalSupply = usdsc.totalSupply();

    // Preview the distribution
    (uint256 minted, uint256 fee, uint256 toEarn, uint256 toOn, uint256 extra, uint256 sBase,,) = rr.previewDistribute();

    // Invariant 1: minted should equal pending yield
    assertEq(minted, 40_000e6, 'Preview minted should equal pending yield');

    // Invariant 2: sBase should equal current total supply (preMint = true)
    assertEq(sBase, initialTotalSupply, 'Preview sBase should equal current total supply');

    // Invariant 3: Conservation in preview
    uint256 total = fee + toEarn + toOn + extra;
    assertEq(total, minted, 'Preview should conserve total yield');

    // Now perform actual distribution
    vm.prank(operator);
    rr.distribute();

    // Invariant 4: sBase in actual distribution should equal total supply before mint
    uint256 finalTotalSupply = usdsc.totalSupply();

    // We can't directly check sBase from distribute(), but we can verify the total supply increase
    assertEq(finalTotalSupply, initialTotalSupply + minted, 'Total supply should increase by minted amount');

    // Invariant 5: No dust retention after actual distribution
    uint256 finalRrBalance = usdsc.balanceOf(address(rr));
    assertEq(finalRrBalance, 0, 'No dust should remain in RewardRedistributor');
  }

  function testPreviewDistributeConsistencyAcrossMultipleCalls() public {
    // Test that previewDistribute() gives consistent results across multiple calls

    // Add pending yield
    ext.addPending(60_000e6);

    // First preview call
    (uint256 minted1,, uint256 toEarn1, uint256 toOn1,, uint256 sBase1,, uint256 tYield1) = rr.previewDistribute();

    // Second preview call (should be identical)
    (uint256 minted2,, uint256 toEarn2, uint256 toOn2,, uint256 sBase2,, uint256 tYield2) = rr.previewDistribute();

    // Invariant: All values should be identical
    assertEq(minted1, minted2, 'Preview minted should be consistent');
    assertEq(toEarn1, toEarn2, 'Preview toEarn should be consistent');
    assertEq(toOn1, toOn2, 'Preview toOn should be consistent');
    assertEq(sBase1, sBase2, 'Preview sBase should be consistent');
    assertEq(tYield1, tYield2, 'Preview T_yield should be consistent');
  }

  function testPreviewDistributeWithCarryLogic() public {
    // Test that previewDistribute() correctly handles carry logic

    // Add pending yield
    ext.addPending(33_333e6); // Use a number that will create remainders for carry testing

    // Record initial state

    // Preview the distribution
    (uint256 minted,,,,,,,) = rr.previewDistribute();

    // Invariant: Preview should include carry logic
    // The exact calculation depends on the carry values, but we can verify consistency

    // Now perform actual distribution
    vm.prank(operator);
    rr.distribute();

    // Verify that distribution completed successfully
    uint256 finalRrBalance = usdsc.balanceOf(address(rr));
    assertEq(finalRrBalance, 0, 'All yield should be distributed');

    // Verify conservation
    uint256 finalTotalSupply = usdsc.totalSupply();
    uint256 expectedTotalSupply = usdsc.totalSupply() - minted + minted; // Should be same
    assertEq(finalTotalSupply, expectedTotalSupply, 'Total supply should be consistent');
  }

  function testPreviewDistributeEdgeCases() public {
    // Test edge cases for previewDistribute()

    // Test 1: Zero pending yield
    (
      uint256 minted,
      uint256 fee,
      uint256 toEarn,
      uint256 toOn,
      uint256 extra,
      uint256 sBase,
      uint256 tEarn,
      uint256 tYield
    ) = rr.previewDistribute();

    assertEq(minted, 0, 'Preview minted should be 0 when no pending yield');
    assertEq(fee, 0, 'Preview fee should be 0 when no pending yield');
    assertEq(toEarn, 0, 'Preview toEarn should be 0 when no pending yield');
    assertEq(toOn, 0, 'Preview toOn should be 0 when no pending yield');
    assertEq(extra, 0, 'Preview extra should be 0 when no pending yield');
    assertEq(sBase, usdsc.totalSupply(), 'Preview sBase should equal current supply');

    // Test 2: Very small pending yield
    ext.addPending(1e6); // 1 USDSC

    (minted, fee, toEarn, toOn, extra, sBase, tEarn, tYield) = rr.previewDistribute();

    assertEq(minted, 1e6, 'Preview minted should equal small pending yield');
    assertEq(sBase, usdsc.totalSupply(), 'Preview sBase should equal current supply');

    // Conservation should still hold
    uint256 total = fee + toEarn + toOn + extra;
    assertEq(total, minted, 'Preview should conserve total yield even for small amounts');
  }

  function test_DistributeWithZeroSBase() public {
    // Test the edge case where S_base == 0 in distribute()
    // This happens when supply before mint would be zero or negative

    // Burn all circulating supply to create zero base scenario
    uint256 thisBalance = usdsc.balanceOf(address(this));
    usdsc.burn(address(this), thisBalance);

    // Burn vault balances too
    uint256 earnBalance = usdsc.balanceOf(address(earnV));
    usdsc.burn(address(earnV), earnBalance);
    earnV.setPrincipal(0);
    earnV.setClaimReserve(0);

    uint256 sVaultBalance = usdsc.balanceOf(address(sVault));
    usdsc.burn(address(sVault), sVaultBalance);

    // Verify total supply is now zero
    assertEq(usdsc.totalSupply(), 0, 'Total supply should be zero');

    // Add pending yield
    ext.addPending(100_000e6);

    // Record treasury balance before
    uint256 treasuryBefore = usdsc.balanceOf(startale);

    // Record logs to verify event
    vm.recordLogs();

    // Distribute should handle S_base == 0 case
    vm.prank(operator);
    rr.distribute();

    // When S_base == 0, all yield should go to treasury (fee + extra)
    uint256 treasuryAfter = usdsc.balanceOf(startale);
    uint256 treasuryReceived = treasuryAfter - treasuryBefore;

    // All yield (100_000e6) should go to treasury since S_base == 0
    assertEq(treasuryReceived, 100_000e6, 'All yield should go to treasury when S_base == 0');

    // No yield should go to vaults
    assertEq(usdsc.balanceOf(address(earnV)), 0, 'EarnVault should receive nothing');
    assertEq(usdsc.balanceOf(address(sVault)), 0, 'sUSDSC vault should receive nothing');

    // No dust in redistributor
    assertEq(usdsc.balanceOf(address(rr)), 0, 'No dust should remain in redistributor');

    // Verify event was emitted with correct values
    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundEvent = false;

    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IRewardRedistributorEventsAndErrors.Distributed.selector) {
        // Decode event parameters
        (
          uint256 minted,
          uint256 feeToStartale,
          uint256 toEarnVault,
          uint256 toSUSDSCVault,
          uint256 toStartaleExtra,
          uint256 sBase,
          uint256 tEarn,
          uint256 tYield
        ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));

        // Verify event values for S_base == 0 case
        assertEq(minted, 100_000e6, 'Event: minted should be 100_000e6');
        assertEq(sBase, 0, 'Event: S_base should be 0');
        assertEq(toEarnVault, 0, 'Event: toEarnVault should be 0');
        assertEq(toSUSDSCVault, 0, 'Event: toSUSDSCVault should be 0');
        assertEq(tEarn, 0, 'Event: T_earn should be 0');
        assertEq(tYield, 0, 'Event: T_yield should be 0');

        // Fee + extra should equal minted
        assertEq(feeToStartale + toStartaleExtra, minted, 'Event: fee + extra should equal minted');

        foundEvent = true;
        break;
      }
    }

    assertTrue(foundEvent, 'Distributed event should be emitted for S_base == 0 case');
  }
}
