// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {EarnVaultV3FromV2} from '../mocks/EarnVaultV3FromV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

/// @title V1 -> V2 -> V3 upgrade path on the current EarnVaultV2
/// @notice Builds V1 state, upgrades to EarnVaultV2 and uses it (deposits, yield, boost reward, boost
///         credit, compounding), then upgrades the same proxy to EarnVaultV3FromV2 - a V3 that
///         inherits the current V2. Every piece of user and vault state must be identical across the
///         V2 -> V3 upgrade, V3's own storage must not touch V2's, and onBoostReward can be retired
///         while onBoostCredit and already-owed boost rewards keep working.
contract EarnVaultV3UpgradePathTest is Test {
  EarnVaultV2 vault;
  MockUSDSC usdsc;
  ProxyAdmin proxyAdmin;
  address proxy;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address redistributor = makeAddr('redistributor');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address boostRewardKeeper = makeAddr('boostRewardKeeper');
  address boostKeeper = makeAddr('boostKeeper');

  address legacyUser = makeAddr('legacyUser'); // V1 `accrued` balance
  address passiveUser = makeAddr('passiveUser'); // never settled before the upgrades
  address alice = makeAddr('alice'); // V2 depositor, credited boost
  address bob = makeAddr('bob'); // V2 depositor
  address[] users;

  uint256 constant CAP = 10_000e6;
  bytes32 constant EARN_VAULT_STORAGE = 0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;
  bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
  bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

  function setUp() public {
    usdsc = new MockUSDSC();
    proxy = address(
      new TransparentUpgradeableProxy(
        address(new EarnVaultUpgradeable()),
        admin,
        abi.encodeWithSelector(
          EarnVaultUpgradeable.initialize.selector,
          address(usdsc),
          owner,
          redistributor,
          treasury,
          pauser,
          boostRewardKeeper
        )
      )
    );
    proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));
    users = [legacyUser, passiveUser, alice, bob];
    for (uint256 i = 0; i < users.length; i++) {
      usdsc.mint(users[i], 100_000e6);
      vm.prank(users[i]);
      usdsc.approve(proxy, type(uint256).max);
    }

    // --- V1 state ---
    EarnVaultUpgradeable v1 = EarnVaultUpgradeable(payable(proxy));
    vm.prank(legacyUser);
    v1.deposit(1000e6);
    _yield(300e6);
    vm.prank(legacyUser);
    v1.deposit(1e6); // settles under V1: owed moves into `accrued`
    vm.prank(passiveUser);
    v1.deposit(2000e6);
    _yield(400e6);
    _boostReward(50e6); // USDSC boost owed across V1 depositors

    // --- V2 ---
    address v2Impl = address(new EarnVaultV2());
    bytes memory init2 = abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, CAP));
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), v2Impl, init2);
    vault = EarnVaultV2(payable(proxy));

    // --- V2 activity ---
    vm.prank(alice);
    vault.deposit(5000e6);
    vm.prank(bob);
    vault.deposit(3000e6);
    _yield(200e6);
    _boostReward(50e6);
    _credit(1, alice, 25e6);
    address[] memory batch = new address[](1);
    batch[0] = bob;
    vault.compoundMany(batch);
    _yield(100e6); // pending yield left unsettled across the upgrade
  }

  // ---------------------------------------------------------------------------------------------
  // State is identical across V2 -> V3
  // ---------------------------------------------------------------------------------------------

  function test_UpgradeToV3_PreservesEveryUserAndVaultValue() public {
    bytes memory before = _state();
    _upgradeToV3(42, false);
    assertEq(_state(), before, 'state changed across the V2 -> V3 upgrade');
    assertEq(EarnVaultV3FromV2(payable(proxy)).newSetting(), 42);
  }

  function test_UpgradeToV3_RetiringBoostRewardChangesOnlyTheKeeper() public {
    bytes memory before = _state();
    _upgradeToV3(42, true);
    assertEq(_state(), before, 'retiring onBoostReward changed other state');
    assertEq(_boostRewardKeeper(), address(0));
    assertEq(vault.boostKeeper(), boostKeeper, 'onBoostCredit keeper untouched');
  }

  /// @dev V3's namespace is the ERC-7201 slot of its own id, so it cannot overlap V2's storage
  function test_V3StorageIsItsOwnErc7201Namespace() public {
    bytes32 expected =
      keccak256(abi.encode(uint256(keccak256('startale.storage.EarnVaultV3')) - 1)) & ~bytes32(uint256(0xff));
    assertEq(new EarnVaultV3FromV2().EARN_VAULT_V3_STORAGE_LOCATION(), expected);
    assertTrue(expected != EARN_VAULT_STORAGE);
  }

  // ---------------------------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------------------------

  function test_UpgradeToV3_VersionAndInitializersLocked() public {
    _upgradeToV3(42, false);
    assertEq(vault.getVersion(), 'EarnVaultV3');
    assertEq(uint64(uint256(vm.load(proxy, INITIALIZABLE_SLOT))), 3);

    address impl = address(new EarnVaultV3FromV2());
    bytes memory again3 = abi.encodeCall(EarnVaultV3FromV2.initializeV3, (7, false));
    vm.prank(admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, again3);

    bytes memory again2 = abi.encodeCall(EarnVaultV2.initializeV2, (owner, CAP));
    vm.prank(admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, again2);
  }

  /// @dev Only the ProxyAdmin, inside upgradeAndCall, can run initializeV3 - not the owner, not anyone
  function test_InitializeV3_OnlyFromProxyAdmin() public {
    address impl = address(new EarnVaultV3FromV2());
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, '');
    assertEq(uint64(uint256(vm.load(proxy, INITIALIZABLE_SLOT))), 2, 'upgraded but not initialized');

    vm.prank(owner);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    EarnVaultV3FromV2(payable(proxy)).initializeV3(1, true);
    assertEq(_boostRewardKeeper(), boostRewardKeeper);
  }

  // ---------------------------------------------------------------------------------------------
  // Boost entry points after V3: retire onBoostReward, keep onBoostCredit
  // ---------------------------------------------------------------------------------------------

  function test_AfterRetire_OnBoostRewardClosed_OwnerCanReenable() public {
    _upgradeToV3(0, true);
    usdsc.mint(proxy, 50e6);
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.NotBoostRewardKeeper.selector);
    vault.onBoostReward(address(usdsc), 50e6);

    // reversible: the owner can appoint a keeper again
    vm.prank(owner);
    vault.setBoostRewardKeeper(boostRewardKeeper);
    vm.prank(boostRewardKeeper);
    vault.onBoostReward(address(usdsc), 50e6);
    _assertSolvent();
  }

  function test_AfterRetire_OnBoostCreditContinuesNextCycle() public {
    _upgradeToV3(0, true);
    uint256 before = vault.principal(bob) + vault.pendingYield(bob);
    _credit(2, bob, 30e6);
    assertEq(vault.principal(bob), before + 30e6);
    assertEq(vault.latestCycleId(), 2);
    _assertSolvent();
  }

  /// @dev Boost rewards owed before retirement are still paid, and every position exits whole
  function test_AfterRetire_OwedBoostStillPaid_EveryoneExitsWhole() public {
    uint256[] memory owed = new uint256[](users.length);
    for (uint256 i = 0; i < users.length; i++) {
      owed[i] = vault.totalValue(users[i]) + vault.getClaimableBoostReward(users[i], address(usdsc));
    }
    assertGt(vault.getClaimableBoostReward(legacyUser, address(usdsc)), 0, 'boost owed before the upgrade');

    _upgradeToV3(0, true);

    for (uint256 i = 0; i < users.length; i++) {
      uint256 bal = usdsc.balanceOf(users[i]);
      vm.prank(users[i]);
      vault.withdrawAll();
      assertEq(usdsc.balanceOf(users[i]) - bal, owed[i], 'not paid in full');
      assertEq(vault.totalValue(users[i]), 0);
      assertEq(vault.getClaimableBoostReward(users[i], address(usdsc)), 0);
    }
    assertEq(vault.totalPrincipal(), 0);
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------

  function _upgradeToV3(uint256 setting, bool retire) internal {
    address impl = address(new EarnVaultV3FromV2());
    bytes memory init3 = abi.encodeCall(EarnVaultV3FromV2.initializeV3, (setting, retire));
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, init3);
  }

  /// @dev Every user- and vault-level value V2 exposes, except boostRewardKeeper (compared separately)
  function _state() internal view returns (bytes memory s) {
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      s = abi.encode(
        s,
        vault.principal(u),
        vault.pendingYield(u),
        vault.accrued(u),
        vault.userIndex(u),
        vault.totalValue(u),
        vault.getClaimableBoostReward(u, address(usdsc)),
        vault.lastCreditedCycle(u),
        vault.isBlacklisted(u)
      );
    }
    s = abi.encode(
      s,
      vault.totalPrincipal(),
      vault.claimReserve(),
      vault.boostClaimReserve(address(usdsc)),
      vault.globalIndex(),
      vault.surplusUSDSC(),
      usdsc.balanceOf(proxy)
    );
    s = abi.encode(
      s,
      vault.latestCycleId(),
      vault.boostKeeper(),
      vault.maxBoostPerBatch(),
      vault.owner(),
      vault.pauser(),
      vault.treasury(),
      vault.yieldRedistributor(),
      vault.paused()
    );
  }

  function _boostRewardKeeper() internal view returns (address) {
    return address(uint160(uint256(vm.load(proxy, bytes32(uint256(EARN_VAULT_STORAGE) + 2)))));
  }

  function _yield(uint256 amount) internal {
    usdsc.mint(proxy, amount);
    vm.prank(redistributor);
    EarnVaultUpgradeable(payable(proxy)).onYield(amount);
  }

  function _boostReward(uint256 amount) internal {
    usdsc.mint(proxy, amount);
    vm.prank(boostRewardKeeper);
    EarnVaultUpgradeable(payable(proxy)).onBoostReward(address(usdsc), amount);
  }

  function _credit(uint256 cycleId, address user, uint256 amount) internal {
    address[] memory u = new address[](1);
    uint256[] memory a = new uint256[](1);
    (u[0], a[0]) = (user, amount);
    usdsc.mint(proxy, amount);
    vm.prank(boostKeeper);
    vault.onBoostCredit(cycleId, u, a);
  }

  function _assertSolvent() internal view {
    assertGe(
      usdsc.balanceOf(proxy), vault.claimReserve() + vault.boostClaimReserve(address(usdsc)), 'vault under-reserved'
    );
  }
}
