// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UpgradeEarnVaultToV2} from '../../script/upgrade/UpgradeEarnVaultToV2.s.sol';
import {VerifyEarnVaultV2Upgrade} from '../../script/upgrade/VerifyEarnVaultV2Upgrade.s.sol';
import {RewardRedistributor} from '../../src/distributor/RewardRedistributor.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test, console2} from 'forge-std/Test.sol';

/**
 * @title EarnVaultV2UpgradeSoneiumFork
 * @notice Rehearses the live EarnVault V1 -> V2 upgrade on a Soneium mainnet fork, sent the way
 *         production will send it (the Safe calling ProxyAdmin.upgradeAndCall), then exercises the
 *         upgraded vault with real depositors and the real RewardRedistributor.
 * @dev Opt-in (it needs an RPC and is not deterministic across blocks):
 *        RUN_SONEIUM_FORK=true forge test --match-path test/fork/EarnVaultV2Upgrade.soneium.fork.t.sol \
 *          --libraries src/vaults/earn/BoostRewardsLib.sol:BoostRewardsLib:0x674894C99714bf7E6Acdd9a73d46c6f9EACe66CE -vv
 *      `--libraries` links the implementation to the live BoostRewardsLib, as the production deploy must.
 *      Optional env: SONEIUM_RPC_URL (default: public RPC), SONEIUM_FORK_BLOCK (default: latest).
 */
contract EarnVaultV2UpgradeSoneiumFork is Test {
  address constant VAULT = 0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0;
  address constant PROXY_ADMIN = 0xDBc42e5c7E6BF89886F2f359F9b0BB9344824066;
  address constant SAFE = 0x3C27038D9906caa5D68355B1800625EAcaCd93dA;
  address constant REDISTRIBUTOR = 0xda798684ffD5eb509c2Ab7b8352EC55B31F18201;
  address constant RR_OPERATOR = 0x86bE13a26d548FA5407Ee3E5a8321B4E1019333C;
  address constant LIVE_BOOST_LIB = 0x674894C99714bf7E6Acdd9a73d46c6f9EACe66CE;

  uint256 constant CAP = 10_000e6;

  address boostKeeper = makeAddr('boostKeeper');

  EarnVaultV2 vault = EarnVaultV2(payable(VAULT));
  RewardRedistributor rr = RewardRedistributor(REDISTRIBUTOR);
  IERC20 usdsc;
  address impl;

  // Real depositors (largest by deposit count over ~2M blocks), mixed EOAs and AA wallets
  address[] users;

  struct UserState {
    uint256 principal;
    uint256 accrued;
    uint256 totalValue;
    uint256 userIndex;
  }

  mapping(address => UserState) beforeState;
  uint256 totalPrincipalBefore;
  uint256 claimReserveBefore;
  uint256 globalIndexBefore;
  UpgradeEarnVaultToV2.V1Snapshot v1Snap;

  function setUp() public {
    if (!vm.envOr('RUN_SONEIUM_FORK', false)) {
      vm.skip(true);
      return;
    }
    string memory rpc = vm.envOr('SONEIUM_RPC_URL', string('https://rpc.soneium.org'));
    uint256 forkBlock = vm.envOr('SONEIUM_FORK_BLOCK', uint256(0));
    if (forkBlock == 0) vm.createSelectFork(rpc);
    else vm.createSelectFork(rpc, forkBlock);
    console2.log('Forked Soneium at block', block.number);

    users.push(0xAfC03035BDe20071BC930eE8112a7B4b683Cff49);
    users.push(0x471a495039eF5c4264B61aE45eaC407D3C5214D1);
    users.push(0x3238e4dbb25EFEFc5d00624F949bc40e719a6F27);
    users.push(0x00b9228eb19a13C6A943b350916Dd2AA7F182c21);
    users.push(0xFb1244244D314d5E36e77079dCF9dd79279550fe);
    users.push(0xF894803c21d4f79Dd6D4808930c2e08cb715ca6A);
    users.push(0x9bD7a342706231f092AA3Fb70a35e015E67E8180);
    users.push(0x411BBdA5d0bc1d58DF88b46f7F726f0Fef1092Eb);
    users.push(0x30158ccFFC88c8cfB1a924Bd35faCa4dA71563b8);
    users.push(0xba89D66aC9549E5AAbb2e23528702cbb974BdE68);
    users.push(0xD315CB4d44eaE8f1E6499169b0B5B9a6a365cB48);
    users.push(0xc1e2EA5E5512eD6B87fE181d73780354Bc422b5d);

    usdsc = IERC20(vault.asset());

    // State as V1 reports it, before anything changes
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      beforeState[u] = UserState({
        principal: vault.principal(u),
        accrued: vault.accrued(u),
        totalValue: vault.totalValue(u),
        userIndex: vault.userIndex(u)
      });
    }
    totalPrincipalBefore = vault.totalPrincipal();
    claimReserveBefore = vault.claimReserve();
    globalIndexBefore = vault.globalIndex();

    _upgradeAsSafe();
  }

  /// @dev The production path: the script's own pre-flight with the Safe as sender, then the Safe's
  ///      single transaction (ProxyAdmin.upgradeAndCall carrying initializeV2), then post-flight.
  function _upgradeAsSafe() internal {
    impl = address(new EarnVaultV2());
    UpgradeEarnVaultToV2 script = new UpgradeEarnVaultToV2();
    UpgradeEarnVaultToV2.Params memory p = UpgradeEarnVaultToV2.Params({
      proxy: VAULT, expectedAdmin: PROXY_ADMIN, keeper: boostKeeper, cap: CAP, implementation: impl
    });

    v1Snap = script.preflight(p, SAFE);

    vm.prank(SAFE);
    ProxyAdmin(PROXY_ADMIN)
      .upgradeAndCall(
        ITransparentUpgradeableProxy(VAULT), impl, abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, CAP))
      );

    script.postflight(p, impl, v1Snap);
  }

  // ---------------------------------------------------------------------------------------------
  // Upgrade itself
  // ---------------------------------------------------------------------------------------------

  function test_UpgradeLinksLiveBoostRewardsLib() public view {
    // The implementation must DELEGATECALL the already-deployed library, not a fresh copy.
    // Run with --libraries (see contract NatSpec); without it forge deploys a new lib and this fails.
    bytes memory code = impl.code;
    bool found;
    bytes20 lib = bytes20(LIVE_BOOST_LIB);
    for (uint256 i = 0; i + 20 <= code.length && !found; i++) {
      bytes20 w;
      assembly {
        w := mload(add(add(code, 32), i))
      }
      found = w == lib;
    }
    assertTrue(found, 'implementation is not linked to the live BoostRewardsLib');
  }

  function test_VerifyScriptPassesAgainstUpgradedState() public {
    VerifyEarnVaultV2Upgrade verifier = new VerifyEarnVaultV2Upgrade();
    verifier.verify(VAULT, PROXY_ADMIN, impl, boostKeeper, CAP, v1Snap.roles);
  }

  function test_UpgradeCannotBeReinitialized() public {
    vm.prank(SAFE);
    vm.expectRevert(); // ProxyAdmin is the only admin; the Safe calling the proxy directly is just a user
    vault.initializeV2(SAFE, 1);

    // Even through the ProxyAdmin, version 2 is consumed
    vm.prank(SAFE);
    vm.expectRevert();
    ProxyAdmin(PROXY_ADMIN)
      .upgradeAndCall(ITransparentUpgradeableProxy(VAULT), impl, abi.encodeCall(EarnVaultV2.initializeV2, (SAFE, 1)));
    assertEq(vault.boostKeeper(), boostKeeper);
  }

  function test_UserValuePreservedAcrossUpgrade() public view {
    assertEq(vault.totalPrincipal(), totalPrincipalBefore, 'totalPrincipal');
    assertEq(vault.claimReserve(), claimReserveBefore, 'claimReserve');
    assertEq(vault.globalIndex(), globalIndexBefore, 'globalIndex');
    _assertSolvent();

    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      UserState memory b = beforeState[u];
      assertEq(vault.principal(u), b.principal, 'principal');
      assertEq(vault.accrued(u), b.accrued, 'accrued');
      assertEq(vault.userIndex(u), b.userIndex, 'userIndex');
      // V1 totalValue = principal + accrued + pending; V2 reports the same three parts
      assertEq(vault.totalValue(u), b.totalValue, 'totalValue');
      assertEq(vault.claimable(u), b.accrued, 'V2 claimable is legacy accrued only');
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Existing depositors after the upgrade
  // ---------------------------------------------------------------------------------------------

  function test_EveryoneCanWithdrawEverything_VaultStaysSolvent() public {
    _unlockDeposits();
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      // USDSC is also a live V1 boost token; withdraw() pays those boost rewards out too
      uint256 owed = vault.totalValue(u) + vault.getClaimableBoostReward(u, address(usdsc));
      if (vault.principal(u) == 0) continue;

      // compound first so principal holds everything except legacy accrued
      vault.compound(u);
      uint256 p = vault.principal(u);
      uint256 balBefore = usdsc.balanceOf(u);

      vm.prank(u);
      vault.withdraw(p);
      if (vault.accrued(u) > 0) {
        vm.prank(u);
        vault.claim();
      }
      assertEq(usdsc.balanceOf(u) - balBefore, owed, 'paid != totalValue + USDSC boost');
      assertEq(vault.totalValue(u), 0);
      _assertSolvent();
    }
  }

  function test_ClaimPaysOnlyLegacyAccruedAndBoost() public {
    uint256 checked;
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      if (vault.principal(u) == 0) continue;
      uint256 boost = vault.getClaimableBoostReward(u, address(usdsc));
      uint256 accrued = vault.accrued(u);
      uint256 principal = vault.principal(u) + vault.pendingYield(u);
      uint256 balBefore = usdsc.balanceOf(u);

      vm.prank(u);
      if (boost == 0 && accrued == 0) {
        // Product note: a V1 user who used to claim() yield now gets NothingToClaim, because
        // yield compounds into principal instead
        vm.expectRevert(IEarnVaultEventsAndErrors.NothingToClaim.selector);
        vault.claim();
      } else {
        vault.claim();
        assertEq(usdsc.balanceOf(u) - balBefore, boost + accrued, 'claim payout');
      }
      // pending yield went into principal, not out to the user
      assertEq(vault.principal(u), principal, 'yield compounded on claim');
      checked++;
    }
    assertGt(checked, 0);
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------
  // Real distribution cycle against the live RewardRedistributor
  // ---------------------------------------------------------------------------------------------

  function test_RealSnapshotDistributeCycle_LockThenYieldThenCompound() public {
    address depositor = users[0];
    _unlockDeposits();

    // 1) Snapshot: deposits lock for exactly snapshotMaxAge seconds
    vm.prank(RR_OPERATOR);
    rr.snapshotVaultTVLs();
    uint256 unlocksAt = block.timestamp + rr.snapshotMaxAge() + 1;
    (bool locked, uint256 reportedUnlock) = vault.depositsLocked();
    assertTrue(locked);
    assertEq(reportedUnlock, unlocksAt);

    deal(address(usdsc), depositor, usdsc.balanceOf(depositor) + 100e6);
    vm.startPrank(depositor);
    usdsc.approve(VAULT, 100e6);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, unlocksAt));
    vault.deposit(100e6);
    // withdrawals stay open during the lock
    vault.withdraw(1e6);
    vm.stopPrank();

    // 2) Distribute in a later block with the real claimYield()
    vm.roll(block.number + 2);
    vm.warp(block.timestamp + 4);
    uint256 gi = vault.globalIndex();
    uint256 reserve = vault.claimReserve();
    uint256 pendingBefore = vault.pendingYield(depositor);
    vm.prank(RR_OPERATOR);
    rr.distribute();
    assertGt(vault.globalIndex(), gi, 'no yield reached the vault');
    assertGt(vault.claimReserve(), reserve);
    assertGt(vault.pendingYield(depositor), pendingBefore);
    _assertSolvent();

    // 3) Compound keeper folds pending yield into principal for everyone
    uint256[] memory expected = new uint256[](users.length);
    for (uint256 i = 0; i < users.length; i++) {
      expected[i] = vault.principal(users[i]) + vault.pendingYield(users[i]);
    }
    vault.compoundMany(users);
    for (uint256 i = 0; i < users.length; i++) {
      assertEq(vault.principal(users[i]), expected[i], 'compound');
      assertEq(vault.pendingYield(users[i]), 0);
    }

    // 4) After snapshotMaxAge the deposit goes through
    vm.warp(unlocksAt);
    (locked,) = vault.depositsLocked();
    assertFalse(locked);
    uint256 p = vault.principal(depositor);
    vm.prank(depositor);
    vault.deposit(100e6);
    assertEq(vault.principal(depositor), p + 100e6);
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------
  // Boost credit
  // ---------------------------------------------------------------------------------------------

  function test_BoostCreditWithRealUsers() public {
    address[] memory to = new address[](3);
    uint256[] memory amounts = new uint256[](3);
    to[0] = users[0];
    to[1] = users[5];
    to[2] = users[11];
    amounts[0] = 50e6;
    amounts[1] = 25e6;
    amounts[2] = 1e6;
    uint256 total = 76e6;

    // fund exactly the batch on top of whatever surplus already sits in the vault
    _fundVault(total);

    uint256[] memory p = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      p[i] = vault.principal(to[i]) + vault.pendingYield(to[i]);
    }
    uint256 tp = vault.totalPrincipal();

    vm.prank(makeAddr('notKeeper'));
    vm.expectRevert(EarnVaultV2.NotBoostKeeper.selector);
    vault.onBoostCredit(1, to, amounts);

    vm.prank(boostKeeper);
    vault.onBoostCredit(1, to, amounts);

    for (uint256 i = 0; i < 3; i++) {
      assertEq(vault.principal(to[i]), p[i] + amounts[i], 'credited principal');
      assertEq(vault.lastCreditedCycle(to[i]), 1);
    }
    assertGe(vault.totalPrincipal(), tp + total);
    assertEq(vault.latestCycleId(), 1);
    _assertSolvent();

    // replay of the same cycle for the same user is refused
    vm.prank(boostKeeper);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    vault.onBoostCredit(1, to, amounts);

    // the cap holds
    address[] memory one = new address[](1);
    uint256[] memory big = new uint256[](1);
    one[0] = users[1];
    big[0] = CAP + 1;
    _fundVault(CAP + 1);
    vm.prank(boostKeeper);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.BoostBatchCapExceeded.selector, CAP + 1, CAP));
    vault.onBoostCredit(2, one, big);
  }

  /// @dev FINDING: onBoostCredit's funding check is `balance >= claimReserve + total`, but on the
  ///      live vault USDSC is also a V1 boost token whose owed rewards sit in
  ///      boostClaimReserve[USDSC], outside claimReserve. A batch can therefore be "funded" by
  ///      USDSC that users are already owed. This test passes while the bug exists; once the check
  ///      also counts boostClaimReserve[USDSC], the credit below should revert InsufficientFunding.
  function test_Finding_BoostCreditCanSpendOwedUsdscBoostRewards() public {
    uint256 boostReserve = _usdscBoostReserve();
    uint256 looksFree = usdsc.balanceOf(VAULT) - vault.claimReserve();
    console2.log('balance - claimReserve (what onBoostCredit treats as free):', looksFree);
    console2.log('boostClaimReserve[USDSC] (owed to V1 boost holders):     ', boostReserve);
    assertGt(boostReserve, 0);
    assertGt(looksFree, boostReserve);

    address[] memory one = new address[](1);
    uint256[] memory amt = new uint256[](1);
    one[0] = users[1];
    amt[0] = looksFree; // no new USDSC sent in
    vm.prank(boostKeeper);
    vault.onBoostCredit(1, one, amt);

    // Every USDSC in the vault is now claimed by principal, so the boost holders are unbacked
    assertEq(usdsc.balanceOf(VAULT), vault.claimReserve());
    assertLt(usdsc.balanceOf(VAULT), vault.claimReserve() + _usdscBoostReserve(), 'expected under-reserve');
  }

  function test_BoostCreditRefusesUnfundedBatch() public {
    uint256 surplus = usdsc.balanceOf(VAULT) - vault.claimReserve();

    address[] memory one = new address[](1);
    uint256[] memory amt = new uint256[](1);
    one[0] = users[0];
    amt[0] = surplus + 1;
    vm.prank(SAFE);
    vault.setMaxBoostPerBatch(type(uint256).max);
    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    vault.onBoostCredit(1, one, amt);
  }

  // ---------------------------------------------------------------------------------------------
  // Admin surface still owned by the Safe
  // ---------------------------------------------------------------------------------------------

  function test_SafeKeepsAdminControl() public {
    vm.startPrank(SAFE);
    vault.pause();
    vm.stopPrank();

    vm.prank(users[0]);
    vm.expectRevert();
    vault.withdraw(1);

    vm.startPrank(SAFE);
    vault.unpause();
    address newKeeper = makeAddr('newKeeper');
    vault.setBoostKeeper(newKeeper);
    vault.setMaxBoostPerBatch(1);
    vm.stopPrank();
    assertEq(vault.boostKeeper(), newKeeper);
    assertEq(vault.maxBoostPerBatch(), 1);
  }

  // ---------------------------------------------------------------------------------------------

  function _unlockDeposits() internal {
    (bool locked, uint256 unlocksAt) = vault.depositsLocked();
    if (locked) vm.warp(unlocksAt);
  }

  /// @dev boostClaimReserve has no getter; it is field 15 of the EarnVault ERC-7201 struct
  function _usdscBoostReserve() internal view returns (uint256) {
    bytes32 mapSlot = bytes32(uint256(0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00) + 15);
    return uint256(vm.load(VAULT, keccak256(abi.encode(address(usdsc), mapSlot))));
  }

  /// @dev USDSC in the vault must back principal/legacy accrued AND owed USDSC boost rewards
  function _assertSolvent() internal view {
    assertGe(usdsc.balanceOf(VAULT), vault.claimReserve() + _usdscBoostReserve(), 'vault under-reserved');
  }

  function _fundVault(uint256 amount) internal {
    deal(address(usdsc), boostKeeper, amount);
    vm.prank(boostKeeper);
    usdsc.transfer(VAULT, amount);
  }
}
