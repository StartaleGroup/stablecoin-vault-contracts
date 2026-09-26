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
  address public boostKeeper;
  uint256 public boostCycleId;

  /// @notice Upper bound on per-user settlements performed so far (each floors <= 1 wei of
  ///         yield in the vault's favour). Over-counting only loosens the dust bound below.
  uint256 public settleOps;
  /// @notice Two INELIGIBLE entries mixed into credit batches: the vault itself and an
  ///         always-blacklisted address. onBoostCredit() must skip both.
  address public blacklistedAddr;
  uint256 public constant INELIGIBLE_ENTRIES = 2;
  /// @notice onYield() calls so far (each index update floors < 1 wei in the vault's favour)
  uint256 public yieldOps;

  address[] public users;
  uint256 public constant MAX_USERS = 15;
  uint256 public constant MAX_AMOUNT = 1_000_000e6;

  constructor(
    EarnVaultV2 _vault,
    MockUSDSC _usdsc,
    MockUSDSC _boostToken,
    address _redistributor,
    address _operator,
    address _boostKeeper
  ) {
    vault = _vault;
    usdsc = _usdsc;
    boostToken = _boostToken;
    redistributor = _redistributor;
    operator = _operator;
    boostKeeper = _boostKeeper;
    blacklistedAddr = makeAddr('handlerBlacklisted');

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

    settleOps++;
    vm.prank(user);
    vault.deposit(amount);
  }

  function withdraw(uint256 userIndex, uint256 amount) external {
    userIndex = bound(userIndex, 0, users.length - 1);
    address user = users[userIndex];
    uint256 p = vault.principal(user);
    if (p == 0) return;
    amount = bound(amount, 1, p);

    settleOps++;
    vm.prank(user);
    vault.withdraw(amount);
  }

  function claim(uint256 userIndex) external {
    userIndex = bound(userIndex, 0, users.length - 1);
    address user = users[userIndex];
    settleOps++;

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
    settleOps++;
    vault.compound(users[userIndex]); // permissionless, never reverts on a no-op
  }

  function compoundMany(uint256 countSeed) external {
    uint256 count = bound(countSeed, 1, users.length);
    address[] memory batch = new address[](count);
    for (uint256 i = 0; i < count; i++) {
      batch[i] = users[i];
    }
    settleOps += count;
    vault.compoundMany(batch);
  }

  function onYield(uint256 amount) external {
    if (vault.totalPrincipal() == 0) return;
    amount = bound(amount, 1, MAX_AMOUNT / 10);

    // Mint exactly `amount` more so the balance stays ahead of claimReserve + amount,
    // matching how a real yield redistributor funds the vault before calling onYield().
    usdsc.mint(address(vault), amount);
    yieldOps++;
    vm.prank(redistributor);
    vault.onYield(amount);
  }

  /// @dev Credit pool index -> address: every handler user, then the vault itself, then the
  ///      always-blacklisted address (the two ineligible entries onBoostCredit() must skip).
  function _poolAddress(uint256 i) internal view returns (address) {
    if (i < users.length) return users[i];
    return i == users.length ? address(vault) : blacklistedAddr;
  }

  /// @dev Credits a batch of distinct addresses (contiguous from a random offset, wrapping), so
  ///      it never trips the duplicate-in-batch StaleCycle revert; cycleId strictly increases
  ///      per call, so it never trips the replay guard either. Amounts may be zero on purpose.
  function onBoostCredit(uint256 offsetSeed, uint256 countSeed, uint256 amountSeed) external {
    // pool = every user address plus the two ineligible ones; contiguous distinct window
    uint256 pool = users.length + INELIGIBLE_ENTRIES;
    uint256 count = bound(countSeed, 1, pool);
    uint256 offset = bound(offsetSeed, 0, pool - 1);
    address[] memory batch = new address[](count);
    uint256[] memory amounts = new uint256[](count);
    uint256 total = 0;
    for (uint256 i = 0; i < count; i++) {
      batch[i] = _poolAddress((offset + i) % pool);
      amounts[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 0, MAX_AMOUNT / 10);
      total += amounts[i];
    }

    // Fund first, exactly like the real keeper flow (transfer USDSC in, then call).
    usdsc.mint(address(vault), total);
    // Always open the next cycle, using latestCycleId + 1 read from chain (an all-skipped batch
    // doesn't advance it, so the next call just retries that cycle).
    boostCycleId = vault.latestCycleId() + 1;
    settleOps += count;
    vm.prank(boostKeeper);
    vault.onBoostCredit(boostCycleId, batch, amounts);
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
///         onBoostReward/onBoostCredit via the handler above, checking these properties hold after every
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

    address boostKeeper = makeAddr('boostKeeper');

    EarnVaultV2 v2Implementation = new EarnVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector, boostKeeper, type(uint256).max)
    );

    vault = EarnVaultV2(payable(address(proxy)));

    handler = new EarnVaultV2Handler(vault, usdsc, boostToken, redistributor, operator, boostKeeper);
    address blacklisted = handler.blacklistedAddr(); // read BEFORE the prank - an external call would consume it
    vm.prank(owner);
    vault.setBlacklisted(blacklisted, true);

    bytes4[] memory selectors = new bytes4[](8);
    selectors[0] = EarnVaultV2Handler.deposit.selector;
    selectors[1] = EarnVaultV2Handler.withdraw.selector;
    selectors[2] = EarnVaultV2Handler.claim.selector;
    selectors[3] = EarnVaultV2Handler.compound.selector;
    selectors[4] = EarnVaultV2Handler.compoundMany.selector;
    selectors[5] = EarnVaultV2Handler.onYield.selector;
    selectors[6] = EarnVaultV2Handler.onBoostReward.selector;
    selectors[7] = EarnVaultV2Handler.onBoostCredit.selector;

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
    uint256 owed = vault.totalPrincipal() + sumAccrued + sumPending;
    uint256 reserve = vault.claimReserve();
    // Solvency, exact: every rounding step floors in the vault's favour, so the reserve can
    // never fall below what users are owed - not even by 1 wei.
    assertGe(reserve, owed, 'claimReserve below accounted user value');
    // Dust bound - DERIVED, not fitted:
    //  - claimReserve moves 1:1 with deposits, withdrawals, onYield amounts and credited boost.
    //  - onYield indexes with a remainder carry: delta = floor((amount*RAY + carry)/TP), carry kept.
    //    Summed over all yields this telescopes: total yield = indexed value + carry/RAY, and
    //    carry < TP, so the index side leaves < 1 wei IN TOTAL (while TP < 1e27 raw units).
    //  - Every principal change (_deposit, withdraw, _creditBoostEntry) settles the user first, so
    //    each settlement floors one p*(gi-ui)/RAY: a fractional loss in [0, 1).
    //  - pendingYield() floors each user's un-settled amount the same way in `owed` above.
    //  => 0 <= reserve - owed < 1 + settlements + users, and both sides are integers, so
    //     reserve - owed <= settlements + users. The bound below is that plus yieldOps (slack the
    //     carry makes unnecessary); settleOps over-counts settlements, which only loosens it. A fixed
    //     tolerance instead grows stale with run depth, which is why the old one failed spuriously.
    //  Mutation-checked: over-crediting 1 wei per settle fails the assertGe above; leaking 1000 wei
    //  per settle fails the assertLe below.
    assertLe(
      reserve - owed, handler.settleOps() + handler.yieldOps() + handler.MAX_USERS(), 'rounding dust exceeds bound'
    );
  }

  /// @notice The vault must always hold enough USDSC to cover claimReserve - the funding
  ///         invariant carried over unchanged from V1.
  /// @notice Skipped entries never credit anyone: the vault's own address and the blacklisted
  ///         address (both mixed into every credit pool) never hold principal.
  /// @notice No address's replay guard can ever be ahead of the global cycle counter - the property
  ///         that makes a permanent lockout structurally impossible (the keeper can always credit
  ///         anyone at latestCycleId + 1).
  function invariant_LastCreditedCycleNeverExceedsLatestCycle() external view {
    uint256 latest = vault.latestCycleId();
    for (uint256 i = 0; i < handler.MAX_USERS(); i++) {
      assertLe(vault.lastCreditedCycle(handler.users(i)), latest);
    }
    assertLe(vault.lastCreditedCycle(handler.blacklistedAddr()), latest);
    assertLe(vault.lastCreditedCycle(address(vault)), latest);
  }

  function invariant_IneligibleAddressesNeverCredited() external view {
    assertEq(vault.principal(address(vault)), 0);
    assertEq(vault.principal(handler.blacklistedAddr()), 0);
  }

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
