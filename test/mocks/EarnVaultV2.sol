// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';

/// @title EarnVaultV2 - Version 2 with additional features
/// @notice Adds a new feature: emergency yield multiplier for testing upgrade functionality
contract EarnVaultV2 is EarnVaultUpgradeable {
  using SafeERC20 for IERC20;

  /// @custom:storage-location erc7201:startale.storage.EarnVaultV2
  struct EarnVaultV2Storage {
    uint256 emergencyYieldMultiplier; // New feature: emergency yield multiplier (in basis points)
    bool emergencyMode; // New feature: emergency mode flag
  }

  // keccak256(abi.encode(uint256(keccak256("startale.storage.EarnVaultV2")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant EARN_VAULT_V2_STORAGE_LOCATION =
    0x234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1;

  function _getEarnVaultV2Storage() internal pure returns (EarnVaultV2Storage storage $) {
    assembly {
      $.slot := EARN_VAULT_V2_STORAGE_LOCATION
    }
  }

  // New events for V2 features
  event EmergencyModeToggled(bool enabled);
  event EmergencyYieldMultiplierSet(uint256 multiplier);

  // New errors for V2 features
  error InvalidMultiplier();
  error EmergencyModeNotActive();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initialize V2 (reinitializer for upgrades)
  function initializeV2() public reinitializer(2) {
    EarnVaultV2Storage storage $ = _getEarnVaultV2Storage();
    $.emergencyYieldMultiplier = 10_000; // Default to 100% (no change)
    $.emergencyMode = false;
  }

  /// @notice Set emergency yield multiplier (only owner)
  /// @param multiplier Multiplier in basis points (10000 = 100%)
  function setEmergencyYieldMultiplier(uint256 multiplier) external onlyOwner {
    if (multiplier == 0 || multiplier > 20_000) revert InvalidMultiplier(); // Max 200%
    EarnVaultV2Storage storage $ = _getEarnVaultV2Storage();
    $.emergencyYieldMultiplier = multiplier;
    emit EmergencyYieldMultiplierSet(multiplier);
  }

  /// @notice Toggle emergency mode (only owner)
  /// @param enabled Whether to enable emergency mode
  function setEmergencyMode(bool enabled) external onlyOwner {
    EarnVaultV2Storage storage $ = _getEarnVaultV2Storage();
    $.emergencyMode = enabled;
    emit EmergencyModeToggled(enabled);
  }

  /// @notice Get emergency yield multiplier
  function getEmergencyYieldMultiplier() external view returns (uint256) {
    EarnVaultV2Storage storage $ = _getEarnVaultV2Storage();
    return $.emergencyYieldMultiplier;
  }

  /// @notice Check if emergency mode is active
  function isEmergencyModeActive() external view returns (bool) {
    EarnVaultV2Storage storage $ = _getEarnVaultV2Storage();
    return $.emergencyMode;
  }

  /// @notice Override onYield to apply emergency multiplier when in emergency mode
  function onYield(uint256 amount) external override onlyYieldRedistributor nonReentrant {
    EarnVaultV2Storage storage $ = _getEarnVaultV2Storage();

    if ($.emergencyMode) {
      // Apply emergency multiplier to yield amount
      uint256 adjustedAmount = (amount * $.emergencyYieldMultiplier) / 10_000;
      _onYieldInternal(adjustedAmount);
    } else {
      _onYieldInternal(amount);
    }
  }

  /// @notice Internal function to call parent onYield
  function _onYieldInternal(uint256 amount) internal {
    EarnVaultStorage storage $ = _getStorage();
    if (amount == 0) return;

    // Verify actual balance before updating accounting
    uint256 bal = $.USDSC.balanceOf(address(this));

    if ($.totalPrincipal == 0) {
      // No deposits: just need enough for treasury transfer
      if (bal < amount) revert IEarnVaultEventsAndErrors.InsufficientFunding();
      $.USDSC.safeTransfer($.treasury, amount);
      emit IEarnVaultEventsAndErrors.YieldTransferredToTreasury(amount);
      return;
    }

    // Deposits exist: need enough for claimReserve + new yield
    if (bal < $.claimReserve + amount) revert IEarnVaultEventsAndErrors.InsufficientFunding();

    // Exact, immediate index update with Ray remainder carry
    // delta = floor( (amount*RAY + _carryRay) / totalPrincipal )
    // _carryRay = (amount*RAY + _carryRay) % totalPrincipal
    unchecked {
      uint256 num = amount * $.RAY + $._carryRay;
      uint256 delta = num / $.totalPrincipal;
      $._carryRay = num % $.totalPrincipal;
      $.globalIndex += delta;
    }

    $.claimReserve += amount;
    emit IEarnVaultEventsAndErrors.YieldIndexed(amount, $.globalIndex, $.claimReserve);
  }

  /// @notice Get V2 version info
  function getVersion() external pure virtual override returns (string memory) {
    return 'EarnVaultV2';
  }
}

