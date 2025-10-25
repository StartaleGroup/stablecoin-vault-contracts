// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

/// @title EarnVaultUpgradeable Edge Cases Tests
/// @notice Tests for zero address validations and access control
contract EarnVaultUpgradeableEdgeCasesTest is Test {
  EarnVaultUpgradeable vault;
  MockUSDSC usdsc;

  address owner = address(0xA11CE);
  address redistributor = address(0xAED157);
  address treasury = address(0x71EA);
  address pauser = address(0x9A);
  address user = address(0x5E4);

  function setUp() public {
    usdsc = new MockUSDSC();

    // Deploy implementation
    EarnVaultUpgradeable implementation = new EarnVaultUpgradeable();

    // Deploy proxy and initialize
    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser
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
      pauser
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
      pauser
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
      pauser
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
      pauser
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
      address(0) // zero pauser
    );

    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    new ERC1967Proxy(address(impl), initData);
  }

  // ========== Setter Zero Address Tests (3 tests) ==========

  function test_Revert_SetYieldRedistributorZeroAddress() public {
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.setYieldRedistributor(address(0));
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
    vm.prank(user); // not redistributor
    vm.expectRevert(IEarnVaultEventsAndErrors.NotYieldRedistributor.selector);
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
    usdsc.mint(user, 10000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10000e6);
    vault.deposit(10000e6);
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
    usdsc.mint(user, 10000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10000e6);
    vault.deposit(10000e6);
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
    uint256 amount = 10000e6;
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
    usdsc.mint(user, 10000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10000e6);
    vault.deposit(10000e6);
    vm.stopPrank();

    // Distribute boost rewards to create boostClaimReserve
    uint256 boostAmount = 5000e6;
    boostToken.mint(address(vault), boostAmount);
    vm.prank(redistributor);
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
    usdsc.mint(user, 10000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10000e6);
    vault.deposit(10000e6);
    vm.stopPrank();

    // Distribute boost rewards to create boostClaimReserve
    uint256 boostAmount = 5000e6;
    boostToken.mint(address(vault), boostAmount);
    vm.prank(redistributor);
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

  // ========== getAllClaimables Tests ==========

  function test_GetAllClaimables_WithUSDSCOnly() public {
    // Setup: user deposits
    usdsc.mint(user, 10000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10000e6);
    vault.deposit(10000e6);
    vm.stopPrank();

    // Add USDSC yield
    uint256 yieldAmount = 1000e6;
    usdsc.mint(address(vault), yieldAmount);
    vm.prank(redistributor);
    vault.onYield(yieldAmount);

    // Get all claimables
    (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts) =
      vault.getAllClaimables(user);

    // Should have USDSC claimable but no boost rewards
    assertEq(usdscClaimable, yieldAmount);
    assertEq(boostTokens.length, 0);
    assertEq(boostAmounts.length, 0);
  }

  function test_GetAllClaimables_WithBoostRewards() public {
    // Setup: user deposits
    usdsc.mint(user, 10000e6);
    vm.startPrank(user);
    usdsc.approve(address(vault), 10000e6);
    vault.deposit(10000e6);
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
    vm.prank(redistributor);
    vault.onBoostReward(address(astrToken), astrAmount);

    dotToken.mint(address(vault), dotAmount);
    vm.prank(redistributor);
    vault.onBoostReward(address(dotToken), dotAmount);

    // Get all claimables
    (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts) =
      vault.getAllClaimables(user);

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
    (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts) =
      vault.getAllClaimables(user);

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
