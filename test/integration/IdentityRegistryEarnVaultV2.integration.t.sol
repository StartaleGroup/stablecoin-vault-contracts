// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IdentityRegistry} from '../../src/identity/IdentityRegistry.sol';
import {IIdentityRegistryEventsAndErrors} from '../../src/interfaces/identity/IIdentityRegistryEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'lib/forge-std/src/Test.sol';

contract IdentityRegistryEarnVaultV2IntegrationTest is Test {
  IdentityRegistry public registry;
  EarnVaultV2 public vault;
  MockUSDSC public usdsc;

  address public admin = makeAddr('admin');
  address public owner = makeAddr('owner');
  address public redistributor = makeAddr('redistributor');
  address public treasury = makeAddr('treasury');
  address public vaultPauser = makeAddr('vaultPauser');
  address public operator = makeAddr('operator');
  address public boostKeeper = makeAddr('boostKeeper');

  address public registryAdmin = makeAddr('registryAdmin');
  address public registryPauser = makeAddr('registryPauser');
  address public backendSigner;
  uint256 public backendSignerKey;

  uint64 public constant SWITCH_COOLDOWN = 2 days;

  bytes32 internal constant DOMAIN_TYPEHASH =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');

  function setUp() public {
    usdsc = new MockUSDSC();

    EarnVaultUpgradeable v1Implementation = new EarnVaultUpgradeable();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(v1Implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, vaultPauser, operator
      )
    );
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    address proxyAdminAddress = address(uint160(uint256(vm.load(address(proxy), adminSlot))));
    ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddress);

    (backendSigner, backendSignerKey) = makeAddrAndKey('backendSigner');
    address[] memory signers = new address[](1);
    signers[0] = backendSigner;
    registry = new IdentityRegistry(registryAdmin, signers, registryPauser, SWITCH_COOLDOWN);

    EarnVaultV2 v2Implementation = new EarnVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector, boostKeeper, address(registry))
    );

    vault = EarnVaultV2(payable(address(proxy)));
  }

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

  function _register(bytes32 identityId, address addr) internal {
    uint256 nonce = registry.nonces(identityId);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes32 structHash = keccak256(abi.encode(registry.REGISTER_TYPEHASH(), identityId, addr, nonce, expiry));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendSignerKey, _digest(structHash));
    registry.register(identityId, addr, nonce, expiry, abi.encodePacked(r, s, v));
  }

  function _switchAddress(bytes32 identityId, address oldAddr, address newAddr, uint256 newKey) internal {
    uint256 nonce = registry.nonces(identityId);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes32 structHash = keccak256(abi.encode(registry.SWITCH_TYPEHASH(), identityId, newAddr, nonce, expiry));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(newKey, _digest(structHash));
    vm.prank(oldAddr);
    registry.switchAddress(identityId, newAddr, nonce, expiry, abi.encodePacked(r, s, v));
  }

  function test_E2E_RegisterThenOnBoostCreditCreditsRegisteredAddress() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _register(identityId, user);

    uint256 amount = 100e6;
    usdsc.mint(address(vault), amount);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(user), amount);
  }

  function test_E2E_SwitchAddressRedirectsWhereFutureCreditsLand() public {
    bytes32 identityId = keccak256('identity-1');
    address oldAddr = makeAddr('oldAddr');
    _register(identityId, oldAddr);

    // cycle 1 credited while oldAddr is registered
    usdsc.mint(address(vault), 100e6);
    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);
    assertEq(vault.principal(oldAddr), 100e6);

    // identity switches address
    vm.warp(block.timestamp + SWITCH_COOLDOWN);
    (address newAddr, uint256 newKey) = makeAddrAndKey('newAddr');
    _switchAddress(identityId, oldAddr, newAddr, newKey);

    // cycle 2 must credit the NEW address, not the old one
    usdsc.mint(address(vault), 50e6);
    amounts[0] = 50e6;
    vm.prank(boostKeeper);
    vault.onBoostCredit(2, ids, amounts);

    assertEq(vault.principal(newAddr), 50e6);
    assertEq(vault.principal(oldAddr), 100e6); // unchanged by cycle 2
  }

  function test_E2E_ReplayGuardBlocksResubmittedBatch() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _register(identityId, user);

    usdsc.mint(address(vault), 200e6);
    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vault.onBoostCredit(7, ids, amounts);

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(7, ids, amounts);

    assertEq(vault.principal(user), 100e6);
  }

  /// @dev Backs the claim that only a backend signature can bind the vault's address: a user
  ///      cannot switchAddress() to it, because the vault cannot produce a valid signature (no
  ///      isValidSignature; the ERC-1271 staticcall hits its reverting fallback). Tried with both a
  ///      well-formed ECDSA signature from an unrelated key and an arbitrary non-ECDSA blob.
  function test_E2E_UserCannotSwitchAddressToVault() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _register(identityId, user);
    vm.warp(block.timestamp + SWITCH_COOLDOWN);

    uint256 nonce = registry.nonces(identityId);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes32 structHash = keccak256(abi.encode(registry.SWITCH_TYPEHASH(), identityId, address(vault), nonce, expiry));
    (, uint256 otherKey) = makeAddrAndKey('someKey');
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, _digest(structHash));

    vm.prank(user);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.InvalidSignature.selector);
    registry.switchAddress(identityId, address(vault), nonce, expiry, abi.encodePacked(r, s, v));

    vm.prank(user);
    vm.expectRevert(IIdentityRegistryEventsAndErrors.InvalidSignature.selector);
    registry.switchAddress(identityId, address(vault), nonce, expiry, hex'deadbeef');

    assertEq(registry.registeredAddress(identityId), user);
  }

  /// @dev The registry does not track the vault, so the vault's address CAN be registered (it
  ///      takes a backend signature). EarnVaultV2 is what refuses to credit principal to itself,
  ///      and it fails the whole batch closed - nothing moves.
  function test_E2E_VaultAddressRegisteredAsPayoutTarget_OnBoostCreditRejectsIt() public {
    bytes32 identityId = keccak256('identity-1');
    uint256 nonce = registry.nonces(identityId);
    uint64 expiry = uint64(block.timestamp + 1 hours);
    bytes32 structHash = keccak256(abi.encode(registry.REGISTER_TYPEHASH(), identityId, address(vault), nonce, expiry));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendSignerKey, _digest(structHash));
    registry.register(identityId, address(vault), nonce, expiry, abi.encodePacked(r, s, v));
    assertEq(registry.registeredAddress(identityId), address(vault));

    usdsc.mint(address(vault), 100e6);
    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.IdentityNotRegistered.selector);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(address(vault)), 0);
    assertEq(vault.totalPrincipal(), 0);
    assertEq(vault.lastCreditedCycle(identityId), 0);
  }
}
