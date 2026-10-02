// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RewardRedistributor} from '../../src/distributor/RewardRedistributor.sol';
import {
  IRewardRedistributorEventsAndErrors
} from '../../src/interfaces/distributor/IRewardRedistributorEventsAndErrors.sol';
import {IEarnVault} from '../../src/interfaces/vaults/earn/IEarnVault.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockERC20Permit} from '../mocks/MockERC20Permit.sol';
import {MockERC4626Vault} from '../mocks/MockERC4626Vault.sol';
import {MockExtension} from '../mocks/MockExtension.sol';
import {
  MockEmptyReturnRedistributor,
  MockRevertingSnapshotRedistributor,
  MockSnapshotRedistributor,
  MockStateChangingSnapshotRedistributor
} from '../mocks/MockSnapshotRedistributor.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {console2} from 'forge-std/console2.sol';
import {Test} from 'lib/forge-std/src/Test.sol';
import {IERC4626} from 'lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol';

/// @title EarnVaultV2 JIT deposit lock
/// @notice Unit coverage for EarnVaultV2's `_depositLockState()` / `depositsLocked()` / the
///         `DepositsLockedForDistribution` revert wired into `_deposit()` - see
///         base-tier-auto-compounding.md's "JIT deposit lock (Phase 2)" section for the design.
/// @dev `vault`/`vaultEOA` both use `usdsc` (a permit-capable token, so this file can also drive
///      depositWithPermit) and differ only in their yieldRedistributor: a MockSnapshotRedistributor
///      CONTRACT vs a plain EOA address. The integration test further down deploys its own,
///      separate MockUSDSC-backed vault wired to a REAL RewardRedistributor, since
///      RewardRedistributor's yield-delivery mechanics (via MockExtension) are hardwired to
///      MockUSDSC - see that test's comment.
contract EarnVaultV2DepositLockTest is Test {
  MockERC20Permit internal usdsc;
  MockSnapshotRedistributor internal redistributor;
  EarnVaultV2 internal vault;

  address internal eoaRedistributor = makeAddr('eoaRedistributor');
  EarnVaultV2 internal vaultEOA;

  address internal admin = makeAddr('admin');
  address internal owner = makeAddr('owner');
  address internal treasury = makeAddr('treasury');
  address internal pauser = makeAddr('pauser');
  address internal operator = makeAddr('operator'); // V1's boostRewardKeeper
  address internal boostKeeper = makeAddr('boostKeeper');

  uint256 internal constant DEFAULT_MAX_AGE = 5 minutes;
  uint256 internal constant TEST_MAX_BOOST = type(uint256).max;
  bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);

  function setUp() public {
    usdsc = new MockERC20Permit('Mock USDSC', 'USDSC');
    redistributor = new MockSnapshotRedistributor(DEFAULT_MAX_AGE);

    vault = _deployV2Vault(address(usdsc), address(redistributor));
    vaultEOA = _deployV2Vault(address(usdsc), eoaRedistributor);
  }

  /// @dev Mirrors the proxy/upgrade setup used by EarnVaultV2BoostCreditTest.setUp(): V1 proxy,
  ///      then one ProxyAdmin.upgradeAndCall carrying initializeV2.
  function _deployV2Vault(address assetToken, address rdist) internal returns (EarnVaultV2) {
    EarnVaultUpgradeable v1Implementation = new EarnVaultUpgradeable();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(v1Implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, assetToken, owner, rdist, treasury, pauser, operator
      )
    );

    address proxyAdminAddress = address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));
    ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddress);

    EarnVaultV2 v2Implementation = new EarnVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector, boostKeeper, TEST_MAX_BOOST)
    );

    return EarnVaultV2(payable(address(proxy)));
  }

  function _mintApprove(address user, uint256 amount) internal {
    usdsc.mint(user, amount);
    vm.prank(user);
    usdsc.approve(address(vault), type(uint256).max);
  }

  function _getPermitSignature(
    address tokenOwnerAddr,
    address spender,
    uint256 value,
    uint256 deadline,
    uint256 privateKey
  ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
    bytes32 typeHash = keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');
    bytes32 domainSeparator = usdsc.DOMAIN_SEPARATOR();
    uint256 nonce = usdsc.nonces(tokenOwnerAddr);
    bytes32 structHash = keccak256(abi.encode(typeHash, tokenOwnerAddr, spender, value, nonce, deadline));
    bytes32 hash = keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
    return vm.sign(privateKey, hash);
  }

  // ---------------------------------------------------------------------
  // Basic lock state
  // ---------------------------------------------------------------------

  function test_NoSnapshotEver_DepositWorks_DepositsLockedFalse() public {
    (bool locked, uint256 unlocksAt) = vault.depositsLocked();
    assertFalse(locked);
    assertEq(unlocksAt, 0);

    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    vm.prank(alice);
    vault.deposit(1000e18);
    assertEq(vault.principal(alice), 1000e18);
  }

  function test_FreshSnapshotSameBlock_DepositAndDepositWithPermitRevert() public {
    uint256 ts = block.timestamp;
    redistributor.setSnapshot(ts, DEFAULT_MAX_AGE);
    uint256 expectedUnlocksAt = ts + DEFAULT_MAX_AGE + 1;

    (bool locked, uint256 unlocksAt) = vault.depositsLocked();
    assertTrue(locked);
    assertEq(unlocksAt, expectedUnlocksAt);

    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, expectedUnlocksAt));
    vault.deposit(1000e18);

    // depositWithPermit must revert the same way. It runs permit() before reaching _deposit(),
    // but the lock revert rolls back the whole call, so the permit nonce stays unused.
    (address tokenOwner, uint256 tokenOwnerKey) = makeAddrAndKey('permitOwner');
    usdsc.mint(tokenOwner, 1000e18);
    uint256 nonceBefore = usdsc.nonces(tokenOwner);
    uint256 deadline = block.timestamp + 1 hours;
    (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(tokenOwner, address(vault), 1000e18, deadline, tokenOwnerKey);

    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, expectedUnlocksAt));
    vault.depositWithPermit(tokenOwner, 1000e18, deadline, v, r, s);
    assertEq(usdsc.nonces(tokenOwner), nonceBefore, 'permit nonce must be unchanged by a locked deposit');
  }

  function test_Boundary_LockedAtMaxAge_UnlockedAtMaxAgePlusOne() public {
    uint256 ts = block.timestamp;
    redistributor.setSnapshot(ts, DEFAULT_MAX_AGE);

    vm.warp(ts + DEFAULT_MAX_AGE);
    (bool lockedAtBoundary,) = vault.depositsLocked();
    assertTrue(lockedAtBoundary, 'still locked exactly at snapTs + maxAge');

    address alice = makeAddr('alice');
    _mintApprove(alice, 2000e18);
    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, ts + DEFAULT_MAX_AGE + 1)
    );
    vault.deposit(1000e18);

    vm.warp(ts + DEFAULT_MAX_AGE + 1);
    (bool lockedAfter,) = vault.depositsLocked();
    assertFalse(lockedAfter, 'unlocked one second past snapTs + maxAge');

    vm.prank(alice);
    vault.deposit(1000e18);
    assertEq(vault.principal(alice), 1000e18);
  }

  // ---------------------------------------------------------------------
  // Integration: lock window vs. the real RewardRedistributor's acceptance window
  // ---------------------------------------------------------------------

  /// @dev Deploys its OWN MockUSDSC-backed vault (not the file's `vault`/`usdsc`, which is
  ///      permit-capable) and a REAL RewardRedistributor, because RewardRedistributor's yield
  ///      delivery (via test/mocks/MockExtension.sol, reused unchanged from
  ///      test/unit/RewardRedistributor.t.sol) is hardwired to the concrete MockUSDSC type: its
  ///      `transfer()` mints directly into the underlying MockUSDSC balance of the recipient, so
  ///      the vault's own asset must be that same MockUSDSC instance for the funding invariant
  ///      onYield() checks to hold. Asserts the vault's lock window is EXACTLY
  ///      RewardRedistributor.distribute()'s snapshot-acceptance window, at the three timestamps
  ///      that matter: the snapshot instant, the boundary (snapTs + maxAge), and one second past
  ///      it. Each check runs under vm.snapshotState()/revertToState so the three are independent
  ///      (distribute() is state-changing on success).
  function test_Integration_RealRewardRedistributor_LockWindowMatchesDistributeAcceptanceWindow() public {
    MockUSDSC rrUsdsc = new MockUSDSC();
    EarnVaultV2 rrVault = _deployV2Vault(address(rrUsdsc), makeAddr('placeholderRedistributor'));

    address alice = makeAddr('rrAlice');
    rrUsdsc.mint(alice, 10_000e6);
    vm.startPrank(alice);
    rrUsdsc.approve(address(rrVault), type(uint256).max);
    rrVault.deposit(5000e6);
    vm.stopPrank();

    MockExtension ext = new MockExtension(rrUsdsc, address(0), address(this));
    MockERC4626Vault sVault = new MockERC4626Vault(rrUsdsc);
    address rrAdmin = makeAddr('rrAdmin');
    address rrOperator = makeAddr('rrOperator');
    address rrTreasury = makeAddr('rrTreasury');
    RewardRedistributor rr = new RewardRedistributor(
      address(ext), rrTreasury, IEarnVault(address(rrVault)), IERC4626(address(sVault)), rrAdmin, rrOperator
    );
    ext.setYieldRecipient(address(rr));
    ext.setClaimer(address(rr));

    vm.prank(owner);
    rrVault.setYieldRedistributor(address(rr));

    ext.addPending(1000e6);
    vm.prank(rrOperator);
    rr.snapshotVaultTVLs();
    uint256 snapTs = block.timestamp;
    uint256 maxAge = rr.snapshotMaxAge();
    vm.roll(block.number + 1);

    _assertLockMatchesDistributeAcceptance(rrVault, rr, rrOperator, ext, snapTs, 'at snapshot timestamp');
    _assertLockMatchesDistributeAcceptance(rrVault, rr, rrOperator, ext, snapTs + maxAge, 'at snapTs + maxAge boundary');
    _assertLockMatchesDistributeAcceptance(
      rrVault, rr, rrOperator, ext, snapTs + maxAge + 1, 'one second past snapTs + maxAge'
    );
  }

  function _assertLockMatchesDistributeAcceptance(
    EarnVaultV2 rrVault,
    RewardRedistributor rr,
    address rrOperator,
    MockExtension ext,
    uint256 ts,
    string memory label
  ) internal {
    uint256 snapshotId = vm.snapshotState();
    vm.warp(ts);
    ext.addPending(1000e6); // keep `minted > 0` so the only possible revert is the age check

    (bool locked,) = rrVault.depositsLocked();

    vm.prank(rrOperator);
    bool reverted;
    try rr.distribute() {
      reverted = false;
    } catch (bytes memory reason) {
      reverted = true;
      // Every other distribute() precondition (role, pause, yield recipient, minted > 0,
      // S_base > 0, block already advanced past the snapshot block) is held constant across
      // all three checks here, so SnapshotTooOld is the only revert this can be.
      // forge-lint: disable-next-line(unsafe-typecast)
      assertEq(bytes4(reason), IRewardRedistributorEventsAndErrors.SnapshotTooOld.selector, label);
    }

    assertEq(locked, !reverted, label);
    vm.revertToState(snapshotId);
  }

  // ---------------------------------------------------------------------
  // What stays allowed while locked
  // ---------------------------------------------------------------------

  function test_WhileLocked_WithdrawClaimCompoundCompoundManyOnBoostCreditOnYieldAllSucceed() public {
    address alice = makeAddr('alice');
    address bob = makeAddr('bob');
    _mintApprove(alice, 10_000e18);
    usdsc.mint(bob, 10_000e18);
    vm.prank(bob);
    usdsc.approve(address(vault), type(uint256).max);

    vm.prank(alice);
    vault.deposit(5000e18);
    vm.prank(bob);
    vault.deposit(3000e18);

    // Give alice a boost-token claim so claim() has something to pay out: V2's claim() only
    // pays legacy `accrued` USDSC, which a fresh post-upgrade user never has (pending USDSC
    // yield auto-compounds into principal instead) - a boost reward is the only way to give a
    // brand-new V2 user something claim() actually pays.
    MockERC20Permit boostToken = new MockERC20Permit('Boost', 'BST');
    boostToken.mint(address(vault), 100e18);
    vm.prank(operator);
    vault.onBoostReward(address(boostToken), 100e18);

    redistributor.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);
    (bool locked,) = vault.depositsLocked();
    assertTrue(locked);

    vm.prank(bob);
    vault.withdraw(1000e18);
    assertEq(vault.principal(bob), 2000e18);

    assertGt(vault.getClaimableBoostReward(alice, address(boostToken)), 0);
    vm.prank(alice);
    vault.claim();

    vault.compound(alice);
    address[] memory batch = new address[](2);
    batch[0] = alice;
    batch[1] = bob;
    vault.compoundMany(batch);

    usdsc.mint(address(vault), 10e18);
    address[] memory creditUsers = new address[](1);
    creditUsers[0] = alice;
    uint256[] memory creditAmounts = new uint256[](1);
    creditAmounts[0] = 10e18;
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, creditUsers, creditAmounts);

    usdsc.mint(address(vault), 50e18);
    vm.prank(address(redistributor));
    vault.onYield(50e18);

    (bool stillLocked,) = vault.depositsLocked();
    assertTrue(stillLocked, 'none of the above are gated by the deposit lock');
  }

  function test_SecondOnYieldWithinSameSnapshotWindow_DepositsStillLocked() public {
    address alice = makeAddr('alice');
    _mintApprove(alice, 10_000e18);
    vm.prank(alice);
    vault.deposit(5000e18);

    redistributor.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);

    usdsc.mint(address(vault), 10e18);
    vm.prank(address(redistributor));
    vault.onYield(10e18);
    (bool lockedAfterFirst,) = vault.depositsLocked();
    assertTrue(lockedAfterFirst);

    usdsc.mint(address(vault), 5e18);
    vm.prank(address(redistributor));
    vault.onYield(5e18);
    (bool lockedAfterSecond,) = vault.depositsLocked();
    assertTrue(lockedAfterSecond, 'a second distribute() against the same snapshot must not unlock deposits');
  }

  // ---------------------------------------------------------------------
  // Fail-open / fail-closed
  // ---------------------------------------------------------------------

  function test_EOARedistributor_NeverLocked() public {
    (bool locked,) = vaultEOA.depositsLocked();
    assertFalse(locked);

    address alice = makeAddr('alice');
    usdsc.mint(alice, 2000e18);
    vm.startPrank(alice);
    usdsc.approve(address(vaultEOA), type(uint256).max);
    vaultEOA.deposit(1000e18);
    vm.stopPrank();
    assertEq(vaultEOA.principal(alice), 1000e18);

    // onYield right afterward is the closest an EOA redistributor can get to "just took a
    // snapshot" - it still never locks deposits, because an EOA has no snapshot state at all.
    usdsc.mint(address(vaultEOA), 10e18);
    vm.prank(eoaRedistributor);
    vaultEOA.onYield(10e18);
    (bool lockedAfterYield,) = vaultEOA.depositsLocked();
    assertFalse(lockedAfterYield);

    vm.prank(alice);
    vaultEOA.deposit(1000e18);
    // 1000e18 (first deposit) + 10e18 (the onYield above, folded in by this deposit's _settle())
    // + 1000e18 (this deposit) - confirms the deposit went through, not just that it didn't revert.
    assertEq(vaultEOA.principal(alice), 2010e18);
  }

  /// @dev Bare expectRevert() - the ONLY place in this file that uses it, exactly as the spec
  ///      allows. yieldRedistributor is set to `usdsc` (a real contract, so code.length > 0, but
  ///      one that doesn't implement lastSnapshotTimestamp()/snapshotMaxAge()); the resulting
  ///      revert is a plain ABI call failure (no matching function / failed decode), not a custom
  ///      error EarnVaultV2 defines, so there's no selector or data to assert against.
  function test_ContractRedistributorWithoutSnapshotGetters_DepositReverts() public {
    vm.prank(owner);
    vault.setYieldRedistributor(address(usdsc));

    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    vm.prank(alice);
    vm.expectRevert();
    vault.deposit(1000e18);
  }

  // ---------------------------------------------------------------------
  // End-to-end JIT scenario
  // ---------------------------------------------------------------------

  function test_JITScenario_AttackerDepositBlocked_ThenAllowedAfterExpiryEarningNothing() public {
    address alice = makeAddr('alice');
    address bob = makeAddr('bob');
    address attacker = makeAddr('attacker');
    _mintApprove(alice, 10_000e18);
    usdsc.mint(bob, 10_000e18);
    vm.prank(bob);
    usdsc.approve(address(vault), type(uint256).max);
    usdsc.mint(attacker, 10_000e18);
    vm.prank(attacker);
    usdsc.approve(address(vault), type(uint256).max);

    vm.prank(alice);
    vault.deposit(6000e18);
    vm.prank(bob);
    vault.deposit(4000e18);
    // incumbent principal P = 10_000e18

    uint256 snapTs = block.timestamp;
    redistributor.setSnapshot(snapTs, DEFAULT_MAX_AGE);

    vm.prank(attacker);
    vm.expectRevert(
      abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, snapTs + DEFAULT_MAX_AGE + 1)
    );
    vault.deposit(1000e18);

    uint256 toEarn = 1000e18;
    usdsc.mint(address(vault), toEarn);
    vm.prank(address(redistributor));
    vault.onYield(toEarn);

    uint256 aliceOwed = vault.pendingYield(alice);
    uint256 bobOwed = vault.pendingYield(bob);
    assertLe(aliceOwed + bobOwed, toEarn, 'incumbents cannot be owed more than was transferred in (solvency)');
    assertApproxEqAbs(aliceOwed + bobOwed, toEarn, 10, "incumbents' pendingYield sums to toEarn, minus flooring dust");

    vm.warp(snapTs + DEFAULT_MAX_AGE + 1);
    (bool locked,) = vault.depositsLocked();
    assertFalse(locked);

    vm.prank(attacker);
    vault.deposit(1000e18);
    assertEq(vault.pendingYield(attacker), 0, 'attacker must not earn from the distribution it was locked out of');
  }

  /// @dev Contrast for the test above: the same sequence on `vaultEOA`, whose EOA redistributor
  ///      means no lock applies, shows the dilution the lock prevents. toEarn is sized off the
  ///      incumbents' P (as distribute() sizes it off the snapshot), but a deposit d landing before
  ///      onYield takes toEarn * d / (P + d) of it.
  function test_WithoutLock_PostSnapshotDepositDilutesIncumbents() public {
    address alice = makeAddr('alice');
    address attacker = makeAddr('attacker');
    usdsc.mint(alice, 10_000e18);
    usdsc.mint(attacker, 10_000e18);
    vm.prank(alice);
    usdsc.approve(address(vaultEOA), type(uint256).max);
    vm.prank(attacker);
    usdsc.approve(address(vaultEOA), type(uint256).max);

    vm.prank(alice);
    vaultEOA.deposit(10_000e18); // P = 10_000e18, the principal a snapshot would record

    vm.prank(attacker);
    vaultEOA.deposit(10_000e18); // d = P, landing "after the snapshot"

    uint256 toEarn = 1000e18; // sized off P alone
    usdsc.mint(address(vaultEOA), toEarn);
    vm.prank(eoaRedistributor);
    vaultEOA.onYield(toEarn);

    // With d = P, the attacker takes half of a distribution sized for alice alone.
    assertApproxEqAbs(vaultEOA.pendingYield(alice), toEarn / 2, 10, 'incumbent diluted to P / (P + d)');
    assertApproxEqAbs(vaultEOA.pendingYield(attacker), toEarn / 2, 10, 'late depositor takes d / (P + d)');
  }

  // ---------------------------------------------------------------------
  // Saturation and fuzzing
  // ---------------------------------------------------------------------

  function test_GarbageHugeMaxAge_NoOverflowRevert_LockedWithUnlocksAtMax() public {
    uint256 ts = block.timestamp;
    redistributor.setSnapshot(ts, type(uint256).max);

    (bool locked, uint256 unlocksAt) = vault.depositsLocked();
    assertTrue(locked);
    assertEq(unlocksAt, type(uint256).max);

    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, type(uint256).max));
    vault.deposit(1000e18);
  }

  function testFuzz_DepositsLocked_MatchesFormula(uint256 ts, uint256 maxAge, uint256 nowTs) public {
    nowTs = bound(nowTs, 1, type(uint64).max);
    ts = bound(ts, 0, type(uint64).max);
    maxAge = bound(maxAge, 0, type(uint256).max);

    vm.warp(nowTs);
    redistributor.setSnapshot(ts, maxAge);

    bool expectedLocked = ts != 0 && (nowTs < ts || nowTs - ts <= maxAge);
    (bool locked,) = vault.depositsLocked();
    assertEq(locked, expectedLocked);
  }

  // ---------------------------------------------------------------------
  // Negative cases and edge cases
  // ---------------------------------------------------------------------

  /// @dev Independent oracle for unlocksAt: snapTs + maxAge + 1, saturating at type(uint256).max.
  function _expectedUnlocksAt(uint256 ts, uint256 maxAge) internal pure returns (uint256) {
    if (maxAge >= type(uint256).max - ts) return type(uint256).max;
    return ts + maxAge + 1;
  }

  /// @dev deposit() checks pause, then blacklist, then zero amount, then the lock: each earlier
  ///      check wins while the vault is also locked.
  function test_LockPrecedence_PauseBlacklistZeroAmountBeforeLock() public {
    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    redistributor.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);

    vm.prank(pauser);
    vault.pause();
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSignature('EnforcedPause()'));
    vault.deposit(1000e18);
    vm.prank(pauser);
    vault.unpause();

    vm.prank(owner);
    vault.setBlacklisted(alice, true);
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.AddressBlacklisted.selector);
    vault.deposit(1000e18);
    vm.prank(owner);
    vault.setBlacklisted(alice, false);

    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.ZeroAmount.selector);
    vault.deposit(0);

    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, block.timestamp + DEFAULT_MAX_AGE + 1)
    );
    vault.deposit(1000e18);
  }

  /// @dev depositWithPermit: a zero token owner or an invalid permit is rejected before the lock.
  function test_DepositWithPermit_ZeroOwnerAndBadPermitCheckedBeforeLock() public {
    redistributor.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);

    vm.expectRevert(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector);
    vault.depositWithPermit(address(0), 1000e18, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));

    (address tokenOwner,) = makeAddrAndKey('permitOwner2');
    usdsc.mint(tokenOwner, 1000e18);
    vm.expectRevert(IEarnVaultEventsAndErrors.PermitFailed.selector);
    vault.depositWithPermit(
      tokenOwner, 1000e18, block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(2))
    );
  }

  /// @dev Fail closed: a contract redistributor whose getters revert makes the deposit revert
  ///      with that reason.
  function test_RedistributorGettersRevert_DepositReverts() public {
    MockRevertingSnapshotRedistributor bad = new MockRevertingSnapshotRedistributor();
    vm.prank(owner);
    vault.setYieldRedistributor(address(bad));

    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    vm.prank(alice);
    vm.expectRevert(MockRevertingSnapshotRedistributor.GetterReverted.selector);
    vault.deposit(1000e18);

    vm.expectRevert(MockRevertingSnapshotRedistributor.GetterReverted.selector);
    vault.depositsLocked();
  }

  /// @dev Fail closed: a contract that answers with empty return data fails the ABI decode.
  ///      Bare expectRevert(): an ABI decode failure carries no revert data to match.
  function test_RedistributorReturnsEmptyData_DepositReverts() public {
    MockEmptyReturnRedistributor empty = new MockEmptyReturnRedistributor();
    vm.prank(owner);
    vault.setYieldRedistributor(address(empty));

    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    vm.prank(alice);
    vm.expectRevert();
    vault.deposit(1000e18);
    assertEq(vault.principal(alice), 0);
  }

  /// @dev The getters are called with STATICCALL: a redistributor that tries to write state in
  ///      a getter makes the deposit revert, and its write does not happen.
  ///      Bare expectRevert(): a STATICCALL state-change violation carries no revert data.
  function test_RedistributorCannotChangeStateThroughLockCheck() public {
    MockStateChangingSnapshotRedistributor writer = new MockStateChangingSnapshotRedistributor();
    vm.prank(owner);
    vault.setYieldRedistributor(address(writer));

    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    vm.prank(alice);
    vm.expectRevert();
    vault.deposit(1000e18);
    assertEq(writer.calls(), 0, 'the getter write must not have happened');
    assertEq(vault.principal(alice), 0);
  }

  /// @dev No gas limit lets a deposit through while locked: a failing sub-call reverts the whole
  ///      deposit instead of being treated as "unlocked".
  function testFuzz_GasLimitedDepositNeverBypassesLock(uint256 gasLimit) public {
    gasLimit = bound(gasLimit, 0, 3_000_000);
    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    redistributor.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);

    vm.prank(alice);
    (bool ok,) = address(vault).call{gas: gasLimit}(abi.encodeCall(vault.deposit, (1000e18)));
    assertFalse(ok, 'a deposit must never succeed while locked, at any gas limit');
    assertEq(vault.principal(alice), 0);
    assertEq(vault.totalPrincipal(), 0);
  }

  /// @dev The actual deposit outcome (not just the view) matches an independent formula, and a
  ///      locked deposit reverts with exactly the independently computed unlocksAt.
  function testFuzz_DepositOutcomeMatchesFormula(uint256 ts, uint256 maxAge, uint256 nowTs) public {
    nowTs = bound(nowTs, 1, type(uint64).max);
    ts = bound(ts, 0, type(uint64).max);
    maxAge = bound(maxAge, 0, type(uint256).max);

    address alice = makeAddr('alice');
    _mintApprove(alice, 1000e18);
    vm.warp(nowTs);
    redistributor.setSnapshot(ts, maxAge);

    bool expectedLocked = ts != 0 && (nowTs < ts || nowTs - ts <= maxAge);
    (bool locked, uint256 unlocksAt) = vault.depositsLocked();
    assertEq(locked, expectedLocked);

    if (expectedLocked) {
      uint256 expectedUnlocksAt = _expectedUnlocksAt(ts, maxAge);
      assertEq(unlocksAt, expectedUnlocksAt);
      assertGt(expectedUnlocksAt, nowTs, 'unlocksAt is always in the future while locked');
      vm.prank(alice);
      vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, expectedUnlocksAt));
      vault.deposit(1000e18);
      assertEq(vault.principal(alice), 0);
    } else {
      assertEq(unlocksAt, 0);
      vm.prank(alice);
      vault.deposit(1000e18);
      assertEq(vault.principal(alice), 1000e18);
    }
  }

  /// @dev unlocksAt saturation: both overflow branches (ts + maxAge overflows; ts + maxAge fits
  ///      but + 1 does not) and the largest exact value.
  function test_UnlocksAt_SaturationBranches() public {
    vm.warp(1000);
    redistributor.setSnapshot(1000, type(uint256).max - 1000); // ts + maxAge == max, + 1 overflows
    (, uint256 u1) = vault.depositsLocked();
    assertEq(u1, type(uint256).max);

    redistributor.setSnapshot(1000, type(uint256).max - 1001); // ts + maxAge == max - 1: exact
    (, uint256 u2) = vault.depositsLocked();
    assertEq(u2, type(uint256).max);

    redistributor.setSnapshot(1000, type(uint256).max - 1002); // exact, below max
    (, uint256 u3) = vault.depositsLocked();
    assertEq(u3, type(uint256).max - 1);
  }

  /// @dev A snapshot timestamp in the future (impossible for the real redistributor) is treated
  ///      as locked, with no underflow.
  function test_FutureSnapshotTimestamp_LockedNoUnderflow() public {
    uint256 ts = block.timestamp + 100;
    redistributor.setSnapshot(ts, DEFAULT_MAX_AGE);
    (bool locked, uint256 unlocksAt) = vault.depositsLocked();
    assertTrue(locked);
    assertEq(unlocksAt, ts + DEFAULT_MAX_AGE + 1);
  }

  /// @dev maxAge == 0 (below the real minimum of 1 minute): locked only in the snapshot second.
  function test_ZeroMaxAge_LockedOnlyInSnapshotSecond() public {
    uint256 ts = block.timestamp;
    redistributor.setSnapshot(ts, 0);
    (bool lockedNow, uint256 unlocksAt) = vault.depositsLocked();
    assertTrue(lockedNow);
    assertEq(unlocksAt, ts + 1);
    vm.warp(ts + 1);
    (bool lockedLater,) = vault.depositsLocked();
    assertFalse(lockedLater);
  }

  /// @dev The lock is re-evaluated against whatever yieldRedistributor is set now.
  function test_SwitchingRedistributor_ReevaluatesLock() public {
    redistributor.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);
    (bool l1,) = vault.depositsLocked();
    assertTrue(l1);

    vm.prank(owner);
    vault.setYieldRedistributor(eoaRedistributor);
    (bool l2,) = vault.depositsLocked();
    assertFalse(l2, 'EOA redistributor: unlocked');

    MockSnapshotRedistributor other = new MockSnapshotRedistributor(DEFAULT_MAX_AGE);
    vm.warp(block.timestamp + 1 hours);
    other.setSnapshot(block.timestamp - 1 hours, DEFAULT_MAX_AGE);
    vm.prank(owner);
    vault.setYieldRedistributor(address(other));
    (bool l3,) = vault.depositsLocked();
    assertFalse(l3, 'new redistributor with a stale snapshot: unlocked');

    other.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);
    (bool l4,) = vault.depositsLocked();
    assertTrue(l4, 'new redistributor with a fresh snapshot: locked');
  }

  /// @dev The view keeps working while the vault is paused (frontends can still show the state).
  function test_DepositsLockedView_WorksWhilePaused() public {
    redistributor.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);
    vm.prank(pauser);
    vault.pause();
    (bool locked,) = vault.depositsLocked();
    assertTrue(locked);
  }

  /// @dev A locked deposit attempt leaves the depositor's pending yield and every vault total
  ///      untouched (the check runs before _settle()).
  function test_LockedDeposit_LeavesAllStateUntouched() public {
    address alice = makeAddr('alice');
    _mintApprove(alice, 10_000e18);
    vm.prank(alice);
    vault.deposit(5000e18);
    usdsc.mint(address(vault), 100e18);
    vm.prank(address(redistributor));
    vault.onYield(100e18);

    redistributor.setSnapshot(block.timestamp, DEFAULT_MAX_AGE);
    uint256 pendingBefore = vault.pendingYield(alice);
    uint256 principalBefore = vault.principal(alice);
    uint256 totalBefore = vault.totalPrincipal();
    uint256 reserveBefore = vault.claimReserve();
    uint256 balBefore = usdsc.balanceOf(alice);

    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, block.timestamp + DEFAULT_MAX_AGE + 1)
    );
    vault.deposit(1000e18);

    assertGt(pendingBefore, 0);
    assertEq(vault.pendingYield(alice), pendingBefore, 'pending yield not compounded');
    assertEq(vault.principal(alice), principalBefore);
    assertEq(vault.totalPrincipal(), totalBefore);
    assertEq(vault.claimReserve(), reserveBefore);
    assertEq(usdsc.balanceOf(alice), balBefore, 'no tokens moved');
  }

  // ---------------------------------------------------------------------
  // Gas
  // ---------------------------------------------------------------------

  /// @dev Loose regression bound (not a precise gas snapshot): the lock check against a contract
  ///      redistributor costs two extra external view calls (code.length check plus two staticcalls
  ///      via the high-level interface) versus an EOA's single code.length short-circuit.
  function test_Gas_Deposit_ContractRedistributorOverheadVsEOA() public {
    address userMock = makeAddr('gasUserMock');
    address userEOA = makeAddr('gasUserEOA');
    usdsc.mint(userMock, 1000e18);
    usdsc.mint(userEOA, 1000e18);
    vm.prank(userMock);
    usdsc.approve(address(vault), type(uint256).max);
    vm.prank(userEOA);
    usdsc.approve(address(vaultEOA), type(uint256).max);

    vm.prank(userMock);
    uint256 gasBeforeMock = gasleft();
    vault.deposit(1000e18);
    uint256 gasMock = gasBeforeMock - gasleft();

    vm.prank(userEOA);
    uint256 gasBeforeEOA = gasleft();
    vaultEOA.deposit(1000e18);
    uint256 gasEOA = gasBeforeEOA - gasleft();

    console2.log('deposit gas, contract (mock) redistributor, unlocked', gasMock);
    console2.log('deposit gas, EOA redistributor', gasEOA);

    assertGt(gasMock, gasEOA, 'a contract redistributor does strictly more work than an EOA short-circuit');
    uint256 overhead = gasMock - gasEOA;
    console2.log('overhead of a contract redistributor over an EOA (gas)', overhead);
    assertLt(overhead, 15_000, 'JIT lock check gas overhead regression');
  }
}
