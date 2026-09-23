// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IdentityRegistry} from '../../src/identity/IdentityRegistry.sol';
import {IIdentityRegistryEventsAndErrors} from '../../src/interfaces/identity/IIdentityRegistryEventsAndErrors.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
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

  function _switchAddress(bytes32 identityId, address oldAddr, address newAddr) internal {
    vm.prank(oldAddr);
    registry.switchAddress(identityId, newAddr);
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
    address newAddr = makeAddr('newAddr');
    _switchAddress(identityId, oldAddr, newAddr);

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

  function _creditOne(bytes32 identityId, uint256 cycleId, uint256 amount) internal {
    usdsc.mint(address(vault), amount);
    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    vm.prank(boostKeeper);
    vault.onBoostCredit(cycleId, ids, amounts);
  }

  function _twoEntryBatch(
    bytes32 a,
    bytes32 b,
    uint256 amount
  ) internal returns (bytes32[] memory ids, uint256[] memory amounts) {
    usdsc.mint(address(vault), 2 * amount);
    ids = new bytes32[](2);
    ids[0] = a;
    ids[1] = b;
    amounts = new uint256[](2);
    amounts[0] = amount;
    amounts[1] = amount;
  }

  /// @dev A user can switchAddress() to the vault's own address (no consent check on newAddr).
  ///      onBoostCredit() skips that entry and still credits everyone else in the same batch.
  function test_E2E_UserSwitchesToVaultAddress_EntrySkippedRestOfBatchCredited() public {
    bytes32 honestId = keccak256('honest');
    bytes32 griefId = keccak256('griefer');
    address honest = makeAddr('honest');
    address griefer = makeAddr('griefer');
    _register(honestId, honest);
    _register(griefId, griefer);
    vm.warp(block.timestamp + SWITCH_COOLDOWN);

    _switchAddress(griefId, griefer, address(vault));
    assertEq(registry.registeredAddress(griefId), address(vault));

    (bytes32[] memory ids, uint256[] memory amounts) = _twoEntryBatch(honestId, griefId, 10e6);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCreditSkipped(griefId, address(vault), 10e6, 1, EarnVaultV2.BoostSkipReason.VaultAddress);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(honest), 10e6);
    assertEq(vault.principal(address(vault)), 0);
    assertEq(vault.lastCreditedCycle(griefId), 0);
  }

  /// @dev An address blacklisted after it was bound (ordinary operations, no griefing needed) -
  ///      its entry is skipped and the honest entry in the same batch is credited.
  function test_E2E_BoundAddressLaterBlacklisted_EntrySkippedRestOfBatchCredited() public {
    bytes32 honestId = keccak256('honest');
    bytes32 laterId = keccak256('later-blacklisted');
    address honest = makeAddr('honest');
    address later = makeAddr('later-blacklisted');
    _register(honestId, honest);
    _register(laterId, later);
    vm.prank(owner);
    vault.setBlacklisted(later, true);

    (bytes32[] memory ids, uint256[] memory amounts) = _twoEntryBatch(honestId, laterId, 10e6);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCreditSkipped(laterId, later, 10e6, 1, EarnVaultV2.BoostSkipReason.Blacklisted);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(honest), 10e6);
    assertEq(vault.principal(later), 0);
  }

  /// @dev Same outcome when a user deliberately switches to a blacklisted (unbound) address.
  function test_E2E_UserSwitchesToBlacklistedAddress_EntrySkippedRestOfBatchCredited() public {
    bytes32 honestId = keccak256('honest');
    bytes32 griefId = keccak256('griefer');
    address honest = makeAddr('honest');
    address griefer = makeAddr('griefer');
    address blacklisted = makeAddr('blacklisted');
    _register(honestId, honest);
    _register(griefId, griefer);
    vm.prank(owner);
    vault.setBlacklisted(blacklisted, true);
    vm.warp(block.timestamp + SWITCH_COOLDOWN);

    _switchAddress(griefId, griefer, blacklisted);

    (bytes32[] memory ids, uint256[] memory amounts) = _twoEntryBatch(honestId, griefId, 10e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(honest), 10e6);
    assertEq(vault.principal(blacklisted), 0);
  }

  /// @dev The registry does not track the vault, so the vault's address CAN be registered (by a
  ///      backend-signed register, or by any user via switchAddress - see above). EarnVaultV2
  ///      refuses to credit principal to itself: the entry is skipped and nothing moves.
  function test_E2E_VaultAddressRegisteredAsPayoutTarget_OnBoostCreditSkipsIt() public {
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

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCycleCredited(1, 1, 100e6, 1, 100e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(address(vault)), 0);
    assertEq(vault.totalPrincipal(), 0);
    assertEq(vault.claimReserve(), 0);
    assertEq(vault.lastCreditedCycle(identityId), 0);
  }
}
