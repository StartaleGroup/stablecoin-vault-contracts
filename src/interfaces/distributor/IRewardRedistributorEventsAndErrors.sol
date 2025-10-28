// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IRewardRedistributorEventsAndErrors
/// @notice Events and errors interface for RewardRedistributor contract
interface IRewardRedistributorEventsAndErrors {
  // ========================================
  // Errors
  // ========================================

  /// @notice Thrown when a zero address is provided where non-zero is required
  /// @param parameterName Name of the parameter that is zero
  error ZeroAddress(string parameterName);

  /// @notice Thrown when fee is too high
  /// @param feeBps Requested fee in basis points
  /// @param maxFeeBps Maximum allowed fee in basis points
  error FeeTooHigh(uint16 feeBps, uint16 maxFeeBps);

  /// @notice Thrown when attempting to distribute with zero yield
  error ZeroYield();
}

