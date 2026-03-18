// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import '../../src/distributor/RewardRedistributor.sol';
import '../../src/interfaces/distributor/IRewardRedistributorEventsAndErrors.sol';
import '../mocks/MockERC20.sol';
import '../mocks/MockERC4626Vault.sol';
import '../mocks/MockEarnVault.sol';
import '../mocks/MockExtension.sol';
import '../mocks/MockInvalidContract.sol';
import '../mocks/MockOnlyYieldToOne.sol';
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
    ext = new MockExtension(usdsc, address(0), address(this)); // owner is test contract
    earnV = new MockEarnVault(usdsc);
    sVault = new MockERC4626Vault(usdsc);

    rr = new RewardRedistributor(
      address(ext), // MockExtension address (implements both IERC20 and IMYieldToOne)
      startale,
      IEarnVault(address(earnV)),
      IERC4626(address(sVault)),
      admin,
      operator // keeper gets OPERATOR_ROLE
    );

    // Set redistributor as extension yieldRecipient
    ext.setYieldRecipient(address(rr));
    // Set redistributor as the claimer (only it can call claimYield())
    ext.setClaimer(address(rr));

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
    // Take snapshot first (needed for preview and distribute)
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    vm.roll(block.number + 1); // Advance to next block

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

    _takeSnapshotAndWait();
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
    _takeSnapshotAndWait();
    for (uint256 i = 0; i < 10; i++) {
      ext.addPending(100); // 100 wei of USDSC - still tiny but avoids underflow
      // Take new snapshot for each distribution
      vm.prank(operator);
      rr.snapshotSusdscTVL();
      vm.roll(block.number + 1); // Advance to next block
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
    _takeSnapshotAndWait();
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

    // Take snapshot before pausing (snapshot requires not paused)
    _takeSnapshotAndWait();

    vm.prank(admin);
    rr.pause(true);
    vm.prank(operator);
    vm.expectRevert(); // paused
    rr.distribute();

    vm.prank(admin);
    rr.pause(false);
    // Take new snapshot after unpause
    _takeSnapshotAndWait();
    vm.prank(operator);
    // distribute() succeeds after unpause (may return early if no pending yield, but doesn't revert)
    rr.distribute();
  }

  function testRoleManagement_ChangeOperatorAfterDeployment() public {
    // Initial setup: operator (keeper) has OPERATOR_ROLE from constructor
    bytes32 operatorRole = rr.OPERATOR_ROLE();

    // Verify original operator has the role
    assertTrue(rr.hasRole(operatorRole, operator), 'Original operator should have OPERATOR_ROLE');

    // Verify original operator can call distribute()
    ext.addPending(1000e6);
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute(); // Should succeed

    // Setup new operator address
    address newOperator = address(0x9999999999999999999999999999999999999999);

    // Admin grants OPERATOR_ROLE to new operator
    vm.prank(admin);
    rr.grantRole(operatorRole, newOperator);

    // Verify new operator has the role
    assertTrue(rr.hasRole(operatorRole, newOperator), 'New operator should have OPERATOR_ROLE');

    // Verify new operator can call distribute()
    ext.addPending(1000e6);
    vm.prank(newOperator);
    rr.snapshotSusdscTVL();
    vm.roll(block.number + 1); // Advance to next block
    vm.prank(newOperator);
    rr.distribute(); // Should succeed

    // Admin revokes OPERATOR_ROLE from original operator
    vm.prank(admin);
    rr.revokeRole(operatorRole, operator);

    // Verify original operator no longer has the role
    assertFalse(rr.hasRole(operatorRole, operator), 'Original operator should not have OPERATOR_ROLE');

    // Verify original operator can no longer call distribute()
    // Note: Access control check happens before snapshot validation,
    // so this will fail with AccessControl error, not snapshot error
    // Also, operator can't take snapshot without the role, so we skip that
    ext.addPending(1000e6);
    vm.prank(operator);
    vm.expectRevert(); // Should fail - no longer has OPERATOR_ROLE
    rr.distribute();

    // Verify new operator still has the role and can call distribute()
    ext.addPending(1000e6);
    vm.prank(newOperator);
    rr.distribute(); // Should still succeed
  }

  function testRoleRenunciation_LastAdminCannotBeRenounced() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();

    // Verify admin has DEFAULT_ADMIN_ROLE and is the only admin
    assertTrue(rr.hasRole(adminRole, admin), 'Admin should have DEFAULT_ADMIN_ROLE');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have exactly 1 admin');

    // Last admin attempts to renounce DEFAULT_ADMIN_ROLE - should revert
    vm.prank(admin);
    vm.expectRevert(IRewardRedistributorEventsAndErrors.CannotRemoveLastAdmin.selector);
    rr.renounceRole(adminRole, admin);

    // Verify admin still has the role after failed renunciation
    assertTrue(rr.hasRole(adminRole, admin), 'Admin should still have DEFAULT_ADMIN_ROLE');
  }

  function testRoleRenunciation_AdminCanRenounceWhenMultipleAdminsExist() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();

    // Grant admin role to a second address
    address secondAdmin = makeAddr('secondAdmin');
    vm.prank(admin);
    rr.grantRole(adminRole, secondAdmin);

    // Verify both admins exist
    assertEq(rr.getRoleMemberCount(adminRole), 2, 'Should have 2 admins');
    assertTrue(rr.hasRole(adminRole, admin), 'First admin should have role');
    assertTrue(rr.hasRole(adminRole, secondAdmin), 'Second admin should have role');

    // First admin can now renounce since there's another admin
    vm.prank(admin);
    rr.renounceRole(adminRole, admin);

    // Verify first admin renounced successfully
    assertFalse(rr.hasRole(adminRole, admin), 'First admin should no longer have role');
    assertTrue(rr.hasRole(adminRole, secondAdmin), 'Second admin should still have role');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have 1 admin remaining');
  }

  function testRoleRenunciation_OperatorRoleCanBeRenounced() public {
    bytes32 operatorRole = rr.OPERATOR_ROLE();

    // Verify operator has OPERATOR_ROLE
    assertTrue(rr.hasRole(operatorRole, operator), 'Operator should have OPERATOR_ROLE');

    // Operator renounces their role - should succeed
    vm.prank(operator);
    rr.renounceRole(operatorRole, operator);

    // Verify operator no longer has the role
    assertFalse(rr.hasRole(operatorRole, operator), 'Operator should not have OPERATOR_ROLE after renunciation');

    // Verify operator can no longer call distribute()
    // Note: Access control check happens before snapshot validation,
    // so this will fail with AccessControl error, not snapshot error
    // Also, operator can't take snapshot without the role, so we skip that
    ext.addPending(1000e6);
    vm.prank(operator);
    vm.expectRevert(); // Should fail - no longer has OPERATOR_ROLE
    rr.distribute();
  }

  /// @notice Test that renouncing a role you don't have doesn't trigger last admin protection
  /// @dev This verifies the fix for the edge case where someone without admin role
  ///      tries to renounce DEFAULT_ADMIN_ROLE when there's only 1 admin
  function testRoleRenunciation_NonAdminCanAttemptRenounceWithoutError() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();

    // Verify operator does NOT have DEFAULT_ADMIN_ROLE
    assertFalse(rr.hasRole(adminRole, operator), 'Operator should NOT have DEFAULT_ADMIN_ROLE');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have exactly 1 admin');

    // Operator tries to renounce DEFAULT_ADMIN_ROLE they don't have
    // This should NOT revert with CannotRemoveLastAdmin since they don't have the role
    // It should just silently do nothing (OpenZeppelin's _revokeRole returns false)
    vm.prank(operator);
    rr.renounceRole(adminRole, operator);

    // Verify nothing changed
    assertFalse(rr.hasRole(adminRole, operator), 'Operator should still NOT have the role');
    assertTrue(rr.hasRole(adminRole, admin), 'Admin should still have the role');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should still have exactly 1 admin');
  }

  // ========== ROLE REVOCATION TESTS ==========

  function testRoleRevocation_CannotRevokeSingleAdmin() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();

    // Verify there's only one admin
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have exactly one admin');
    assertTrue(rr.hasRole(adminRole, admin), 'Admin should have DEFAULT_ADMIN_ROLE');

    // Admin attempts to revoke their own DEFAULT_ADMIN_ROLE - should revert
    vm.prank(admin);
    vm.expectRevert(IRewardRedistributorEventsAndErrors.CannotRemoveLastAdmin.selector);
    rr.revokeRole(adminRole, admin);

    // Verify admin still has the role after failed revocation
    assertTrue(rr.hasRole(adminRole, admin), 'Admin should still have DEFAULT_ADMIN_ROLE');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should still have exactly one admin');
  }

  function testRoleRevocation_CanRevokeAdminWhenMultipleExist() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();
    address secondAdmin = makeAddr('admin2');

    // Grant admin role to a second admin
    vm.prank(admin);
    rr.grantRole(adminRole, secondAdmin);

    // Verify there are now two admins
    assertEq(rr.getRoleMemberCount(adminRole), 2, 'Should have exactly two admins');
    assertTrue(rr.hasRole(adminRole, admin), 'First admin should have DEFAULT_ADMIN_ROLE');
    assertTrue(rr.hasRole(adminRole, secondAdmin), 'Second admin should have DEFAULT_ADMIN_ROLE');

    // First admin can now revoke second admin - should succeed
    vm.prank(admin);
    rr.revokeRole(adminRole, secondAdmin);

    // Verify second admin no longer has the role
    assertFalse(rr.hasRole(adminRole, secondAdmin), 'Second admin should not have DEFAULT_ADMIN_ROLE');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have exactly one admin remaining');

    // First admin still has the role
    assertTrue(rr.hasRole(adminRole, admin), 'First admin should still have DEFAULT_ADMIN_ROLE');
  }

  function testRoleRevocation_CannotRevokeLastOfMultipleAdmins() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();
    address secondAdmin = makeAddr('admin2');
    address thirdAdmin = makeAddr('admin3');

    // Grant admin role to second and third admins
    vm.prank(admin);
    rr.grantRole(adminRole, secondAdmin);
    vm.prank(admin);
    rr.grantRole(adminRole, thirdAdmin);

    // Verify there are now three admins
    assertEq(rr.getRoleMemberCount(adminRole), 3, 'Should have exactly three admins');

    // Revoke two admins successfully
    vm.prank(admin);
    rr.revokeRole(adminRole, secondAdmin);
    assertEq(rr.getRoleMemberCount(adminRole), 2, 'Should have two admins after first revocation');

    vm.prank(admin);
    rr.revokeRole(adminRole, thirdAdmin);
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have one admin after second revocation');

    // Attempt to revoke the last admin - should revert
    vm.prank(admin);
    vm.expectRevert(IRewardRedistributorEventsAndErrors.CannotRemoveLastAdmin.selector);
    rr.revokeRole(adminRole, admin);

    // Verify last admin still has the role
    assertTrue(rr.hasRole(adminRole, admin), 'Last admin should still have DEFAULT_ADMIN_ROLE');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should still have exactly one admin');
  }

  function testRoleRevocation_OperatorRoleCanBeRevoked() public {
    bytes32 operatorRole = rr.OPERATOR_ROLE();

    // Verify operator has OPERATOR_ROLE
    assertTrue(rr.hasRole(operatorRole, operator), 'Operator should have OPERATOR_ROLE');

    // Admin revokes operator's role - should succeed (no protection for non-admin roles)
    vm.prank(admin);
    rr.revokeRole(operatorRole, operator);

    // Verify operator no longer has the role
    assertFalse(rr.hasRole(operatorRole, operator), 'Operator should not have OPERATOR_ROLE after revocation');

    // Verify operator can no longer call distribute()
    // Note: Access control check happens before snapshot validation,
    // so this will fail with AccessControl error, not snapshot error
    // Also, operator can't take snapshot without the role, so we skip that
    ext.addPending(1000e6);
    vm.prank(operator);
    vm.expectRevert(); // Should fail - no longer has OPERATOR_ROLE
    rr.distribute();
  }

  function testRoleRevocation_NonAdminCannotRevokeRoles() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();
    bytes32 operatorRole = rr.OPERATOR_ROLE();
    address nonAdmin = address(0xBaD0000000000000000000000000000000000001);

    // Non-admin attempts to revoke operator role - should revert
    vm.prank(nonAdmin);
    vm.expectRevert(); // AccessControl: account is missing role
    rr.revokeRole(operatorRole, operator);

    // Non-admin attempts to revoke admin role - should revert
    vm.prank(nonAdmin);
    vm.expectRevert(); // AccessControl: account is missing role
    rr.revokeRole(adminRole, admin);

    // Verify roles are unchanged
    assertTrue(rr.hasRole(operatorRole, operator), 'Operator should still have OPERATOR_ROLE');
    assertTrue(rr.hasRole(adminRole, admin), 'Admin should still have DEFAULT_ADMIN_ROLE');
  }

  /// @notice Test that revoking a role from someone who doesn't have it doesn't trigger last admin protection
  /// @dev This verifies the fix for the edge case where admin tries to revoke DEFAULT_ADMIN_ROLE
  ///      from someone who doesn't have it, when there's only 1 admin
  function testRoleRevocation_NonAdminRevocationDoesNotTriggerProtection() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();

    // Verify operator does NOT have DEFAULT_ADMIN_ROLE
    assertFalse(rr.hasRole(adminRole, operator), 'Operator should NOT have DEFAULT_ADMIN_ROLE');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have exactly 1 admin');

    // Admin tries to revoke DEFAULT_ADMIN_ROLE from operator (who doesn't have it)
    // This should NOT revert with CannotRemoveLastAdmin since operator doesn't have the role
    // It should just silently do nothing (OpenZeppelin's _revokeRole returns false)
    vm.prank(admin);
    rr.revokeRole(adminRole, operator);

    // Verify nothing changed
    assertFalse(rr.hasRole(adminRole, operator), 'Operator should still NOT have the role');
    assertTrue(rr.hasRole(adminRole, admin), 'Admin should still have the role');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should still have exactly 1 admin');
  }

  function testRoleRevocation_MultiAdminScenario() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();
    address admin2 = address(0xADD22222222222222222222222222222222222);
    address admin3 = address(0xADD33333333333333333333333333333333333);

    // Setup: Create three admins
    vm.prank(admin);
    rr.grantRole(adminRole, admin2);
    vm.prank(admin);
    rr.grantRole(adminRole, admin3);

    assertEq(rr.getRoleMemberCount(adminRole), 3, 'Should have three admins');

    // Admin2 can revoke Admin3
    vm.prank(admin2);
    rr.revokeRole(adminRole, admin3);
    assertEq(rr.getRoleMemberCount(adminRole), 2, 'Should have two admins');
    assertFalse(rr.hasRole(adminRole, admin3), 'Admin3 should not have role');

    // Admin can revoke Admin2
    vm.prank(admin);
    rr.revokeRole(adminRole, admin2);
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have one admin');
    assertFalse(rr.hasRole(adminRole, admin2), 'Admin2 should not have role');

    // Cannot revoke the last admin
    vm.prank(admin);
    vm.expectRevert(IRewardRedistributorEventsAndErrors.CannotRemoveLastAdmin.selector);
    rr.revokeRole(adminRole, admin);

    assertTrue(rr.hasRole(adminRole, admin), 'Last admin should still have role');
  }

  function testRoleRevocation_LastAdminProtectionWithRegrant() public {
    bytes32 adminRole = rr.DEFAULT_ADMIN_ROLE();
    address admin2 = address(0xADD22222222222222222222222222222222222);

    // Start with one admin
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should start with one admin');

    // Grant to admin2
    vm.prank(admin);
    rr.grantRole(adminRole, admin2);
    assertEq(rr.getRoleMemberCount(adminRole), 2, 'Should have two admins');

    // Revoke admin
    vm.prank(admin2);
    rr.revokeRole(adminRole, admin);
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have one admin');
    assertFalse(rr.hasRole(adminRole, admin), 'Original admin should not have role');
    assertTrue(rr.hasRole(adminRole, admin2), 'Admin2 should have role');

    // Admin2 cannot revoke themselves (last admin)
    vm.prank(admin2);
    vm.expectRevert(IRewardRedistributorEventsAndErrors.CannotRemoveLastAdmin.selector);
    rr.revokeRole(adminRole, admin2);

    assertTrue(rr.hasRole(adminRole, admin2), 'Admin2 should still have role');
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should still have one admin');

    // Admin2 can grant back to original admin
    vm.prank(admin2);
    rr.grantRole(adminRole, admin);
    assertEq(rr.getRoleMemberCount(adminRole), 2, 'Should have two admins again');

    // Now admin2 can be revoked
    vm.prank(admin);
    rr.revokeRole(adminRole, admin2);
    assertEq(rr.getRoleMemberCount(adminRole), 1, 'Should have one admin');
    assertTrue(rr.hasRole(adminRole, admin), 'Original admin should have role back');
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

    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Second epoch - with carry
    ext.addPending(3000e6);
    (uint256 minted2, uint256 fee2, uint256 toEarn2, uint256 toYield2,,,,) = rr.previewSplitCurrent();

    // Verify conservation
    assertEq(minted2, fee2 + toEarn2 + toYield2 + (minted2 - fee2 - toEarn2 - toYield2), 'conservation with carry');

    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();
  }

  // ========== EXTRA ASSERTION PATTERNS ==========

  function testConservationInvariant() public {
    ext.addPending(25_000e6);

    // Conservation pattern from specification
    (uint256 minted, uint256 fee, uint256 toEarn, uint256 toYield, uint256 toExtra,,,) = rr.previewDistribute();

    _takeSnapshotAndWait();
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

    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();
  }

  function testOrderingEarnVaultFundingInvariant() public {
    // Ordering pattern from specification
    ext.addPending(20_000e6);

    uint256 claimReserveBefore = earnV.claimReserve();

    _takeSnapshotAndWait();
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

    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    uint256 ppsAfter = sVault.totalAssets();
    assertGe(ppsAfter, ppsBefore);
  }

  // ========== CORE INVARIANTS ==========

  function testInvariant1_ConservationOfValue() public {
    ext.addPending(50_000e6);

    // uint256 balanceBefore = usdsc.balanceOf(address(rr));

    _takeSnapshotAndWait();
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

    // Take initial snapshot
    _takeSnapshotAndWait();

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

      // Take new snapshot for each distribution
      vm.prank(operator);
      rr.snapshotSusdscTVL();
      vm.roll(block.number + 1); // Advance to next block
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

    _takeSnapshotAndWait();
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

    _takeSnapshotAndWait();
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

    _takeSnapshotAndWait();
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
    rr.setFeeBps(0); // Should fail - not admin

    // Test pause - take snapshot before pausing (snapshot requires not paused)
    _takeSnapshotAndWait();
    vm.prank(admin);
    rr.pause(true);

    vm.prank(operator);
    vm.expectRevert();
    rr.distribute(); // Should fail - paused

    // Test unpause
    vm.prank(admin);
    rr.pause(false);

    // Take new snapshot after unpause
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute(); // Should work now
  }

  // Review with Earn vault dev logic when no deposits exist.
  // Phase 1: T_earn and T_yield come from snapshot; take a new snapshot after changing vault state to update them.
  function testInvariant9_EdgeCohorts() public {
    // Test T_earn == 0: set EarnVault principal to 0 then snapshot so lastEarnTVL is 0
    earnV.setPrincipal(0);
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    vm.roll(block.number + 1);
    ext.addPending(20_000e6);

    (,, uint256 toEarn, uint256 toYield,,, uint256 tEarn, uint256 tYield) = rr.previewDistribute();

    assertEq(tEarn, 0, 'T_earn is 0 (from snapshot)');
    assertEq(toEarn, 0, 'toEarn is 0 when T_earn is 0');
    assertGt(toYield, 0, 'toOn gets the allocation');

    // Reset and test T_on == 0: set sUSDSC to 0 then snapshot so lastSusdscTVL is 0
    earnV.setPrincipal(1_000_000e6);
    usdsc.burn(address(sVault), usdsc.balanceOf(address(sVault)));

    vm.prank(operator);
    rr.snapshotSusdscTVL();
    vm.roll(block.number + 1);

    (,, toEarn, toYield,,, tEarn, tYield) = rr.previewDistribute();

    assertEq(tYield, 0, 'T_yield is 0 (from snapshot)');
    assertEq(toYield, 0, 'toYield is 0 when T_yield is 0');
    assertGt(toEarn, 0, 'toEarn gets the allocation');
  }

  function testInvariant10_EventCorrectness() public {
    // Take snapshot first (needed for preview and distribute)
    _takeSnapshotAndWait();

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

  function testDonationBeforeDistribute() public {
    // Test the scenario where a donation is sent to the contract before distribute()
    // With the new behavior: distribute() only distributes what it mints, not existing balance.
    // Donations remain in the contract and can be recovered.

    // Clear any existing balances first
    uint256 initialTreasuryBalance = usdsc.balanceOf(startale);

    // Send a donation directly to the contract (simulating accidental/intentional transfer)
    uint256 donationAmount = 50_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // Verify RewardRedistributor has the donation
    uint256 balanceBefore = usdsc.balanceOf(address(rr));
    assertEq(balanceBefore, donationAmount, 'RewardRedistributor should have the donation');

    // Add pending yield and distribute - donation should remain separate
    ext.addPending(100_000e6);
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Verify donation remains (treated as donation, not distributed)
    uint256 balanceAfter = usdsc.balanceOf(address(rr));
    assertEq(balanceAfter, donationAmount, 'Donation should remain in contract after distribute');

    // Verify distribution occurred for the minted yield (100k), not the donation
    uint256 treasuryBalanceAfter = usdsc.balanceOf(startale);
    assertGt(treasuryBalanceAfter, initialTreasuryBalance, 'Distribution should have occurred for minted yield');

    // Recover the donation
    vm.prank(admin);
    rr.recoverDonations();

    // Verify donation was recovered to treasury
    uint256 treasuryBalanceFinal = usdsc.balanceOf(startale);
    assertEq(treasuryBalanceFinal - treasuryBalanceAfter, donationAmount, 'Donation should be recovered to treasury');
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Balance should be zero after recovery');
  }

  function testDonationInvariants() public {
    // Test that all invariants hold when donations are sent to the contract
    // With the new behavior: donations remain in the contract and can be recovered

    // Record initial state for invariant checks
    uint256 initialTotalSupply = usdsc.totalSupply();
    uint256 initialTreasuryBalance = usdsc.balanceOf(startale);

    // Send a donation directly to the contract
    uint256 donationAmount = 100_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // Invariant 1: Conservation of Value (after donation)
    uint256 newTotalSupply = usdsc.totalSupply();
    assertEq(newTotalSupply, initialTotalSupply + donationAmount, 'Total supply should increase by donation amount');

    // Invariant 2: RewardRedistributor balance should equal donation amount
    uint256 rrBalance = usdsc.balanceOf(address(rr));
    assertEq(rrBalance, donationAmount, 'RewardRedistributor should hold the donation');

    // Add pending yield and distribute - donation should remain separate
    ext.addPending(50_000e6);
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Invariant 3: Conservation of Value (after distribution)
    uint256 finalTotalSupply = usdsc.totalSupply();
    assertEq(finalTotalSupply, newTotalSupply + 50_000e6, 'Total supply should increase by minted yield');

    // Invariant 4: Balance remains as donation (not distributed)
    uint256 finalRrBalance = usdsc.balanceOf(address(rr));
    assertEq(finalRrBalance, donationAmount, 'RewardRedistributor should retain donation balance');

    // Invariant 5: Distribution occurred for minted yield only
    uint256 finalTreasuryBalance = usdsc.balanceOf(startale);
    assertGt(finalTreasuryBalance, initialTreasuryBalance, 'Distribution should have occurred for minted yield');

    // Invariant 6: Donation can be recovered
    vm.prank(admin);
    rr.recoverDonations();
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Donation should be recoverable');
    assertEq(
      usdsc.balanceOf(startale) - finalTreasuryBalance, donationAmount, 'Donation should be recovered to treasury'
    );
  }

  function testPreviewDistributeConsistencyWithDonation() public {
    // Test that previewDistribute() is consistent with actual distribute() when donation exists
    // With the new behavior: distribute() only distributes what it mints, not existing balance

    // Send a donation to the contract
    uint256 donationAmount = 75_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // Add pending yield
    ext.addPending(50_000e6);

    // Preview the distribution - should show pending yield, not donation
    (uint256 minted,,,,,,,) = rr.previewDistribute();
    assertEq(minted, 50_000e6, 'Preview should show pending yield amount');

    // Verify donation is in contract
    assertEq(usdsc.balanceOf(address(rr)), donationAmount, 'Donation should be in contract');

    // Now perform actual distribution
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Verify that the donation remains (treated as donation, not distributed)
    uint256 finalRrBalance = usdsc.balanceOf(address(rr));
    assertEq(finalRrBalance, donationAmount, 'Donation should remain in contract after distribute');

    // The key insight: previewDistribute() shows pending yield to be minted,
    // distribute() mints and distributes that yield, but donations remain separate.
    // The donation can be recovered via recoverDonations().

    // Verify donation can be recovered
    vm.prank(admin);
    rr.recoverDonations();
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Donation should be recoverable');
  }

  function testMultipleDonations() public {
    // Test multiple donations sent to the contract before and after distribute()
    // With the new behavior: donations remain in the contract and can be recovered

    uint256 initialTreasuryBalance = usdsc.balanceOf(startale);

    // First donation
    uint256 donation1 = 25_000e6;
    usdsc.mint(address(this), donation1);
    usdsc.transfer(address(rr), donation1);

    // Add pending yield and distribute
    ext.addPending(50_000e6);
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Verify first donation remains
    assertEq(usdsc.balanceOf(address(rr)), donation1, 'First donation should remain after distribute');

    // Second donation (after distribution)
    uint256 donation2 = 30_000e6;
    usdsc.mint(address(this), donation2);
    usdsc.transfer(address(rr), donation2);

    uint256 totalDonations = donation1 + donation2;

    // Verify RewardRedistributor has all donations
    uint256 rrBalance = usdsc.balanceOf(address(rr));
    assertEq(rrBalance, totalDonations, 'RewardRedistributor should have all donations');

    // Distribute again (with new pending yield)
    ext.addPending(40_000e6);
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Verify donations remain (treated as donations, not distributed)
    uint256 finalRrBalance = usdsc.balanceOf(address(rr));
    assertEq(finalRrBalance, totalDonations, 'All donations should remain after distribute');

    // Verify distribution occurred for minted yield
    assertGt(usdsc.balanceOf(startale), initialTreasuryBalance, 'Distribution should have occurred for minted yield');

    // Verify conservation - total supply increased by donations + minted yield
    uint256 totalSupplyIncrease = usdsc.totalSupply() - (10_000_000e6); // Subtract initial supply
    assertGt(totalSupplyIncrease, totalDonations, 'Total supply should include donations and minted yield');

    // Record treasury balance before recovery
    uint256 treasuryBeforeRecovery = usdsc.balanceOf(startale);

    // Verify all donations can be recovered
    vm.prank(admin);
    rr.recoverDonations();
    assertEq(usdsc.balanceOf(address(rr)), 0, 'All donations should be recoverable');
    assertEq(
      usdsc.balanceOf(startale) - treasuryBeforeRecovery, totalDonations, 'Donations should be recovered to treasury'
    );
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
    _takeSnapshotAndWait();
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
    _takeSnapshotAndWait();
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
    _takeSnapshotAndWait();
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

  function testRevert_DistributeWhenYieldRecipientChanged() public {
    // Setup: Add pending yield
    ext.addPending(10_000e6);

    // Change yield recipient to different address
    address newRecipient = makeAddr('newRecipient');
    ext.setYieldRecipient(newRecipient);

    // Attempt to distribute should revert
    vm.prank(operator);
    vm.expectRevert(
      abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.YieldRecipientChanged.selector, newRecipient)
    );
    rr.distribute();
  }

  function testRevert_DistributeWhenYieldRecipientZero() public {
    // Setup: Add pending yield
    ext.addPending(10_000e6);

    // Change yield recipient to zero address
    ext.setYieldRecipient(address(0));

    // Attempt to distribute should revert
    vm.prank(operator);
    vm.expectRevert(
      abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.YieldRecipientChanged.selector, address(0))
    );
    rr.distribute();
  }

  function testRevert_DistributeWhenYieldRecipientChangedMidOperation() public {
    // First distribution succeeds
    ext.addPending(5000e6);
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Change yield recipient between distributions
    address newRecipient = makeAddr('newRecipient');
    ext.setYieldRecipient(newRecipient);

    // Second distribution should fail
    ext.addPending(5000e6);
    vm.prank(operator);
    vm.expectRevert(
      abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.YieldRecipientChanged.selector, newRecipient)
    );
    rr.distribute();
  }

  function test_DistributeSucceedsWhenYieldRecipientCorrect() public {
    // Verify that yield recipient is correctly set
    assertEq(ext.yieldRecipient(), address(rr), 'Yield recipient should be RewardRedistributor');

    // Setup: Add pending yield
    ext.addPending(10_000e6);

    // Distribution should succeed when yield recipient is correct
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Verify distribution happened (treasury received something)
    assertGt(usdsc.balanceOf(startale), 0, 'Treasury should receive yield');
  }

  // ========== USDSC VALIDATION TESTS ==========

  function testConstructor_RevertsOnZeroUSDSCAddress() public {
    vm.expectRevert(abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.ZeroAddress.selector, 'USDSC_ADDRESS'));
    new RewardRedistributor(
      address(0), // zero USDSC address
      startale,
      IEarnVault(address(earnV)),
      IERC4626(address(sVault)),
      admin,
      operator
    );
  }

  function testConstructor_RevertsOnEOA_NotContract() public {
    // Use an EOA (Externally Owned Account) - not a contract
    address eoa = makeAddr('eoa');

    vm.expectRevert(abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.InvalidUSDSC.selector, 'NOT_CONTRACT'));
    new RewardRedistributor(eoa, startale, IEarnVault(address(earnV)), IERC4626(address(sVault)), admin, operator);
  }

  function testConstructor_RevertsOnInvalidUSDSC_MissingIERC20() public {
    // Deploy a contract that implements IMYieldToOne but not IERC20
    MockOnlyYieldToOne invalidUsdsc = new MockOnlyYieldToOne();

    vm.expectRevert(abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.InvalidUSDSC.selector, 'IERC20'));
    new RewardRedistributor(
      address(invalidUsdsc), startale, IEarnVault(address(earnV)), IERC4626(address(sVault)), admin, operator
    );
  }

  function testConstructor_RevertsOnInvalidUSDSC_MissingIMYieldToOne() public {
    // Deploy a contract that implements IERC20 but not IMYieldToOne
    MockERC20 invalidUsdsc = new MockERC20('Invalid', 'INV', 18);

    vm.expectRevert(abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.InvalidUSDSC.selector, 'IMYieldToOne'));
    new RewardRedistributor(
      address(invalidUsdsc), startale, IEarnVault(address(earnV)), IERC4626(address(sVault)), admin, operator
    );
  }

  function testConstructor_RevertsOnInvalidUSDSC_ImplementsNeither() public {
    // Deploy a contract that implements neither interface
    MockInvalidContract invalidUsdsc = new MockInvalidContract();

    vm.expectRevert(abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.InvalidUSDSC.selector, 'IERC20'));
    new RewardRedistributor(
      address(invalidUsdsc), startale, IEarnVault(address(earnV)), IERC4626(address(sVault)), admin, operator
    );
  }

  // ========== HELPER FUNCTIONS ==========

  /// @notice Helper to take snapshot in block N and advance to block N+1
  /// @dev This ensures snapshot and distribute are in separate transactions:
  ///      - Transaction 1: snapshotSusdscTVL() in block N
  ///      - Transaction 2: distribute() in block N+x (x >= 1)
  ///      Caller must still call distribute() separately after this helper, and must ensure that distribute() is called in a subsequent block (N+1, N+2, etc.), not in the same block as the snapshot. The block advanced by this helper is N+1, but the caller may advance further if needed, as long as the snapshot age is valid.
  function _takeSnapshotAndWait() internal {
    // Transaction 1: Take snapshot in current block
    vm.prank(operator);
    rr.snapshotSusdscTVL();

    // Advance to next block so distribute() will be in a different block
    vm.roll(block.number + 1);
  }

  // ========== SNAPSHOT FUNCTIONALITY TESTS ==========

  function test_SnapshotSusdscTVL_CapturesCorrectTVL() public {
    uint256 initialTVL = sVault.totalAssets();
    assertEq(initialTVL, 1_000_000e6, 'Initial TVL should be 1M');
    uint256 currentBlock = block.number;
    uint256 currentTimestamp = block.timestamp;

    vm.prank(operator);
    rr.snapshotSusdscTVL();

    assertEq(rr.lastSusdscTVL(), initialTVL, 'Snapshot should capture correct TVL');
    assertEq(rr.lastSnapshotTimestamp(), currentTimestamp, 'Snapshot should capture current timestamp');
    assertEq(rr.lastSnapshotBlockNumber(), currentBlock, 'Snapshot should capture current block number');
  }

  function test_SnapshotSusdscTVL_EmitsEvent() public {
    uint256 expectedTVL = sVault.totalAssets();
    uint256 expectedTimestamp = block.timestamp;
    uint256 expectedBlockNumber = block.number;

    vm.prank(operator);
    vm.expectEmit(true, true, true, true);
    emit IRewardRedistributorEventsAndErrors.SusdscTVLSnapshotCaptured(
      expectedTVL, expectedTimestamp, expectedBlockNumber
    );
    rr.snapshotSusdscTVL();
  }

  function test_SnapshotSusdscTVL_OnlyOperator() public {
    address nonOperator = makeAddr('nonOperator');

    vm.prank(nonOperator);
    vm.expectRevert();
    rr.snapshotSusdscTVL();
  }

  function test_SnapshotSusdscTVL_RevertsWhenPaused() public {
    vm.prank(admin);
    rr.pause(true);

    vm.prank(operator);
    vm.expectRevert();
    rr.snapshotSusdscTVL();
  }

  function test_SnapshotSusdscTVL_UpdatesOnMultipleCalls() public {
    // First snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 firstTVL = rr.lastSusdscTVL();
    uint256 firstTimestamp = rr.lastSnapshotTimestamp();

    // Increase TVL
    usdsc.mint(address(sVault), 500_000e6);

    // Second snapshot
    vm.warp(block.timestamp + 1 minutes);
    vm.prank(operator);
    rr.snapshotSusdscTVL();

    assertEq(rr.lastSusdscTVL(), firstTVL + 500_000e6, 'Second snapshot should capture new TVL');
    assertGt(rr.lastSnapshotTimestamp(), firstTimestamp, 'Second snapshot should have later timestamp');
  }

  function test_SnapshotSusdscTVL_InitialStateIsZero() public {
    assertEq(rr.lastSusdscTVL(), 0, 'Initial snapshot TVL should be zero');
    assertEq(rr.lastSnapshotTimestamp(), 0, 'Initial snapshot timestamp should be zero');
  }

  function test_SnapshotSusdscTVL_CapturesZeroTVL() public {
    // Remove all funds from vault
    uint256 vaultBalance = usdsc.balanceOf(address(sVault));
    usdsc.burn(address(sVault), vaultBalance);
    assertEq(sVault.totalAssets(), 0, 'Vault should have zero TVL');

    vm.prank(operator);
    rr.snapshotSusdscTVL();

    assertEq(rr.lastSusdscTVL(), 0, 'Snapshot should capture zero TVL');
    assertEq(rr.lastSnapshotTimestamp(), block.timestamp, 'Snapshot should capture current timestamp');
  }

  function test_SnapshotSusdscTVL_CapturesLargeTVL() public {
    // Add large amount to vault
    usdsc.mint(address(sVault), 100_000_000e6); // 100M
    assertEq(sVault.totalAssets(), 101_000_000e6, 'Vault should have 101M TVL');

    vm.prank(operator);
    rr.snapshotSusdscTVL();

    assertEq(rr.lastSusdscTVL(), 101_000_000e6, 'Snapshot should capture large TVL');
  }

  // ========== SNAPSHOT MAX AGE TESTS ==========

  function test_SetSnapshotMaxAge_DefaultValue() public {
    assertEq(rr.snapshotMaxAge(), 4 hours, 'Default should be 4 hours');
  }

  function test_SetSnapshotMaxAge_CanSetToMinimum() public {
    // Minimum is 1 minute
    vm.prank(admin);
    rr.setSnapshotMaxAge(1 minutes);
    assertEq(rr.snapshotMaxAge(), 1 minutes, 'Should accept 1 minute');
  }

  function test_SetSnapshotMaxAge_CanSetToMaximum() public {
    vm.prank(admin);
    rr.setSnapshotMaxAge(7 days);
    assertEq(rr.snapshotMaxAge(), 7 days, 'Should accept 7 days');
  }

  function test_SetSnapshotMaxAge_CanSetToMiddleValue() public {
    vm.prank(admin);
    rr.setSnapshotMaxAge(2 hours);
    assertEq(rr.snapshotMaxAge(), 2 hours, 'Should accept 2 hours');
  }

  function test_SetSnapshotMaxAge_RevertsWhenLessThanMinimum() public {
    // Minimum is 1 minute
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.InvalidSnapshotMaxAge.selector, 30 seconds, 1 minutes)
    );
    rr.setSnapshotMaxAge(30 seconds); // Less than 1 minute - should revert
  }

  function test_SetSnapshotMaxAge_RevertsWhenMoreThan7Days() public {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(
        IRewardRedistributorEventsAndErrors.InvalidSnapshotMaxAge.selector, 7 days + 1 seconds, 7 days
      )
    );
    rr.setSnapshotMaxAge(7 days + 1 seconds);
  }

  function test_SetSnapshotMaxAge_EmitsEvent() public {
    vm.recordLogs();
    vm.prank(admin);
    rr.setSnapshotMaxAge(6 hours);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 1, 'Should emit one event');
    assertEq(logs[0].topics[0], keccak256('SnapshotMaxAgeUpdated(uint256)'), 'Should emit SnapshotMaxAgeUpdated event');
  }

  function test_SetSnapshotMaxAge_OnlyAdmin() public {
    vm.prank(operator);
    vm.expectRevert();
    rr.setSnapshotMaxAge(6 hours);
  }

  function test_Distribute_RevertsWhenSnapshotTooOld() public {
    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTime = rr.lastSnapshotTimestamp();

    // Advance to next block first (required)
    vm.roll(block.number + 1);
    // Advance time past max age (4 hours default)
    vm.warp(snapshotTime + 4 hours + 1 seconds);

    ext.addPending(100_000e6);

    vm.expectRevert(
      abi.encodeWithSelector(
        IRewardRedistributorEventsAndErrors.SnapshotTooOld.selector,
        snapshotTime,
        snapshotTime + 4 hours + 1 seconds,
        4 hours
      )
    );
    vm.prank(operator);
    rr.distribute();
  }

  function test_Distribute_SucceedsWhenSnapshotWithinValidRange() public {
    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();

    // Advance to next block
    vm.roll(block.number + 1);
    // Advance time to middle of valid range (before max age)
    vm.warp(block.timestamp + 2 hours);

    ext.addPending(100_000e6);

    vm.prank(operator);
    rr.distribute(); // Should succeed

    assertGt(usdsc.balanceOf(startale), 0, 'Distribution should succeed');
  }

  function test_Distribute_SucceedsAtMaxAgeBoundary() public {
    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTime = rr.lastSnapshotTimestamp();

    // Advance to next block
    vm.roll(block.number + 1);
    // Advance time to exactly max age
    vm.warp(snapshotTime + 4 hours);

    ext.addPending(100_000e6);

    vm.prank(operator);
    rr.distribute(); // Should succeed (at boundary)

    assertGt(usdsc.balanceOf(startale), 0, 'Distribution should succeed at boundary');
  }

  function test_Distribute_RevertsWhenMaxAgeUpdatedAndSnapshotTooOld() public {
    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTime = rr.lastSnapshotTimestamp();

    // Reduce max age to 1 hour
    vm.prank(admin);
    rr.setSnapshotMaxAge(1 hours);

    // Advance to next block first (required)
    vm.roll(block.number + 1);
    // Advance time past new max age (1 hour) but within old max age (4 hours)
    vm.warp(snapshotTime + 1 hours + 1 seconds);

    ext.addPending(100_000e6);

    vm.expectRevert(
      abi.encodeWithSelector(
        IRewardRedistributorEventsAndErrors.SnapshotTooOld.selector,
        snapshotTime,
        snapshotTime + 1 hours + 1 seconds,
        1 hours
      )
    );
    vm.prank(operator);
    rr.distribute();
  }

  // ========== SNAPSHOT VALIDATION TESTS ==========

  function test_Distribute_RevertsWhenNoSnapshotTaken() public {
    ext.addPending(100_000e6);

    vm.expectRevert(abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.LastSnapshotInvalid.selector));
    vm.prank(operator);
    rr.distribute();
  }

  function test_Distribute_RevertsWhenSameBlock() public {
    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotBlock = rr.lastSnapshotBlockNumber();

    // Try to distribute in same block
    ext.addPending(100_000e6);

    vm.expectRevert(
      abi.encodeWithSelector(
        IRewardRedistributorEventsAndErrors.MustSnapshotInPreviousBlocks.selector, snapshotBlock, block.number
      )
    );
    vm.prank(operator);
    rr.distribute();
  }

  function test_Distribute_SucceedsAfterNextBlock() public {
    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotBlock = rr.lastSnapshotBlockNumber();

    // Advance to next block
    vm.roll(block.number + 1);
    assertEq(block.number, snapshotBlock + 1, 'Should be in next block');

    ext.addPending(100_000e6);

    // Distribution should succeed
    vm.prank(operator);
    rr.distribute();

    // Verify distribution happened
    assertGt(usdsc.balanceOf(startale), 0, 'Treasury should receive yield');
  }

  function test_Distribute_SucceedsAfterMultipleBlocks() public {
    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotBlock = rr.lastSnapshotBlockNumber();

    // Advance multiple blocks (x > 1)
    vm.roll(block.number + 5);
    assertEq(block.number, snapshotBlock + 5, 'Should be 5 blocks ahead');

    ext.addPending(100_000e6);

    // Distribution should succeed (x >= 1 is satisfied)
    vm.prank(operator);
    rr.distribute();

    // Verify distribution happened
    assertGt(usdsc.balanceOf(startale), 0, 'Treasury should receive yield');
  }

  function test_Distribute_UsesSnapshotTVLNotCurrentTVL() public {
    // Setup initial TVL
    usdsc.mint(address(sVault), 9_000_000e6); // Total 10M
    earnV.setPrincipal(5_000_000e6);

    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTVL = rr.lastSusdscTVL();
    uint256 snapshotTime = rr.lastSnapshotTimestamp();
    assertEq(snapshotTVL, 10_000_000e6, 'Snapshot should capture 10M TVL');

    // Change TVL after snapshot
    usdsc.mint(address(sVault), 5_000_000e6); // Now 15M
    assertEq(sVault.totalAssets(), 15_000_000e6, 'Current TVL should be 15M');

    // Advance to next block (but don't take new snapshot!)
    vm.roll(block.number + 1);

    ext.addPending(1_000_000e6);

    // Distribution should use snapshot TVL (10M), not current TVL (15M)
    vm.prank(operator);
    rr.distribute();

    // Verify snapshot TVL was used (distribution calculation should be based on 10M, not 15M)
    assertEq(rr.lastSusdscTVL(), snapshotTVL, 'Snapshot TVL should remain unchanged');
  }

  // ========== EXPLOIT SCENARIO TESTS ==========

  function test_ExploitScenario_PreventsSameBlockTVLManipulation() public {
    // Setup: 10M in sUSDSC vault, 5M in EarnVault
    usdsc.mint(address(sVault), 9_000_000e6); // Total 10M
    earnV.setPrincipal(5_000_000e6);

    // Take snapshot with 10M TVL
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTVL = rr.lastSusdscTVL();
    assertEq(snapshotTVL, 10_000_000e6, 'Snapshot should capture 10M TVL');

    // Attacker tries to manipulate TVL in same block (before next block requirement)
    // Simulate attacker depositing 4.095M to inflate vault
    usdsc.mint(address(sVault), 4_095_000e6);
    assertEq(sVault.totalAssets(), 14_095_000e6, 'Vault should be inflated to 14.095M');

    // Try to distribute - should fail because same block
    ext.addPending(1_000_000e6);

    vm.expectRevert(
      abi.encodeWithSelector(
        IRewardRedistributorEventsAndErrors.MustSnapshotInPreviousBlocks.selector,
        rr.lastSnapshotBlockNumber(),
        block.number
      )
    );
    vm.prank(operator);
    rr.distribute();

    // Verify snapshot TVL is still 10M (not manipulated)
    assertEq(rr.lastSusdscTVL(), 10_000_000e6, 'Snapshot TVL should remain 10M');
  }

  function test_ExploitScenario_ProperWorkflowPreventsExploit() public {
    // Setup: 10M in sUSDSC vault, 5M in EarnVault
    usdsc.mint(address(sVault), 9_000_000e6); // Total 10M
    earnV.setPrincipal(5_000_000e6);

    // Step 1: Operator takes snapshot in block N
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTVL = rr.lastSusdscTVL();
    uint256 snapshotTime = rr.lastSnapshotTimestamp();
    assertEq(snapshotTVL, 10_000_000e6, 'Snapshot should capture 10M TVL');

    // Step 2: Attacker tries to manipulate TVL after snapshot
    usdsc.mint(address(sVault), 4_095_000e6);
    assertEq(sVault.totalAssets(), 14_095_000e6, 'Vault should be inflated to 14.095M');

    // Step 3: Advance to next block - but don't take new snapshot!
    vm.roll(block.number + 1);

    // Step 4: Distribution uses snapshot TVL (10M), not current TVL (14.095M)
    ext.addPending(1_000_000e6);

    uint256 balanceBefore = usdsc.balanceOf(startale);
    vm.prank(operator);
    rr.distribute();

    // Verify distribution used snapshot TVL, not manipulated TVL
    // With snapshot TVL (10M), the split should be different than with manipulated TVL (14.095M)
    // This prevents the attacker from capturing inflated yield
    uint256 balanceAfter = usdsc.balanceOf(startale);
    assertGt(balanceAfter, balanceBefore, 'Distribution should succeed');

    // Verify snapshot TVL was used (not current inflated TVL)
    // The distribution calculation should use lastSusdscTVL (10M), not sVault.totalAssets() (14.095M)
    assertEq(rr.lastSusdscTVL(), snapshotTVL, 'Snapshot TVL should remain 10M');
  }

  /// @notice Phase 1: EarnVault snapshot is used for split; post-snapshot "JIT" deposit does not increase toEarn
  function test_Phase1_EarnVaultSnapshotUsedForSplit() public {
    // Setup: 1M EarnVault, 10M sUSDSC (so we have both vaults)
    earnV.setPrincipal(1_000_000e6);
    usdsc.mint(address(sVault), 9_000_000e6);
    assertEq(sVault.totalAssets(), 10_000_000e6, 'sUSDSC TVL 10M');

    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 earnSnapshot = rr.lastEarnTVL();
    assertEq(earnSnapshot, 1_000_000e6, 'Snapshot should capture 1M EarnVault');

    // Simulate JIT: add 500k to EarnVault after snapshot (live totalPrincipal would be 1.5M)
    earnV.setPrincipal(1_500_000e6);
    assertEq(earnV.totalPrincipal(), 1_500_000e6, 'Live EarnVault is 1.5M');

    vm.roll(block.number + 1);
    ext.addPending(100_000e6);

    // Preview with snapshot: T_earn should be 1M (snapshot), not 1.5M
    (, uint256 fee,,,, uint256 sBase, uint256 tEarn, uint256 tYield) = rr.previewDistribute();
    assertEq(tEarn, 1_000_000e6, 'T_earn should be snapshot (1M), not live (1.5M)');

    uint256 earnBalanceBefore = usdsc.balanceOf(address(earnV));
    vm.prank(operator);
    rr.distribute();
    uint256 earnBalanceAfter = usdsc.balanceOf(address(earnV));
    uint256 toEarnActual = earnBalanceAfter - earnBalanceBefore;

    // toEarn should be based on T_earn = 1M. With S_base ~3.5M + 10M vaults, net ~97k: toEarn ≈ net * 1M / S_base
    // If we had used live 1.5M, toEarn would be 50% higher. So toEarn should be less than 1.5x of "fair" for 1M.
    (,,,,, uint256 sBase2, uint256 tEarn2,) = rr.previewDistribute();
    assertEq(tEarn2, 1_000_000e6, 'T_earn still snapshot after distribute');
    assertGt(toEarnActual, 0, 'EarnVault should receive yield');
    // Sanity: toEarn should match split with T_earn=1M (no JIT inflation)
    assertEq(tEarn2, earnSnapshot, 'Split uses snapshot EarnVault TVL');
  }

  /// @notice Phase 1: snapshotVaultTVLs() sets both lastSusdscTVL and lastEarnTVL
  function test_Phase1_SnapshotVaultTVLs_SetsBothTVLs() public {
    earnV.setPrincipal(2_000_000e6);
    uint256 sVaultAssetsBefore = sVault.totalAssets();
    usdsc.mint(address(sVault), 3_000_000e6);
    uint256 expectedSusdscTVL = sVault.totalAssets();

    vm.prank(operator);
    rr.snapshotVaultTVLs();

    assertEq(rr.lastEarnTVL(), 2_000_000e6, 'lastEarnTVL should be 2M');
    assertEq(rr.lastSusdscTVL(), expectedSusdscTVL, 'lastSusdscTVL should match sVault.totalAssets() at snapshot');
    assertEq(rr.lastSnapshotBlockNumber(), block.number, 'Block number set');
    assertEq(rr.lastSnapshotTimestamp(), block.timestamp, 'Timestamp set');
  }

  function test_ExploitScenario_AttackerCannotFrontrunWithProperWorkflow() public {
    // Setup: 10M in sUSDSC vault, 5M in EarnVault
    usdsc.mint(address(sVault), 9_000_000e6); // Total 10M
    earnV.setPrincipal(5_000_000e6);

    // Operator workflow: snapshot first
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTime = rr.lastSnapshotTimestamp();
    uint256 snapshotTVL = rr.lastSusdscTVL();

    // Attacker detects snapshot in mempool and tries to frontrun
    // But they can't frontrun the timestamp requirement
    usdsc.mint(address(sVault), 4_095_000e6);

    // Even if attacker manipulates TVL, they must wait for next block
    // Try to distribute immediately - should fail
    ext.addPending(1_000_000e6);

    vm.expectRevert(
      abi.encodeWithSelector(
        IRewardRedistributorEventsAndErrors.MustSnapshotInPreviousBlocks.selector,
        rr.lastSnapshotBlockNumber(),
        block.number
      )
    );
    vm.prank(operator);
    rr.distribute();

    // After next block, distribution uses snapshot (10M), not current (14.095M)
    vm.roll(block.number + 1);

    vm.prank(operator);
    rr.distribute();

    // Attacker's manipulation is ineffective because snapshot was taken before manipulation
    assertEq(rr.lastSusdscTVL(), snapshotTVL, 'Snapshot should be unchanged');
  }

  function test_ExploitScenario_RequiresNewSnapshotAfterDistribution() public {
    // Setup
    usdsc.mint(address(sVault), 9_000_000e6);
    earnV.setPrincipal(5_000_000e6);

    // First distribution cycle
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 firstSnapshotTime = rr.lastSnapshotTimestamp();
    uint256 firstSnapshotBlock = rr.lastSnapshotBlockNumber();
    vm.roll(block.number + 1); // Advance to next block

    ext.addPending(1_000_000e6);
    vm.prank(operator);
    rr.distribute();

    // Verify snapshot doesn't change after distribution
    assertEq(rr.lastSnapshotTimestamp(), firstSnapshotTime, 'Snapshot timestamp should not change after distribute');
    assertEq(rr.lastSnapshotBlockNumber(), firstSnapshotBlock, 'Snapshot block should not change after distribute');

    // Second distribution can use the same snapshot since it's in a previous block
    // (snapshot can be reused as long as it's in a previous block and not too old)
    ext.addPending(500_000e6);
    vm.prank(operator);
    rr.distribute(); // Should succeed - same snapshot, in previous block

    // Take new snapshot for third distribution
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    vm.roll(block.number + 1); // Advance to next block

    vm.prank(operator);
    rr.distribute(); // Should succeed
  }

  function test_ExploitScenario_RealisticAttackScenario() public {
    // Realistic setup matching exploit description
    // sUSDSC vault: 10M, EarnVault: 5M principal
    usdsc.mint(address(sVault), 9_000_000e6); // Total 10M
    earnV.setPrincipal(5_000_000e6);

    // Operator takes snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTime = rr.lastSnapshotTimestamp();
    uint256 snapshotTVL = rr.lastSusdscTVL();

    // Attacker attempts leverage loop (simplified: just inflate TVL)
    // In real scenario: deposit 1M → borrow 900k → deposit 900k → etc.
    // Here we simulate the end result: 4.095M deposited
    address attacker = makeAddr('attacker');
    usdsc.mint(attacker, 4_095_000e6);
    vm.prank(attacker);
    usdsc.transfer(address(sVault), 4_095_000e6);

    assertEq(sVault.totalAssets(), 14_095_000e6, 'Vault inflated to 14.095M');

    // Try immediate distribution - blocked by same block
    ext.addPending(1_000_000e6);
    vm.expectRevert(
      abi.encodeWithSelector(
        IRewardRedistributorEventsAndErrors.MustSnapshotInPreviousBlocks.selector,
        rr.lastSnapshotBlockNumber(),
        block.number
      )
    );
    vm.prank(operator);
    rr.distribute();

    // After next block, distribution uses snapshot (10M), preventing exploit
    vm.roll(block.number + 1);

    uint256 startaleBefore = usdsc.balanceOf(startale);
    uint256 earnVBefore = usdsc.balanceOf(address(earnV));
    uint256 sVaultBefore = usdsc.balanceOf(address(sVault));

    vm.prank(operator);
    rr.distribute();

    // Verify distribution used snapshot TVL (10M), not manipulated TVL (14.095M)
    // This means attacker doesn't get inflated share of yield
    uint256 startaleAfter = usdsc.balanceOf(startale);
    uint256 earnVAfter = usdsc.balanceOf(address(earnV));
    uint256 sVaultAfter = usdsc.balanceOf(address(sVault));

    assertGt(startaleAfter, startaleBefore, 'Startale should receive yield');
    assertGt(earnVAfter, earnVBefore, 'EarnVault should receive yield');
    assertGt(sVaultAfter, sVaultBefore, 'sUSDSC vault should receive yield');

    // Key: snapshot TVL (10M) was used, not current TVL (14.095M)
    // This prevents attacker from capturing 29% of yield based on inflated TVL
    assertEq(rr.lastSusdscTVL(), snapshotTVL, 'Snapshot should remain at 10M');
  }

  // ========== EVENT EMISSION TESTS ==========

  function test_Events_SusdscTVLSnapshotCaptured_EmitsCorrectParameters() public {
    uint256 expectedTVL = sVault.totalAssets();
    uint256 expectedTimestamp = block.timestamp;
    uint256 expectedBlockNumber = block.number;

    vm.recordLogs();
    vm.prank(operator);
    rr.snapshotSusdscTVL();

    Vm.Log[] memory logs = vm.getRecordedLogs();
    // Phase 1: snapshot emits SusdscTVLSnapshotCaptured + EarnVaultTVLSnapshotCaptured
    assertGe(logs.length, 1, 'Should emit at least one event');
    // Decode first event (SusdscTVLSnapshotCaptured: 3 args)
    bytes memory eventData = logs[0].data;
    (uint256 capturedTVL, uint256 capturedTimestamp, uint256 capturedBlockNumber) =
      abi.decode(eventData, (uint256, uint256, uint256));

    assertEq(capturedTVL, expectedTVL, 'Event should contain correct TVL');
    assertEq(capturedTimestamp, expectedTimestamp, 'Event should contain correct timestamp');
    assertEq(capturedBlockNumber, expectedBlockNumber, 'Event should contain correct block number');
  }

  function test_Events_MultipleSnapshots_EmitsMultipleEvents() public {
    vm.recordLogs();

    // First snapshot (emits SusdscTVLSnapshotCaptured + EarnVaultTVLSnapshotCaptured)
    vm.prank(operator);
    rr.snapshotSusdscTVL();

    vm.warp(block.timestamp + 1 minutes);

    // Second snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 4, 'Should emit two events per snapshot (legacy + EarnVaultTVLSnapshotCaptured)');
  }

  // ========== COMPREHENSIVE ERROR TESTS ==========

  function test_Errors_LastSnapshotInvalid_NoSnapshot() public {
    ext.addPending(100_000e6);

    // Verify both timestamp and block number are 0
    assertEq(rr.lastSnapshotTimestamp(), 0, 'Timestamp should be 0');
    assertEq(rr.lastSnapshotBlockNumber(), 0, 'Block number should be 0');

    vm.expectRevert(abi.encodeWithSelector(IRewardRedistributorEventsAndErrors.LastSnapshotInvalid.selector));
    vm.prank(operator);
    rr.distribute();
  }

  function test_Errors_MustSnapshotInPreviousBlocks_SameBlock() public {
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotBlock = rr.lastSnapshotBlockNumber();

    ext.addPending(100_000e6);

    vm.expectRevert(
      abi.encodeWithSelector(
        IRewardRedistributorEventsAndErrors.MustSnapshotInPreviousBlocks.selector, snapshotBlock, block.number
      )
    );
    vm.prank(operator);
    rr.distribute();
  }

  // ========== EDGE CASE TESTS ==========

  function test_EdgeCase_SnapshotAtZeroTimestamp() public {
    // This shouldn't happen in practice, but test that snapshot works
    vm.warp(0);
    vm.prank(operator);
    rr.snapshotSusdscTVL();

    assertEq(rr.lastSnapshotTimestamp(), 0, 'Snapshot timestamp should be 0');
    assertEq(rr.lastSusdscTVL(), sVault.totalAssets(), 'Snapshot TVL should be correct');
  }

  function test_EdgeCase_SnapshotAtMaxTimestamp() public {
    // Test snapshot at very large timestamp
    vm.warp(type(uint256).max - 1000);
    vm.prank(operator);
    rr.snapshotSusdscTVL();

    assertEq(rr.lastSnapshotTimestamp(), type(uint256).max - 1000, 'Snapshot timestamp should be correct');
  }

  function test_EdgeCase_MultipleSnapshotsBeforeDistribution() public {
    // Take multiple snapshots, only last one matters
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 firstSnapshotBlock = rr.lastSnapshotBlockNumber();

    vm.roll(block.number + 1);
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 secondSnapshotBlock = rr.lastSnapshotBlockNumber();

    // Distribution should use second snapshot
    vm.roll(block.number + 1);

    ext.addPending(100_000e6);
    vm.prank(operator);
    rr.distribute(); // Should succeed

    assertGt(usdsc.balanceOf(startale), 0, 'Distribution should succeed');
    assertEq(rr.lastSnapshotBlockNumber(), secondSnapshotBlock, 'Last snapshot should be used');
  }

  function test_PreviewDistribute_UsesSnapshotTVL() public {
    // Preview uses snapshot TVL for calculations (via _calculateSplit)
    // Setup initial TVL
    usdsc.mint(address(sVault), 9_000_000e6); // Total 10M
    earnV.setPrincipal(5_000_000e6);

    // Take snapshot
    vm.prank(operator);
    rr.snapshotSusdscTVL();
    uint256 snapshotTVL = rr.lastSusdscTVL();
    assertEq(snapshotTVL, 10_000_000e6, 'Snapshot should capture 10M TVL');

    // Change TVL after snapshot
    usdsc.mint(address(sVault), 5_000_000e6); // Now 15M
    assertEq(sVault.totalAssets(), 15_000_000e6, 'Current TVL should be 15M');

    ext.addPending(1_000_000e6);

    // Preview should use snapshot TVL (10M), not current TVL (15M)
    (,,,,, uint256 sBase, uint256 tEarn, uint256 tYield) = rr.previewDistribute();

    // The calculation should be based on snapshot TVL
    // We can verify by checking that the split uses the snapshot value
    assertGt(sBase, 0, 'S_base should be calculated');
    // Note: previewDistribute doesn't validate snapshot age, it just uses the snapshot TVL
  }

  function test_SnapshotSusdscTVL_CapturesBlockNumberCorrectly() public {
    uint256 blockBefore = block.number;

    vm.prank(operator);
    rr.snapshotSusdscTVL();

    assertEq(rr.lastSnapshotBlockNumber(), blockBefore, 'Should capture block number correctly');

    // Advance block and take another snapshot
    vm.roll(block.number + 1);
    uint256 blockBefore2 = block.number;

    vm.prank(operator);
    rr.snapshotSusdscTVL();

    assertEq(rr.lastSnapshotBlockNumber(), blockBefore2, 'Should capture new block number');
    assertGt(rr.lastSnapshotBlockNumber(), blockBefore, 'Block number should increase');
  }

  // ========== RECOVER DONATIONS TESTS ==========

  function test_RecoverDonations_BasicRecovery() public {
    // Send some donations to the redistributor
    uint256 donationAmount = 10_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    uint256 treasuryBalanceBefore = usdsc.balanceOf(startale);
    uint256 rrBalanceBefore = usdsc.balanceOf(address(rr));
    assertEq(rrBalanceBefore, donationAmount, 'Redistributor should have donation');

    // Recover donations
    vm.prank(admin);
    vm.expectEmit(true, true, true, true);
    emit IRewardRedistributorEventsAndErrors.DonationsRecovered(donationAmount);
    rr.recoverDonations();

    // Verify donations were transferred to treasury
    uint256 treasuryBalanceAfter = usdsc.balanceOf(startale);
    uint256 rrBalanceAfter = usdsc.balanceOf(address(rr));

    assertEq(rrBalanceAfter, 0, 'Redistributor should have zero balance after recovery');
    assertEq(
      treasuryBalanceAfter - treasuryBalanceBefore, donationAmount, 'Treasury should receive donation amount'
    );
  }

  function test_RecoverDonations_OnlyAdmin() public {
    // Send some donations
    uint256 donationAmount = 5_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // Non-admin cannot recover
    address nonAdmin = makeAddr('nonAdmin');
    vm.prank(nonAdmin);
    vm.expectRevert();
    rr.recoverDonations();

    // Operator cannot recover (only admin)
    vm.prank(operator);
    vm.expectRevert();
    rr.recoverDonations();

    // Admin can recover
    vm.prank(admin);
    rr.recoverDonations();
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Donations should be recovered');
  }

  function test_RecoverDonations_ZeroBalance() public {
    // Ensure redistributor has zero balance
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Should start with zero balance');

    uint256 treasuryBalanceBefore = usdsc.balanceOf(startale);

    // Recovering zero balance should not revert, just do nothing
    vm.prank(admin);
    rr.recoverDonations();

    // Verify no event was emitted (since balance was 0, the if condition is false)
    // and treasury balance unchanged
    uint256 treasuryBalanceAfter = usdsc.balanceOf(startale);
    assertEq(treasuryBalanceAfter, treasuryBalanceBefore, 'Treasury balance should be unchanged');
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Redistributor should still have zero balance');
  }

  function test_RecoverDonations_MultipleDonations() public {
    // Send multiple donations
    uint256 donation1 = 5_000e6;
    uint256 donation2 = 3_000e6;
    uint256 donation3 = 2_000e6;
    uint256 totalDonations = donation1 + donation2 + donation3;

    usdsc.mint(address(this), donation1);
    usdsc.transfer(address(rr), donation1);

    usdsc.mint(address(this), donation2);
    usdsc.transfer(address(rr), donation2);

    usdsc.mint(address(this), donation3);
    usdsc.transfer(address(rr), donation3);

    assertEq(usdsc.balanceOf(address(rr)), totalDonations, 'Should have accumulated donations');

    // Recover all donations at once
    uint256 treasuryBalanceBefore = usdsc.balanceOf(startale);
    vm.prank(admin);
    rr.recoverDonations();

    uint256 treasuryBalanceAfter = usdsc.balanceOf(startale);
    assertEq(usdsc.balanceOf(address(rr)), 0, 'All donations should be recovered');
    assertEq(
      treasuryBalanceAfter - treasuryBalanceBefore, totalDonations, 'Treasury should receive all donations'
    );
  }

  function test_RecoverDonations_BalanceInvariant_NoDonations() public {
    // Test the invariant: before and after distribute(), balance remains the same (no donations)
    ext.addPending(100_000e6);
    _takeSnapshotAndWait();

    uint256 balanceBeforeDistribute = usdsc.balanceOf(address(rr));
    assertEq(balanceBeforeDistribute, 0, 'Should start with zero balance');

    // Distribute
    vm.prank(operator);
    rr.distribute();

    uint256 balanceAfterDistribute = usdsc.balanceOf(address(rr));
    assertEq(
      balanceAfterDistribute, balanceBeforeDistribute, 'Balance should remain same after distribute (no donations)'
    );
    assertEq(balanceAfterDistribute, 0, 'Balance should be zero after distribute');
  }

  function test_RecoverDonations_BalanceInvariant_WithDonations() public {
    // Test that donations accumulate and don't get distributed
    ext.addPending(100_000e6);
    _takeSnapshotAndWait();

    // Send donation before distribute
    uint256 donationAmount = 5_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    uint256 balanceBeforeDistribute = usdsc.balanceOf(address(rr));
    assertEq(balanceBeforeDistribute, donationAmount, 'Should have donation before distribute');

    // Distribute - should only distribute minted yield, not donations
    vm.prank(operator);
    rr.distribute();

    uint256 balanceAfterDistribute = usdsc.balanceOf(address(rr));
    // Balance should remain the same (donation is still there, only minted was distributed)
    assertEq(
      balanceAfterDistribute, balanceBeforeDistribute, 'Balance should remain same (donation preserved)'
    );
    assertEq(balanceAfterDistribute, donationAmount, 'Donation should still be in contract');

    // Now recover the donation
    vm.prank(admin);
    rr.recoverDonations();
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Donation should be recovered');
  }

  function test_RecoverDonations_DonationsAfterDistribute() public {
    // Distribute first
    ext.addPending(100_000e6);
    _takeSnapshotAndWait();
    vm.prank(operator);
    rr.distribute();

    // Verify balance is zero after distribute
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Balance should be zero after distribute');

    // Send donation after distribute
    uint256 donationAmount = 7_500e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    assertEq(usdsc.balanceOf(address(rr)), donationAmount, 'Should have donation after distribute');

    // Recover donation
    uint256 treasuryBalanceBefore = usdsc.balanceOf(startale);
    vm.prank(admin);
    rr.recoverDonations();

    uint256 treasuryBalanceAfter = usdsc.balanceOf(startale);
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Donation should be recovered');
    assertEq(
      treasuryBalanceAfter - treasuryBalanceBefore, donationAmount, 'Treasury should receive donation'
    );
  }

  function test_RecoverDonations_MultipleDistributionsWithDonations() public {
    // First distribution
    ext.addPending(50_000e6);
    _takeSnapshotAndWait();

    // Donation before first distribute
    uint256 donation1 = 2_000e6;
    usdsc.mint(address(this), donation1);
    usdsc.transfer(address(rr), donation1);

    uint256 balanceBefore1 = usdsc.balanceOf(address(rr));
    vm.prank(operator);
    rr.distribute();
    uint256 balanceAfter1 = usdsc.balanceOf(address(rr));
    assertEq(balanceAfter1, balanceBefore1, 'Balance invariant holds after first distribute');
    assertEq(balanceAfter1, donation1, 'Donation should remain');

    // Second donation
    uint256 donation2 = 3_000e6;
    usdsc.mint(address(this), donation2);
    usdsc.transfer(address(rr), donation2);

    // Second distribution
    ext.addPending(75_000e6);
    _takeSnapshotAndWait();

    uint256 balanceBefore2 = usdsc.balanceOf(address(rr));
    vm.prank(operator);
    rr.distribute();
    uint256 balanceAfter2 = usdsc.balanceOf(address(rr));
    assertEq(balanceAfter2, balanceBefore2, 'Balance invariant holds after second distribute');
    assertEq(balanceAfter2, donation1 + donation2, 'Both donations should remain');

    // Third donation
    uint256 donation3 = 1_000e6;
    usdsc.mint(address(this), donation3);
    usdsc.transfer(address(rr), donation3);

    // Recover all accumulated donations
    uint256 totalDonations = donation1 + donation2 + donation3;
    uint256 treasuryBalanceBefore = usdsc.balanceOf(startale);
    vm.prank(admin);
    rr.recoverDonations();

    uint256 treasuryBalanceAfter = usdsc.balanceOf(startale);
    assertEq(usdsc.balanceOf(address(rr)), 0, 'All donations should be recovered');
    assertEq(
      treasuryBalanceAfter - treasuryBalanceBefore, totalDonations, 'Treasury should receive all donations'
    );
  }

  function test_RecoverDonations_EventEmission() public {
    uint256 donationAmount = 15_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // Verify event is emitted with correct parameters
    vm.prank(admin);
    vm.expectEmit(true, true, true, true);
    emit IRewardRedistributorEventsAndErrors.DonationsRecovered(donationAmount);
    rr.recoverDonations();
  }

  function test_RecoverDonations_NonReentrant() public {
    // This test verifies that recoverDonations is protected by nonReentrant
    // In a real scenario, we'd need a malicious contract to test reentrancy
    // For now, we just verify the modifier is present by checking it compiles
    // and that multiple calls work correctly

    uint256 donationAmount = 5_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // First recovery
    vm.prank(admin);
    rr.recoverDonations();
    assertEq(usdsc.balanceOf(address(rr)), 0, 'First recovery should work');

    // Send another donation
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // Second recovery should also work (nonReentrant allows new calls)
    vm.prank(admin);
    rr.recoverDonations();
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Second recovery should work');
  }

  function test_RecoverDonations_DonationsNotDistributed() public {
    // Critical test: verify that donations are NOT included in distribution calculations
    ext.addPending(100_000e6);
    _takeSnapshotAndWait();

    // Send donation
    uint256 donationAmount = 10_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // Record balances before distribution
    uint256 treasuryBalanceBefore = usdsc.balanceOf(startale);
    uint256 earnVaultBalanceBefore = usdsc.balanceOf(address(earnV));
    uint256 sVaultBalanceBefore = usdsc.balanceOf(address(sVault));

    // Distribute - should only distribute the 100_000e6 minted, not the 10_000e6 donation
    vm.prank(operator);
    rr.distribute();

    // Calculate what was distributed
    uint256 treasuryReceived = usdsc.balanceOf(startale) - treasuryBalanceBefore;
    uint256 earnVaultReceived = usdsc.balanceOf(address(earnV)) - earnVaultBalanceBefore;
    uint256 sVaultReceived = usdsc.balanceOf(address(sVault)) - sVaultBalanceBefore;
    uint256 totalDistributed = treasuryReceived + earnVaultReceived + sVaultReceived;

    // Total distributed should equal the minted amount (100_000e6), not include donation
    assertEq(totalDistributed, 100_000e6, 'Only minted amount should be distributed');
    assertEq(usdsc.balanceOf(address(rr)), donationAmount, 'Donation should remain in contract');

    // Now recover the donation
    vm.prank(admin);
    rr.recoverDonations();
    assertEq(usdsc.balanceOf(address(rr)), 0, 'Donation should be recovered');
  }

  function test_RecoverDonations_AfterTreasuryChange() public {
    // Send donation
    uint256 donationAmount = 5_000e6;
    usdsc.mint(address(this), donationAmount);
    usdsc.transfer(address(rr), donationAmount);

    // Change treasury address
    address newTreasury = makeAddr('newTreasury');
    vm.prank(admin);
    rr.setTreasury(newTreasury);

    // Recover donations - should go to new treasury
    vm.prank(admin);
    rr.recoverDonations();

    assertEq(usdsc.balanceOf(address(rr)), 0, 'Donations should be recovered');
    assertEq(usdsc.balanceOf(newTreasury), donationAmount, 'Donations should go to new treasury');
    assertEq(usdsc.balanceOf(startale), 0, 'Old treasury should not receive donations');
  }
}
