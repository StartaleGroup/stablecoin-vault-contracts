// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'lib/forge-std/src/Test.sol';
import {Ownable} from 'lib/openzeppelin-contracts/contracts/access/Ownable.sol';

contract MockIdentityRegistryForVault {
  mapping(bytes32 => address) public registeredAddress;

  function setRegisteredAddress(bytes32 identityId, address addr) external {
    registeredAddress[identityId] = addr;
  }
}

contract EarnVaultV2BoostCreditTest is Test {
  EarnVaultV2 public vault;
  MockUSDSC public usdsc;
  MockIdentityRegistryForVault public registryMock;

  address public admin = makeAddr('admin');
  address public owner = makeAddr('owner');
  address public redistributor = makeAddr('redistributor');
  address public treasury = makeAddr('treasury');
  address public pauser = makeAddr('pauser');
  address public operator = makeAddr('operator');
  address public boostKeeper = makeAddr('boostKeeper');

  function setUp() public virtual {
    usdsc = new MockUSDSC();
    registryMock = new MockIdentityRegistryForVault();

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
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector, boostKeeper, address(registryMock))
    );

    vault = EarnVaultV2(payable(address(proxy)));
  }

  function _registerMock(bytes32 identityId, address addr) internal {
    registryMock.setRegisteredAddress(identityId, addr);
  }

  function test_InitializeV2_SetsBoostCreditState() public view {
    assertEq(vault.boostKeeper(), boostKeeper);
    assertEq(vault.identityRegistry(), address(registryMock));
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
    v2.initializeV2(attacker, attacker);

    // not even the vault owner can - only the ProxyAdmin, via upgradeAndCall
    vm.prank(owner);
    vm.expectRevert(EarnVaultV2.NotProxyAdmin.selector);
    v2.initializeV2(boostKeeper, address(registryMock));

    assertEq(v2.boostKeeper(), address(0));
  }

  function test_InitializeV2_UpgradeWithoutInitIsInertThenRecoverableViaUpgradeAndCall() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();

    // uninitialized boost credit is inert: boostKeeper is address(0), no caller can match it
    bytes32[] memory ids = new bytes32[](0);
    uint256[] memory amounts = new uint256[](0);
    vm.prank(makeAddr('attacker'));
    vm.expectRevert(EarnVaultV2.NotBoostKeeper.selector);
    v2.onBoostCredit(1, ids, amounts);

    // recovery: repeat upgradeAndCall to the same implementation, this time with the init call
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, address(registryMock)))
    );
    assertEq(v2.boostKeeper(), boostKeeper);
    assertEq(v2.identityRegistry(), address(registryMock));
  }

  /// @dev The gate's premise: the ProxyAdmin (the only accepted caller) cannot reach initializeV2
  ///      through the proxy except via upgradeToAndCall - the proxy itself rejects it.
  function test_InitializeV2_ProxyAdminCannotCallItOutsideUpgradeAndCall() public {
    (EarnVaultV2 v2, ProxyAdmin pa,) = _upgradeWithoutInit();
    vm.prank(address(pa));
    vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
    v2.initializeV2(boostKeeper, address(registryMock));
  }

  function test_InitializeV2_CannotRunTwiceEvenViaUpgradeAndCall() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();
    bytes memory initData = abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, address(registryMock)));
    vm.prank(admin);
    pa.upgradeAndCall(ITransparentUpgradeableProxy(address(v2)), impl, initData);

    address attackerKeeper = makeAddr('attackerKeeper');
    vm.prank(admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (attackerKeeper, address(registryMock)))
    );
    assertEq(v2.boostKeeper(), boostKeeper);
  }

  function test_InitializeV2_RevertsOnZeroBoostKeeper() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();
    vm.prank(admin);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (address(0), address(registryMock)))
    );
  }

  function test_InitializeV2_RevertsOnZeroIdentityRegistry() public {
    (EarnVaultV2 v2, ProxyAdmin pa, address impl) = _upgradeWithoutInit();
    vm.prank(admin);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(v2)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, address(0)))
    );
  }

  function test_InitializeV2_ImplementationContractCannotBeInitialized() public {
    EarnVaultV2 impl = new EarnVaultV2();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    impl.initializeV2(boostKeeper, address(registryMock));
  }

  /// @dev BOOST_CREDIT_STORAGE_LOCATION is a hand-pasted hash and private - recompute the
  ///      ERC-7201 formula here and check the struct's first two fields actually live there.
  function test_BoostCreditStorage_MatchesErc7201Location() public view {
    bytes32 expected = keccak256(abi.encode(uint256(keccak256('startale.storage.EarnVaultV2.BoostCredit')) - 1))
      & ~bytes32(uint256(0xff));
    assertEq(address(uint160(uint256(vm.load(address(vault), expected)))), boostKeeper);
    assertEq(address(uint160(uint256(vm.load(address(vault), bytes32(uint256(expected) + 1))))), address(registryMock));
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

  function test_SetIdentityRegistry_UpdatesStateAndEmits() public {
    address newRegistry = makeAddr('newRegistry');
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.IdentityRegistryChanged(owner, address(registryMock), newRegistry);
    vm.prank(owner);
    vault.setIdentityRegistry(newRegistry);
    assertEq(vault.identityRegistry(), newRegistry);
  }

  function test_SetIdentityRegistry_RevertsForNonOwner() public {
    vm.prank(makeAddr('rando'));
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr('rando')));
    vault.setIdentityRegistry(makeAddr('newRegistry'));
  }

  function test_SetIdentityRegistry_RevertsOnZeroAddress() public {
    vm.prank(owner);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.setIdentityRegistry(address(0));
  }

  function test_OnBoostCredit_CreditsPrincipalForSingleIdentity() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);

    uint256 amount = 100e6;
    usdsc.mint(address(vault), amount);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCredited(identityId, user, amount, 1);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(user), amount);
    assertEq(vault.totalPrincipal(), amount);
    assertEq(vault.claimReserve(), amount);
    assertEq(vault.lastCreditedCycle(identityId), 1);
  }

  function test_OnBoostCredit_CreditsMultipleIdentitiesInOneBatch() public {
    bytes32 idA = keccak256('identity-A');
    bytes32 idB = keccak256('identity-B');
    address userA = makeAddr('userA');
    address userB = makeAddr('userB');
    _registerMock(idA, userA);
    _registerMock(idB, userB);

    uint256 amountA = 50e6;
    uint256 amountB = 75e6;
    usdsc.mint(address(vault), amountA + amountB);

    bytes32[] memory ids = new bytes32[](2);
    ids[0] = idA;
    ids[1] = idB;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = amountA;
    amounts[1] = amountB;

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(userA), amountA);
    assertEq(vault.principal(userB), amountB);
    assertEq(vault.totalPrincipal(), amountA + amountB);
  }

  function test_OnBoostCredit_RevertsForNonBoostKeeper() public {
    bytes32[] memory ids = new bytes32[](0);
    uint256[] memory amounts = new uint256[](0);
    vm.prank(makeAddr('rando'));
    vm.expectRevert(EarnVaultV2.NotBoostKeeper.selector);
    vault.onBoostCredit(1, ids, amounts);
  }

  function test_OnBoostCredit_RevertsOnLengthMismatch() public {
    bytes32[] memory ids = new bytes32[](2);
    uint256[] memory amounts = new uint256[](1);
    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.LengthMismatch.selector);
    vault.onBoostCredit(1, ids, amounts);
  }

  function test_OnBoostCredit_RevertsWholeBatchOnInsufficientBalance() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);

    // fund less than the batch total
    usdsc.mint(address(vault), 10e6);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(user), 0);
  }

  function test_OnBoostCredit_RevertsWholeBatchOnUnregisteredIdentity() public {
    bytes32 registeredId = keccak256('identity-registered');
    bytes32 unregisteredId = keccak256('identity-unregistered');
    address user = makeAddr('user1');
    _registerMock(registeredId, user);
    // unregisteredId is never registered - registeredAddress returns address(0)

    usdsc.mint(address(vault), 200e6);

    bytes32[] memory ids = new bytes32[](2);
    ids[0] = registeredId;
    ids[1] = unregisteredId;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 100e6;
    amounts[1] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.IdentityNotRegistered.selector);
    vault.onBoostCredit(1, ids, amounts);

    // whole batch reverted - not even the first, valid entry should be credited
    assertEq(vault.principal(user), 0);
  }

  function test_OnBoostCredit_RevertsOnStaleCycleForSameIdentity() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);
    usdsc.mint(address(vault), 200e6);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vault.onBoostCredit(5, ids, amounts);

    // resubmitting the SAME cycleId (5) for this identity must not double-credit
    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(5, ids, amounts);

    assertEq(vault.principal(user), 100e6);
  }

  /// @dev Pins the NatSpec'd behavior: a zero entry is not a no-op - it consumes the cycleId,
  ///      so a later non-zero credit for the same identity and cycle reverts.
  function test_OnBoostCredit_ZeroAmountStillConsumesCycleId() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCredited(identityId, user, 0, 3);
    vm.prank(boostKeeper);
    vault.onBoostCredit(3, ids, amounts);
    assertEq(vault.lastCreditedCycle(identityId), 3);
    assertEq(vault.principal(user), 0);

    usdsc.mint(address(vault), 100e6);
    amounts[0] = 100e6;
    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(3, ids, amounts);
  }

  function test_OnBoostCredit_RevertsOnLowerCycleIdThanLastCredited() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);
    usdsc.mint(address(vault), 200e6);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vault.onBoostCredit(5, ids, amounts);

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(3, ids, amounts);
  }

  function test_OnBoostCredit_AllowsIncreasingCycleIdsForSameIdentity() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);
    usdsc.mint(address(vault), 200e6);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);
    vm.prank(boostKeeper);
    vault.onBoostCredit(2, ids, amounts);

    assertEq(vault.principal(user), 200e6);
    assertEq(vault.lastCreditedCycle(identityId), 2);
  }

  function test_OnBoostCredit_RevertsWhilePaused() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);
    usdsc.mint(address(vault), 100e6);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(pauser);
    vault.pause();

    vm.prank(boostKeeper);
    vm.expectRevert(); // EnforcedPause
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(user), 0);
  }

  function test_OnBoostCredit_RevertsWholeBatchWhenResolvedUserIsBlacklisted() public {
    bytes32 idA = keccak256('identity-A');
    bytes32 idB = keccak256('identity-B');
    address userA = makeAddr('userA');
    address userB = makeAddr('userB');
    _registerMock(idA, userA);
    _registerMock(idB, userB);

    vm.prank(owner);
    vault.setBlacklisted(userB, true);

    uint256 amountA = 50e6;
    uint256 amountB = 75e6;
    usdsc.mint(address(vault), amountA + amountB);

    bytes32[] memory ids = new bytes32[](2);
    ids[0] = idA;
    ids[1] = idB;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = amountA;
    amounts[1] = amountB;

    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.onBoostCredit(1, ids, amounts);

    // whole batch reverted - not even the first, non-blacklisted entry should be credited
    assertEq(vault.principal(userA), 0);
    assertEq(vault.principal(userB), 0);
  }

  function _depositAsUser(address user, uint256 amount) internal {
    usdsc.mint(user, amount);
    vm.prank(user);
    usdsc.approve(address(vault), amount);
    vm.prank(user);
    vault.deposit(amount);
  }

  function test_OnBoostCredit_FoldsPendingBaseYieldThenCreditsBoost_WithNonZeroPrincipalAndClaimReserve() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);

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

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = boostAmount;

    vm.expectEmit(true, false, false, true, address(vault));
    emit EarnVaultV2.Compounded(user, pendingBeforeCredit);
    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCredited(identityId, user, boostAmount, 1);
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, ids, amounts);

    uint256 expectedPrincipal = depositAmount + yieldAmount + boostAmount;
    assertEq(vault.principal(user), expectedPrincipal);
    assertEq(vault.totalPrincipal(), expectedPrincipal);
    assertEq(vault.claimReserve(), depositAmount + yieldAmount + boostAmount);
    assertEq(vault.pendingYield(user), 0);
  }

  function test_OnBoostCredit_RevertsOnInsufficientBalance_WithNonZeroClaimReserveFromRealDeposit() public {
    bytes32 identityId = keccak256('identity-1');
    address user = makeAddr('user1');
    _registerMock(identityId, user);

    uint256 depositAmount = 500e6;
    _depositAsUser(user, depositAmount);
    assertEq(vault.claimReserve(), depositAmount);

    // Vault balance exactly matches the existing claimReserve (no extra funds transferred in
    // for this credit) - bal < claimReserve + total must revert since total > 0.
    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(user), depositAmount);
    assertEq(vault.claimReserve(), depositAmount);
  }

  function test_OnBoostCredit_RevertsWholeBatchOnDuplicateIdentityInSameBatch() public {
    bytes32 idA = keccak256('identity-A');
    address userA = makeAddr('userA');
    _registerMock(idA, userA);

    usdsc.mint(address(vault), 200e6);

    bytes32[] memory ids = new bytes32[](2);
    ids[0] = idA;
    ids[1] = idA;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 100e6;
    amounts[1] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(1, ids, amounts);

    // whole batch reverted - the first occurrence's write-before-resolve must not have
    // credited anything either
    assertEq(vault.principal(userA), 0);
    assertEq(vault.lastCreditedCycle(idA), 0);
  }

  function test_OnBoostCredit_RevertsWhenResolvedUserIsVaultItself() public {
    // If the registry resolves an identity to the vault's own address, the vault must never
    // credit itself. This check in EarnVaultV2.onBoostCredit() is the ONLY guard - the registry
    // deliberately does not track the vault's address.
    bytes32 identityId = keccak256('identity-1');
    _registerMock(identityId, address(vault));

    usdsc.mint(address(vault), 100e6);

    bytes32[] memory ids = new bytes32[](1);
    ids[0] = identityId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 100e6;

    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.IdentityNotRegistered.selector);
    vault.onBoostCredit(1, ids, amounts);

    assertEq(vault.principal(address(vault)), 0);
  }

  function test_OnBoostCredit_EmitsBoostCycleCreditedSummaryEvent() public {
    bytes32 idA = keccak256('identity-A');
    bytes32 idB = keccak256('identity-B');
    address userA = makeAddr('userA');
    address userB = makeAddr('userB');
    _registerMock(idA, userA);
    _registerMock(idB, userB);

    uint256 amountA = 50e6;
    uint256 amountB = 75e6;
    usdsc.mint(address(vault), amountA + amountB);

    bytes32[] memory ids = new bytes32[](2);
    ids[0] = idA;
    ids[1] = idB;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = amountA;
    amounts[1] = amountB;

    vm.expectEmit(true, true, true, true);
    emit EarnVaultV2.BoostCycleCredited(7, 2, amountA + amountB);
    vm.prank(boostKeeper);
    vault.onBoostCredit(7, ids, amounts);
  }
}
