// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVault} from '../../src/vaults/earn/EarnVault.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockERC20Permit} from '../mocks/MockERC20Permit.sol';
import {MockSnapshotRedistributor} from '../mocks/MockSnapshotRedistributor.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {Test} from 'lib/forge-std/src/Test.sol';

/// @title depositWithPermit when the permit has already been used
/// @notice A relayed depositWithPermit() must not fail just because someone submitted the same permit
///         to the token first (consuming its nonce): if the allowance the permit grants is in place,
///         the deposit goes ahead and is credited to the token owner. It still reverts PermitFailed
///         when no sufficient allowance exists.
contract EarnVaultPermitDepositTest is Test {
  EarnVaultV2 vault;
  MockERC20Permit usdsc;
  MockSnapshotRedistributor redistributor;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address relayer = makeAddr('relayer');
  address observer = makeAddr('observer');

  uint256 constant OWNER_KEY = 0xA11CE;
  address tokenOwner;
  uint256 constant AMOUNT = 5000e6;

  function setUp() public {
    tokenOwner = vm.addr(OWNER_KEY);
    usdsc = new MockERC20Permit('USDSC', 'USDSC');
    redistributor = new MockSnapshotRedistributor(5 minutes);
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        address(redistributor),
        treasury,
        pauser,
        makeAddr('boostRewardKeeper')
      )
    );
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), adminSlot)))));
    address impl = address(new EarnVaultV2());
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (makeAddr('boostKeeper'), type(uint256).max))
    );
    vault = EarnVaultV2(payable(address(proxy)));
    usdsc.mint(tokenOwner, AMOUNT * 3);
  }

  // ---------------------------------------------------------------------------------------------
  // The scenario from the review: the permit is submitted to the token first
  // ---------------------------------------------------------------------------------------------

  function test_PermitAlreadySubmitted_RelayedDepositStillSucceeds() public {
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), AMOUNT, deadline);

    // someone submits the same permit to the token first: nonce used, allowance set
    vm.prank(observer);
    usdsc.permit(tokenOwner, address(vault), AMOUNT, deadline, v, r, s);
    assertEq(usdsc.allowance(tokenOwner, address(vault)), AMOUNT);

    vm.prank(relayer);
    vault.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);

    assertEq(vault.principal(tokenOwner), AMOUNT, 'credited to the token owner');
    assertEq(vault.principal(relayer), 0);
    assertEq(vault.principal(observer), 0);
    assertEq(usdsc.balanceOf(observer), 0, 'the observer gains nothing');
    assertEq(usdsc.allowance(tokenOwner, address(vault)), 0, 'allowance used exactly once');
  }

  /// @dev The same permit relayed twice: the second call has neither a valid permit nor allowance
  function test_SamePermitRelayedTwice_SecondReverts() public {
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), AMOUNT, deadline);
    vm.prank(relayer);
    vault.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);

    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    vault.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
    assertEq(vault.principal(tokenOwner), AMOUNT);
  }

  // ---------------------------------------------------------------------------------------------
  // A failed permit without sufficient allowance still reverts
  // ---------------------------------------------------------------------------------------------

  function test_InvalidPermitAndNoAllowance_Reverts() public {
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(makeAddr('someoneElse'), AMOUNT, deadline); // wrong spender
    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    vault.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
  }

  function test_ExpiredPermitAndNoAllowance_Reverts() public {
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), AMOUNT, deadline);
    vm.warp(deadline + 1);
    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    vault.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
  }

  /// @dev An existing allowance one unit short of the amount: the deposit reverts
  function test_FailedPermitAllowanceOneShort_Reverts() public {
    vm.prank(tokenOwner);
    usdsc.approve(address(vault), AMOUNT - 1);
    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    vault.depositWithPermit(tokenOwner, AMOUNT, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
  }

  /// @dev An existing allowance exactly covering the amount: the deposit goes ahead
  function test_FailedPermitAllowanceExact_Deposits() public {
    vm.prank(tokenOwner);
    usdsc.approve(address(vault), AMOUNT);
    vm.prank(relayer);
    vault.depositWithPermit(tokenOwner, AMOUNT, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    assertEq(vault.principal(tokenOwner), AMOUNT);
    assertEq(vault.principal(relayer), 0);
  }

  /// @dev With an infinite approval, a third party can trigger a deposit of the owner's approved
  ///      USDSC, but only ever into the owner's own position: no value moves to anyone else
  function test_InfiniteApproval_ThirdPartyDepositIsCreditedOnlyToOwner() public {
    vm.prank(tokenOwner);
    usdsc.approve(address(vault), type(uint256).max);
    uint256 ownerBalance = usdsc.balanceOf(tokenOwner);

    vm.prank(observer);
    vault.depositWithPermit(tokenOwner, ownerBalance, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));

    assertEq(vault.principal(tokenOwner), ownerBalance, 'all of it credited to the owner');
    assertEq(vault.principal(observer), 0);
    assertEq(vault.totalPrincipal(), ownerBalance, 'nobody else was credited');
    assertEq(usdsc.balanceOf(observer), 0);

    // and the owner can take it straight back out
    vm.prank(tokenOwner);
    vault.withdraw(ownerBalance);
    assertEq(usdsc.balanceOf(tokenOwner), ownerBalance);
  }

  /// @dev A contract relayer gets no credit and holds no tokens afterwards
  function test_ContractRelayer_CannotRedirectCredit() public {
    PermitRelayer relayerContract = new PermitRelayer();
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), AMOUNT, deadline);
    vm.prank(observer);
    usdsc.permit(tokenOwner, address(vault), AMOUNT, deadline, v, r, s);

    relayerContract.relay(vault, tokenOwner, AMOUNT, deadline, v, r, s);

    assertEq(vault.principal(tokenOwner), AMOUNT);
    assertEq(vault.principal(address(relayerContract)), 0);
    assertEq(vault.totalPrincipal(), AMOUNT, 'only the owner was credited');
    assertEq(usdsc.balanceOf(address(relayerContract)), 0);
  }

  // ---------------------------------------------------------------------------------------------
  // Everything else around depositWithPermit is unchanged
  // ---------------------------------------------------------------------------------------------

  function test_ValidPermit_StillWorks() public {
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), AMOUNT, deadline);
    vm.prank(relayer);
    vault.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
    assertEq(vault.principal(tokenOwner), AMOUNT);
  }

  function test_BlacklistedOwnerWithAllowance_StillReverts() public {
    vm.prank(tokenOwner);
    usdsc.approve(address(vault), AMOUNT);
    vm.prank(owner);
    vault.setBlacklisted(tokenOwner, true);
    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.depositWithPermit(tokenOwner, AMOUNT, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
  }

  function test_AllowanceInPlaceButDepositsLocked_StillReverts() public {
    vm.prank(tokenOwner);
    usdsc.approve(address(vault), AMOUNT);
    redistributor.setSnapshot(block.timestamp, 5 minutes);
    vm.prank(relayer);
    vm.expectRevert(
      abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, block.timestamp + 5 minutes + 1)
    );
    vault.depositWithPermit(tokenOwner, AMOUNT, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
  }

  // ---------------------------------------------------------------------------------------------
  // Non-upgradeable twin
  // ---------------------------------------------------------------------------------------------

  function test_Twin_PermitAlreadySubmitted_RelayedDepositStillSucceeds() public {
    EarnVault twin = new EarnVault(address(usdsc), owner, makeAddr('r'), treasury, pauser, makeAddr('k'));
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _sign(address(twin), AMOUNT, deadline);
    vm.prank(observer);
    usdsc.permit(tokenOwner, address(twin), AMOUNT, deadline, v, r, s);

    vm.prank(relayer);
    twin.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
    assertEq(twin.principal(tokenOwner), AMOUNT);

    vm.prank(relayer);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    twin.depositWithPermit(tokenOwner, AMOUNT, deadline, v, r, s);
  }

  // ---------------------------------------------------------------------------------------------

  function _sign(address spender, uint256 value, uint256 deadline) internal view returns (uint8, bytes32, bytes32) {
    bytes32 typeHash = keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');
    bytes32 structHash = keccak256(abi.encode(typeHash, tokenOwner, spender, value, usdsc.nonces(tokenOwner), deadline));
    bytes32 digest =
      keccak256(abi.encodePacked('\x19\x01', IERC20Permit(address(usdsc)).DOMAIN_SEPARATOR(), structHash));
    return vm.sign(OWNER_KEY, digest);
  }
}

/// @dev A contract that relays depositWithPermit on someone else's behalf
contract PermitRelayer {
  function relay(
    EarnVaultV2 vault,
    address owner_,
    uint256 amount,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external {
    vault.depositWithPermit(owner_, amount, deadline, v, r, s);
  }
}
