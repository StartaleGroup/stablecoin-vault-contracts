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

  /// @notice Emitted when a backend-signed recovery is initiated for an identity
  /// @param identityId Opaque identifier for the loyalty identity
  /// @param oldAddr Address currently registered (as of initiation)
  /// @param newAddr Address recovery will switch to once finalized
  /// @param finalizeAfter Timestamp after which finalizeRecovery() may be called
  event RecoveryInitiated(
    bytes32 indexed identityId, address indexed oldAddr, address indexed newAddr, uint64 finalizeAfter
  );

  /// @notice Emitted when a pending recovery is finalized, taking effect
  /// @param identityId Opaque identifier for the loyalty identity
  /// @param oldAddr Address the identity was registered to before finalization
  /// @param newAddr Address the identity is now registered to
  event RecoveryFinalized(bytes32 indexed identityId, address indexed oldAddr, address indexed newAddr);

  /// @notice Emitted when a backend-signed migration-window correction takes effect
  /// @param identityId Opaque identifier for the loyalty identity
  /// @param oldAddr Address the identity was registered to before the correction
  /// @param newAddr Address the identity is now registered to
  event MigrationCorrected(bytes32 indexed identityId, address indexed oldAddr, address indexed newAddr);

  /// @notice Emitted when a pending recovery is cancelled by a successful switchAddress()
  /// @dev A user proving direct control via switchAddress() moots any recovery in flight -
  ///      whether that recovery was legitimate (user regained access another way) or the
  ///      product of a compromised backend signer.
  /// @param identityId Opaque identifier for the loyalty identity
  event RecoveryCancelled(bytes32 indexed identityId);

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

  /// @notice Emitted when the migration grace window end timestamp is changed
  /// @param actor Address that initiated the change (msg.sender)
  /// @param oldEnd Previous migration grace end timestamp
  /// @param newEnd New migration grace end timestamp
  event MigrationGraceEndChanged(address indexed actor, uint64 oldEnd, uint64 newEnd);

  /// @notice Emitted when the EarnVault address (a reserved registration target) is changed
  /// @param actor Address that initiated the change (msg.sender)
  /// @param oldVault Previous EarnVault address
  /// @param newVault New EarnVault address
  event EarnVaultChanged(address indexed actor, address indexed oldVault, address indexed newVault);

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

  /// @notice Thrown when initiateRecovery()/migrationCorrection() is called for an identityId with no registered address
  error IdentityNotRegistered();

  /// @notice Thrown when switchAddress() is called by any address other than the identity's
  ///         current registered address (this also covers an unregistered identityId, whose
  ///         registered address is address(0) - a value msg.sender can never equal)
  error NotRegisteredAddress();

  /// @notice Thrown when an address being registered/switched to is already bound to a different identity
  error AddressAlreadyBound();

  /// @notice Thrown when an address being registered/switched to is this registry or the EarnVault -
  ///         neither is a valid boost-payout or principal-holding destination
  error ReservedAddress();

  /// @notice Thrown when switchAddress()/initiateRecovery()/migrationCorrection() is called with
  ///         newAddr equal to the current address
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

  /// @notice Thrown when initiateRecovery() is called for an identity with an already-pending recovery
  error RecoveryAlreadyPending();

  /// @notice Thrown when finalizeRecovery() is called for an identity with no pending recovery
  error RecoveryNotPending();

  /// @notice Thrown when finalizeRecovery() is called before the recovery delay has elapsed
  error RecoveryDelayNotElapsed();

  /// @notice Thrown when migrationCorrection() is called while the migration grace window is
  ///         closed (migrationGraceEnd is 0, or block.timestamp is past it)
  error MigrationGraceWindowClosed();

  /// @notice Thrown when migrationCorrection() is called for an identity that has already
  ///         consumed its one-time migration-window correction
  error MigrationGraceAlreadyUsed();

  /// @notice Thrown when a non-pauser address calls pause()/unpause()
  error NotAuthorizedToPause();
}
