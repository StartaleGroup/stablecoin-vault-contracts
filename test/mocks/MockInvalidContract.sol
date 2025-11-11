// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Mock contract that implements neither IERC20 nor IMYieldToOne
/// @dev Used for testing RewardRedistributor constructor validation
contract MockInvalidContract {
  function someRandomFunction() external pure returns (uint256) {
    return 42;
  }

  // Intentionally missing both IERC20 and IMYieldToOne methods
}
