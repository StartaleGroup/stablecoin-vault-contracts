// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';

/// @title EarnVault V1 -> V2 user journey
/// @notice Tells the whole story end to end for three users sharing one vault, across a real
///         proxy upgrade, rather than testing mechanisms in isolation:
///           - Alice (A): active both before and after the upgrade. Pre-upgrade, she claims
///             yield manually (V1 has no auto-compound - claiming is the only way to realize
///             it, and it never touches her principal). Post-upgrade, she never calls
///             compound() herself - her own deposit()/withdraw() calls auto-compound for her
///             as a side effect, because V2's _settle() does that unconditionally.
///           - Bob and Charlie (B, C): deposit pre-upgrade, then go fully passive - after the
///             upgrade they never call anything themselves. A keeper has to call
///             compound()/compoundMany() on their behalf for their yield to ever be realized.
///             Gas for those keeper calls is measured and logged.
/// @dev Uses one shared vault/proxy for all three users and a single upgrade event partway
///      through, so yield rounds genuinely split proportionally between whoever holds
///      principal at the time - not three independent, artificially isolated scenarios.
/// @dev Split into per-phase internal functions (rather than one long test function) purely to
///      stay under Solidity's local-variable stack limit - each phase hands the next phase
///      what it needs via storage, not a giant shared local-variable list.
contract EarnVaultV1ToV2UserJourneyTest is Test {
  EarnVaultUpgradeable vaultV1;
  EarnVaultV2 vault;
  MockUSDSC usdsc;

  ProxyAdmin proxyAdmin;
  TransparentUpgradeableProxy proxy;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address redistributor = makeAddr('redistributor');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address operator = makeAddr('operator');
  // Compound()/compoundMany() are deliberately permissionless - "keeper" is just a narrative
  // label for whichever address actually submits these transactions in production, not a
  // privileged role the contract enforces.
  address keeper = makeAddr('keeper');

  address alice = makeAddr('alice'); // A - active before and after the upgrade
  address bob = makeAddr('bob'); // B - passive after the upgrade
  address charlie = makeAddr('charlie'); // C - passive after the upgrade

  // Cross-phase snapshots (state, not locals, to stay under the stack limit).
  uint256 aliceRound2Pending;
  uint256 bobPendingAtUpgrade;
  uint256 charliePendingAtUpgrade;
  uint256 globalIndexBeforeUpgrade;
  uint256 claimReserveBeforeUpgrade;
  uint256 totalPrincipalBeforeUpgrade;
  uint256 vaultBalanceBeforeUpgrade;
  uint256 alicePrincipalBeforeUpgrade;
  uint256 bobPrincipalBeforeUpgrade;
  uint256 charliePrincipalBeforeUpgrade;

  function setUp() public {
    usdsc = new MockUSDSC();

    EarnVaultUpgradeable v1Implementation = new EarnVaultUpgradeable();
    proxy = new TransparentUpgradeableProxy(
      address(v1Implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
      )
    );
    vaultV1 = EarnVaultUpgradeable(payable(address(proxy)));

    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    address proxyAdminAddress = address(uint160(uint256(vm.load(address(proxy), adminSlot))));
    proxyAdmin = ProxyAdmin(proxyAdminAddress);

    usdsc.mint(alice, 1_000_000e6);
    usdsc.mint(bob, 1_000_000e6);
    usdsc.mint(charlie, 1_000_000e6);
    usdsc.mint(redistributor, 1_000_000e6);

    vm.prank(alice);
    usdsc.approve(address(vaultV1), type(uint256).max);
    vm.prank(bob);
    usdsc.approve(address(vaultV1), type(uint256).max);
    vm.prank(charlie);
    usdsc.approve(address(vaultV1), type(uint256).max);
  }

  function _distributeYieldV1(uint256 amount) internal {
    usdsc.mint(address(vaultV1), amount);
    vm.prank(redistributor);
    vaultV1.onYield(amount);
  }

  function _distributeYieldV2(uint256 amount) internal {
    usdsc.mint(address(vault), amount);
    vm.prank(redistributor);
    vault.onYield(amount);
  }

  function test_FullJourney_ActiveAliceAutoCompoundsHerself_PassiveBobAndCharlieNeedKeeper() public {
    _phase1_preUpgradeOnV1();
    _phase2_upgradeAndVerifyConservation();
    _phase3_activeAliceAutoCompoundsHerself();
    _phase4_passiveBobAndCharlieNeedKeeper();
  }

  // ====================================================================
  // PHASE 1 - pre-upgrade, on V1 (no auto-compound exists yet)
  // ====================================================================
  function _phase1_preUpgradeOnV1() internal {
    vm.prank(alice);
    vaultV1.deposit(1000e6);
    vm.prank(bob);
    vaultV1.deposit(2000e6);
    vm.prank(charlie);
    vaultV1.deposit(1500e6);

    assertEq(vaultV1.totalPrincipal(), 4500e6, 'sanity: three deposits should sum correctly');

    // --- Yield round 1: 450 USDSC, split proportionally (A:1000/4500, B:2000/4500, C:1500/4500) ---
    _distributeYieldV1(450e6);

    uint256 aliceRound1Claimable = vaultV1.claimable(alice);
    assertEq(aliceRound1Claimable, 100e6, 'alice should be owed 1000/4500 * 450 = 100');

    // Alice claims - this is the ONLY way to realize yield under V1. It pays out in USDSC and
    // leaves her principal completely untouched: yield and principal are two separate things
    // under V1, unlike V2 where a settlement folds one into the other.
    uint256 aliceBalanceBeforeClaim = usdsc.balanceOf(alice);
    vm.prank(alice);
    vaultV1.claim();
    assertEq(
      usdsc.balanceOf(alice), aliceBalanceBeforeClaim + aliceRound1Claimable, 'alice should receive round 1 yield as a liquid transfer'
    );
    assertEq(vaultV1.principal(alice), 1000e6, 'claiming must NOT change principal under V1 - no auto-compound exists');

    // Bob and Charlie deliberately do NOT claim round 1 - their share stays unrealized,
    // carried forward purely as a (globalIndex - userIndex) delta.
    assertEq(vaultV1.claimable(bob), 200e6, '2000/4500 * 450 = 200');
    assertEq(vaultV1.claimable(charlie), 150e6, '1500/4500 * 450 = 150');

    // Alice deposits again - now with a larger principal for the next yield round.
    vm.prank(alice);
    vaultV1.deposit(500e6);
    assertEq(vaultV1.principal(alice), 1500e6);

    // --- Yield round 2: 500 USDSC, now split over A:1500, B:2000, C:1500 = 5000 total ---
    _distributeYieldV1(500e6);

    // Alice gets a NEW reward reflecting her new (larger) principal - and this is genuinely
    // new/unclaimed, not a continuation of round 1 (she already fully claimed that).
    aliceRound2Pending = vaultV1.claimable(alice);
    assertEq(aliceRound2Pending, 150e6, '1500/5000 * 500 = 150, and accrued was 0 going in since she just claimed');

    // Bob and Charlie's unclaimed balance now reflects BOTH rounds, still never touched.
    bobPendingAtUpgrade = vaultV1.claimable(bob);
    charliePendingAtUpgrade = vaultV1.claimable(charlie);
    assertEq(bobPendingAtUpgrade, 200e6 + 200e6, 'round 1 (200) + round 2 (2000/5000*500=200)');
    assertEq(charliePendingAtUpgrade, 150e6 + 150e6, 'round 1 (150) + round 2 (1500/5000*500=150)');
  }

  // ====================================================================
  // PHASE 2 - the upgrade itself: snapshot everything, upgrade, verify nothing moved
  // ====================================================================
  function _phase2_upgradeAndVerifyConservation() internal {
    globalIndexBeforeUpgrade = vaultV1.globalIndex();
    claimReserveBeforeUpgrade = vaultV1.claimReserve();
    totalPrincipalBeforeUpgrade = vaultV1.totalPrincipal();
    vaultBalanceBeforeUpgrade = usdsc.balanceOf(address(vaultV1));
    alicePrincipalBeforeUpgrade = vaultV1.principal(alice);
    bobPrincipalBeforeUpgrade = vaultV1.principal(bob);
    charliePrincipalBeforeUpgrade = vaultV1.principal(charlie);

    EarnVaultV2 v2Implementation = new EarnVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2Implementation), '');
    vault = EarnVaultV2(payable(address(proxy)));

    // Nothing about the upgrade itself moves a single wei or changes anyone's recorded
    // principal - "the vault money doesn't go anywhere net" across the boundary.
    assertEq(vault.globalIndex(), globalIndexBeforeUpgrade, 'globalIndex must survive the upgrade unchanged');
    assertEq(vault.claimReserve(), claimReserveBeforeUpgrade, 'claimReserve must survive the upgrade unchanged');
    assertEq(vault.totalPrincipal(), totalPrincipalBeforeUpgrade, 'totalPrincipal must survive the upgrade unchanged');
    assertEq(usdsc.balanceOf(address(vault)), vaultBalanceBeforeUpgrade, 'vault USDSC balance must survive the upgrade unchanged');
    assertEq(vault.principal(alice), alicePrincipalBeforeUpgrade, "alice's principal must hold across the upgrade");
    assertEq(vault.principal(bob), bobPrincipalBeforeUpgrade, "bob's principal must hold across the upgrade");
    assertEq(vault.principal(charlie), charliePrincipalBeforeUpgrade, "charlie's principal must hold across the upgrade");

    // Each user's pre-upgrade pending yield also carries forward exactly, now expressed via
    // V2's pendingYield() instead of V1's claimable() (same underlying globalIndex delta).
    assertEq(vault.pendingYield(alice), aliceRound2Pending);
    assertEq(vault.pendingYield(bob), bobPendingAtUpgrade);
    assertEq(vault.pendingYield(charlie), charliePendingAtUpgrade);
  }

  // ====================================================================
  // PHASE 3 - post-upgrade, Alice stays active: her OWN actions auto-compound for her
  // ====================================================================
  function _phase3_activeAliceAutoCompoundsHerself() internal {
    uint256 alicePendingBeforeDeposit = vault.pendingYield(alice); // == aliceRound2Pending
    uint256 alicePrincipalBeforeDeposit = vault.principal(alice); // == 1500e6

    // Alice deposits more, exactly as she would under V1 - no compound() call, no keeper.
    // V2's _settle() auto-compounds her still-pending round-2 yield as a side effect.
    vm.prank(alice);
    vault.deposit(300e6);

    assertEq(
      vault.principal(alice),
      alicePrincipalBeforeDeposit + alicePendingBeforeDeposit + 300e6,
      "alice's deposit should auto-compound her pending yield for free, on top of the new deposit"
    );
    assertEq(vault.accrued(alice), 0, "auto-compounded yield never lands in accrued - it's principal now");

    // A further yield round lands, then Alice partially withdraws - withdraw() must ALSO
    // auto-compound whatever is pending before honoring the withdrawal.
    _distributeYieldV2(200e6);

    uint256 alicePendingBeforeWithdraw = vault.pendingYield(alice);
    assertGt(alicePendingBeforeWithdraw, 0);
    uint256 alicePrincipalBeforeWithdraw = vault.principal(alice);
    uint256 aliceBalanceBeforeWithdraw = usdsc.balanceOf(alice);

    vm.prank(alice);
    vault.withdraw(400e6);

    assertEq(
      vault.principal(alice),
      alicePrincipalBeforeWithdraw + alicePendingBeforeWithdraw - 400e6,
      "alice's withdraw should auto-compound pending yield first, then subtract the withdrawn amount"
    );
    assertEq(
      usdsc.balanceOf(alice), aliceBalanceBeforeWithdraw + 400e6, 'alice should receive exactly what she asked to withdraw'
    );
  }

  // ====================================================================
  // PHASE 4 - post-upgrade, Bob and Charlie go fully passive: a keeper compounds for them
  // ====================================================================
  function _phase4_passiveBobAndCharlieNeedKeeper() internal {
    // Neither Bob nor Charlie has done anything since before the upgrade - but that doesn't
    // freeze their pending yield: they keep earning their proportional share of every new
    // onYield() round (Phase 3's included) purely because they still hold principal, whether
    // or not they ever act on it. Passive just means nobody has folded it into principal for
    // them yet - it does NOT mean they stopped earning. So their pending can only have grown
    // since the upgrade, never shrunk or stayed frozen.
    uint256 bobPendingBeforeKeeper = vault.pendingYield(bob);
    uint256 charliePendingBeforeKeeper = vault.pendingYield(charlie);
    assertGe(bobPendingBeforeKeeper, bobPendingAtUpgrade, "bob's pending should have grown (Phase 3's yield round), never shrunk");
    assertGe(charliePendingBeforeKeeper, charliePendingAtUpgrade, "charlie's pending should have grown too");

    uint256 bobPrincipalBeforeKeeper = vault.principal(bob);
    uint256 charliePrincipalBeforeKeeper = vault.principal(charlie);

    // Keeper compounds Bob individually - measure and log the real gas cost of this action.
    vm.prank(keeper);
    uint256 gasBeforeBobCompound = gasleft();
    vault.compound(bob);
    uint256 gasUsedForBobCompound = gasBeforeBobCompound - gasleft();
    console2.log('gas used: keeper compound(bob), single user, no active boost tokens', gasUsedForBobCompound);

    assertEq(
      vault.principal(bob), bobPrincipalBeforeKeeper + bobPendingBeforeKeeper, "bob's principal should now include his compounded yield"
    );
    assertEq(vault.pendingYield(bob), 0);
    assertEq(vault.accrued(bob), 0, 'bob never claims - his yield only ever became principal, never accrued');

    // Keeper compounds Charlie via the batch entry point instead - measure and log that too.
    address[] memory batch = new address[](1);
    batch[0] = charlie;
    vm.prank(keeper);
    uint256 gasBeforeCharlieCompound = gasleft();
    vault.compoundMany(batch);
    uint256 gasUsedForCharlieCompound = gasBeforeCharlieCompound - gasleft();
    console2.log('gas used: keeper compoundMany([charlie]), single-element batch', gasUsedForCharlieCompound);

    assertEq(
      vault.principal(charlie),
      charliePrincipalBeforeKeeper + charliePendingBeforeKeeper,
      "charlie's principal should now include his compounded yield"
    );
    assertEq(vault.pendingYield(charlie), 0);
    assertEq(vault.accrued(charlie), 0);

    // Finally: Bob and Charlie each withdraw, having done nothing themselves except let the
    // keeper compound for them - they should receive their compounded interest as ordinary
    // principal, with no special "claim my compounded yield" step required.
    uint256 bobPrincipalAfterKeeper = vault.principal(bob);
    uint256 bobBalanceBeforeWithdraw = usdsc.balanceOf(bob);
    vm.prank(bob);
    vault.withdraw(bobPrincipalAfterKeeper); // full withdrawal
    assertEq(usdsc.balanceOf(bob), bobBalanceBeforeWithdraw + bobPrincipalAfterKeeper, 'bob should receive his full (compounded) principal');
    assertEq(vault.principal(bob), 0);

    uint256 charliePrincipalAfterKeeper = vault.principal(charlie);
    uint256 charlieBalanceBeforeWithdraw = usdsc.balanceOf(charlie);
    vm.prank(charlie);
    vault.withdraw(charliePrincipalAfterKeeper); // full withdrawal
    assertEq(
      usdsc.balanceOf(charlie), charlieBalanceBeforeWithdraw + charliePrincipalAfterKeeper, "charlie should receive his full (compounded) principal"
    );
    assertEq(vault.principal(charlie), 0);
  }
}
