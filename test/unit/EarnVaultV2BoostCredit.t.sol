// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'lib/forge-std/src/Test.sol';
import {Ownable} from 'lib/openzeppelin-contracts/contracts/access/Ownable.sol';

/// @dev Minimal stand-in for a future V3 using reinitializer(3) - no new state, just proves the
///      next reinitializer still runs from any EarnVaultV2 initialization state.
contract EarnVaultV3ReinitMock is EarnVaultV2 {
  event V3Initialized();

  function initializeV3() public reinitializer(3) {
    emit V3Initialized();
  }
}

contract EarnVaultV2BoostCreditTest is Test {
  EarnVaultV2 public vault;
  MockUSDSC public usdsc;

  address public admin = makeAddr('admin');
  address public owner = makeAddr('owner');
  address public redistributor = makeAddr('redistributor');
  address public treasury = makeAddr('treasury');
  address public pauser = makeAddr('pauser');
  address public operator = makeAddr('operator');
  address public boostKeeper = makeAddr('boostKeeper');

  function setUp() public virtual {
    usdsc = new MockUSDSC();

    EarnVaultUpgradeable v1Implementation = new EarnVaultUpgradeable();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(v1Implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
      )
    );

    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    address proxyAdminAddress = address(uint160(uint256(vm.load(address(proxy), adminSlot))));
    ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddress);

    EarnVaultV2 v2Implementation = new EarnVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector, boostKeeper)
    );

    vault = EarnVaultV2(payable(address(proxy)));
  }

  function test_InitializeV2_SetsBoostCreditState() public view {
    assertEq(vault.boostKeeper(), boostKeeper);
  }

  /// @dev Deploys a fresh V1 proxy and upgrades it to V2 WITHOUT calling initializeV2 - the
  ///      operator mistake the ProxyAdmin gate on initializeV2 exists to make harmless.
  function _upgradeWithoutInit() internal returns (EarnVaultV2 v2, ProxyAdmin pa, address impl) {
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
      )
    );
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    pa = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), adminSlot)))));
    impl = address(new EarnVaultV2());
    vm.prank(admin);
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), impl, '');
    v2 = EarnVaultV2(payable(address(proxy)));
  }

  function test_InitializeV2_RevertsWhenCalledDirectlyAfterUpgradeWithoutInit() public {
    (EarnVaultV2 v2,,) = _upgradeWithoutInit();
    address attacker = makeAddr('attacker');

    vm.prank(attacker);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    v2.initializeV2(attacker);

    // not even the vault owner can - only the ProxyAdmin, via upgradeAndCall
    vm.prank(owner);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    v2.initializeV2(boostKeeper);

    assertEq(v2.boostKeeper(), address(0));
  }

  function test_InitializeV2_UpgradeWithoutInitIsInertThenRecoverableViaUpgradeAndCall() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();

    // uninitialized boost credit is inert: boostKeeper is address(0), no caller can match it
    address[] memory users = new address[](0);
    uint256[] memory amounts = new uint256[](0);
    vm.prank(makeAddr('attacker'));
    vm.expectRevert(EarnVaultV2.NotBoostKeeper.selector);
    v2.onBoostCredit(1, users, amounts);

    assertEq(_initializedVersion(address(v2)), 1, 'reinitializer(2) not consumed yet');

    // proper recovery: repeat upgradeAndCall to the SAME implementation, this time with the init call
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)), impl, abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper))
    );
    assertEq(v2.boostKeeper(), boostKeeper);
    assertEq(_initializedVersion(address(v2)), 2, 'proper recovery consumes reinitializer(2)');
  }

  /// @dev OZ v5 Initializable's ERC-7201 slot; `_initialized` (uint64) is its low 8 bytes.
  bytes32 internal constant OZ_INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

  function _initializedVersion(address proxy) internal view returns (uint64) {
    return uint64(uint256(vm.load(proxy, OZ_INITIALIZABLE_SLOT)));
  }

  /// @dev Stopgap recovery (owner sets the keeper directly) makes boost credit work but does NOT
  ///      consume reinitializer(2): the version stays 1, and initializeV2 remains runnable - only by
  ///      the ProxyAdmin via upgradeAndCall, overwriting the keeper - after which it is locked.
  function test_InitializeV2Gate_SetBoostKeeperStopgapLeavesReinitializerUnconsumed() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();
    address stopgapKeeper = makeAddr('stopgapKeeper');
    vm.prank(owner);
    v2.setBoostKeeper(stopgapKeeper);
    assertEq(v2.boostKeeper(), stopgapKeeper);
    assertEq(_initializedVersion(address(v2)), 1, 'stopgap leaves the version gap');

    // boost credit works under the stopgap keeper
    address user = makeAddr('user1');
    usdsc.mint(address(v2), 10e6);
    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 10e6;
    vm.prank(stopgapKeeper);
    v2.onBoostCredit(1, users, amounts);
    assertEq(v2.principal(user), 10e6);

    // nobody but the ProxyAdmin can use the unconsumed reinitializer...
    vm.prank(owner);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    v2.initializeV2(owner);

    // ...and when it does (via upgradeAndCall to the same impl), it overwrites the keeper, then locks
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)), impl, abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper))
    );
    assertEq(v2.boostKeeper(), boostKeeper);
    assertEq(_initializedVersion(address(v2)), 2);

    vm.prank(admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)), impl, abi.encodeCall(EarnVaultV2.initializeV2, (owner))
    );
  }

  /// @dev The version gap is not a trap: a future V3 using reinitializer(3) still initializes from
  ///      the stopgap state (version 1), after which initializeV2 can never run.
  function test_InitializeV2Gate_FutureReinitializer3WorksFromStopgapState() public {
    (EarnVaultV2 v2, ProxyAdmin pa,) = _upgradeWithoutInit();
    vm.prank(owner);
    v2.setBoostKeeper(boostKeeper);

    address v3Impl = address(new EarnVaultV3ReinitMock());
    vm.expectEmit(address(v2));
    emit EarnVaultV3ReinitMock.V3Initialized();
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)), v3Impl, abi.encodeCall(EarnVaultV3ReinitMock.initializeV3, ())
    );

    assertEq(_initializedVersion(address(v2)), 3);
    assertEq(v2.boostKeeper(), boostKeeper, 'stopgap keeper survives');

    vm.prank(admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)), v3Impl, abi.encodeCall(EarnVaultV2.initializeV2, (owner))
    );
  }

  /// @dev ...and from the normal, fully initialized state (version 2): reinitializer(3) runs,
  ///      boostKeeper is untouched, and initializeV2 stays locked.
  function test_InitializeV2Gate_FutureReinitializer3WorksFromFullyInitializedState() public {
    address proxy = address(vault);
    assertEq(_initializedVersion(proxy), 2);
    ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));

    address v3Impl = address(new EarnVaultV3ReinitMock());
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(proxy), v3Impl, abi.encodeCall(EarnVaultV3ReinitMock.initializeV3, ())
    );

    assertEq(_initializedVersion(proxy), 3);
    assertEq(vault.boostKeeper(), boostKeeper);
  }

  /// @dev The gate's premise: the ProxyAdmin (the only accepted caller) cannot reach initializeV2
  ///      through the proxy except via upgradeToAndCall - the proxy itself rejects it.
  function test_InitializeV2_ProxyAdminCannotCallItOutsideUpgradeAndCall() public {
    (EarnVaultV2 v2, ProxyAdmin pa,) = _upgradeWithoutInit();
    vm.prank(address(pa));
    vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
    v2.initializeV2(boostKeeper);
  }

  function test_InitializeV2_CannotRunTwiceEvenViaUpgradeAndCall() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();
    bytes memory initData = abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper));
    vm.prank(admin);
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(v2)), impl, initData);

    address attackerKeeper = makeAddr('attackerKeeper');
    vm.prank(admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)), impl, abi.encodeCall(EarnVaultV2.initializeV2, (attackerKeeper))
    );
    assertEq(v2.boostKeeper(), boostKeeper);
  }

  function test_InitializeV2_RevertsOnZeroBoostKeeper() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();
    vm.prank(admin);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)), impl, abi.encodeCall(EarnVaultV2.initializeV2, (address(0)))
    );
  }

  function _v1InitData() internal view returns (bytes memory) {
    return abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
    );
  }

  /// @dev Fresh deploy (no V1 history): OZ v5's TransparentUpgradeableProxy runs its constructor
  ///      calldata BEFORE it creates the ProxyAdmin and writes the admin slot, so initializeV2
  ///      cannot be passed there - it reverts NotProxyAdmin and the deploy fails loudly.
  function test_InitializeV2_FreshProxy_CannotRunInConstructorData() public {
    address impl = address(new EarnVaultV2());
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    new TransparentUpgradeableProxy(impl, admin, abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper)));
  }

  /// @dev The supported fresh-deploy path: construct the proxy with the base initialize(), then
  ///      ProxyAdmin.upgradeAndCall to the SAME implementation with initializeV2.
  function test_InitializeV2_FreshProxy_InitializeThenUpgradeAndCallToSameImpl() public {
    address impl = address(new EarnVaultV2());
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(impl, admin, _v1InitData());
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), adminSlot)))));
    EarnVaultV2 v2 = EarnVaultV2(payable(address(proxy)));
    assertEq(v2.owner(), owner);
    assertEq(v2.boostKeeper(), address(0));

    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)), impl, abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper))
    );
    assertEq(v2.boostKeeper(), boostKeeper);
  }

  /// @dev Behind a proxy with NO ERC-1967 admin (the UUPS shape: plain ERC1967Proxy), the admin
  ///      slot is zero, so initializeV2 rejects every caller - even the owner. Pins the current
  ///      Transparent-proxy behaviour: changing the gate (e.g. for UUPS) must update this test. It
  ///      does not by itself detect a proxy migration.
  function test_InitializeV2_ProxyWithoutAdmin_RejectsEvenOwner() public {
    ERC1967Proxy proxy = new ERC1967Proxy(address(new EarnVaultV2()), _v1InitData());
    EarnVaultV2 v2 = EarnVaultV2(payable(address(proxy)));
    assertEq(vm.load(address(proxy), bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1)), bytes32(0));

    vm.prank(owner);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    v2.initializeV2(boostKeeper);
  }

  // ---------------------------------------------------------------------------------------------
  // initializeV2 gate - exhaustive cases. The gate is the only thing standing between an operator
  // mistake and an attacker minting unlimited principal, so every path is pinned here.
  // ---------------------------------------------------------------------------------------------

  bytes32 internal constant IMPL_SLOT = bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1);
  bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);

  /// @dev A live V1 proxy (not yet upgraded) whose ProxyAdmin is owned by `proxyAdminOwner`.
  function _deployV1(address proxyAdminOwner) internal returns (TransparentUpgradeableProxy proxy, ProxyAdmin pa) {
    proxy = new TransparentUpgradeableProxy(address(new EarnVaultUpgradeable()), proxyAdminOwner, _v1InitData());
    pa = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
  }

  function _initData(address keeper) internal pure returns (bytes memory) {
    return abi.encodeCall(EarnVaultV2.initializeV2, (keeper));
  }

  /// @dev Root of trust: upgradeAndCall is ProxyAdmin-owner-only, so a stranger cannot use the
  ///      one path that reaches initializeV2.
  function test_InitializeV2Gate_StrangerCannotUseProxyAdminUpgradeAndCall() public {
    (TransparentUpgradeableProxy proxy, ProxyAdmin pa) = _deployV1(admin);
    address stranger = makeAddr('stranger');
    address impl = address(new EarnVaultV2());

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), impl, _initData(stranger));

    assertEq(EarnVaultV2(payable(address(proxy))).getVersion(), 'EarnVaultV1');
  }

  /// @dev Any caller other than the ProxyAdmin - including the vault owner, the ProxyAdmin's own
  ///      owner, the proxy itself and address(0) - is rejected in the uninitialized window.
  function testFuzz_InitializeV2Gate_RejectsEveryDirectCallerInUninitializedWindow(address caller) public {
    (EarnVaultV2 v2, ProxyAdmin pa,) = _upgradeWithoutInit();
    vm.assume(caller != address(pa));

    vm.prank(caller);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    v2.initializeV2(caller);
    assertEq(v2.boostKeeper(), address(0));
  }

  function test_InitializeV2Gate_RejectsNamedPrivilegedCallersInUninitializedWindow() public {
    (EarnVaultV2 v2,,) = _upgradeWithoutInit();
    address[5] memory callers = [owner, admin, pauser, operator, boostKeeper];
    for (uint256 i = 0; i < callers.length; i++) {
      vm.prank(callers[i]);
      vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
      v2.initializeV2(callers[i]);
    }
    assertEq(v2.boostKeeper(), address(0));
  }

  /// @dev After a successful upgrade+init, nobody can re-run it by any route.
  function test_InitializeV2Gate_LockedForEveryoneAfterSuccessfulInit() public {
    address[3] memory callers = [makeAddr('attacker'), owner, admin];
    for (uint256 i = 0; i < callers.length; i++) {
      vm.prank(callers[i]);
      vm.expectRevert(Initializable.InvalidInitialization.selector);
      vault.initializeV2(callers[i]);
    }
    address pa = address(uint160(uint256(vm.load(address(vault), ADMIN_SLOT))));
    vm.prank(pa);
    vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
    vault.initializeV2(pa);

    assertEq(vault.boostKeeper(), boostKeeper);
  }

  /// @dev Atomicity: if initializeV2 reverts inside upgradeAndCall, the upgrade itself rolls back -
  ///      the proxy is still exactly V1, not a half-upgraded V2 with no keeper.
  function test_InitializeV2Gate_RevertingInitRollsBackTheWholeUpgrade() public {
    (TransparentUpgradeableProxy proxy, ProxyAdmin pa) = _deployV1(admin);
    address v1Impl = address(uint160(uint256(vm.load(address(proxy), IMPL_SLOT))));
    address v2Impl = address(new EarnVaultV2());

    vm.prank(admin);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), v2Impl, _initData(address(0)));

    assertEq(address(uint160(uint256(vm.load(address(proxy), IMPL_SLOT)))), v1Impl);
    assertEq(EarnVaultV2(payable(address(proxy))).getVersion(), 'EarnVaultV1');
  }

  /// @dev Upgrade-without-init only disables boost credit; the vault itself keeps working.
  /// @dev Backs "the rest of the vault works": deposit, yield indexing, compounding and
  ///      withdrawal all behave normally while boost credit is uninitialized.
  function test_InitializeV2Gate_UninitializedVaultStillDepositsIndexesYieldCompoundsAndWithdraws() public {
    (EarnVaultV2 v2,,) = _upgradeWithoutInit();
    address user = makeAddr('depositor');
    usdsc.mint(user, 500e6);

    vm.startPrank(user);
    usdsc.approve(address(v2), 500e6);
    v2.deposit(500e6);
    vm.stopPrank();
    assertEq(v2.principal(user), 500e6);

    usdsc.mint(address(v2), 10e6);
    vm.prank(redistributor);
    v2.onYield(10e6);
    assertApproxEqAbs(v2.pendingYield(user), 10e6, 1);

    v2.compound(user);
    assertApproxEqAbs(v2.principal(user), 510e6, 1);
    assertEq(v2.pendingYield(user), 0);

    vm.prank(user);
    v2.withdraw(200e6);
    assertApproxEqAbs(v2.principal(user), 310e6, 1);
    assertEq(usdsc.balanceOf(user), 200e6);
    assertEq(v2.boostKeeper(), address(0));
  }

  /// @dev Second recovery path from upgrade-without-init: the vault owner configures boost credit
  ///      through the existing owner-only setters. An attacker cannot use them.
  function test_InitializeV2Gate_UninitializedVaultCanBeConfiguredByOwnerSettersOnly() public {
    (EarnVaultV2 v2,,) = _upgradeWithoutInit();
    address attacker = makeAddr('attacker');

    vm.startPrank(attacker);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
    v2.setBoostKeeper(attacker);
    vm.stopPrank();

    vm.startPrank(owner);
    v2.setBoostKeeper(boostKeeper);
    vm.stopPrank();

    address user = makeAddr('user1');
    usdsc.mint(address(v2), 100e6);
    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;
    vm.prank(boostKeeper);
    v2.onBoostCredit(1, users, amounts);
    assertEq(v2.principal(user), 100e6);
  }

  /// @dev The exact front-run the gate exists for: attacker races the uninitialized window, fails,
  ///      and the legitimate upgradeAndCall afterwards installs the real keeper, not the attacker.
  function test_InitializeV2Gate_FrontRunAttemptFailsThenLegitimateInitWins() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();
    address attacker = makeAddr('attacker');

    vm.prank(attacker);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    v2.initializeV2(attacker);

    vm.prank(admin);
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(v2)), impl, _initData(boostKeeper));

    assertEq(v2.boostKeeper(), boostKeeper);

    address[] memory users = new address[](0);
    uint256[] memory amounts = new uint256[](0);
    vm.prank(attacker);
    vm.expectRevert(EarnVaultV2.NotBoostKeeper.selector);
    v2.onBoostCredit(1, users, amounts);
  }

  /// @dev The reviewer's original scenario: one key owns both the ProxyAdmin and the vault. The
  ///      admin-slot gate still works (an owner() gate would have reverted here too).
  function test_InitializeV2Gate_WorksWhenSameKeyOwnsProxyAdminAndVault() public {
    (TransparentUpgradeableProxy proxy, ProxyAdmin pa) = _deployV1(owner);
    assertEq(pa.owner(), owner);
    assertEq(EarnVaultV2(payable(address(proxy))).owner(), owner);

    // deploy BEFORE the prank - an inline `new` in the args would consume it
    address impl = address(new EarnVaultV2());
    vm.prank(owner);
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), impl, _initData(boostKeeper));
    assertEq(EarnVaultV2(payable(address(proxy))).boostKeeper(), boostKeeper);
  }

  /// @dev ProxyAdmin ownership moved (e.g. to a multisig): the gate keys on the ProxyAdmin
  ///      contract, not on who owns it, so the new owner can upgrade+init and the old one cannot.
  function test_InitializeV2Gate_FollowsProxyAdminOwnershipTransfer() public {
    (TransparentUpgradeableProxy proxy, ProxyAdmin pa) = _deployV1(admin);
    address multisig = makeAddr('multisig');
    vm.prank(admin);
    pa.transferOwnership(multisig);
    address impl = address(new EarnVaultV2());

    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), impl, _initData(boostKeeper));

    vm.prank(multisig);
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), impl, _initData(boostKeeper));
    assertEq(EarnVaultV2(payable(address(proxy))).boostKeeper(), boostKeeper);
  }

  function test_InitializeV2_ImplementationContractCannotBeInitialized() public {
    EarnVaultV2 impl = new EarnVaultV2();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    impl.initializeV2(boostKeeper);
  }

  /// @dev BOOST_CREDIT_STORAGE_LOCATION is a hand-pasted hash and private - recompute the
  ///      ERC-7201 formula here and check the struct's fields actually live there: boostKeeper at
  ///      the base slot, lastCreditedCycle mapping at base + 1.
  function test_BoostCreditStorage_MatchesErc7201Location() public {
    bytes32 expected = keccak256(abi.encode(uint256(keccak256('startale.storage.EarnVaultV2.BoostCredit')) - 1))
      & ~bytes32(uint256(0xff));
    assertEq(address(uint160(uint256(vm.load(address(vault), expected)))), boostKeeper);

    address user = makeAddr('user1');
    usdsc.mint(address(vault), 1e6);
    (address[] memory users, uint256[] memory amounts) = _batch1(user, 1e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    bytes32 mappingSlot = keccak256(abi.encode(user, uint256(expected) + 1));
    assertEq(uint256(vm.load(address(vault), mappingSlot)), 1);
  }

  function test_SetBoostKeeper_UpdatesStateAndEmits() public {
    address newKeeper = makeAddr('newKeeper');
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostKeeperChanged(owner, boostKeeper, newKeeper);
    vm.prank(owner);
    vault.setBoostKeeper(newKeeper);
    assertEq(vault.boostKeeper(), newKeeper);
  }

  function test_SetBoostKeeper_RevertsForNonOwner() public {
    vm.prank(makeAddr('rando'));
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr('rando')));
    vault.setBoostKeeper(makeAddr('newKeeper'));
  }

  function test_SetBoostKeeper_RevertsOnZeroAddress() public {
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.setBoostKeeper(address(0));
  }

  function test_OnBoostCredit_CreditsPrincipalForSingleAddress() public {
    address user = makeAddr('user1');

    uint256 amount = 100e6;
    usdsc.mint(address(vault), amount);

    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCredited(user, amount, 1);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(user), amount);
    assertEq(vault.totalPrincipal(), amount);
    assertEq(vault.claimReserve(), amount);
    assertEq(vault.lastCreditedCycle(user), 1);
  }

  function test_OnBoostCredit_CreditsMultipleAddressesInOneBatch() public {
    address userA = makeAddr('userA');
    address userB = makeAddr('userB');

    uint256 amountA = 50e6;
    uint256 amountB = 75e6;
    usdsc.mint(address(vault), amountA + amountB);

    address[] memory users = new address[](2);
    users[0] = userA;
    users[1] = userB;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = amountA;
    amounts[1] = amountB;

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(userA), amountA);
    assertEq(vault.principal(userB), amountB);
    assertEq(vault.totalPrincipal(), amountA + amountB);
  }

  /// @dev Address-keyed crediting works for any non-zero, non-vault, non-blacklisted address the
  ///      keeper passes (AA wallet or not - eligibility policy lives off-chain in the backend).
  function testFuzz_OnBoostCredit_CreditsArbitraryAddress(address user, uint96 amount) public {
    vm.assume(user != address(0) && user != address(vault));
    vm.assume(amount > 0); // zero amounts are skipped (tested separately)
    uint256 cycleId = 1;
    usdsc.mint(address(vault), amount);
    (address[] memory users, uint256[] memory amounts) = _batch1(user, amount);

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCredited(user, amount, cycleId);
    vm.prank(boostKeeper);
    vault.onBoostCredit(cycleId, users, amounts);

    assertEq(vault.principal(user), amount);
    assertEq(vault.lastCreditedCycle(user), cycleId);
    assertEq(vault.claimReserve(), amount);
  }

  function test_OnBoostCredit_RevertsForNonBoostKeeper() public {
    address[] memory users = new address[](0);
    uint256[] memory amounts = new uint256[](0);
    vm.prank(makeAddr('rando'));
    vm.expectRevert(EarnVaultV2.NotBoostKeeper.selector);
    vault.onBoostCredit(1, users, amounts);
  }

  function test_OnBoostCredit_RevertsOnLengthMismatch() public {
    address[] memory users = new address[](2);
    uint256[] memory amounts = new uint256[](1);
    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.LengthMismatch.selector);
    vault.onBoostCredit(1, users, amounts);
  }

  function test_OnBoostCredit_RevertsWholeBatchOnInsufficientBalance() public {
    address user = makeAddr('user1');

    // fund less than the batch total
    usdsc.mint(address(vault), 10e6);

    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(user), 0);
  }

  /// @dev No registry guarantees a non-zero address any more, so the vault checks it itself: a
  ///      zero address is malformed keeper input and reverts the WHOLE batch.
  function test_OnBoostCredit_RevertsWholeBatchOnZeroAddress() public {
    address user = makeAddr('user1');
    usdsc.mint(address(vault), 200e6);
    (address[] memory users, uint256[] memory amounts) = _batch2(user, 100e6, address(0), 100e6);

    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.onBoostCredit(1, users, amounts);

    // whole batch reverted - not even the first, valid entry is credited
    assertEq(vault.principal(user), 0);
    assertEq(vault.lastCreditedCycle(user), 0);
  }

  function test_OnBoostCredit_RevertsOnStaleCycleForSameAddress() public {
    address user = makeAddr('user1');
    usdsc.mint(address(vault), 200e6);

    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    // resubmitting the SAME cycleId (1) for this address must not double-credit
    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(user), 100e6);
  }

  /// @dev A zero amount is a skip like any other no-credit case: it emits BoostCreditSkipped with
  ///      reason ZeroAmount, does NOT consume the cycleId, and a later non-zero credit for the same
  ///      address and cycle lands normally.
  function test_OnBoostCredit_ZeroAmountIsSkippedWithoutConsumingCycle() public {
    address user = makeAddr('user1');
    (address[] memory users, uint256[] memory amounts) = _batch1(user, 0);

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCreditSkipped(user, 0, 1, EarnVaultV2.BoostSkipReason.ZeroAmount);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCycleCredited(1, 1, 0, 1, 0);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    assertEq(vault.lastCreditedCycle(user), 0, 'zero amount must not consume the cycle');

    usdsc.mint(address(vault), 100e6);
    amounts[0] = 100e6;
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    assertEq(vault.principal(user), 100e6);
    assertEq(vault.lastCreditedCycle(user), 1);
  }

  /// @dev Backs the @param cycleId note: cycleId 0 reverts StaleCycle even for a never-credited
  ///      address (lastCreditedCycle defaults to 0), so cycle numbering must start at 1.
  function test_OnBoostCredit_CycleIdZeroRevertsEvenOnFirstCredit() public {
    usdsc.mint(address(vault), 100e6);
    address[] memory users = new address[](1);
    users[0] = makeAddr('user1');
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(0, users, amounts);

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    assertEq(vault.lastCreditedCycle(makeAddr('user1')), 1);
  }

  function test_OnBoostCredit_RevertsOnLowerCycleIdThanLastCredited() public {
    address user = makeAddr('user1');
    usdsc.mint(address(vault), 200e6);
    (address[] memory users, uint256[] memory amounts) = _batch1(user, 100e6);

    vm.prank(boostKeeper);
    vault.onBoostCredit(5, users, amounts);

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(3, users, amounts);
  }

  function test_OnBoostCredit_AllowsIncreasingCycleIdsForSameAddress() public {
    address user = makeAddr('user1');
    usdsc.mint(address(vault), 200e6);

    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    vm.prank(boostKeeper);
    vault.onBoostCredit(2, users, amounts);

    assertEq(vault.principal(user), 200e6);
    assertEq(vault.lastCreditedCycle(user), 2);
  }

  function test_OnBoostCredit_RevertsWhilePaused() public {
    address user = makeAddr('user1');
    usdsc.mint(address(vault), 100e6);

    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(pauser);
    vault.pause();

    vm.prank(boostKeeper);
    vm.expectRevert(abi.encodeWithSignature('EnforcedPause()'));
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(user), 0);
  }

  function _depositAsUser(address user, uint256 amount) internal {
    usdsc.mint(user, amount);
    vm.prank(user);
    usdsc.approve(address(vault), amount);
    vm.prank(user);
    vault.deposit(amount);
  }

  function test_OnBoostCredit_FoldsPendingBaseYieldThenCreditsBoost_WithNonZeroPrincipalAndClaimReserve() public {
    address user = makeAddr('user1');

    uint256 depositAmount = 1000e6;
    _depositAsUser(user, depositAmount);
    assertEq(vault.claimReserve(), depositAmount);

    // Distribute base yield equal to totalPrincipal so the folded-in owed amount is exact
    // (no RAY rounding loss), matching this single depositor's whole principal.
    uint256 yieldAmount = 1000e6;
    usdsc.mint(address(vault), yieldAmount);
    vm.prank(redistributor);
    vault.onYield(yieldAmount);
    assertEq(vault.claimReserve(), depositAmount + yieldAmount);

    uint256 pendingBeforeCredit = vault.pendingYield(user);
    assertEq(pendingBeforeCredit, yieldAmount);

    uint256 boostAmount = 200e6;
    usdsc.mint(address(vault), boostAmount);

    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = boostAmount;

    vm.expectEmit(true, false, false, true, address(vault));
    emit EarnVaultV2.Compounded(user, pendingBeforeCredit);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCredited(user, boostAmount, 1);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    uint256 expectedPrincipal = depositAmount + yieldAmount + boostAmount;
    assertEq(vault.principal(user), expectedPrincipal);
    assertEq(vault.totalPrincipal(), expectedPrincipal);
    assertEq(vault.claimReserve(), depositAmount + yieldAmount + boostAmount);
    assertEq(vault.pendingYield(user), 0);
  }

  /// @dev Backs the initializeV2 NatSpec claim: even a malicious keeper can
  ///      credit at most the USDSC held above claimReserve - never existing users' funds. Here the
  ///      only surplus is a 30e6 donation: 30e6 + 1 reverts, exactly 30e6 succeeds, and afterwards
  ///      the vault is exactly fully reserved and the depositor is untouched.
  function test_OnBoostCredit_CreditIsBoundedByUnreservedSurplus() public {
    address depositor = makeAddr('depositor');
    _depositAsUser(depositor, 500e6);
    usdsc.mint(address(vault), 30e6); // donation: the only USDSC above claimReserve

    address beneficiary = makeAddr('beneficiary');
    address[] memory users = new address[](1);
    users[0] = beneficiary;
    uint256[] memory amounts = new uint256[](1);

    amounts[0] = 30e6 + 1;
    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onBoostCredit(1, users, amounts);

    amounts[0] = 30e6;
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(beneficiary), 30e6);
    assertEq(vault.principal(depositor), 500e6);
    assertEq(vault.claimReserve(), usdsc.balanceOf(address(vault)));
  }

  function test_OnBoostCredit_RevertsOnInsufficientBalance_WithNonZeroClaimReserveFromRealDeposit() public {
    address user = makeAddr('user1');

    uint256 depositAmount = 500e6;
    _depositAsUser(user, depositAmount);
    assertEq(vault.claimReserve(), depositAmount);

    // Vault balance exactly matches the existing claimReserve (no extra funds transferred in
    // for this credit) - bal < claimReserve + total must revert since total > 0.
    address[] memory users = new address[](1);
    users[0] = user;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(user), depositAmount);
    assertEq(vault.claimReserve(), depositAmount);
  }

  // ---------------------------------------------------------------------------------------------
  // Per-entry eligibility: entries that are the vault itself or a blacklisted address are
  // SKIPPED (event emitted, nothing credited, cycleId not consumed); the rest of the batch lands.
  // ---------------------------------------------------------------------------------------------

  function _batch2(
    address a,
    uint256 amtA,
    address b,
    uint256 amtB
  ) internal pure returns (address[] memory users, uint256[] memory amounts) {
    users = new address[](2);
    users[0] = a;
    users[1] = b;
    amounts = new uint256[](2);
    amounts[0] = amtA;
    amounts[1] = amtB;
  }

  function _batch1(address a, uint256 amt) internal pure returns (address[] memory users, uint256[] memory amounts) {
    users = new address[](1);
    users[0] = a;
    amounts = new uint256[](1);
    amounts[0] = amt;
  }

  function test_OnBoostCredit_SkipsBlacklistedEntry_CreditsTheRest() public {
    address userA = makeAddr('userA');
    address userB = makeAddr('userB');
    vm.prank(owner);
    vault.setBlacklisted(userB, true);

    usdsc.mint(address(vault), 50e6 + 75e6);
    (address[] memory users, uint256[] memory amounts) = _batch2(userA, 50e6, userB, 75e6);

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCredited(userA, 50e6, 1);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCreditSkipped(userB, 75e6, 1, EarnVaultV2.BoostSkipReason.Blacklisted);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCycleCredited(1, 2, 125e6, 1, 75e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(userA), 50e6);
    assertEq(vault.principal(userB), 0);
    assertEq(vault.lastCreditedCycle(userA), 1);
    assertEq(vault.lastCreditedCycle(userB), 0, 'skip must not consume the cycleId');
    assertEq(vault.claimReserve(), 50e6, 'reserve grows only by credited amounts');
    assertEq(usdsc.balanceOf(address(vault)) - vault.claimReserve(), 75e6, 'skipped amount is surplus');
  }

  function test_OnBoostCredit_SkipsVaultAddressEntry_CreditsTheRest() public {
    address userA = makeAddr('userA');

    usdsc.mint(address(vault), 50e6 + 40e6);
    (address[] memory users, uint256[] memory amounts) = _batch2(address(vault), 40e6, userA, 50e6);

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCreditSkipped(address(vault), 40e6, 1, EarnVaultV2.BoostSkipReason.VaultAddress);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(address(vault)), 0, 'vault never credits itself');
    assertEq(vault.principal(userA), 50e6);
    assertEq(vault.totalPrincipal(), 50e6);
    assertEq(vault.lastCreditedCycle(address(vault)), 0);
  }

  function test_OnBoostCredit_SkippedAddressCanBeCreditedLaterInSameCycle() public {
    address userB = makeAddr('userB');
    vm.prank(owner);
    vault.setBlacklisted(userB, true);

    usdsc.mint(address(vault), 75e6);
    (address[] memory users, uint256[] memory amounts) = _batch1(userB, 75e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    assertEq(vault.principal(userB), 0);

    // condition clears; the SAME cycleId is still available because the skip didn't consume it.
    // The earlier skipped 75e6 is still surplus, so this retry needs no new funding.
    vm.prank(owner);
    vault.setBlacklisted(userB, false);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.principal(userB), 75e6);
    assertEq(vault.lastCreditedCycle(userB), 1);
    assertEq(vault.claimReserve(), usdsc.balanceOf(address(vault)));
  }

  /// @dev The "ordinary operations" case: an address credited normally, then that address is
  ///      blacklisted later. Its next credit is skipped; everyone else's still lands.
  function test_OnBoostCredit_AddressBlacklistedAfterEarlierCredit_OnlyThatEntrySkipped() public {
    address userA = makeAddr('userA');
    address userB = makeAddr('userB');

    usdsc.mint(address(vault), 20e6);
    (address[] memory users, uint256[] memory amounts) = _batch2(userA, 10e6, userB, 10e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    assertEq(vault.principal(userB), 10e6);

    vm.prank(owner);
    vault.setBlacklisted(userB, true);

    usdsc.mint(address(vault), 20e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(2, users, amounts);

    assertEq(vault.principal(userA), 20e6);
    assertEq(vault.principal(userB), 10e6, 'blacklisted after binding: cycle 2 skipped');
    assertEq(vault.lastCreditedCycle(userB), 1);
  }

  function test_OnBoostCredit_SkippedSurplusIsSweepableAndReserveUntouched() public {
    address depositor = makeAddr('depositor');
    _depositAsUser(depositor, 500e6);
    address userB = makeAddr('userB');
    vm.prank(owner);
    vault.setBlacklisted(userB, true);

    usdsc.mint(address(vault), 33e6);
    (address[] memory users, uint256[] memory amounts) = _batch1(userB, 33e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    uint256 reserveBefore = vault.claimReserve();
    uint256 treasuryBefore = usdsc.balanceOf(treasury);
    vm.prank(owner);
    vault.sweepSurplusToTreasury();

    assertEq(usdsc.balanceOf(treasury) - treasuryBefore, 33e6, 'exactly the skipped amount');
    assertEq(vault.claimReserve(), reserveBefore);
    assertEq(usdsc.balanceOf(address(vault)), vault.claimReserve());
    assertEq(vault.principal(depositor), 500e6);
  }

  function test_OnBoostCredit_AllEntriesSkipped_BatchSucceedsCreditingNothing() public {
    address userB = makeAddr('userB');
    vm.prank(owner);
    vault.setBlacklisted(userB, true);

    usdsc.mint(address(vault), 30e6);
    (address[] memory users, uint256[] memory amounts) = _batch2(address(vault), 10e6, userB, 20e6);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCycleCredited(1, 2, 30e6, 2, 30e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    assertEq(vault.totalPrincipal(), 0);
    assertEq(vault.claimReserve(), 0);
  }

  /// @dev Replay stays all-or-nothing and is checked BEFORE eligibility: a resubmitted cycle
  ///      reverts the whole batch even when the offending entry would now be skipped.
  function test_OnBoostCredit_StaleCycleRevertsEvenForEntryThatWouldBeSkipped() public {
    address userB = makeAddr('userB');
    usdsc.mint(address(vault), 20e6);
    (address[] memory users, uint256[] memory amounts) = _batch1(userB, 10e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);

    vm.prank(owner);
    vault.setBlacklisted(userB, true);
    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(1, users, amounts);
  }

  /// @dev The funding check stays conservative: it requires the FULL submitted total, including
  ///      entries that end up skipped.
  function test_OnBoostCredit_FundingCheckStillCoversSkippedAmounts() public {
    vm.prank(owner);
    vault.setBlacklisted(makeAddr('userB'), true);

    usdsc.mint(address(vault), 50e6); // only enough for the eligible entry
    (address[] memory users, uint256[] memory amounts) = _batch2(makeAddr('userA'), 50e6, makeAddr('userB'), 75e6);
    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onBoostCredit(1, users, amounts);
  }

  /// @dev A duplicate of an INELIGIBLE address is skipped twice (no StaleCycle, since a skip
  ///      writes nothing); a duplicate of an eligible one still reverts StaleCycle (tested below).
  function test_OnBoostCredit_DuplicateIneligibleEntryIsSkippedTwice() public {
    address userB = makeAddr('userB');
    vm.prank(owner);
    vault.setBlacklisted(userB, true);

    usdsc.mint(address(vault), 20e6);
    (address[] memory users, uint256[] memory amounts) = _batch2(userB, 10e6, userB, 10e6);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCycleCredited(1, 2, 20e6, 2, 20e6);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
    assertEq(vault.principal(userB), 0);
  }

  // ---------------------------------------------------------------------------------------------
  // Initialization event, empty batch
  // ---------------------------------------------------------------------------------------------

  /// @dev initializeV2 announces the initial keeper, so indexers see it.
  function test_InitializeV2_EmitsBoostKeeperChanged() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();
    vm.expectEmit(true, true, true, true, address(v2));
    emit EarnVaultV2.BoostKeeperChanged(address(pa), address(0), boostKeeper);
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)), impl, abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper))
    );
  }

  function test_OnBoostCredit_RevertsOnEmptyBatch() public {
    address[] memory users = new address[](0);
    uint256[] memory amounts = new uint256[](0);
    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.EmptyBatch.selector);
    vault.onBoostCredit(1, users, amounts);
  }

  function test_OnBoostCredit_RevertsWholeBatchOnDuplicateAddressInSameBatch() public {
    address userA = makeAddr('userA');

    usdsc.mint(address(vault), 200e6);

    address[] memory users = new address[](2);
    users[0] = userA;
    users[1] = userA;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 100e6;
    amounts[1] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(1, users, amounts);

    // whole batch reverted - the first occurrence, credited before the second hit StaleCycle,
    // must be rolled back too
    assertEq(vault.principal(userA), 0);
    assertEq(vault.lastCreditedCycle(userA), 0);
  }

  function test_OnBoostCredit_EmitsBoostCycleCreditedSummaryEvent() public {
    address userA = makeAddr('userA');
    address userB = makeAddr('userB');

    uint256 amountA = 50e6;
    uint256 amountB = 75e6;
    usdsc.mint(address(vault), amountA + amountB);

    address[] memory users = new address[](2);
    users[0] = userA;
    users[1] = userB;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = amountA;
    amounts[1] = amountB;

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCycleCredited(1, 2, amountA + amountB, 0, 0);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, users, amounts);
  }
}
