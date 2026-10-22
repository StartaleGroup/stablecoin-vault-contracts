// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {UsdscToken} from '../../src/coin/UsdscToken.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC3009} from 'lib/evm-m-extensions/lib/common/src/interfaces/IERC3009.sol';
import {IERC712} from 'lib/evm-m-extensions/lib/common/src/interfaces/IERC712.sol';
import {MockM, MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';

/// @dev Minimal ERC-1271 smart wallet: a signature is valid when its single owner signed the hash
contract MockSmartWallet {
  address public immutable walletOwner;

  constructor(address owner_) {
    walletOwner = owner_;
  }

  function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
    (uint8 v, bytes32 r, bytes32 s) = (uint8(signature[64]), bytes32(signature[0:32]), bytes32(signature[32:64]));
    return ecrecover(hash, v, r, s) == walletOwner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
  }
}

/// @dev ERC-1271 wallet that accepts any signature
contract PermissiveWallet {
  function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
    return 0x1626ba7e;
  }
}

/// @dev ERC-1271 wallet that tries to change vault state while its signature is checked
contract HostileWallet {
  EarnVaultV2 public immutable vault;

  constructor(EarnVaultV2 vault_) {
    vault = vault_;
  }

  function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
    vault.compound(address(this)); // state change: fails, USDSC checks signatures with staticcall
    return 0x1626ba7e;
  }
}

/// @dev Stand-in redistributor exposing only the snapshot getters EarnVaultV2's deposit lock reads
contract SnapshotStub {
  uint256 public lastSnapshotTimestamp;
  uint256 public snapshotMaxAge = 60;

  function snapshot() external {
    lastSnapshotTimestamp = block.timestamp;
  }
}

/// @title EarnVaultV2.depositWithAuthorization() against the real USDSC token code
/// @notice Uses this repo's copy of the live USDSC implementation (UsdscToken), so the ERC-3009
///         receiveWithAuthorization() being exercised is the real one.
contract EarnVaultV2DepositWithAuthorizationTest is Test {
  EarnVaultV2 vault;
  UsdscToken usdsc;
  MockM mToken;
  MockSwapFacility swapFacility;
  SnapshotStub redistributor;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address boostRewardKeeper = makeAddr('boostRewardKeeper');
  address relayer = makeAddr('relayer');
  address observer = makeAddr('observer');

  uint256 constant PAYER_KEY = 0xA11CE;
  address payer;
  uint256 constant AMOUNT = 1000e6;

  function setUp() public {
    mToken = new MockM();
    swapFacility = new MockSwapFacility();
    redistributor = new SnapshotStub();
    UsdscToken usdscImpl = new UsdscToken(address(mToken), address(swapFacility));
    usdsc = UsdscToken(
      address(
        new TransparentUpgradeableProxy(
          address(usdscImpl),
          admin,
          abi.encodeCall(UsdscToken.initialize, ('USDSC', 'USDSC', treasury, admin, admin, admin, admin))
        )
      )
    );

    address proxy = address(
      new TransparentUpgradeableProxy(
        address(new EarnVaultUpgradeable()),
        admin,
        abi.encodeWithSelector(
          EarnVaultUpgradeable.initialize.selector,
          address(usdsc),
          owner,
          address(redistributor),
          treasury,
          pauser,
          boostRewardKeeper
        )
      )
    );
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(proxy, adminSlot)))));
    address v2 = address(new EarnVaultV2());
    bytes memory init2 = abi.encodeCall(EarnVaultV2.initializeV2, (makeAddr('boostKeeper'), 10_000e6));
    vm.prank(admin);
    pa.upgradeAndCall(ITransparentUpgradeableProxy(proxy), v2, init2);
    vault = EarnVaultV2(payable(proxy));

    payer = vm.addr(PAYER_KEY);
    _mintUsdsc(payer, AMOUNT * 3);
  }

  // ---------------------------------------------------------------------------------------------
  // Positive
  // ---------------------------------------------------------------------------------------------

  function test_RelayedDeposit_CreditsThePayer() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    uint256 vaultBal = usdsc.balanceOf(address(vault));

    vm.expectEmit(true, false, false, true, address(vault));
    emit IEarnVaultEventsAndErrors.Deposit(payer, AMOUNT);
    vm.prank(relayer);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);

    assertEq(vault.principal(payer), AMOUNT);
    assertEq(vault.principal(relayer), 0);
    assertEq(vault.totalPrincipal(), AMOUNT);
    assertEq(vault.claimReserve(), AMOUNT);
    assertEq(usdsc.balanceOf(address(vault)) - vaultBal, AMOUNT);
    assertEq(usdsc.balanceOf(payer), AMOUNT * 2);
    assertTrue(usdsc.authorizationState(payer, nonce));
    assertEq(usdsc.allowance(payer, address(vault)), 0, 'no approval involved');
  }

  /// @dev An observer submitting first can only complete exactly the deposit the payer signed;
  ///      the relayer's copy then reverts in USDSC and changes nothing
  function test_FrontRun_CompletesTheSignedDepositOnly() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);

    vm.prank(observer);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(vault.principal(payer), AMOUNT);
    assertEq(vault.principal(observer), 0);

    vm.prank(relayer);
    vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationAlreadyUsed.selector, payer, nonce));
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(vault.principal(payer), AMOUNT, 'credited exactly once');
    assertEq(vault.totalPrincipal(), AMOUNT);
  }

  /// @dev Nothing the payer did not sign can be deposited: not part of the amount, not more
  function test_PartialOrLargerAmountReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    vm.startPrank(observer);
    vm.expectRevert(IERC712.SignerMismatch.selector);
    vault.depositWithAuthorization(payer, 1, va, vb, nonce, sig);
    vm.expectRevert(IERC712.SignerMismatch.selector);
    vault.depositWithAuthorization(payer, AMOUNT + 1, va, vb, nonce, sig);
    vm.stopPrank();
    assertFalse(usdsc.authorizationState(payer, nonce), 'authorization still unused');
    assertEq(vault.totalPrincipal(), 0);

    vm.prank(relayer);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(vault.principal(payer), AMOUNT);
  }

  function test_SmartWallet_Erc1271Signature() public {
    uint256 walletOwnerKey = 0xB0B;
    MockSmartWallet wallet = new MockSmartWallet(vm.addr(walletOwnerKey));
    _mintUsdsc(address(wallet), AMOUNT);

    (uint256 va, uint256 vb, bytes32 nonce) = _window();
    bytes memory sig = _sign(walletOwnerKey, address(wallet), address(vault), AMOUNT, va, vb, nonce);
    vm.prank(relayer);
    vault.depositWithAuthorization(address(wallet), AMOUNT, va, vb, nonce, sig);
    assertEq(vault.principal(address(wallet)), AMOUNT);
  }

  /// @dev A wallet that accepts any signature can only be made to deposit its own USDSC, credited
  ///      to itself: whoever submits gains nothing
  function test_PermissiveWallet_OnlyDepositsIntoItself() public {
    PermissiveWallet wallet = new PermissiveWallet();
    _mintUsdsc(address(wallet), AMOUNT);
    (uint256 va, uint256 vb, bytes32 nonce) = _window();
    vm.prank(observer);
    vault.depositWithAuthorization(address(wallet), AMOUNT, va, vb, nonce, hex'00');
    assertEq(vault.principal(address(wallet)), AMOUNT);
    assertEq(vault.principal(observer), 0);
    assertEq(usdsc.balanceOf(observer), 0);
  }

  /// @dev A wallet cannot change state from inside the signature check: the deposit just reverts
  function test_HostileWallet_CannotActDuringSignatureCheck() public {
    HostileWallet wallet = new HostileWallet(vault);
    _mintUsdsc(address(wallet), AMOUNT);
    (uint256 va, uint256 vb, bytes32 nonce) = _window();
    vm.prank(relayer);
    vm.expectRevert();
    vault.depositWithAuthorization(address(wallet), AMOUNT, va, vb, nonce, hex'00');
    assertEq(vault.totalPrincipal(), 0);
    assertFalse(usdsc.authorizationState(address(wallet), nonce));
  }

  /// @dev Like deposit(): the payer's pending yield is folded in before the new principal lands
  function test_SettlesPendingYieldFirst() public {
    _plainDeposit(payer, AMOUNT);
    _yield(100e6);
    uint256 pending = vault.pendingYield(payer);
    assertGt(pending, 0);

    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    vm.prank(relayer);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(vault.principal(payer), AMOUNT * 2 + pending);
    assertEq(vault.pendingYield(payer), 0);
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------
  // Negative: the authorization itself
  // ---------------------------------------------------------------------------------------------

  /// @dev USDSC lets only the payee execute: an authorization made out to the vault cannot be
  ///      used directly on the token, so it cannot be consumed outside depositWithAuthorization()
  function test_DirectExecutionOnTokenReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    vm.prank(observer);
    vm.expectRevert(abi.encodeWithSelector(IERC3009.CallerMustBePayee.selector, observer, address(vault)));
    usdsc.receiveWithAuthorization(payer, address(vault), AMOUNT, va, vb, nonce, sig);
    assertFalse(usdsc.authorizationState(payer, nonce));
  }

  /// @dev An authorization made out to another payee cannot be used here
  function test_AuthorizationToAnotherPayeeReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce) = _window();
    bytes memory sig = _sign(PAYER_KEY, payer, makeAddr('otherPayee'), AMOUNT, va, vb, nonce);
    vm.prank(relayer);
    vm.expectRevert(IERC712.SignerMismatch.selector);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
  }

  /// @dev A signature cannot be credited to anyone other than its signer
  function test_WrongPayerReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    address other = makeAddr('other');
    _mintUsdsc(other, AMOUNT);
    vm.prank(relayer);
    vm.expectRevert(IERC712.SignerMismatch.selector);
    vault.depositWithAuthorization(other, AMOUNT, va, vb, nonce, sig);
    assertEq(vault.principal(other), 0);
  }

  function test_TransferAuthorizationIsNotAReceiveAuthorization() public {
    (uint256 va, uint256 vb, bytes32 nonce) = _window();
    bytes32 structHash =
      keccak256(abi.encode(usdsc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), payer, address(vault), AMOUNT, va, vb, nonce));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, _digest(structHash));
    vm.prank(relayer);
    vm.expectRevert(IERC712.SignerMismatch.selector);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, abi.encodePacked(r, s, v));
  }

  function test_NotYetValidAndExpiredRevert() public {
    bytes32 nonce = keccak256('n');
    uint256 va = block.timestamp + 100;
    uint256 vb = block.timestamp + 1 hours;
    bytes memory sig = _sign(PAYER_KEY, payer, address(vault), AMOUNT, va, vb, nonce);
    vm.prank(relayer);
    vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationNotYetValid.selector, block.timestamp, va));
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);

    vm.warp(vb);
    vm.prank(relayer);
    vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationExpired.selector, vb, vb));
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(vault.totalPrincipal(), 0);
  }

  function test_CancelledAuthorizationReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    bytes32 cancelHash = keccak256(abi.encode(usdsc.CANCEL_AUTHORIZATION_TYPEHASH(), payer, nonce));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, _digest(cancelHash));
    usdsc.cancelAuthorization(payer, nonce, abi.encodePacked(r, s, v));

    vm.prank(relayer);
    vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationAlreadyUsed.selector, payer, nonce));
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
  }

  function test_InsufficientBalanceReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT * 4);
    vm.prank(relayer);
    vm.expectRevert();
    vault.depositWithAuthorization(payer, AMOUNT * 4, va, vb, nonce, sig);
    assertFalse(usdsc.authorizationState(payer, nonce));
    assertEq(vault.totalPrincipal(), 0);
  }

  // ---------------------------------------------------------------------------------------------
  // Negative: the vault's own checks (same as deposit())
  // ---------------------------------------------------------------------------------------------

  /// @dev Locked like deposit(), with nothing consumed: the same authorization works after unlock
  function test_DepositLock_AuthorizationStaysUsable() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    redistributor.snapshot();
    (bool locked, uint256 unlocksAt) = vault.depositsLocked();
    assertTrue(locked);

    vm.prank(relayer);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, unlocksAt));
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertFalse(usdsc.authorizationState(payer, nonce), 'authorization not consumed');

    vm.warp(unlocksAt);
    vm.prank(relayer);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(vault.principal(payer), AMOUNT);
  }

  function test_PausedReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    vm.prank(pauser);
    vault.pause();
    vm.prank(relayer);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
  }

  function test_BlacklistedPayerReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    vm.prank(owner);
    vault.setBlacklisted(payer, true);
    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
  }

  function test_ZeroAmountAndZeroPayerRevert() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, 0);
    vm.startPrank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.ZeroAmount.selector);
    vault.depositWithAuthorization(payer, 0, va, vb, nonce, sig);
    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.depositWithAuthorization(address(0), AMOUNT, va, vb, nonce, sig);
    vm.stopPrank();
  }

  function test_FrozenPayerReverts() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, AMOUNT);
    vm.prank(admin); // admin holds the freeze manager role in this setup
    usdsc.freeze(payer);
    vm.prank(relayer);
    vm.expectRevert();
    vault.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(vault.totalPrincipal(), 0);
  }

  /// @dev deposit() and depositWithPermit() share the refactored halves; deposit() still works
  function test_PlainDepositUnchanged() public {
    _plainDeposit(payer, AMOUNT);
    assertEq(vault.principal(payer), AMOUNT);
    assertEq(vault.claimReserve(), AMOUNT);
  }

  // ---------------------------------------------------------------------------------------------
  // Fuzz: succeeds exactly when the authorization matches, and accounting stays exact
  // ---------------------------------------------------------------------------------------------

  function testFuzz_OnlyTheSignedDepositSucceeds(uint256 signed, uint256 submitted, bytes32 nonce) public {
    signed = bound(signed, 1, AMOUNT * 3);
    submitted = bound(submitted, 1, AMOUNT * 3);
    (uint256 va, uint256 vb,) = _window();
    bytes memory sig = _sign(PAYER_KEY, payer, address(vault), signed, va, vb, nonce);

    vm.prank(relayer);
    if (submitted != signed) vm.expectRevert(IERC712.SignerMismatch.selector);
    vault.depositWithAuthorization(payer, submitted, va, vb, nonce, sig);

    uint256 expected = submitted == signed ? signed : 0;
    assertEq(vault.principal(payer), expected);
    assertEq(vault.totalPrincipal(), expected);
    assertEq(vault.claimReserve(), expected);
    assertEq(usdsc.authorizationState(payer, nonce), submitted == signed);
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------

  function _window() internal view returns (uint256 va, uint256 vb, bytes32 nonce) {
    return (block.timestamp - 1, block.timestamp + 1 hours, keccak256(abi.encode(block.timestamp, gasleft())));
  }

  function _authorize(
    uint256 key,
    uint256 amount
  ) internal view returns (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) {
    (va, vb, nonce) = _window();
    sig = _sign(key, vm.addr(key), address(vault), amount, va, vb, nonce);
  }

  function _sign(
    uint256 key,
    address from,
    address to,
    uint256 value,
    uint256 va,
    uint256 vb,
    bytes32 nonce
  ) internal view returns (bytes memory) {
    bytes32 structHash =
      keccak256(abi.encode(usdsc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, va, vb, nonce));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(structHash));
    return abi.encodePacked(r, s, v);
  }

  function _digest(bytes32 structHash) internal view returns (bytes32) {
    return keccak256(abi.encodePacked('\x19\x01', usdsc.DOMAIN_SEPARATOR(), structHash));
  }

  function _mintUsdsc(address to, uint256 amount) internal {
    deal(address(mToken), address(swapFacility), mToken.balanceOf(address(swapFacility)) + amount);
    vm.prank(address(swapFacility));
    usdsc.wrap(to, amount);
  }

  function _plainDeposit(address user, uint256 amount) internal {
    vm.startPrank(user);
    usdsc.approve(address(vault), amount);
    vault.deposit(amount);
    vm.stopPrank();
  }

  /// @dev Yield as the redistributor delivers it: USDSC arrives, then onYield indexes it
  function _yield(uint256 amount) internal {
    _mintUsdsc(address(redistributor), amount);
    vm.prank(address(redistributor));
    usdsc.transfer(address(vault), amount);
    vm.prank(address(redistributor));
    vault.onYield(amount);
  }

  function _assertSolvent() internal view {
    assertGe(
      usdsc.balanceOf(address(vault)),
      vault.claimReserve() + vault.boostClaimReserve(address(usdsc)),
      'vault under-reserved'
    );
  }
}
