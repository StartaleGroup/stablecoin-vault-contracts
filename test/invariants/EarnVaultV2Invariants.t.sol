// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {Test} from 'forge-std/Test.sol';

/// @title EarnVaultV2Handler
/// @notice Bounded fuzz-target actions for the invariant suite below, mirroring the
///         Handler pattern already used by SUSDSCVaultInvariants.t.sol. Every action is
///         defensively bounded/early-returning so it never reverts on its own (invariant.
///         fail_on_revert = true in foundry.toml means a stray revert here would kill a run).
contract EarnVaultV2Handler is Test {
  EarnVaultV2 public vault;
  MockUSDSC public usdsc;
  MockUSDSC public boostToken;
  address public redistributor;
  address public operator;

  address[] public users;
  uint256 public constant MAX_USERS = 15;
  uint256 public constant MAX_AMOUNT = 1_000_000e6;

  constructor(EarnVaultV2 _vault, MockUSDSC _usdsc, MockUSDSC _boostToken, address _redistributor, address _operator) {
    vault = _vault;
    usdsc = _usdsc;
    boostToken = _boostToken;
    redistributor = _redistributor;
    operator = _operator;

    for (uint256 i = 0; i < MAX_USERS; i++) {
      address user = makeAddr(string(abi.encodePacked('handlerUser', i)));
      users.push(user);
      usdsc.mint(user, MAX_AMOUNT);
      vm.prank(user);
      usdsc.approve(address(vault), type(uint256).max);
    }
  }

  function deposit(uint256 userIndex, uint256 amount) external {
    userIndex = bound(userIndex, 0, users.length - 1);
    address user = users[userIndex];
    uint256 balance = usdsc.balanceOf(user);
    if (balance == 0) return;
    amount = bound(amount, 1, balance);

    vm.prank(user);
    vault.deposit(amount);
  }

  function withdraw(uint256 userIndex, uint256 amount) external {
    userIndex = bound(userIndex, 0, users.length - 1);
    address user = users[userIndex];
    uint256 p = vault.principal(user);
    if (p == 0) return;
    amount = bound(amount, 1, p);

    vm.prank(user);
    vault.withdraw(amount);
  }

  function claim(uint256 userIndex) external {
    userIndex = bound(userIndex, 0, users.length - 1);
    address user = users[userIndex];

    // claim() reverts with NothingToClaim() if there's nothing to pay out - avoid wasting a
    // fuzz run on a known-guaranteed revert by checking first.
    if (vault.claimable(user) > 0) {
      vm.prank(user);
      vault.claim();
      return;
    }
    (,, uint256[] memory boostAmounts) = vault.getAllClaimables(user);
    for (uint256 i = 0; i < boostAmounts.length; i++) {
      if (boostAmounts[i] > 0) {
        vm.prank(user);
        vault.claim();
        return;
      }
    }
  }

  function compound(uint256 userIndex) external {
    userIndex = bound(userIndex, 0, users.length - 1);
    vault.compound(users[userIndex]); // permissionless, never reverts on a no-op
  }

  function compoundMany(uint256 countSeed) external {
    uint256 count = bound(countSeed, 1, users.length);
    address[] memory batch = new address[](count);
    for (uint256 i = 0; i < count; i++) {
      batch[i] = users[i];
    }
    vault.compoundMany(batch);
  }

  function onYield(uint256 amount) external {
    if (vault.totalPrincipal() == 0) return;
    amount = bound(amount, 1, MAX_AMOUNT / 10);

    // Mint exactly `amount` more so the balance stays ahead of claimReserve + amount,
    // matching how a real yield redistributor funds the vault before calling onYield().
    usdsc.mint(address(vault), amount);
    vm.prank(redistributor);
    vault.onYield(amount);
  }

  function onBoostReward(uint256 amount) external {
    if (vault.totalPrincipal() == 0) return;
    amount = bound(amount, 1, MAX_AMOUNT / 10);

    boostToken.mint(address(vault), amount);
    vm.prank(operator);
    vault.onBoostReward(address(boostToken), amount);
  }
}

/// @title EarnVaultV2 stateful invariants
/// @notice Deploys EarnVaultV2 directly (steady-state fuzzing, not the upgrade boundary -
///         that's covered separately by EarnVaultAutoCompound.t.sol's upgrade-path tests) and
///         runs arbitrary sequences of deposit/withdraw/claim/compound/compoundMany/onYield/
///         onBoostReward via the handler above, checking these properties hold after every
///         sequence regardless of ordering.
contract EarnVaultV2Invariants is StdInvariant, Test {
  EarnVaultV2 internal vault;
  MockUSDSC internal usdsc;
  MockUSDSC internal boostToken;
  EarnVaultV2Handler internal handler;

  uint256 internal constant RAY = 1e27;

  address internal admin = makeAddr('admin');
  address internal owner = makeAddr('owner');
  address internal redistributor = makeAddr('redistributor');
  address internal treasury = makeAddr('treasury');
  address internal pauser = makeAddr('pauser');
  address internal operator = makeAddr('operator');

  function setUp() external {
    usdsc = new MockUSDSC();
    boostToken = new MockUSDSC();

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2Implementation), '');

    vault = EarnVaultV2(payable(address(proxy)));

    handler = new EarnVaultV2Handler(vault, usdsc, boostToken, redistributor, operator);

    bytes4[] memory selectors = new bytes4[](7);
    selectors[0] = EarnVaultV2Handler.deposit.selector;
    selectors[1] = EarnVaultV2Handler.withdraw.selector;
    selectors[2] = EarnVaultV2Handler.claim.selector;
    selectors[3] = EarnVaultV2Handler.compound.selector;
    selectors[4] = EarnVaultV2Handler.compoundMany.selector;
    selectors[5] = EarnVaultV2Handler.onYield.selector;
    selectors[6] = EarnVaultV2Handler.onBoostReward.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  /// @notice totalPrincipal must always exactly equal the sum of every user's own principal -
  ///         this is the ledger `_settle()`'s auto-compounding fold has to keep in lockstep.
  function invariant_TotalPrincipalEqualsSumOfUserPrincipal() external view {
    uint256 sum = 0;
    for (uint256 i = 0; i < handler.MAX_USERS(); i++) {
      sum += vault.principal(handler.users(i));
    }
    assertEq(vault.totalPrincipal(), sum);
  }

  /// @notice claimReserve must always cover totalPrincipal plus every user's own accrued and
  ///         pending (not-yet-settled) yield - this is the funding invariant that makes
  ///         compounding safe to be a pure internal relabeling with no token movement.
  function invariant_ClaimReserveCoversAccountedValue() external view {
    uint256 sumAccrued = 0;
    uint256 sumPending = 0;
    for (uint256 i = 0; i < handler.MAX_USERS(); i++) {
      address user = handler.users(i);
      sumAccrued += vault.accrued(user);
      sumPending += vault.pendingYield(user);
    }
    // Each independent settlement floors at RAY precision, so a few wei of dust can
    // accumulate across many users/rounds over an invariant run's full depth.
    assertApproxEqAbs(vault.claimReserve(), vault.totalPrincipal() + sumAccrued + sumPending, handler.MAX_USERS() * 2);
  }

  /// @notice The vault must always hold enough USDSC to cover claimReserve - the funding
  ///         invariant carried over unchanged from V1.
  function invariant_VaultBalanceCoversClaimReserve() external view {
    assertGe(usdsc.balanceOf(address(vault)), vault.claimReserve());
  }

  /// @notice globalIndex only ever increases from its RAY-scaled starting point (onYield only
  ///         ever adds a non-negative delta; nothing in this contract can decrease it).
  function invariant_GlobalIndexNeverBelowInitialRay() external view {
    assertGe(vault.globalIndex(), RAY);
  }

  /// @notice The vault must always hold enough of a boost token to cover what every tracked
  ///         user could currently claim of it - the boost-side funding invariant, unaffected
  ///         by USDSC auto-compounding since the two are independent index systems.
  function invariant_BoostTokenBalanceCoversClaimableAcrossUsers() external view {
    uint256 sumClaimable = 0;
    for (uint256 i = 0; i < handler.MAX_USERS(); i++) {
      sumClaimable += vault.getClaimableBoostReward(handler.users(i), address(boostToken));
    }
    assertGe(boostToken.balanceOf(address(vault)), sumClaimable);
  }

  /// @notice The read-only accounting views must never revert for any tracked user, regardless
  ///         of what sequence of actions produced the current state.
  function invariant_ReadOnlyViewsNeverRevert() external view {
    for (uint256 i = 0; i < handler.MAX_USERS(); i++) {
      address user = handler.users(i);
      vault.pendingYield(user);
      vault.claimable(user);
      vault.totalValue(user);
      vault.getUserInfo(user);
      vault.getAllClaimables(user);
    }
  }
}
