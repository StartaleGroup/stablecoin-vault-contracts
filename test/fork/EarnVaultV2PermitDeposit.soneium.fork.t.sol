// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {Test} from 'forge-std/Test.sol';

/// @title depositWithPermit on the live vault, with the live USDSC permit
/// @notice Forks Soneium, upgrades the live EarnVault to EarnVaultV2 through the owner Safe, and checks
///         that when the same permit was already submitted to USDSC only the token owner can complete
///         the deposit (a relayer gets PermitFailed), and that it still reverts PermitFailed without a
///         sufficient allowance.
/// @dev Opt-in:
///        RUN_SONEIUM_FORK=true forge test --match-path test/fork/EarnVaultV2PermitDeposit.soneium.fork.t.sol \
///          --libraries src/vaults/earn/BoostRewardsLib.sol:BoostRewardsLib:0x674894C99714bf7E6Acdd9a73d46c6f9EACe66CE -vv
contract EarnVaultV2PermitDepositSoneiumFork is Test {
  EarnVaultV2 constant VAULT = EarnVaultV2(payable(0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0));
  ProxyAdmin constant PROXY_ADMIN = ProxyAdmin(0xDBc42e5c7E6BF89886F2f359F9b0BB9344824066);
  address constant OWNER_SAFE = 0x3C27038D9906caa5D68355B1800625EAcaCd93dA;

  uint256 constant OWNER_KEY = 0xA11CE;
  uint256 constant AMOUNT = 1000e6;

  IERC20 usdsc;
  address tokenOwner;
  address relayer = makeAddr('relayer');
  address observer = makeAddr('observer');

  function setUp() public {
    if (!vm.envOr('RUN_SONEIUM_FORK', false)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(vm.envOr('SONEIUM_RPC_URL', string('https://rpc.soneium.org')));
    usdsc = IERC20(VAULT.asset());
    tokenOwner = vm.addr(OWNER_KEY);

    address impl = address(new EarnVaultV2());
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(
      ITransparentUpgradeableProxy(address(VAULT)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (makeAddr('boostKeeper'), 10_000e6))
    );
    deal(address(usdsc), tokenOwner, AMOUNT * 2);
    _unlockDeposits();
  }

  function test_PermitAlreadySubmitted_OnlyOwnerCanDeposit() public {
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(AMOUNT, deadline);

    // the same permit reaches USDSC first
    vm.prank(observer);
    IERC20Permit(address(usdsc)).permit(tokenOwner, address(VAULT), AMOUNT, deadline, v, r, s);

    uint256 before = VAULT.principal(tokenOwner);

    // a relayer can no longer complete it on the owner's behalf
    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    VAULT.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
    assertEq(VAULT.principal(tokenOwner), before);

    // the owner can
    vm.prank(tokenOwner);
    VAULT.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);

    assertEq(VAULT.principal(tokenOwner), before + AMOUNT, 'credited to the token owner');
    assertEq(VAULT.principal(relayer), 0);
    assertEq(VAULT.principal(observer), 0);
    assertEq(usdsc.allowance(tokenOwner, address(VAULT)), 0, 'allowance used exactly once');
  }

  function test_ValidPermit_StillWorks() public {
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(AMOUNT, deadline);
    vm.prank(relayer);
    VAULT.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
    assertEq(VAULT.principal(tokenOwner), AMOUNT);
  }

  function test_SamePermitRelayedTwice_SecondReverts() public {
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(AMOUNT, deadline);
    vm.prank(relayer);
    VAULT.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    VAULT.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
  }

  function test_BadPermitAndNoAllowance_Reverts() public {
    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    VAULT.depositWithPermit(tokenOwner, AMOUNT, block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(2)));
  }

  // ---------------------------------------------------------------------------------------------

  function _sign(uint256 value, uint256 deadline) internal view returns (uint8, bytes32, bytes32) {
    bytes32 typeHash = keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');
    bytes32 structHash = keccak256(
      abi.encode(typeHash, tokenOwner, address(VAULT), value, IERC20Permit(address(usdsc)).nonces(tokenOwner), deadline)
    );
    bytes32 digest =
      keccak256(abi.encodePacked('\x19\x01', IERC20Permit(address(usdsc)).DOMAIN_SEPARATOR(), structHash));
    return vm.sign(OWNER_KEY, digest);
  }

  function _unlockDeposits() internal {
    (bool locked, uint256 unlocksAt) = VAULT.depositsLocked();
    if (locked) vm.warp(unlocksAt);
  }
}
