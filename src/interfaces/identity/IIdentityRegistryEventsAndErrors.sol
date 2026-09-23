// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IIdentityRegistryEventsAndErrors
/// @notice Events and errors interface for IdentityRegistry
/// @dev Separates events and errors for cleaner code organization and reusability
interface IIdentityRegistryEventsAndErrors {
  // ========================================
  // Events
  // ========================================

  /// @notice Emitted when an identity is registered to an address for the first time
  /// @param identityId Opaque identifier for the loyalty identity
  /// @param addr Address registered to this identity
  event IdentityRegistered(bytes32 indexed identityId, address indexed addr);

  /// @notice Emitted when an identity's registered address is switched
  /// @param identityId Opaque identifier for the loyalty identity
  /// @param oldAddr Previously registered address
  /// @param newAddr Newly registered address
  event AddressSwitched(bytes32 indexed identityId, address indexed oldAddr, address indexed newAddr);

  /// @notice Emitted when a backend signer is added to the valid signer set
  /// @param actor Address that initiated the change (msg.sender)
  /// @param signer Address added as a backend signer
  event BackendSignerAdded(address indexed actor, address indexed signer);

  /// @notice Emitted when a backend signer is removed from the valid signer set
  /// @param actor Address that initiated the change (msg.sender)
  /// @param signer Address removed as a backend signer
  event BackendSignerRemoved(address indexed actor, address indexed signer);

  /// @notice Emitted when the switch cooldown duration is changed
  /// @param actor Address that initiated the change (msg.sender)
  /// @param oldCooldown Previous cooldown, in seconds
  /// @param newCooldown New cooldown, in seconds
  event SwitchCooldownChanged(address indexed actor, uint64 oldCooldown, uint64 newCooldown);

  /// @notice Emitted when the pauser address is changed
  /// @param actor Address that initiated the change (msg.sender)
  /// @param oldPauser Previous pauser address
  /// @param newPauser New pauser address
  event PauserChanged(address indexed actor, address indexed oldPauser, address indexed newPauser);

  // ========================================
  // Errors
  // ========================================

  /// @notice Thrown when a zero address is provided where one is not allowed
  error CanNotBeZeroAddress();

  /// @notice Thrown when a zero identityId is provided where one is not allowed
  error CanNotBeZeroIdentityId();

  /// @notice Thrown when addBackendSigner()/the constructor is given an address already in the backend signer set
  error BackendSignerAlreadyExists();

  /// @notice Thrown when removeBackendSigner() is given an address not in the backend signer set,
  ///         or the constructor is given zero initial backend signers
  error BackendSignerNotFound();

  /// @notice Thrown when adding a backend signer would exceed MAX_BACKEND_SIGNERS
  error TooManyBackendSigners();

  /// @notice Thrown when removeBackendSigner() would remove the last remaining backend signer
  error CanNotRemoveLastBackendSigner();

  /// @notice Thrown when register()/registerBatch() is called for an identityId that already has a registered address
  error AlreadyRegistered();

  /// @notice Thrown when switchAddress() is called by any address other than the identity's
  ///         current registered address (this also covers an unregistered identityId, whose
  ///         registered address is address(0) - a value msg.sender can never equal)
  error NotRegisteredAddress();

  /// @notice Thrown when an address being registered/switched to is already bound to a different identity
  error AddressAlreadyBound();

  /// @notice Thrown when an address being registered/switched to is this registry itself - never a
  ///         valid payout destination (the EarnVault's own address is instead rejected at credit
  ///         time, by EarnVaultV2.onBoostCredit())
  error ReservedAddress();

  /// @notice Thrown when switchAddress() is called with newAddr equal to the current address
  error NewAddressEqualsCurrent();

  /// @notice Thrown when a signature's expiry timestamp has passed
  error SignatureExpired();

  /// @notice Thrown when a signature does not recover/validate to the expected signer
  error InvalidSignature();

  /// @notice Thrown when a supplied nonce does not match the identity's current nonce
  error InvalidNonce();

  /// @notice Thrown when registerBatch()'s identityIds and addrs arrays have different lengths
  error LengthMismatch();

  /// @notice Thrown when switchAddress() is called before the cooldown since the last change has elapsed
  error CooldownNotElapsed();

  /// @notice Thrown when a non-pauser address calls pause()/unpause()
  error NotAuthorizedToPause();
}
