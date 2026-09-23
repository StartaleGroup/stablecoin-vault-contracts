// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IIdentityRegistry
/// @notice Minimal external interface for reading an identity's currently registered address.
/// @dev Currently UNUSED: nothing imports it since EarnVaultV2 credits addresses directly. Kept with
///      IdentityRegistry for a possible future identity-based credit path (EarnVaultV2 NatSpec,
///      scenario B).
interface IIdentityRegistry {
  function registeredAddress(bytes32 identityId) external view returns (address);
}
