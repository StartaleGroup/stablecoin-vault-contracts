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
}
