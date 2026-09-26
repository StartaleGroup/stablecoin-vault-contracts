// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IdentityRegistry} from '../../src/identity/IdentityRegistry.sol';
import {IIdentityRegistryEventsAndErrors} from '../../src/interfaces/identity/IIdentityRegistryEventsAndErrors.sol';
import {MockERC1271Wallet} from '../mocks/MockERC1271Wallet.sol';
import {Test} from 'lib/forge-std/src/Test.sol';
import {Ownable} from 'lib/openzeppelin-contracts/contracts/access/Ownable.sol';

/// @title MinimalSmartWallet
/// @notice Bare-bones AA-style wallet stand-in: forwards an arbitrary call, so the wallet
///         CONTRACT itself is msg.sender to the target - exactly how a real ERC-4337 account
///         calling switchAddress() directly would appear, regardless of who sponsored gas.
contract MinimalSmartWallet {
  function execute(address target, bytes calldata data) external {
    (bool success, bytes memory returndata) = target.call(data);
    if (!success) {
      assembly {
        revert(add(returndata, 32), mload(returndata))
      }
    }
  }
}

contract IdentityRegistryTest is Test {
  IdentityRegistry public registry;

  address public admin = makeAddr('admin');
  address public pauser = makeAddr('pauser');
  address public backendSigner;
  uint256 public backendSignerKey;

  uint64 public constant INITIAL_COOLDOWN = 2 days;

  bytes32 internal constant DOMAIN_TYPEHASH =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');

  function setUp() public virtual {
    (backendSigner, backendSignerKey) = makeAddrAndKey('backendSigner');
    address[] memory initialSigners = new address[](1);
    initialSigners[0] = backendSigner;
    registry = new IdentityRegistry(admin, initialSigners, pauser, INITIAL_COOLDOWN);
  }

  function _singleSigner(address signer) internal pure returns (address[] memory signers) {
    signers = new address[](1);
    signers[0] = signer;
  }

  // ================================================================
  // SIGNING HELPERS
  // ================================================================

  function _domainSeparator() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        DOMAIN_TYPEHASH, keccak256(bytes('IdentityRegistry')), keccak256(bytes('1')), block.chainid, address(registry)
      )
    );
  }

  function _digest(bytes32 structHash) internal view returns (bytes32) {
    return keccak256(abi.encodePacked('\x19\x01', _domainSeparator(), structHash));
  }

  function _signRegister(
    bytes32 identityId,
    address addr,
    uint256 nonce,
    uint64 expiry,
    uint256 signerKey
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(registry.REGISTER_TYPEHASH(), identityId, addr, nonce, expiry));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(structHash));
    return abi.encodePacked(r, s, v);
  }

  function _signRegisterBatch(
    bytes32[] memory identityIds,
    address[] memory addrs,
    uint64 expiry,
    uint256 batchNonceValue,
    uint256 signerKey
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(
      abi.encode(
        registry.REGISTER_BATCH_TYPEHASH(),
        keccak256(abi.encodePacked(identityIds)),
        keccak256(abi.encodePacked(addrs)),
        expiry,
        batchNonceValue
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(structHash));
    return abi.encodePacked(r, s, v);
  }

  function _register(bytes32 identityId, address addr) internal {
    uint256 nonce = registry.nonces(identityId);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(identityId, addr, nonce, expiry, backendSignerKey);
    registry.register(identityId, addr, nonce, expiry, sig);
  }

  // ================================================================
  // DEPLOYMENT / ADMIN
  // ================================================================

  function test_Deployment_SetsInitialState() public view {
    assertEq(registry.owner(), admin);
    assertTrue(registry.isBackendSigner(backendSigner));
    assertEq(registry.getBackendSigners().length, 1);
    assertEq(registry.getBackendSigners()[0], backendSigner);
    assertEq(registry.pauser(), pauser);
    assertEq(registry.switchCooldown(), INITIAL_COOLDOWN);
  }

  function test_Constructor_RevertsOnZeroOwner() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new IdentityRegistry(address(0), _singleSigner(backendSigner), pauser, INITIAL_COOLDOWN);
  }

  function test_Constructor_RevertsOnZeroBackendSigner() public {
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotBeZeroAddress.selector);
    new IdentityRegistry(admin, _singleSigner(address(0)), pauser, INITIAL_COOLDOWN);
  }

  function test_Constructor_RevertsOnEmptyBackendSignerArray() public {
    vm.expectRevert(IIdentityRegistryEventsAndErrors.BackendSignerNotFound.selector);
    new IdentityRegistry(admin, new address[](0), pauser, INITIAL_COOLDOWN);
  }

  function test_Constructor_RevertsOnTooManyBackendSigners() public {
    address[] memory tooMany = new address[](registry.MAX_BACKEND_SIGNERS() + 1);
    for (uint256 i = 0; i < tooMany.length; i++) {
      tooMany[i] = address(uint160(i + 1));
    }
    vm.expectRevert(IIdentityRegistryEventsAndErrors.TooManyBackendSigners.selector);
    new IdentityRegistry(admin, tooMany, pauser, INITIAL_COOLDOWN);
  }

  function test_Constructor_RevertsOnDuplicateBackendSigner() public {
    address[] memory dup = new address[](2);
    dup[0] = backendSigner;
    dup[1] = backendSigner;
    vm.expectRevert(IIdentityRegistryEventsAndErrors.BackendSignerAlreadyExists.selector);
    new IdentityRegistry(admin, dup, pauser, INITIAL_COOLDOWN);
  }

  function test_Constructor_RevertsOnZeroPauser() public {
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotBeZeroAddress.selector);
    new IdentityRegistry(admin, _singleSigner(backendSigner), address(0), INITIAL_COOLDOWN);
  }

  function test_Constructor_AcceptsMultipleBackendSigners() public {
    address signer2 = makeAddr('signer2');
    address signer3 = makeAddr('signer3');
    address[] memory signers = new address[](3);
    signers[0] = backendSigner;
    signers[1] = signer2;
    signers[2] = signer3;

    IdentityRegistry multi = new IdentityRegistry(admin, signers, pauser, INITIAL_COOLDOWN);
    assertEq(multi.getBackendSigners().length, 3);
    assertTrue(multi.isBackendSigner(backendSigner));
    assertTrue(multi.isBackendSigner(signer2));
    assertTrue(multi.isBackendSigner(signer3));
  }

  function test_AddBackendSigner_UpdatesStateAndEmits() public {
    address newSigner = makeAddr('newSigner');
    vm.expectEmit(true, true, true, true);
    emit IIdentityRegistryEventsAndErrors.BackendSignerAdded(admin, newSigner);
    vm.prank(admin);
    registry.addBackendSigner(newSigner);

    assertTrue(registry.isBackendSigner(newSigner));
    assertEq(registry.getBackendSigners().length, 2);
  }

  function test_AddBackendSigner_RevertsForNonOwner() public {
    address rando = makeAddr('rando');
    vm.prank(rando);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
    registry.addBackendSigner(makeAddr('newSigner'));
  }

  function test_AddBackendSigner_RevertsOnZeroAddress() public {
    vm.prank(admin);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotBeZeroAddress.selector);
    registry.addBackendSigner(address(0));
  }

  function test_AddBackendSigner_RevertsOnDuplicate() public {
    vm.prank(admin);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.BackendSignerAlreadyExists.selector);
    registry.addBackendSigner(backendSigner);
  }

  function test_AddBackendSigner_RevertsAtCap() public {
    vm.startPrank(admin);
    // registry already has 1 signer (backendSigner) from setUp - fill up to the cap
    for (uint256 i = 0; i < registry.MAX_BACKEND_SIGNERS() - 1; i++) {
      registry.addBackendSigner(address(uint160(i + 1)));
    }
    vm.expectRevert(IIdentityRegistryEventsAndErrors.TooManyBackendSigners.selector);
    registry.addBackendSigner(makeAddr('oneTooMany'));
    vm.stopPrank();
  }

  function test_RemoveBackendSigner_UpdatesStateAndEmits() public {
    address newSigner = makeAddr('newSigner');
    vm.startPrank(admin);
    registry.addBackendSigner(newSigner);

    vm.expectEmit(true, true, true, true);
    emit IIdentityRegistryEventsAndErrors.BackendSignerRemoved(admin, backendSigner);
    registry.removeBackendSigner(backendSigner);
    vm.stopPrank();

    assertFalse(registry.isBackendSigner(backendSigner));
    assertTrue(registry.isBackendSigner(newSigner));
    assertEq(registry.getBackendSigners().length, 1);
  }

  function test_RemoveBackendSigner_RevertsForNonOwner() public {
    address rando = makeAddr('rando');
    vm.prank(rando);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
    registry.removeBackendSigner(backendSigner);
  }

  function test_RemoveBackendSigner_RevertsWhenNotASigner() public {
    vm.prank(admin);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.BackendSignerNotFound.selector);
    registry.removeBackendSigner(makeAddr('notASigner'));
  }

  function test_RemoveBackendSigner_RevertsOnLastSigner() public {
    vm.prank(admin);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotRemoveLastBackendSigner.selector);
    registry.removeBackendSigner(backendSigner);
  }

  function test_BackendSigners_EitherOfTwoSignersCanAuthorizeRegister() public {
    (address signer2, uint256 signer2Key) = makeAddrAndKey('signer2');
    vm.prank(admin);
    registry.addBackendSigner(signer2);

    // identity 1 signed by the original signer
    bytes32 identityId1 = keccak256('identity-1');
    address addr1 = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig1 = _signRegister(identityId1, addr1, 0, expiry, backendSignerKey);
    registry.register(identityId1, addr1, 0, expiry, sig1);
    assertEq(registry.registeredAddress(identityId1), addr1);

    // identity 2 signed by the newly added second signer
    bytes32 identityId2 = keccak256('identity-2');
    address addr2 = makeAddr('user2');
    bytes memory sig2 = _signRegister(identityId2, addr2, 0, expiry, signer2Key);
    registry.register(identityId2, addr2, 0, expiry, sig2);
    assertEq(registry.registeredAddress(identityId2), addr2);
  }

  function test_BackendSigners_RemovedSignerCanNoLongerAuthorize() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);

    // signed BEFORE removal and not yet submitted - removal must still invalidate it
    // (the rotation/compromise property documented on backendSigners)
    bytes memory staleSig = _signRegister(identityId, addr, 0, expiry, backendSignerKey);

    (address signer2, uint256 signer2Key) = makeAddrAndKey('signer2');
    vm.startPrank(admin);
    registry.addBackendSigner(signer2);
    registry.removeBackendSigner(backendSigner);
    vm.stopPrank();

    vm.expectRevert(IIdentityRegistryEventsAndErrors.InvalidSignature.selector);
    registry.register(identityId, addr, 0, expiry, staleSig);

    // but the still-valid second signer works fine
    bytes memory validSig = _signRegister(identityId, addr, 0, expiry, signer2Key);
    registry.register(identityId, addr, 0, expiry, validSig);
    assertEq(registry.registeredAddress(identityId), addr);
  }

  function test_SetSwitchCooldown_UpdatesStateAndEmits() public {
    vm.expectEmit(true, true, true, true);
    emit IIdentityRegistryEventsAndErrors.SwitchCooldownChanged(admin, INITIAL_COOLDOWN, 3 days);
    vm.prank(admin);
    registry.setSwitchCooldown(3 days);
    assertEq(registry.switchCooldown(), 3 days);
  }

  function test_SetPauser_UpdatesStateAndEmits() public {
    address newPauser = makeAddr('newPauser');
    vm.expectEmit(true, true, true, true);
    emit IIdentityRegistryEventsAndErrors.PauserChanged(admin, pauser, newPauser);
    vm.prank(admin);
    registry.setPauser(newPauser);
    assertEq(registry.pauser(), newPauser);
  }

  function test_Register_RevertsOnRegistryOwnAddress() public {
    bytes32 identityId = keccak256('identity-1');
    uint64 expiry = uint64(block.timestamp + 1 hours);

    bytes memory sigToSelf = _signRegister(identityId, address(registry), 0, expiry, backendSignerKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.ReservedAddress.selector);
    registry.register(identityId, address(registry), 0, expiry, sigToSelf);
  }

  // ================================================================
  // REGISTER
  // ================================================================

  function test_Register_Succeeds() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(identityId, addr, 0, expiry, backendSignerKey);

    vm.expectEmit(true, true, true, true);
    emit IIdentityRegistryEventsAndErrors.IdentityRegistered(identityId, addr);
    registry.register(identityId, addr, 0, expiry, sig);

    assertEq(registry.registeredAddress(identityId), addr);
    assertEq(registry.identityOf(addr), identityId);
    assertEq(registry.nonces(identityId), 1);
    assertEq(registry.lastSwitchAt(identityId), block.timestamp);
  }

  function test_Register_RevertsOnZeroIdentityId() public {
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(bytes32(0), addr, 0, expiry, backendSignerKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotBeZeroIdentityId.selector);
    registry.register(bytes32(0), addr, 0, expiry, sig);
  }

  function test_Register_RevertsOnZeroAddress() public {
    bytes32 identityId = keccak256('identity-1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(identityId, address(0), 0, expiry, backendSignerKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotBeZeroAddress.selector);
    registry.register(identityId, address(0), 0, expiry, sig);
  }

  function test_Register_RevertsOnDoubleRegistration() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    _register(identityId, addr);

    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(identityId, addr, 1, expiry, backendSignerKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.AlreadyRegistered.selector);
    registry.register(identityId, addr, 1, expiry, sig);
  }

  function test_Register_RevertsWhenAddressAlreadyBoundToDifferentIdentity() public {
    address addr = makeAddr('user1');
    _register(keccak256('identity-1'), addr);

    bytes32 identityId2 = keccak256('identity-2');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(identityId2, addr, 0, expiry, backendSignerKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.AddressAlreadyBound.selector);
    registry.register(identityId2, addr, 0, expiry, sig);
  }

  function test_Register_RevertsOnExpiredSignature() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(identityId, addr, 0, expiry, backendSignerKey);

    vm.warp(expiry + 1);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.SignatureExpired.selector);
    registry.register(identityId, addr, 0, expiry, sig);
  }

  function test_Register_RevertsOnWrongNonce() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(identityId, addr, 5, expiry, backendSignerKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.InvalidNonce.selector);
    registry.register(identityId, addr, 5, expiry, sig);
  }

  function test_Register_RevertsOnWrongSigner() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    (, uint256 wrongKey) = makeAddrAndKey('notBackendSigner');
    bytes memory sig = _signRegister(identityId, addr, 0, expiry, wrongKey);

    vm.expectRevert(IIdentityRegistryEventsAndErrors.InvalidSignature.selector);
    registry.register(identityId, addr, 0, expiry, sig);
  }

  function test_Register_RevertsOnReplayedSignatureAfterUnrelatedNonceBump() public {
    // A signature valid at nonce 0 must not still be usable once some other operation has
    // already bumped nonces[identityId] to 1 - this is the "leaked signature can be
    // invalidated" property the spec calls out.
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory leakedSig = _signRegister(identityId, addr, 0, expiry, backendSignerKey);

    _register(identityId, addr); // consumes nonce 0 through a different, later-signed message
    vm.expectRevert(IIdentityRegistryEventsAndErrors.AlreadyRegistered.selector);
    registry.register(identityId, addr, 0, expiry, leakedSig);
  }

  function testFuzz_Register_ArbitraryIdentityAndAddress(
    bytes32 identityId,
    address addr,
    uint256 expiryOffset
  ) public {
    vm.assume(identityId != bytes32(0));
    vm.assume(addr != address(0) && addr != address(registry));
    uint64 expiry = uint64(block.timestamp + bound(expiryOffset, 1, 365 days));
    bytes memory sig = _signRegister(identityId, addr, 0, expiry, backendSignerKey);

    registry.register(identityId, addr, 0, expiry, sig);

    assertEq(registry.registeredAddress(identityId), addr);
    assertEq(registry.identityOf(addr), identityId);
  }

  // ================================================================
  // REGISTER BATCH
  // ================================================================

  function _batchArrays(uint256 n) internal pure returns (bytes32[] memory ids, address[] memory addrs) {
    ids = new bytes32[](n);
    addrs = new address[](n);
    for (uint256 i = 0; i < n; i++) {
      ids[i] = keccak256(abi.encode('batch-identity', i));
      addrs[i] = address(uint160(uint256(keccak256(abi.encode('batch-addr', i)))));
    }
  }

  /// @dev register/registerBatch are permissionless to SUBMIT - authorization is the backend
  ///      signature alone, so any relayer can pay gas for them.
  function test_Register_PermissionlessToSubmitByAnyRelayer() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(identityId, addr, 0, expiry, backendSignerKey);

    vm.prank(makeAddr('randomRelayer'));
    registry.register(identityId, addr, 0, expiry, sig);
    assertEq(registry.registeredAddress(identityId), addr);
  }

  function test_RegisterBatch_PermissionlessToSubmitByAnyRelayer() public {
    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(2);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);

    vm.prank(makeAddr('randomRelayer'));
    registry.registerBatch(ids, addrs, expiry, sig);
    assertEq(registry.registeredAddress(ids[0]), addrs[0]);
    assertEq(registry.registeredAddress(ids[1]), addrs[1]);
  }

  function test_RegisterBatch_Succeeds() public {
    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(3);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);

    registry.registerBatch(ids, addrs, expiry, sig);

    for (uint256 i = 0; i < ids.length; i++) {
      assertEq(registry.registeredAddress(ids[i]), addrs[i]);
      assertEq(registry.identityOf(addrs[i]), ids[i]);
      assertEq(registry.nonces(ids[i]), 1);
    }
    assertEq(registry.batchNonce(), 1);
  }

  function test_RegisterBatch_RevertsOnLengthMismatch() public {
    (bytes32[] memory ids,) = _batchArrays(3);
    address[] memory addrs = new address[](2);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.LengthMismatch.selector);
    registry.registerBatch(ids, addrs, expiry, sig);
  }

  function test_RegisterBatch_RevertsOnWrongSigner() public {
    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(2);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    (, uint256 wrongKey) = makeAddrAndKey('notBackendSigner');
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, wrongKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.InvalidSignature.selector);
    registry.registerBatch(ids, addrs, expiry, sig);
  }

  function test_RegisterBatch_RevertsWholeBatchOnOneBadEntry() public {
    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(3);
    addrs[1] = addrs[0]; // duplicate within the batch -> AddressAlreadyBound on the 2nd entry
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);

    vm.expectRevert(IIdentityRegistryEventsAndErrors.AddressAlreadyBound.selector);
    registry.registerBatch(ids, addrs, expiry, sig);

    // whole batch reverted - not even the first entry should be registered
    assertEq(registry.registeredAddress(ids[0]), address(0));
  }

  function test_RegisterBatch_RevertsOnZeroAddressEntry() public {
    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(3);
    addrs[1] = address(0);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);

    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotBeZeroAddress.selector);
    registry.registerBatch(ids, addrs, expiry, sig);
    assertEq(registry.registeredAddress(ids[0]), address(0));
  }

  function test_RegisterBatch_RevertsOnZeroIdentityIdEntry() public {
    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(3);
    ids[1] = bytes32(0);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);

    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotBeZeroIdentityId.selector);
    registry.registerBatch(ids, addrs, expiry, sig);
    assertEq(registry.registeredAddress(ids[0]), address(0));
  }

  function test_RegisterBatch_RevertsOnReservedAddressEntry() public {
    address reserved = address(registry);

    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(3);
    addrs[1] = reserved;
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);

    vm.expectRevert(IIdentityRegistryEventsAndErrors.ReservedAddress.selector);
    registry.registerBatch(ids, addrs, expiry, sig);
    assertEq(registry.registeredAddress(ids[0]), address(0));
  }

  function test_RegisterBatch_RevertsWhenAlreadyRegisteredEntry() public {
    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(3);
    _register(ids[1], makeAddr('someoneElse'));

    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);

    vm.expectRevert(IIdentityRegistryEventsAndErrors.AlreadyRegistered.selector);
    registry.registerBatch(ids, addrs, expiry, sig);
    assertEq(registry.registeredAddress(ids[0]), address(0));
  }

  function test_RegisterBatch_SignatureCannotBeReplayedForSecondBatch() public {
    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(2);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey);
    registry.registerBatch(ids, addrs, expiry, sig);

    (bytes32[] memory ids2, address[] memory addrs2) = _batchArrays(4);
    // ids2/addrs2 overlap with the first batch's entries at index 0-1, so this would revert
    // on AlreadyRegistered even if the stale batchNonce=0 signature were (wrongly) accepted -
    // but it must be rejected on InvalidSignature first, since batchNonce already moved to 1.
    vm.expectRevert(IIdentityRegistryEventsAndErrors.InvalidSignature.selector);
    registry.registerBatch(ids2, addrs2, expiry, sig);
  }

  // ================================================================
  // SWITCH ADDRESS
  // ================================================================
  // switchAddress(identityId, newAddr) is gated ONLY on msg.sender == the identity's current
  // registered address - that gate is what stops hijacking, since identityId is public. There is
  // deliberately no consent signature from newAddr: the current owner can bind to an address they
  // don't control (the frontend is expected to verify control). It carries no signed artifact, so
  // it never reads or bumps nonces.

  function _switch(bytes32 identityId, address caller, address newAddr) internal {
    vm.prank(caller);
    registry.switchAddress(identityId, newAddr);
  }

  function test_SwitchAddress_SucceedsAfterCooldown() public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    address newAddr = makeAddr('user1-new');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    vm.expectEmit(true, true, true, true);
    emit IIdentityRegistryEventsAndErrors.AddressSwitched(identityId, oldAddr, newAddr);
    _switch(identityId, oldAddr, newAddr);

    assertEq(registry.registeredAddress(identityId), newAddr);
    assertEq(registry.identityOf(newAddr), identityId);
    assertEq(registry.identityOf(oldAddr), bytes32(0));
    assertEq(registry.lastSwitchAt(identityId), uint64(block.timestamp));
  }

  function test_SwitchAddress_RevertsExactlyBeforeCooldownBoundary() public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN - 1);

    vm.prank(oldAddr);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CooldownNotElapsed.selector);
    registry.switchAddress(identityId, makeAddr('user1-new'));
  }

  function test_SwitchAddress_SucceedsExactlyAtCooldownBoundary() public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    address newAddr = makeAddr('user1-new');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    _switch(identityId, oldAddr, newAddr);
    assertEq(registry.registeredAddress(identityId), newAddr);
  }

  function test_SwitchAddress_RevertsForUnregisteredIdentity() public {
    // registeredAddress is address(0) for an unregistered identity, which msg.sender can never be.
    vm.prank(makeAddr('anyone'));
    vm.expectRevert(IIdentityRegistryEventsAndErrors.NotRegisteredAddress.selector);
    registry.switchAddress(keccak256('never-registered'), makeAddr('someone'));
  }

  function test_SwitchAddress_RevertsForCallerOtherThanCurrentOwner() public {
    // The hijack the msg.sender gate exists to prevent: a third party who knows the (public)
    // identityId cannot redirect it to themselves.
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    address attacker = makeAddr('attacker');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    vm.prank(attacker);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.NotRegisteredAddress.selector);
    registry.switchAddress(identityId, attacker);
    assertEq(registry.registeredAddress(identityId), oldAddr);
  }

  function testFuzz_SwitchAddress_RejectsEveryCallerExceptCurrentOwner(address caller) public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    vm.assume(caller != oldAddr);
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    vm.prank(caller);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.NotRegisteredAddress.selector);
    registry.switchAddress(identityId, makeAddr('target'));
    assertEq(registry.registeredAddress(identityId), oldAddr);
  }

  function test_SwitchAddress_RevertsOnZeroAddress() public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    vm.prank(oldAddr);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CanNotBeZeroAddress.selector);
    registry.switchAddress(identityId, address(0));
  }

  function test_SwitchAddress_RevertsOnSameAddress() public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    vm.prank(oldAddr);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.NewAddressEqualsCurrent.selector);
    registry.switchAddress(identityId, oldAddr);
  }

  function test_SwitchAddress_RevertsWhenNewAddrBoundElsewhere() public {
    bytes32 identityId1 = keccak256('identity-1');
    bytes32 identityId2 = keccak256('identity-2');
    address addr1 = makeAddr('user1');
    address addr2 = makeAddr('user2');
    _register(identityId1, addr1);
    _register(identityId2, addr2);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    vm.prank(addr1);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.AddressAlreadyBound.selector);
    registry.switchAddress(identityId1, addr2);
  }

  function test_SwitchAddress_RevertsOnReservedAddress() public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    vm.prank(oldAddr);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.ReservedAddress.selector);
    registry.switchAddress(identityId, address(registry));
  }

  function test_SwitchAddress_CooldownReArmsAfterSwitch() public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    address newAddr = makeAddr('user1-new');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);
    _switch(identityId, oldAddr, newAddr);

    // re-armed: a second switch right away reverts, and succeeds once a full cooldown passes
    vm.prank(newAddr);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.CooldownNotElapsed.selector);
    registry.switchAddress(identityId, makeAddr('user1-newer'));

    vm.warp(block.timestamp + INITIAL_COOLDOWN);
    _switch(identityId, newAddr, makeAddr('user1-newer'));
    assertEq(registry.registeredAddress(identityId), makeAddr('user1-newer'));
  }

  function test_SwitchAddress_WorksForSmartContractWalletAsCurrentOwner() public {
    // AA compatibility with no special-casing: the wallet contract itself is msg.sender when it
    // calls switchAddress() via its own execute(), regardless of who sponsored the gas.
    MinimalSmartWallet wallet = new MinimalSmartWallet();
    bytes32 identityId = keccak256('identity-1');
    _register(identityId, address(wallet));
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    address newAddr = makeAddr('newAddr');
    wallet.execute(address(registry), abi.encodeCall(registry.switchAddress, (identityId, newAddr)));
    assertEq(registry.registeredAddress(identityId), newAddr);
  }

  function test_SwitchAddress_CanTargetSmartContractWallet() public {
    // AA as destination: no signature is involved any more, so any contract address works.
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    MinimalSmartWallet wallet = new MinimalSmartWallet();
    _switch(identityId, oldAddr, address(wallet));
    assertEq(registry.registeredAddress(identityId), address(wallet));
  }

  function test_SwitchAddress_NeverTouchesNonces() public {
    // After register (nonce 1) and after registerBatch (nonce 1), switching leaves the counter
    // exactly where it was - switchAddress has no signed artifact to replay.
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('user1');
    _register(identityId, oldAddr);

    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(1);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    registry.registerBatch(ids, addrs, expiry, _signRegisterBatch(ids, addrs, expiry, 0, backendSignerKey));

    vm.warp(block.timestamp + INITIAL_COOLDOWN);
    _switch(identityId, oldAddr, makeAddr('user1-new'));
    _switch(ids[0], addrs[0], makeAddr('batch-new'));

    assertEq(registry.nonces(identityId), 1);
    assertEq(registry.nonces(ids[0]), 1);
  }

  /// @dev Pins the accepted consequence of having no consent check: the current owner can bind
  ///      their identity to an address they don't control, and that address's real owner cannot
  ///      register their own identity to it until the squatter switches away.
  function test_SwitchAddress_NoConsentCheck_SquattedAddressBlocksItsRealOwnerUntilReleased() public {
    bytes32 squatterId = keccak256('squatter');
    address squatterAddr = makeAddr('squatter');
    address victimAddr = makeAddr('victim');
    bytes32 victimId = keccak256('victim');
    _register(squatterId, squatterAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);

    _switch(squatterId, squatterAddr, victimAddr); // no signature from victimAddr needed
    assertEq(registry.identityOf(victimAddr), squatterId);

    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory sig = _signRegister(victimId, victimAddr, 0, expiry, backendSignerKey);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.AddressAlreadyBound.selector);
    registry.register(victimId, victimAddr, 0, expiry, sig);

    // only the squatter can release it - by switching away, after its cooldown
    vm.warp(block.timestamp + INITIAL_COOLDOWN);
    _switch(squatterId, victimAddr, makeAddr('squatter-elsewhere'));
    registry.register(
      victimId,
      victimAddr,
      0,
      uint64(block.timestamp + 1 hours),
      _signRegister(victimId, victimAddr, 0, uint64(block.timestamp + 1 hours), backendSignerKey)
    );
    assertEq(registry.registeredAddress(victimId), victimAddr);
  }

  function testFuzz_SwitchAddress_ArbitraryAddresses(bytes32 identityId, address oldAddr, address newAddr) public {
    vm.assume(identityId != bytes32(0));
    vm.assume(oldAddr != address(0) && newAddr != address(0));
    vm.assume(oldAddr != newAddr);
    vm.assume(oldAddr != address(registry) && newAddr != address(registry));

    _register(identityId, oldAddr);
    vm.warp(block.timestamp + INITIAL_COOLDOWN);
    _switch(identityId, oldAddr, newAddr);

    assertEq(registry.registeredAddress(identityId), newAddr);
    assertEq(registry.identityOf(newAddr), identityId);
    assertEq(registry.identityOf(oldAddr), bytes32(0));
  }

  function test_BackendSigner_Eip1271SmartContractSignerCanAuthorizeRegister() public {
    (address ownerAddr, uint256 ownerKey) = makeAddrAndKey('backendSafeOwner');
    MockERC1271Wallet backendSafe = new MockERC1271Wallet(ownerAddr);
    vm.prank(admin);
    registry.addBackendSigner(address(backendSafe));

    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes32 structHash = keccak256(abi.encode(registry.REGISTER_TYPEHASH(), identityId, addr, uint256(0), expiry));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(structHash));
    bytes memory sig = abi.encodePacked(r, s, v);

    registry.register(identityId, addr, 0, expiry, sig);
    assertEq(registry.registeredAddress(identityId), addr);
  }

  // ================================================================
  // PAUSE SEMANTICS
  // ================================================================

  /// @dev Pause blocks all three write paths - register, registerBatch and switchAddress.
  function test_Pause_BlocksRegisterRegisterBatchAndSwitchAddress() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    _register(identityId, addr);

    vm.prank(pauser);
    registry.pause();

    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes memory dummySig = new bytes(65);

    vm.expectRevert(abi.encodeWithSignature('EnforcedPause()'));
    registry.register(keccak256('identity-2'), makeAddr('user2'), 0, expiry, dummySig);

    (bytes32[] memory ids, address[] memory addrs) = _batchArrays(2);
    vm.expectRevert(abi.encodeWithSignature('EnforcedPause()'));
    registry.registerBatch(ids, addrs, expiry, dummySig);

    vm.expectRevert(abi.encodeWithSignature('EnforcedPause()'));
    vm.prank(addr);
    registry.switchAddress(identityId, makeAddr('newAddr'));
  }

  function test_Pause_NeverBlocksViews() public {
    bytes32 identityId = keccak256('identity-1');
    address addr = makeAddr('user1');
    _register(identityId, addr);

    vm.prank(pauser);
    registry.pause();

    assertEq(registry.registeredAddress(identityId), addr);
    assertEq(registry.identityOf(addr), identityId);
    assertTrue(registry.isRegistered(addr));
    assertFalse(registry.isRegistered(makeAddr('unbound')));
    assertEq(registry.nonces(identityId), 1);
    assertEq(registry.lastSwitchAt(identityId), uint64(block.timestamp));
    assertEq(registry.batchNonce(), 0);
    assertEq(registry.switchCooldown(), INITIAL_COOLDOWN);
    assertEq(registry.pauser(), pauser);
    assertEq(registry.owner(), admin);
    assertEq(registry.backendSigners(0), backendSigner);
    assertTrue(registry.isBackendSigner(backendSigner));
    assertEq(registry.getBackendSigners().length, 1);
    assertTrue(registry.paused());
  }

  function test_Pause_RevertsForNonPauser() public {
    vm.prank(makeAddr('rando'));
    vm.expectRevert(IIdentityRegistryEventsAndErrors.NotAuthorizedToPause.selector);
    registry.pause();
  }

  // ================================================================
  // OWNERSHIP
  // ================================================================

  function test_TwoStepOwnershipTransfer_RequiresAcceptance() public {
    address newOwner = makeAddr('newOwner');

    vm.prank(admin);
    registry.transferOwnership(newOwner);
    assertEq(registry.owner(), admin);
    assertEq(registry.pendingOwner(), newOwner);

    vm.prank(newOwner);
    registry.acceptOwnership();
    assertEq(registry.owner(), newOwner);
    assertEq(registry.pendingOwner(), address(0));
  }

  function test_TwoStepOwnershipTransfer_RevertsIfAcceptedByWrongAddress() public {
    address newOwner = makeAddr('newOwner');
    address wrongAddress = makeAddr('wrongAddress');

    vm.prank(admin);
    registry.transferOwnership(newOwner);

    vm.prank(wrongAddress);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, wrongAddress));
    registry.acceptOwnership();
  }
}
