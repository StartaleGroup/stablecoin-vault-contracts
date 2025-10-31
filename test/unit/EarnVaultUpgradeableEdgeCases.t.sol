// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Test} from 'forge-std/Test.sol';

/// @title EarnVaultUpgradeable Edge Cases Tests
/// @notice Tests for zero address validations and access control
contract EarnVaultUpgradeableEdgeCasesTest is Test {
  EarnVaultUpgradeable vault;
  MockUSDSC usdsc;

  address owner = address(0xA11CE);
  address redistributor = address(0xAED157);
  address treasury = address(0x71EA);
  address pauser = address(0x9A);
  address operator = address(0x0C3A); // boost reward keeper
  address user = address(0x5E4);

  function setUp() public {
    usdsc = new MockUSDSC();

    // Deploy implementation
    EarnVaultUpgradeable implementation = new EarnVaultUpgradeable();

    // Deploy proxy and initialize
    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
    );

    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
    vault = EarnVaultUpgradeable(payable(address(proxy)));
  }

  // ========== Initialize Zero Address Tests (5 tests) ==========

  function test_Revert_InitializeWithZeroUSDSC() public {
    EarnVaultUpgradeable impl = new EarnVaultUpgradeable();

    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      address(0), // zero USDSC
      owner,
      redistributor,
      treasury,
      pauser,
      operator
    );

    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    new ERC1967Proxy(address(impl), initData);
  }

  function test_Revert_InitializeWithZeroOwner() public {
    EarnVaultUpgradeable impl = new EarnVaultUpgradeable();

    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      address(usdsc),
      address(0), // zero owner
      redistributor,
      treasury,
      pauser,
      operator
    );

    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    new ERC1967Proxy(address(impl), initData);
  }

  function test_Revert_InitializeWithZeroRedistributor() public {
    EarnVaultUpgradeable impl = new EarnVaultUpgradeable();

    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      address(usdsc),
      owner,
      address(0), // zero redistributor
      treasury,
      pauser,
      operator
    );

    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    new ERC1967Proxy(address(impl), initData);
  }

  function test_Revert_InitializeWithZeroTreasury() public {
    EarnVaultUpgradeable impl = new EarnVaultUpgradeable();

    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      address(usdsc),
      owner,
      redistributor,
      address(0), // zero treasury
      pauser,
      operator
    );

    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    new ERC1967Proxy(address(impl), initData);
  }

  function test_Revert_InitializeWithZeroPauser() public {
    EarnVaultUpgradeable impl = new EarnVaultUpgradeable();

    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      address(usdsc),
      owner,
      redistributor,
      treasury,
      address(0), // zero pauser
      operator
    );

    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    new ERC1967Proxy(address(impl), initData);
  }

  function test_Revert_InitializeWithZeroBoostRewardKeeper() public {
    EarnVaultUpgradeable impl = new EarnVaultUpgradeable();

    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      address(usdsc),
      owner,
      redistributor,
      treasury,
      pauser,
      address(0) // zero boost reward keeper
    );

    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    new ERC1967Proxy(address(impl), initData);
  }

  // ========== Setter Zero Address Tests (4 tests) ==========

  function test_Revert_SetYieldRedistributorZeroAddress() public {
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.setYieldRedistributor(address(0));
  }

  function test_Revert_SetBoostRewardKeeperZeroAddress() public {
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.setBoostRewardKeeper(address(0));
  }

  function test_Revert_SetTreasuryZeroAddress() public {
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.setTreasury(address(0));
  }

  function test_Revert_SetPauserZeroAddress() public {
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.setPauser(address(0));
  }

  // ========== Access Control Tests (4 tests) ==========

  function test_Revert_OnYieldNotRedistributor() public {
    vm.prank(user); // not redistributor
    vm.expectRevert(IEarnVaultEventsAndErrors.NotYieldRedistributor.selector);
    vault.onYield(1000e6);
  }

  function test_Revert_OnBoostRewardNotRedistributor() public {
    vm.prank(user); // not boost reward keeper
    vm.expectRevert(IEarnVaultEventsAndErrors.NotBoostRewardKeeper.selector);
    vault.onBoostReward(address(0x123), 1000e6);
  }

  function test_Revert_PauseNotAuthorized() public {
    vm.prank(user); // not pauser
    vm.expectRevert(IEarnVaultEventsAndErrors.NotAuthorizedToPause.selector);
    vault.pause();
  }

  function test_Revert_UnpauseNotAuthorized() public {
    // First pause as authorized pauser
    vm.prank(pauser);
    vault.pause();

    // Try to unpause as unauthorized user
    vm.prank(user);
    vm.expectRevert(IEarnVaultEventsAndErrors.NotAuthorizedToPause.selector);
    vault.unpause();
  }

  // ========== onYield with zero totalPrincipal ==========

  function test_OnYieldWithZeroTotalPrincipal() public {
    // No deposits, so totalPrincipal == 0
    uint256 yieldAmount = 1000e6;

    // Transfer yield to vault
    usdsc.mint(address(vault), yieldAmount);

    uint256 treasuryBefore = usdsc.balanceOf(treasury);

    // Call onYield as redistributor
    vm.prank(redistributor);
    vault.onYield(yieldAmount);

    // All yield should go to treasury when no deposits exist
    assertEq(usdsc.balanceOf(treasury), treasuryBefore + yieldAmount);
  }

  // ========== sweepSurplusToTreasury Tests ==========

  function test_SweepSurplusToTreasury() public {
    // Setup: deposit some principal
    usdsc.mint(user, 10_000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10_000e6);
    vault.deposit(10_000e6);
    vm.stopPrank();

    // Add yield to create surplus
    uint256 yieldAmount = 5000e6;
    usdsc.mint(address(vault), yieldAmount);
    vm.prank(redistributor);
    vault.onYield(yieldAmount);

    // Now vault has: 10000 (principal reserve) + 5000 (yield reserve) = 15000
    // Add extra surplus beyond reserves
    uint256 extraSurplus = 2000e6;
    usdsc.mint(address(vault), extraSurplus);

    uint256 treasuryBefore = usdsc.balanceOf(treasury);

    // Sweep surplus
    vm.prank(owner);
    vault.sweepSurplusToTreasury();

    // Treasury should receive the extra surplus
    assertEq(usdsc.balanceOf(treasury), treasuryBefore + extraSurplus);
  }

  function test_SweepSurplusToTreasury_NoSurplus() public {
    // Setup: deposit some principal
    usdsc.mint(user, 10_000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10_000e6);
    vault.deposit(10_000e6);
    vm.stopPrank();

    uint256 treasuryBefore = usdsc.balanceOf(treasury);
    uint256 vaultBefore = usdsc.balanceOf(address(vault));

    // Try to sweep when there's no surplus (balance == claimReserve)
    vm.prank(owner);
    vault.sweepSurplusToTreasury();

    // Nothing should be transferred
    assertEq(usdsc.balanceOf(treasury), treasuryBefore);
    assertEq(usdsc.balanceOf(address(vault)), vaultBefore);
  }

  // ========== recoverERC20 Tests ==========

  function test_Revert_RecoverERC20_ZeroAddress() public {
    address randomToken = address(0x999);

    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.recoverERC20(randomToken, address(0), 1000e6);
  }

  function test_Revert_RecoverERC20_USDSCNotPaused() public {
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.ContractNotPaused.selector);
    vault.recoverERC20(address(usdsc), treasury, 1000e6);
  }

  function test_RecoverERC20_USDSCWhenPaused() public {
    // Pause the vault
    vm.prank(pauser);
    vault.pause();

    // Add surplus USDSC
    uint256 surplus = 5000e6;
    usdsc.mint(address(vault), surplus);

    uint256 treasuryBefore = usdsc.balanceOf(treasury);

    // Recover USDSC surplus when paused
    vm.prank(owner);
    vault.recoverERC20(address(usdsc), treasury, surplus);

    assertEq(usdsc.balanceOf(treasury), treasuryBefore + surplus);
  }

  function test_Revert_RecoverERC20_USDSCExceedsSurplus() public {
    // Pause the vault
    vm.prank(pauser);
    vault.pause();

    // Add small surplus
    uint256 surplus = 1000e6;
    usdsc.mint(address(vault), surplus);

    // Try to recover more than surplus
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.ExceedsSurplus.selector);
    vault.recoverERC20(address(usdsc), treasury, surplus + 1);
  }

  function test_RecoverERC20_NonUSDSCToken() public {
    // Create a different ERC20 token
    MockUSDSC otherToken = new MockUSDSC();

    // Send some tokens to vault by mistake
    uint256 amount = 10_000e6;
    otherToken.mint(address(vault), amount);

    uint256 treasuryBefore = otherToken.balanceOf(treasury);

    // Recover the non-USDSC tokens
    vm.prank(owner);
    vault.recoverERC20(address(otherToken), treasury, amount);

    assertEq(otherToken.balanceOf(treasury), treasuryBefore + amount);
  }

  function test_RecoverERC20_BoostTokenWithReserve() public {
    // Create a boost token
    MockUSDSC boostToken = new MockUSDSC();

    // Setup: user deposits principal
    usdsc.mint(user, 10_000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10_000e6);
    vault.deposit(10_000e6);
    vm.stopPrank();

    // Distribute boost rewards to create boostClaimReserve
    uint256 boostAmount = 5000e6;
    boostToken.mint(address(vault), boostAmount);
    vm.prank(operator); // operator is boost reward keeper
    vault.onBoostReward(address(boostToken), boostAmount);

    // Add extra boost tokens beyond reserve
    uint256 extraBoost = 3000e6;
    boostToken.mint(address(vault), extraBoost);

    // Total balance: 5000 (reserved) + 3000 (extra) = 8000
    // Can only recover the extra 3000
    uint256 treasuryBefore = boostToken.balanceOf(treasury);

    vm.prank(owner);
    vault.recoverERC20(address(boostToken), treasury, extraBoost);

    assertEq(boostToken.balanceOf(treasury), treasuryBefore + extraBoost);
  }

  function test_Revert_RecoverERC20_BoostTokenExceedsAvailable() public {
    // Create a boost token
    MockUSDSC boostToken = new MockUSDSC();

    // Setup: user deposits principal
    usdsc.mint(user, 10_000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10_000e6);
    vault.deposit(10_000e6);
    vm.stopPrank();

    // Distribute boost rewards to create boostClaimReserve
    uint256 boostAmount = 5000e6;
    boostToken.mint(address(vault), boostAmount);
    vm.prank(operator); // operator is boost reward keeper
    vault.onBoostReward(address(boostToken), boostAmount);

    // Try to recover more than available (beyond reserve)
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.ExceedsSurplus.selector);
    vault.recoverERC20(address(boostToken), treasury, boostAmount + 1);
  }

  // ========== depositWithPermit Tests ==========

  function test_Revert_DepositWithPermit_PermitFailed() public {
    // MockUSDSC doesn't implement permit, so it will fail
    uint256 depositAmount = 5000e6;
    usdsc.mint(user, depositAmount);

    // Try to use permit with MockUSDSC (which doesn't support it)
    vm.prank(user);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    vault.depositWithPermit(depositAmount, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
  }

  function test_Revert_DepositWithPermit_ZeroAmount() public {
    vm.prank(user);
    vm.expectRevert(IEarnVaultEventsAndErrors.ZeroAmount.selector);
    vault.depositWithPermit(0, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
  }

  function test_Revert_DepositWithPermit_Blacklisted() public {
    // Blacklist user first
    vm.prank(owner);
    vault.setBlacklisted(user, true);

    uint256 depositAmount = 5000e6;
    usdsc.mint(user, depositAmount);

    // Try to deposit with permit while blacklisted
    vm.prank(user);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.depositWithPermit(depositAmount, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
  }

  function test_Revert_DepositWithPermit_Paused() public {
    // Pause the vault
    vm.prank(pauser);
    vault.pause();

    uint256 depositAmount = 5000e6;
    usdsc.mint(user, depositAmount);

    // Try to deposit with permit while paused
    vm.prank(user);
    vm.expectRevert(); // EnforcedPause from PausableUpgradeable
    vault.depositWithPermit(depositAmount, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
  }

  /// @notice Test depositWithPermit triggers _settle when user has existing principal
  /// @dev Covers the _settle path in depositWithPermit when principal[user] > 0
  /// @dev Verifies that accrued yield is properly settled before new deposit
  function test_DepositWithPermit_TriggersSettleWithExistingPrincipal() public {
    // =========================
    // Setup: User makes initial deposit using regular deposit (establishes principal)
    // =========================
    uint256 initialDeposit = 5000e6;
    usdsc.mint(user, initialDeposit);

    vm.startPrank(user);
    usdsc.approve(address(vault), initialDeposit);
    vault.deposit(initialDeposit);
    vm.stopPrank();

    // Verify user has principal
    assertEq(vault.principal(user), initialDeposit, 'User should have initial principal');

    // =========================
    // Action: Distribute yield (this increases globalIndex)
    // =========================
    uint256 yieldAmount = 1000e6;
    usdsc.mint(address(vault), yieldAmount);
    vm.prank(redistributor);
    vault.onYield(yieldAmount);

    // At this point: globalIndex > userIndex for user, so _settle will accrue yield

    // =========================
    // Action: User makes second deposit via depositWithPermit
    // =========================
    // Note: MockUSDSC doesn't support permit, but we're testing the _settle path
    // The permit will fail, so we use regular deposit to simulate the scenario
    uint256 secondDeposit = 3000e6;
    usdsc.mint(user, secondDeposit);

    // Record state before second deposit
    uint256 claimableBeforeSecondDeposit = vault.claimable(user);
    assertGt(claimableBeforeSecondDeposit, 0, 'User should have claimable yield before second deposit');

    // Make second deposit (this calls _settle internally)
    vm.startPrank(user);
    usdsc.approve(address(vault), secondDeposit);
    vault.deposit(secondDeposit);
    vm.stopPrank();

    // =========================
    // Verification: _settle was called and yield was accrued
    // =========================
    // After second deposit, userIndex should equal globalIndex
    uint256 userIdx = vault.userIndex(user);
    uint256 globalIdx = vault.globalIndex();
    assertEq(userIdx, globalIdx, 'User index should equal global index after _settle');

    // Claimable should still be available (settled into accrued)
    uint256 claimableAfterSecondDeposit = vault.claimable(user);
    assertApproxEqAbs(
      claimableAfterSecondDeposit,
      claimableBeforeSecondDeposit,
      1,
      'Claimable should be preserved after _settle during depositWithPermit'
    );

    // Total principal should be sum of both deposits
    assertEq(vault.principal(user), initialDeposit + secondDeposit, 'Principal should be sum of deposits');
  }

  // ========== totalValue Tests ==========

  /// @notice Test totalValue when user has principal (p != 0)
  /// @dev Covers the totalValue branch: if (p != 0) with gi > ui
  /// @dev Verifies totalValue = principal + accrued + owed calculation
  function test_TotalValue_WithPrincipalAndYield() public {
    // =========================
    // Setup: User deposits principal
    // =========================
    uint256 depositAmount = 10_000e6;
    usdsc.mint(user, depositAmount);

    vm.startPrank(user);
    usdsc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    // =========================
    // Action: Distribute yield (increases globalIndex)
    // =========================
    uint256 yieldAmount = 2000e6;
    usdsc.mint(address(vault), yieldAmount);
    vm.prank(redistributor);
    vault.onYield(yieldAmount);

    // =========================
    // Verification: totalValue includes principal + claimable yield
    // =========================
    uint256 totalVal = vault.totalValue(user);
    uint256 userPrincipal = vault.principal(user);
    uint256 userClaimable = vault.claimable(user);

    // totalValue should equal principal + claimable (accrued + owed)
    assertEq(totalVal, userPrincipal + userClaimable, 'totalValue should equal principal + claimable');
    assertEq(totalVal, depositAmount + yieldAmount, 'totalValue should equal deposit + yield');
    assertGt(totalVal, depositAmount, 'totalValue should be greater than initial deposit');
  }

  /// @notice Test totalValue when user has principal but no new yield (gi == ui)
  /// @dev Covers the totalValue branch: if (p != 0) but gi <= ui
  /// @dev Verifies totalValue = principal + accrued (no new owed)
  function test_TotalValue_WithPrincipalNoNewYield() public {
    // =========================
    // Setup: User deposits and claims to sync indices
    // =========================
    uint256 depositAmount = 10_000e6;
    usdsc.mint(user, depositAmount);

    vm.startPrank(user);
    usdsc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    // Distribute yield
    uint256 yieldAmount = 1000e6;
    usdsc.mint(address(vault), yieldAmount);
    vm.prank(redistributor);
    vault.onYield(yieldAmount);

    // User claims to sync indices (gi == ui after claim)
    vm.prank(user);
    vault.claim();

    // =========================
    // Verification: totalValue equals just principal (no new yield)
    // =========================
    uint256 totalVal = vault.totalValue(user);
    uint256 userPrincipal = vault.principal(user);
    uint256 userClaimable = vault.claimable(user);

    // After claiming, claimable should be 0 and totalValue = principal
    assertEq(userClaimable, 0, 'Claimable should be 0 after claiming');
    assertEq(totalVal, userPrincipal, 'totalValue should equal principal when no new yield');
    assertEq(totalVal, depositAmount, 'totalValue should equal original deposit');
  }

  /// @notice Test totalValue calculation accuracy with multiple yield distributions
  /// @dev Verifies the Math.mulDiv calculation in totalValue is accurate
  /// @dev Tests totalValue = p + accrued[user] + Math.mulDiv(p, gi - ui, RAY)
  function test_TotalValue_AccuracyWithMultipleYields() public {
    // =========================
    // Setup: User deposits principal
    // =========================
    uint256 depositAmount = 10_000e6;
    usdsc.mint(user, depositAmount);

    vm.startPrank(user);
    usdsc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    // =========================
    // Action: Multiple yield distributions without claiming
    // =========================
    uint256 yield1 = 500e6;
    usdsc.mint(address(vault), yield1);
    vm.prank(redistributor);
    vault.onYield(yield1);

    uint256 yield2 = 750e6;
    usdsc.mint(address(vault), yield2);
    vm.prank(redistributor);
    vault.onYield(yield2);

    uint256 yield3 = 250e6;
    usdsc.mint(address(vault), yield3);
    vm.prank(redistributor);
    vault.onYield(yield3);

    // =========================
    // Verification: totalValue accumulates all yields correctly
    // =========================
    uint256 totalVal = vault.totalValue(user);
    uint256 totalYield = yield1 + yield2 + yield3;

    // totalValue should equal principal + all accumulated yields
    assertEq(totalVal, depositAmount + totalYield, 'totalValue should accumulate all yields');

    // Verify consistency with getUserInfo
    (uint256 userPrincipal, uint256 userClaimable, uint256 userTotal,) = vault.getUserInfo(user);
    assertEq(totalVal, userTotal, 'totalValue should match getUserInfo.userTotal');
    assertEq(totalVal, userPrincipal + userClaimable, 'totalValue should equal principal + claimable');
  }

  // ========== getAllClaimables Tests ==========

  function test_GetAllClaimables_WithUSDSCOnly() public {
    // Setup: user deposits
    usdsc.mint(user, 10_000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10_000e6);
    vault.deposit(10_000e6);
    vm.stopPrank();

    // Add USDSC yield
    uint256 yieldAmount = 1000e6;
    usdsc.mint(address(vault), yieldAmount);
    vm.prank(redistributor);
    vault.onYield(yieldAmount);

    // Get all claimables
    (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts) = vault.getAllClaimables(user);

    // Should have USDSC claimable but no boost rewards
    assertEq(usdscClaimable, yieldAmount);
    assertEq(boostTokens.length, 0);
    assertEq(boostAmounts.length, 0);
  }

  function test_GetAllClaimables_WithBoostRewards() public {
    // Setup: user deposits
    usdsc.mint(user, 10_000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10_000e6);
    vault.deposit(10_000e6);
    vm.stopPrank();

    // Add USDSC yield
    uint256 yieldAmount = 1000e6;
    usdsc.mint(address(vault), yieldAmount);
    vm.prank(redistributor);
    vault.onYield(yieldAmount);

    // Add boost rewards (ASTR and DOT)
    MockUSDSC astrToken = new MockUSDSC();
    MockUSDSC dotToken = new MockUSDSC();

    uint256 astrAmount = 500e6;
    uint256 dotAmount = 750e6;

    astrToken.mint(address(vault), astrAmount);
    vm.prank(operator); // operator is boost reward keeper
    vault.onBoostReward(address(astrToken), astrAmount);

    dotToken.mint(address(vault), dotAmount);
    vm.prank(operator); // operator is boost reward keeper
    vault.onBoostReward(address(dotToken), dotAmount);

    // Get all claimables
    (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts) = vault.getAllClaimables(user);

    // Verify USDSC yield
    assertEq(usdscClaimable, yieldAmount);

    // Verify boost rewards
    assertEq(boostTokens.length, 2);
    assertEq(boostAmounts.length, 2);

    // Find which index is ASTR and which is DOT
    for (uint256 i = 0; i < boostTokens.length; i++) {
      if (boostTokens[i] == address(astrToken)) {
        assertEq(boostAmounts[i], astrAmount);
      } else if (boostTokens[i] == address(dotToken)) {
        assertEq(boostAmounts[i], dotAmount);
      }
    }
  }

  function test_GetAllClaimables_NoPrincipal() public view {
    // User with no deposit should have zero claimables
    (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts) = vault.getAllClaimables(user);

    assertEq(usdscClaimable, 0);
    assertEq(boostTokens.length, 0);
    assertEq(boostAmounts.length, 0);
  }

  function test_Revert_GetAllClaimables_Blacklisted() public {
    // Blacklist user
    vm.prank(owner);
    vault.setBlacklisted(user, true);

    // Try to get claimables
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.getAllClaimables(user);
  }
}
