// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IIdentityRegistry
/// @notice Minimal external interface for reading an identity's currently registered address.
interface IIdentityRegistry {
  function registeredAddress(bytes32 identityId) external view returns (address);
}
