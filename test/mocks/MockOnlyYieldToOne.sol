// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Mock contract that only implements IMYieldToOne interface (missing IERC20)
/// @dev Used for testing RewardRedistributor constructor validation
contract MockOnlyYieldToOne {
  function yield() external pure returns (uint256) {
    return 0;
  }

  function claimYield() external pure returns (uint256) {
    return 0;
  }

  function YIELD_RECIPIENT_MANAGER_ROLE() external pure returns (bytes32) {
    return keccak256('YIELD_RECIPIENT_MANAGER_ROLE');
  }

  // Intentionally missing IERC20 methods (totalSupply, balanceOf, etc.)
}
