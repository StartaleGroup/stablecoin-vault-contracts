// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IIdentityRegistryEventsAndErrors} from '../interfaces/identity/IIdentityRegistryEventsAndErrors.sol';
import {Ownable} from 'lib/openzeppelin-contracts/contracts/access/Ownable.sol';
import {Ownable2Step} from 'lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol';
import {Pausable} from 'lib/openzeppelin-contracts/contracts/utils/Pausable.sol';
import {EIP712} from 'lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol';
import {SignatureChecker} from 'lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol';

/// @title IdentityRegistry
/// @notice Maps one loyalty identity to one payout address. That address is both where the
///         off-chain rewards engine reads EarnVault principal for boost eligibility, and where
///         EarnVaultV2.onBoostCredit() resolves each identityId to a payout address at credit
///         time. Holds no tier data, no thresholds, no rates, no principal - a pure
///         identity<->address binding. See
///         src/identity/identity-registry.md for the full design rationale; this
///         contract is a direct implementation of that spec.
/// @dev Holds no funds and makes no external calls. Read by two consumers: the off-chain rewards
///      engine (via the public mapping getters/emitted events) and, on-chain, EarnVaultV2's
///      onBoostCredit(), which calls registeredAddress(identityId) once per batch entry every
///      credit cycle to resolve the payout address before crediting principal.
contract IdentityRegistry is IIdentityRegistryEventsAndErrors, Ownable2Step, Pausable, EIP712 {
  // ================================================================
  // CONSTANTS
  // ================================================================

  /// @dev EIP-712 typehash for a single-identity registration attestation, backend-signed.
  bytes32 public constant REGISTER_TYPEHASH =
    keccak256('Register(bytes32 identityId,address addr,uint256 nonce,uint64 expiry)');

  /// @dev EIP-712 typehash for a batch registration attestation, backend-signed. One signature
  ///      covers the whole batch - see src/identity/identity-registry.md section 5.1b
  ///      for why per-entry signatures were rejected (calldata/gas cost with no security benefit).
  bytes32 public constant REGISTER_BATCH_TYPEHASH =
    keccak256('RegisterBatch(bytes32[] identityIds,address[] addrs,uint64 expiry,uint256 batchNonce)');

  /// @dev Bounds the backendSigners array so verification (which tries each entry in turn) stays
  ///      a small, fixed-cost loop rather than an unbounded one. Owner-controlled membership, not
  ///      attacker-controlled, but bounding it is still good practice - mirrors the MAX_BOOST_TOKENS
  ///      pattern used elsewhere in this codebase.
  uint256 public constant MAX_BACKEND_SIGNERS = 10;

  // ================================================================
  // STORAGE
  // ================================================================

  /// @notice identityId => currently registered address (forward mapping)
  mapping(bytes32 identityId => address) public registeredAddress;

  /// @notice address => identityId currently bound to it (reverse mapping, enforced at write time)
  /// @dev Nothing else stops two identities binding the same address without this - see WL-4 in
  ///      the spec. bytes32(0) means "not bound to any identity".
  mapping(address => bytes32 identityId) public identityOf;

  /// @notice identityId => next expected nonce for register() signatures for that identity
  /// @dev Checked by register() and incremented by register()/registerBatch(). switchAddress()
  ///      has no signed artifact and never touches it. Since an identity is registered at most
  ///      once, AlreadyRegistered independently blocks any register() replay.
  mapping(bytes32 identityId => uint256) public nonces;

  /// @notice identityId => timestamp of the last successful register()/registerBatch()/
  ///         switchAddress() for that identity - the anchor the switch cooldown is measured from
  mapping(bytes32 identityId => uint64) public lastSwitchAt;

  /// @notice Global nonce covering registerBatch() attestations - separate from the per-identity
  ///         `nonces` map since a batch signs over many not-yet-registered identities at once
  uint256 public batchNonce;

  /// @notice Enumerable list of addresses whose EIP-712 signature authorizes
  ///         register()/registerBatch() - any ONE of them signing is sufficient
  /// @dev Multiple independent signers (rather than one) let ops rotate a key without a window
  ///      where NO valid signer exists: add the new signer, cut the backend over, then remove the
  ///      old one. Removing a signer immediately invalidates every not-yet-submitted signature it
  ///      produced - intended, since removal is also the response to a compromised key.
  address[] public backendSigners;

  /// @notice addr => whether addr is currently a valid backend signer (source of truth for
  ///         membership; backendSigners is the enumerable mirror of this same set)
  mapping(address => bool) public isBackendSigner;

  /// @notice Address authorized to pause/unpause
  address public pauser;

  /// @notice Minimum time, in seconds, required between successive switchAddress() calls for the
  ///         same identity
  uint64 public switchCooldown;

  // ================================================================
  // CONSTRUCTOR
  // ================================================================

  constructor(
    address owner,
    address[] memory initialBackendSigners,
    address initialPauser,
    uint64 initialSwitchCooldown
  ) Ownable(owner) EIP712('IdentityRegistry', '1') {
    if (initialPauser == address(0)) revert CanNotBeZeroAddress();
    if (initialBackendSigners.length == 0) revert BackendSignerNotFound();
    if (initialBackendSigners.length > MAX_BACKEND_SIGNERS) revert TooManyBackendSigners();

    for (uint256 i = 0; i < initialBackendSigners.length; i++) {
      _addBackendSigner(initialBackendSigners[i]);
    }
    pauser = initialPauser;
    switchCooldown = initialSwitchCooldown;
  }

  // ================================================================
  // REGISTRATION
  // ================================================================

  /// @notice Register an address for an identity for the first time, backed by a backend-signed attestation
  /// @dev Permissionless to submit - authorization is entirely a backend signer's signature, msg.sender
  ///      is never checked. No signature from `addr` itself is required (see spec section 5.1): at
  ///      signup the AA is Startale-created, and at migration-backfill time the address already
  ///      holds the user's principal - requiring a target signature would make both flows
  ///      impractical (every backfilled user would have to sign before being registered).
  /// @param identityId Opaque identifier for the loyalty identity
  /// @param addr Address to register for this identity
  /// @param nonce Must equal nonces[identityId]. A leaked, unused signature stays valid until its
  ///        expiry or until its signer is removed - no other operation bumps this nonce first
  /// @param expiry Timestamp after which the attestation is no longer valid
  /// @param signature EIP-712 signature from any current backend signer over (identityId, addr, nonce, expiry)
  function register(
    bytes32 identityId,
    address addr,
    uint256 nonce,
    uint64 expiry,
    bytes calldata signature
  ) external whenNotPaused {
    if (identityId == bytes32(0)) revert CanNotBeZeroIdentityId();
    if (addr == address(0)) revert CanNotBeZeroAddress();
    if (registeredAddress[identityId] != address(0)) revert AlreadyRegistered();
    if (identityOf[addr] != bytes32(0)) revert AddressAlreadyBound();
    if (_isReserved(addr)) revert ReservedAddress();
    if (block.timestamp > expiry) revert SignatureExpired();
    if (nonce != nonces[identityId]) revert InvalidNonce();

    bytes32 structHash = keccak256(abi.encode(REGISTER_TYPEHASH, identityId, addr, nonce, expiry));
    bytes32 digest = _hashTypedDataV4(structHash);
    if (!_verifyBackendSignature(digest, signature)) revert InvalidSignature();

    nonces[identityId] = nonce + 1;
    _bind(identityId, addr);

    emit IdentityRegistered(identityId, addr);
  }

  /// @notice Register many identities in a single transaction, backed by one backend-signed
  ///         attestation over the whole batch
  /// @dev One signature over the entire batch, not per entry - see REGISTER_BATCH_TYPEHASH and the
  ///      spec section 5.1b for why per-entry signatures were rejected. Each entry gets its own
  ///      registration checks; a single bad entry reverts the whole batch (all-or-nothing).
  /// @param identityIds Opaque identifiers for the loyalty identities being registered
  /// @param addrs Addresses to register, index-aligned with identityIds
  /// @param expiry Timestamp after which the attestation is no longer valid
  /// @param signature EIP-712 signature from any current backend signer over (identityIds, addrs, expiry, batchNonce)
  function registerBatch(
    bytes32[] calldata identityIds,
    address[] calldata addrs,
    uint64 expiry,
    bytes calldata signature
  ) external whenNotPaused {
    if (identityIds.length != addrs.length) revert LengthMismatch();
    if (block.timestamp > expiry) revert SignatureExpired();

    uint256 currentBatchNonce = batchNonce;
    bytes32 structHash = keccak256(
      abi.encode(
        REGISTER_BATCH_TYPEHASH,
        keccak256(abi.encodePacked(identityIds)),
        keccak256(abi.encodePacked(addrs)),
        expiry,
        currentBatchNonce
      )
    );
    bytes32 digest = _hashTypedDataV4(structHash);
    if (!_verifyBackendSignature(digest, signature)) revert InvalidSignature();
    batchNonce = currentBatchNonce + 1;

    for (uint256 i = 0; i < identityIds.length; i++) {
      bytes32 identityId = identityIds[i];
      address addr = addrs[i];

      if (identityId == bytes32(0)) revert CanNotBeZeroIdentityId();
      if (addr == address(0)) revert CanNotBeZeroAddress();
      if (registeredAddress[identityId] != address(0)) revert AlreadyRegistered();
      if (identityOf[addr] != bytes32(0)) revert AddressAlreadyBound();
      if (_isReserved(addr)) revert ReservedAddress();

      nonces[identityId] += 1;
      _bind(identityId, addr);

      emit IdentityRegistered(identityId, addr);
    }
  }

  // ================================================================
  // VOLUNTARY ADDRESS SWITCH
  // ================================================================

  /// @notice Voluntarily change the address registered to an identity
  /// @dev Callable ONLY by the identity's current registered address - msg.sender itself is the
  ///      proof of control. This works unchanged for AA wallets: when the AA contract calls this
  ///      directly (e.g. via its own execute()), msg.sender IS the AA address regardless of who
  ///      sponsored the call's gas, so gas sponsorship is unaffected.
  /// @dev The msg.sender gate is what stops hijacking: identityId is public (emitted on every
  ///      register/switch), so any design that let a third party trigger this would let anyone
  ///      redirect an unrelated identity's future boost to themselves.
  /// @dev Deliberately NO consent check on `newAddr`: the current owner can bind their identity to
  ///      an address they don't control. The frontend is expected to verify control. On-chain, the
  ///      bound address's real owner cannot register their own identity to it (identityOf is
  ///      globally unique) until this identity switches away again.
  /// @param identityId Opaque identifier for the loyalty identity
  /// @param newAddr New address to register for this identity
  function switchAddress(bytes32 identityId, address newAddr) external whenNotPaused {
    address oldAddr = registeredAddress[identityId];
    // oldAddr == address(0) for an unregistered identity, which msg.sender can never equal -
    // so this one check also covers "identity not registered" with no separate branch needed.
    if (msg.sender != oldAddr) revert NotRegisteredAddress();
    if (newAddr == address(0)) revert CanNotBeZeroAddress();
    if (newAddr == oldAddr) revert NewAddressEqualsCurrent();
    if (identityOf[newAddr] != bytes32(0)) revert AddressAlreadyBound();
    if (_isReserved(newAddr)) revert ReservedAddress();
    if (block.timestamp < lastSwitchAt[identityId] + switchCooldown) revert CooldownNotElapsed();

    _rebind(identityId, oldAddr, newAddr);

    emit AddressSwitched(identityId, oldAddr, newAddr);
  }

  // ================================================================
  // ADMIN
  // ================================================================

  /// @notice Add a new backend signer - any one of the current set signing is sufficient to
  ///         authorize register()/registerBatch()
  /// @param signer Address to add as a valid backend signer
  function addBackendSigner(address signer) external onlyOwner {
    if (backendSigners.length >= MAX_BACKEND_SIGNERS) revert TooManyBackendSigners();
    _addBackendSigner(signer);
  }

  /// @notice Remove a backend signer
  /// @dev At least one backend signer must remain - with none, register/registerBatch would be
  ///      unauthorizable until the owner added a signer back.
  /// @param signer Address to remove from the valid backend signer set
  function removeBackendSigner(address signer) external onlyOwner {
    if (!isBackendSigner[signer]) revert BackendSignerNotFound();
    if (backendSigners.length == 1) revert CanNotRemoveLastBackendSigner();

    isBackendSigner[signer] = false;
    uint256 len = backendSigners.length;
    for (uint256 i = 0; i < len; i++) {
      if (backendSigners[i] == signer) {
        backendSigners[i] = backendSigners[len - 1];
        backendSigners.pop();
        break;
      }
    }
    emit BackendSignerRemoved(msg.sender, signer);
  }

  /// @notice Update the cooldown required between successive switchAddress() calls
  /// @param newCooldown New cooldown, in seconds
  function setSwitchCooldown(uint64 newCooldown) external onlyOwner {
    emit SwitchCooldownChanged(msg.sender, switchCooldown, newCooldown);
    switchCooldown = newCooldown;
  }

  /// @notice Update the pauser address
  /// @param newPauser New pauser address
  function setPauser(address newPauser) external onlyOwner {
    if (newPauser == address(0)) revert CanNotBeZeroAddress();
    emit PauserChanged(msg.sender, pauser, newPauser);
    pauser = newPauser;
  }

  /// @notice Pause register()/registerBatch()/switchAddress()
  /// @dev Never blocks any view - see spec section 6. Callable by pauser only.
  function pause() external {
    if (msg.sender != pauser) revert NotAuthorizedToPause();
    _pause();
  }

  /// @notice Unpause register()/registerBatch()/switchAddress()
  /// @dev Callable by pauser only.
  function unpause() external {
    if (msg.sender != pauser) revert NotAuthorizedToPause();
    _unpause();
  }

  // ================================================================
  // VIEWS
  // ================================================================

  /// @notice Whether `addr` is currently bound to any identity
  /// @dev Never reverts, paused or not - see spec section 6/8.
  function isRegistered(address addr) external view returns (bool) {
    return identityOf[addr] != bytes32(0);
  }

  /// @notice The full current set of valid backend signers
  function getBackendSigners() external view returns (address[] memory) {
    return backendSigners;
  }

  // ================================================================
  // INTERNAL
  // ================================================================

  /// @dev True if `addr` is this registry itself - never a valid payout destination. The
  ///      EarnVault is deliberately NOT tracked here: EarnVaultV2.onBoostCredit() rejects crediting
  ///      its own address, so the contract that would be harmed enforces it, with no extra
  ///      storage, setter or deployment-ordering constraint on this side.
  function _isReserved(address addr) internal view returns (bool) {
    return addr == address(this);
  }

  /// @dev Binds a never-before-registered identity to addr and starts its switch-cooldown clock.
  function _bind(bytes32 identityId, address addr) internal {
    registeredAddress[identityId] = addr;
    identityOf[addr] = identityId;
    lastSwitchAt[identityId] = uint64(block.timestamp);
  }

  /// @dev Moves an already-registered identity from oldAddr to newAddr atomically, deleting the
  ///      stale reverse-index entry - an add-without-delete would leave oldAddr still resolving
  ///      to this identity, recreating the exact stale-eligibility bug the reverse index exists
  ///      to prevent (spec section 5.2).
  function _rebind(bytes32 identityId, address oldAddr, address newAddr) internal {
    delete identityOf[oldAddr];
    identityOf[newAddr] = identityId;
    registeredAddress[identityId] = newAddr;
    lastSwitchAt[identityId] = uint64(block.timestamp);
  }

  /// @dev True if `signature` over `digest` validates against ANY current backend signer (ECDSA
  ///      or EIP-1271 - a signer entry may itself be a multisig/smart-contract wallet). The set
  ///      is bounded by MAX_BACKEND_SIGNERS, so this stays a small, fixed-cost loop.
  function _verifyBackendSignature(bytes32 digest, bytes calldata signature) internal view returns (bool) {
    uint256 len = backendSigners.length;
    for (uint256 i = 0; i < len; i++) {
      if (SignatureChecker.isValidSignatureNow(backendSigners[i], digest, signature)) {
        return true;
      }
    }
    return false;
  }

  /// @dev Adds `signer` to the backend signer set. Shared by the constructor and
  ///      addBackendSigner() - the constructor enforces the MAX_BACKEND_SIGNERS cap on the whole
  ///      initial array up front rather than per-entry here.
  function _addBackendSigner(address signer) internal {
    if (signer == address(0)) revert CanNotBeZeroAddress();
    if (isBackendSigner[signer]) revert BackendSignerAlreadyExists();
    isBackendSigner[signer] = true;
    backendSigners.push(signer);
    emit BackendSignerAdded(msg.sender, signer);
  }
}
