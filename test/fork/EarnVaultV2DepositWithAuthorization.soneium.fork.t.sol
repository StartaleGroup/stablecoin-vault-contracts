// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {RewardRedistributor} from '../../src/distributor/RewardRedistributor.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockSmartWallet} from '../unit/EarnVaultV2DepositWithAuthorization.t.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC3009} from 'lib/evm-m-extensions/lib/common/src/interfaces/IERC3009.sol';
import {IERC712} from 'lib/evm-m-extensions/lib/common/src/interfaces/IERC712.sol';

/// @dev The live USDSC functions this test uses
interface IUsdscLive {
  function balanceOf(address) external view returns (uint256);
  function DOMAIN_SEPARATOR() external view returns (bytes32);
  function RECEIVE_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);
  function authorizationState(address, bytes32) external view returns (bool);
  function receiveWithAuthorization(address, address, uint256, uint256, uint256, bytes32, bytes memory) external;
}

/// @title depositWithAuthorization() on the live vault with live USDSC
/// @notice Forks Soneium, upgrades the live EarnVault to EarnVaultV2 through the owner Safe, and makes
///         gasless deposits with real ERC-3009 ReceiveWithAuthorization signatures verified by the live
///         USDSC implementation.
/// @dev Opt-in:
///        RUN_SONEIUM_FORK=true forge test --match-path test/fork/EarnVaultV2DepositWithAuthorization.soneium.fork.t.sol \
///          --libraries src/vaults/earn/BoostRewardsLib.sol:BoostRewardsLib:0x674894C99714bf7E6Acdd9a73d46c6f9EACe66CE -vv
contract EarnVaultV2DepositWithAuthorizationSoneiumFork is Test {
  EarnVaultV2 constant VAULT = EarnVaultV2(payable(0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0));
  ProxyAdmin constant PROXY_ADMIN = ProxyAdmin(0xDBc42e5c7E6BF89886F2f359F9b0BB9344824066);
  address constant OWNER_SAFE = 0x3C27038D9906caa5D68355B1800625EAcaCd93dA;
  RewardRedistributor constant RR = RewardRedistributor(0xda798684ffD5eb509c2Ab7b8352EC55B31F18201);
  address constant RR_OPERATOR = 0x86bE13a26d548FA5407Ee3E5a8321B4E1019333C;

  uint256 constant PAYER_KEY = 0xA11CE;
  uint256 constant AMOUNT = 1000e6;

  IUsdscLive usdsc;
  address payer;
  address relayer = makeAddr('relayer');
  address observer = makeAddr('observer');

  function setUp() public {
    if (!vm.envOr('RUN_SONEIUM_FORK', false)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(vm.envOr('SONEIUM_RPC_URL', string('https://rpc.soneium.org')));
    usdsc = IUsdscLive(VAULT.asset());
    address v2 = address(new EarnVaultV2());
    bytes memory init2 = abi.encodeCall(EarnVaultV2.initializeV2, (makeAddr('boostKeeper'), 10_000e6));
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(address(VAULT)), v2, init2);

    payer = vm.addr(PAYER_KEY);
    deal(address(usdsc), payer, AMOUNT * 2);
    (bool locked, uint256 unlocksAt) = VAULT.depositsLocked();
    if (locked) vm.warp(unlocksAt);
  }

  function test_RelayedDepositWithLiveUsdscAuthorization() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, payer, AMOUNT, 'a');
    uint256 tp = VAULT.totalPrincipal();
    vm.prank(relayer);
    VAULT.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(VAULT.principal(payer), AMOUNT);
    assertEq(VAULT.totalPrincipal(), tp + AMOUNT);
    assertEq(usdsc.balanceOf(payer), AMOUNT);
    assertTrue(usdsc.authorizationState(payer, nonce));
    _assertSolvent();
  }

  /// @dev Front-running completes exactly the signed deposit; the direct token path is closed
  function test_FrontRunAndDirectExecution() public {
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(PAYER_KEY, payer, AMOUNT, 'b');

    vm.prank(observer);
    vm.expectRevert(abi.encodeWithSelector(IERC3009.CallerMustBePayee.selector, observer, address(VAULT)));
    usdsc.receiveWithAuthorization(payer, address(VAULT), AMOUNT, va, vb, nonce, sig);

    vm.prank(observer);
    vm.expectRevert(IERC712.SignerMismatch.selector);
    VAULT.depositWithAuthorization(payer, 1, va, vb, nonce, sig);

    vm.prank(observer);
    VAULT.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(VAULT.principal(payer), AMOUNT);
    assertEq(VAULT.principal(observer), 0);

    vm.prank(relayer);
    vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationAlreadyUsed.selector, payer, nonce));
    VAULT.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(VAULT.principal(payer), AMOUNT);
  }

  /// @dev Live USDSC verifies ERC-1271 smart-wallet signatures through the bytes overload
  function test_SmartWalletDepositWithLiveUsdsc() public {
    uint256 walletOwnerKey = 0xB0B;
    MockSmartWallet wallet = new MockSmartWallet(vm.addr(walletOwnerKey));
    deal(address(usdsc), address(wallet), AMOUNT);
    (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) = _authorize(walletOwnerKey, address(wallet), AMOUNT, 'c');
    vm.prank(relayer);
    VAULT.depositWithAuthorization(address(wallet), AMOUNT, va, vb, nonce, sig);
    assertEq(VAULT.principal(address(wallet)), AMOUNT);
  }

  /// @dev The real redistributor's snapshot locks it like deposit(), without consuming the
  ///      authorization; the same signature works once the window has passed
  function test_LockedByRealSnapshot_AuthorizationStaysUsable() public {
    (uint256 va,, bytes32 nonce,) = _authorize(PAYER_KEY, payer, AMOUNT, 'd');
    uint256 vb = block.timestamp + 1 days;
    bytes memory sig = _sign(PAYER_KEY, payer, AMOUNT, va, vb, nonce);

    vm.warp(block.timestamp + 1 hours);
    vm.roll(block.number + 1800);
    vm.prank(RR_OPERATOR);
    RR.snapshotVaultTVLs();
    (bool locked, uint256 unlocksAt) = VAULT.depositsLocked();
    assertTrue(locked);

    vm.prank(relayer);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, unlocksAt));
    VAULT.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertFalse(usdsc.authorizationState(payer, nonce));

    vm.warp(unlocksAt);
    vm.prank(relayer);
    VAULT.depositWithAuthorization(payer, AMOUNT, va, vb, nonce, sig);
    assertEq(VAULT.principal(payer), AMOUNT);
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------

  function _authorize(
    uint256 key,
    address from,
    uint256 amount,
    bytes memory salt
  ) internal view returns (uint256 va, uint256 vb, bytes32 nonce, bytes memory sig) {
    (va, vb, nonce) = (block.timestamp - 1, block.timestamp + 1 hours, keccak256(salt));
    sig = _sign(key, from, amount, va, vb, nonce);
  }

  function _sign(
    uint256 key,
    address from,
    uint256 amount,
    uint256 va,
    uint256 vb,
    bytes32 nonce
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(
      abi.encode(usdsc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, address(VAULT), amount, va, vb, nonce)
    );
    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', usdsc.DOMAIN_SEPARATOR(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
    return abi.encodePacked(r, s, v);
  }

  function _assertSolvent() internal view {
    assertGe(
      usdsc.balanceOf(address(VAULT)),
      VAULT.claimReserve() + VAULT.boostClaimReserve(address(usdsc)),
      'vault under-reserved'
    );
  }
}
