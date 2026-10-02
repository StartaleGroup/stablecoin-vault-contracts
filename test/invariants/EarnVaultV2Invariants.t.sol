// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockSnapshotRedistributor} from '../mocks/MockSnapshotRedistributor.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {Test} from 'forge-std/Test.sol';

/// @dev Finite per-batch cap the vault is initialized with. Handler entries are up to
///      MAX_AMOUNT / 10 each and a batch has up to MAX_USERS eligible entries, so fuzzed batches land
///      on both sides of it and the BoostBatchCapExceeded path is exercised, not just the happy path.
uint256 constant BOOST_CAP = 500_000e6;

/// @title EarnVaultV2Handler
/// @notice Bounded fuzz-target actions for the invariant suite below, mirroring the
///         Handler pattern already used by SUSDSCVaultInvariants.t.sol. Every action is
///         defensively bounded/early-returning so it never reverts on its own (invariant.
///         fail_on_revert = true in foundry.toml means a stray revert here would kill a run).
contract EarnVaultV2Handler is Test {
  EarnVaultV2 public vault;
  MockUSDSC public usdsc;
  MockUSDSC public boostToken;
  MockSnapshotRedistributor public snapshotRedistributor;
  address public redistributor;
  address public operator;
  address public boostKeeper;
  uint256 public boostCycleId;

  /// @notice deposit() calls the handler issued while vault.depositsLocked() was true - each one
  ///         asserted DepositsLockedForDistribution and changed nothing (see deposit() below).
  uint256 public lockedDepositAttempts;

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
  /// @notice onBoostCredit() batches the cap rejected (each must have changed nothing)
  uint256 public capRejectedBatches;

  constructor(
    EarnVaultV2 _vault,
    MockUSDSC _usdsc,
    MockUSDSC _boostToken,
    MockSnapshotRedistributor _redistributor,
    address _operator,
    address _boostKeeper
  ) {
    vault = _vault;
    usdsc = _usdsc;
    boostToken = _boostToken;
    snapshotRedistributor = _redistributor;
    redistributor = address(_redistributor);
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

  /// @dev When vault.depositsLocked() is locked, deposit() must revert
  ///      DepositsLockedForDistribution and change nothing - asserted here with vm.expectRevert
  ///      rather than skipped, so fail_on_revert = true actually exercises the locked path
  ///      instead of a stray unexpected revert killing the run.
  function deposit(uint256 userIndex, uint256 amount) external {
    userIndex = bound(userIndex, 0, users.length - 1);
    address user = users[userIndex];
    uint256 balance = usdsc.balanceOf(user);
    if (balance == 0) return;
    amount = bound(amount, 1, balance);

    // Expected lock computed from the redistributor's own state, independently of the vault, so
    // a wrong lock formula in the vault fails here (fail_on_revert) instead of being mirrored.
    (bool locked, uint256 unlocksAt) = expectedLock();
    if (locked) {
      lockedDepositAttempts++;
      vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, unlocksAt));
      vm.prank(user);
      vault.deposit(amount);
      return;
    }

    settleOps++;
    vm.prank(user);
    vault.deposit(amount);
  }

  /// @notice Independent oracle for the deposit lock: the redistributor's snapshot is usable by
  ///         distribute() (RewardRedistributor._validateSnapShotAge semantics), and unlocksAt =
  ///         ts + maxAge + 1 (no saturation needed: ts and maxAge are small here).
  function expectedLock() public view returns (bool locked, uint256 unlocksAt) {
    uint256 ts = snapshotRedistributor.lastSnapshotTimestamp();
    uint256 maxAge = snapshotRedistributor.snapshotMaxAge();
    locked = ts != 0 && (block.timestamp < ts || block.timestamp - ts <= maxAge);
    unlocksAt = locked ? ts + maxAge + 1 : 0;
  }

  /// @notice Takes a fresh snapshot on the mock redistributor at the current block timestamp,
  ///         with a bounded maxAge - the only way the fuzzer can put the vault into the locked
  ///         state, since MockSnapshotRedistributor's snapshot is otherwise inert.
  function snapshot(uint256 maxAgeSeed) external {
    uint256 maxAge = bound(maxAgeSeed, 1 minutes, 1 hours);
    snapshotRedistributor.setSnapshot(block.timestamp, maxAge);
  }

  /// @notice Advances block.timestamp by a bounded amount, so fuzzed sequences cross in and out
  ///         of a snapshot's lock window (bounded well above the [1 minutes, 1 hours] maxAge
  ///         snapshot() can set, so both "still locked" and "expired" are reachable).
  function warp(uint256 secondsSeed) external {
    uint256 delta = bound(secondsSeed, 0, 2 hours);
    vm.warp(block.timestamp + delta);
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
  ///      A batch whose credited total exceeds BOOST_CAP is expected to revert whole; that path
  ///      asserts nothing changed, and the invariants then check the state it left behind.
  function onBoostCredit(uint256 offsetSeed, uint256 countSeed, uint256 amountSeed) external {
    // pool = every user address plus the two ineligible ones; contiguous distinct window
    uint256 pool = users.length + INELIGIBLE_ENTRIES;
    uint256 count = bound(countSeed, 1, pool);
    uint256 offset = bound(offsetSeed, 0, pool - 1);
    address[] memory batch = new address[](count);
    uint256[] memory amounts = new uint256[](count);
    uint256 total = 0;
    uint256 credited = 0; // what the vault will actually credit: skips excluded, like the cap
    for (uint256 i = 0; i < count; i++) {
      batch[i] = _poolAddress((offset + i) % pool);
      amounts[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 0, MAX_AMOUNT / 10);
      total += amounts[i];
      if (batch[i] != address(vault) && batch[i] != blacklistedAddr) credited += amounts[i];
    }

    // Fund first, exactly like the real keeper flow (transfer USDSC in, then call).
    usdsc.mint(address(vault), total);
    // Always open the next cycle, using latestCycleId + 1 read from chain (an all-skipped batch
    // doesn't advance it, so the next call just retries that cycle).
    boostCycleId = vault.latestCycleId() + 1;

    if (credited > BOOST_CAP) {
      uint256 latestBefore = vault.latestCycleId();
      uint256 principalBefore = vault.totalPrincipal();
      uint256 reserveBefore = vault.claimReserve();
      vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.BoostBatchCapExceeded.selector, credited, BOOST_CAP));
      vm.prank(boostKeeper);
      vault.onBoostCredit(boostCycleId, batch, amounts);
      // Rejected whole: nothing credited, the cycle not opened. The funding stays as surplus,
      // exactly as it would for a real keeper whose batch the cap rejected.
      assertEq(vault.latestCycleId(), latestBefore, 'cap-rejected batch advanced latestCycleId');
      assertEq(vault.totalPrincipal(), principalBefore, 'cap-rejected batch changed totalPrincipal');
      assertEq(vault.claimReserve(), reserveBefore, 'cap-rejected batch changed claimReserve');
      capRejectedBatches++;
      return;
    }

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
  /// @dev A contract redistributor (not an EOA, as the original harness used) so the handler's
  ///      snapshot()/warp() actions can actually exercise the JIT deposit lock - an EOA
  ///      redistributor would leave it permanently fail-open and never test the locked path.
  MockSnapshotRedistributor internal redistributor;
  address internal treasury = makeAddr('treasury');
  address internal pauser = makeAddr('pauser');
  address internal operator = makeAddr('operator');

  function setUp() external {
    usdsc = new MockUSDSC();
    boostToken = new MockUSDSC();
    redistributor = new MockSnapshotRedistributor(5 minutes);

    EarnVaultUpgradeable v1Implementation = new EarnVaultUpgradeable();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(v1Implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        address(redistributor),
        treasury,
        pauser,
        operator
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
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector, boostKeeper, BOOST_CAP)
    );

    vault = EarnVaultV2(payable(address(proxy)));

    handler = new EarnVaultV2Handler(vault, usdsc, boostToken, redistributor, operator, boostKeeper);
    address blacklisted = handler.blacklistedAddr(); // read BEFORE the prank - an external call would consume it
    vm.prank(owner);
    vault.setBlacklisted(blacklisted, true);

    bytes4[] memory selectors = new bytes4[](10);
    selectors[0] = EarnVaultV2Handler.deposit.selector;
    selectors[1] = EarnVaultV2Handler.withdraw.selector;
    selectors[2] = EarnVaultV2Handler.claim.selector;
    selectors[3] = EarnVaultV2Handler.compound.selector;
    selectors[4] = EarnVaultV2Handler.compoundMany.selector;
    selectors[5] = EarnVaultV2Handler.onYield.selector;
    selectors[6] = EarnVaultV2Handler.onBoostReward.selector;
    selectors[7] = EarnVaultV2Handler.onBoostCredit.selector;
    selectors[8] = EarnVaultV2Handler.snapshot.selector;
    selectors[9] = EarnVaultV2Handler.warp.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  /// @notice Guards the fuzz setup itself: with the handler's bounds, full batches do exceed
  ///         BOOST_CAP, so the cap-rejected path is really exercised. If a later change to the
  ///         bounds or the cap made it unreachable, this fails instead of the path going quiet.
  function test_HandlerCapRejectedPathIsReachable() external {
    uint256 fullPool = handler.MAX_USERS() + handler.INELIGIBLE_ENTRIES();
    for (uint256 seed = 0; seed < 20 && handler.capRejectedBatches() == 0; seed++) {
      handler.onBoostCredit(0, fullPool, seed);
    }
    assertGt(handler.capRejectedBatches(), 0, 'no fuzzed batch exceeded BOOST_CAP');
  }

  /// @notice Guards the fuzz setup for the JIT deposit lock: a snapshot() followed by a deposit()
  ///         in the same block really does hit the locked branch (asserted via vm.expectRevert
  ///         inside the handler), so this path isn't going quiet if a later change to the bounds
  ///         or the lock condition made it unreachable.
  function test_HandlerLockedDepositPathIsReachable() external {
    handler.snapshot(1 minutes);
    for (uint256 seed = 0; seed < 20 && handler.lockedDepositAttempts() == 0; seed++) {
      handler.deposit(seed, seed + 1);
    }
    assertGt(handler.lockedDepositAttempts(), 0, 'no fuzzed deposit hit the locked path');
  }

  /// @notice The vault's depositsLocked() view always equals the redistributor-window formula,
  ///         across every fuzzed sequence of snapshots, warps, yields and deposits.
  function invariant_DepositsLockedMatchesRedistributorWindow() external view {
    (bool locked, uint256 unlocksAt) = vault.depositsLocked();
    (bool expLocked, uint256 expUnlocksAt) = handler.expectedLock();
    assertEq(locked, expLocked, 'depositsLocked() != redistributor window');
    assertEq(unlocksAt, expUnlocksAt, 'unlocksAt mismatch');
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
