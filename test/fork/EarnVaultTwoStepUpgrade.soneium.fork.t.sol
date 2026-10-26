// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {EarnVaultV2UpgradeChecks} from '../../script/upgrade/EarnVaultV2UpgradeChecks.sol';
import {UpgradeEarnVaultToV2} from '../../script/upgrade/UpgradeEarnVaultToV2.s.sol';
import {VerifyEarnVaultV2Upgrade} from '../../script/upgrade/VerifyEarnVaultV2Upgrade.s.sol';
import {RewardRedistributor} from '../../src/distributor/RewardRedistributor.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test, Vm} from 'forge-std/Test.sol';

/// @dev The live M token's index and its portal-only update (a bridge index message)
interface IMTokenIndex {
  function currentIndex() external view returns (uint128);
  function updateIndex(uint128 index) external;
}

interface IPermit {
  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external;
  function nonces(address owner) external view returns (uint256);
  function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title Two upgrades on the live vault: V1 -> fixed EarnVaultUpgradeable -> EarnVaultV2
/// @notice Forks Soneium and runs the planned path on the live EarnVault:
///         step 1, the live V1 implementation -> this repo's EarnVaultUpgradeable (the same contract
///         with the boost-reward fixes); step 2, that -> EarnVaultV2. At every step it checks that the
///         vault's storage and every tracked depositor's position are unchanged by the upgrade itself,
///         that the vault stays solvent, that deposits and withdrawals keep working, that the deposit
///         pause exists only on V2, and that every depositor can exit in full.
/// @dev Opt-in:
///        RUN_SONEIUM_FORK=true forge test --match-path test/fork/EarnVaultTwoStepUpgrade.soneium.fork.t.sol \
///          --libraries src/vaults/earn/BoostRewardsLib.sol:BoostRewardsLib:0x674894C99714bf7E6Acdd9a73d46c6f9EACe66CE -vv
contract EarnVaultTwoStepUpgradeSoneiumFork is Test {
  address constant VAULT = 0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0;
  ProxyAdmin constant PROXY_ADMIN = ProxyAdmin(0xDBc42e5c7E6BF89886F2f359F9b0BB9344824066);
  address constant OWNER_SAFE = 0x3C27038D9906caa5D68355B1800625EAcaCd93dA;
  address constant TREASURY_SAFE = 0x5e41066D55ED832f9E3d9e747DaF352Cf29391Ef;
  address constant KMS_KEEPER = 0x86bE13a26d548FA5407Ee3E5a8321B4E1019333C; // also the redistributor operator
  RewardRedistributor constant RR = RewardRedistributor(0xda798684ffD5eb509c2Ab7b8352EC55B31F18201);
  IMTokenIndex constant M_TOKEN = IMTokenIndex(0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b);
  address constant M_PORTAL = 0xD925C84b55E4e44a53749fF5F2a5A13F63D128fd;

  bytes32 constant VAULT_STORAGE = 0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;
  uint256 constant VAULT_STORAGE_FIELDS = 20; // EarnVaultStorageBase.EarnVaultStorage has fields 0..19
  bytes32 constant OWNABLE_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
  bytes32 constant OWNABLE2STEP_SLOT = 0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00;
  bytes32 constant PAUSABLE_SLOT = 0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300;
  bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
  bytes32 constant IMPL_SLOT = bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1);

  bytes32 constant BOOST_CREDIT_STORAGE = 0x554142adb35c10dc49454118de8343ddca3b3dda8789b6f7bf924bfb6955ee00; // V2 only
  address constant BOOST_LIB = 0x674894C99714bf7E6Acdd9a73d46c6f9EACe66CE; // live BoostRewardsLib

  uint256 constant BOOST_CAP_V2 = 1_000_000; // 1 USDSC, loyalty dormant

  IERC20 usdsc;
  address liveV1Impl;
  address[] users;

  function setUp() public {
    if (!vm.envOr('RUN_SONEIUM_FORK', false)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(vm.envOr('SONEIUM_RPC_URL', string('https://rpc.soneium.org')));
    usdsc = IERC20(EarnVaultUpgradeable(payable(VAULT)).asset());
    liveV1Impl = address(uint160(uint256(vm.load(VAULT, IMPL_SLOT))));
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
  }

  // =============================================================================================
  // Step 1: live V1 -> fixed EarnVaultUpgradeable
  // =============================================================================================

  /// @dev The upgrade itself writes nothing but the implementation slot
  function test_Step1_StorageAndEveryPositionUnchanged() public {
    assertEq(_v().getVersion(), 'EarnVaultV1');
    assertEq(_initializedVersion(), 1);
    bytes memory storageBefore = _rawStorage();
    bytes memory positionsBefore = _positions();
    bytes memory rolesBefore = _roles();

    _upgradeToFixedV1();

    assertEq(_rawStorage(), storageBefore, 'vault storage changed');
    assertEq(_positions(), positionsBefore, 'a position changed');
    assertEq(_roles(), rolesBefore, 'a role changed');
    assertEq(_v().getVersion(), 'EarnVaultV1');
    assertEq(_initializedVersion(), 1, 'initialized version must stay 1 so V2 can still initialize');
    assertTrue(address(uint160(uint256(vm.load(VAULT, IMPL_SLOT)))) != liveV1Impl);
    _assertSolvent();
  }

  /// @dev Same state, same actions, on the live code and on the fixed code: identical results. The
  ///      actions avoid the paths the fixes change (unfunded boosts, surplus over-sweeps)
  function test_Step1_FixedBehavesLikeLiveV1ForNormalUse() public {
    uint256 id = vm.snapshotState();
    bytes memory live = _normalUseScenario();
    vm.revertToState(id);
    _upgradeToFixedV1();
    bytes memory fixedResult = _normalUseScenario();
    assertEq(fixedResult, live, 'fixed implementation behaves differently from the live one');
  }

  /// @dev F1: every onBoostReward must be funded on top of everything the vault owes
  function test_Step1_BoostRewardMustBeFunded() public {
    _upgradeToFixedV1();
    vm.prank(OWNER_SAFE);
    _v().setBoostRewardKeeper(KMS_KEEPER);

    // nothing sent in: refused
    vm.prank(KMS_KEEPER);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    _v().onBoostReward(address(usdsc), 50e6);

    // one unit short of the amount on top of the existing surplus: refused
    uint256 surplus = _v().surplusUSDSC();
    vm.prank(KMS_KEEPER);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    _v().onBoostReward(address(usdsc), surplus + 1);

    // exactly funded: accepted, and the vault still covers both reserves
    _fundedBoost(KMS_KEEPER, 50e6);
    _assertSolvent();

    // any other token: refused, even if it is in the vault
    vm.prank(KMS_KEEPER);
    vm.expectRevert(IEarnVaultEventsAndErrors.BoostTokenNotUSDSC.selector);
    _v().onBoostReward(address(0xdEaD), 1);
  }

  /// @dev F4: sweep and recover can only take USDSC above both reserves
  function test_Step1_SweepAndRecoverCannotTakeOwedFunds() public {
    _upgradeToFixedV1();
    deal(address(usdsc), address(this), 7e6);
    usdsc.transfer(VAULT, 7e6); // a donation
    uint256 surplus = _v().surplusUSDSC();
    address treasury = _v().treasury();
    uint256 before = usdsc.balanceOf(treasury);
    vm.prank(OWNER_SAFE);
    _v().sweepSurplusToTreasury();
    assertEq(usdsc.balanceOf(treasury) - before, surplus, 'sweep took more than the surplus');
    assertEq(_v().surplusUSDSC(), 0);
    _assertSolvent();

    vm.prank(OWNER_SAFE);
    _v().pause();
    vm.prank(OWNER_SAFE);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    _v().recoverERC20(address(usdsc), treasury, 1);
    _assertSolvent();
  }

  /// @dev F3: the token-removal function no longer exists
  function test_Step1_RemoveBoostRewardTokenGone() public {
    _upgradeToFixedV1();
    vm.prank(OWNER_SAFE);
    (bool ok,) = VAULT.call(abi.encodeWithSignature('removeBoostRewardToken(address)', address(0xdEaD)));
    assertFalse(ok);
  }

  /// @dev The deposit pause is V2-only: on the fixed V1, a deposit right after a snapshot works
  function test_Step1_DepositsAlwaysOpen() public {
    _upgradeToFixedV1();
    _snapshot();
    (bool hasLockView,) = VAULT.staticcall(abi.encodeWithSignature('depositsLocked()'));
    assertFalse(hasLockView, 'no deposit lock on the fixed V1');
    address d = _newDepositor('justAfterSnapshot', 500e6);
    vm.prank(d);
    _v().deposit(500e6);
    assertEq(_v().principal(d), 500e6);
    _distribute();
    _assertSolvent();
  }

  /// @dev The implementation under test calls the live library, as the mainnet deploy will
  ///      (run with --libraries ...:0x6748...66CE)
  function test_Step1_LinkedToLiveLibraryLikeLiveV1() public {
    address impl = _upgradeToFixedV1();
    assertTrue(_codeHasAddress(liveV1Impl, BOOST_LIB), 'live V1 is linked to the live library');
    assertTrue(_codeHasAddress(impl, BOOST_LIB), 'run with --libraries ...BoostRewardsLib:0x6748...66CE');
  }

  /// @dev The raw boost-reserve slot used by _assertSolvent before the upgrade is the one the new
  ///      boostClaimReserve view reads
  function test_Step1_BoostReserveSlotMatchesView() public {
    _upgradeToFixedV1();
    vm.prank(OWNER_SAFE);
    _v().setBoostRewardKeeper(KMS_KEEPER);
    _fundedBoost(KMS_KEEPER, 50e6);
    uint256 view_ = _v().boostClaimReserve(address(usdsc));
    assertGt(view_, 0);
    assertEq(uint256(_mapSlot(address(usdsc), 15)), view_);
  }

  /// @dev depositWithPermit with the real USDSC permit, including when someone submits the permit
  ///      first: the deposit still goes through on the allowance it granted
  function test_Step1_DepositWithPermitWorks() public {
    _upgradeToFixedV1();
    (address signer, uint256 key) = makeAddrAndKey('permitDepositor');
    deal(address(usdsc), signer, 400e6);
    (uint8 v, bytes32 r, bytes32 s) = _permitSig(signer, key, 200e6);
    _v().depositWithPermit(signer, 200e6, block.timestamp + 1 hours, v, r, s);
    assertEq(_v().principal(signer), 200e6);

    (v, r, s) = _permitSig(signer, key, 200e6);
    IPermit(address(usdsc)).permit(signer, VAULT, 200e6, block.timestamp + 1 hours, v, r, s); // submitted first
    _v().depositWithPermit(signer, 200e6, block.timestamp + 1 hours, v, r, s);
    assertEq(_v().principal(signer), 400e6);
    _assertSolvent();
  }

  /// @dev Unchanged V1 behaviour, pinned: a pause stops user actions, unpause restores them, and no
  ///      position moves
  function test_Step1_PauseKeepsPositions() public {
    _upgradeToFixedV1();
    bytes memory before = _positions();
    vm.prank(OWNER_SAFE);
    _v().pause();
    vm.prank(users[0]);
    vm.expectRevert();
    _v().withdraw(1);
    vm.prank(OWNER_SAFE);
    _v().unpause();
    assertEq(_positions(), before);
    _exitInFullV1(users[0]);
  }

  // =============================================================================================
  // Step 2: fixed EarnVaultUpgradeable -> EarnVaultV2
  // =============================================================================================

  /// @dev The production V2 pre-flight passes on the fixed V1, the upgrade changes no storage or
  ///      position, and the live verify script passes
  function test_Step2_PreflightPassesAndNothingChanges() public {
    _upgradeToFixedV1();
    vm.prank(OWNER_SAFE);
    _v().setBoostRewardKeeper(KMS_KEEPER);
    _fundedBoost(KMS_KEEPER, 50e6);
    _realRound();

    bytes memory storageBefore = _rawStorage();
    bytes memory valuesBefore = _values();
    for (uint256 i = 0; i < 4; i++) {
      assertEq(vm.load(VAULT, bytes32(uint256(BOOST_CREDIT_STORAGE) + i)), bytes32(0), 'V2 namespace already used');
    }
    address v2 = _upgradeToV2();
    assertEq(EarnVaultV2(payable(VAULT)).boostKeeper(), OWNER_SAFE);
    assertEq(EarnVaultV2(payable(VAULT)).maxBoostPerBatch(), BOOST_CAP_V2);
    vm.prank(OWNER_SAFE);
    vm.expectRevert();
    EarnVaultV2(payable(VAULT)).initializeV2(OWNER_SAFE, BOOST_CAP_V2);

    assertEq(_rawStorage(), storageBefore, 'vault storage changed by the V2 upgrade');
    assertEq(_values(), valuesBefore, 'a position value changed by the V2 upgrade');
    assertEq(_initializedVersion(), 2);
    EarnVaultV2UpgradeChecks.Roles memory roles = EarnVaultV2UpgradeChecks.Roles({
      owner: OWNER_SAFE,
      treasury: _v().treasury(),
      yieldRedistributor: address(RR),
      pauser: _v().pauser(),
      boostRewardKeeper: KMS_KEEPER
    });
    new VerifyEarnVaultV2Upgrade().verify(VAULT, address(PROXY_ADMIN), v2, OWNER_SAFE, BOOST_CAP_V2, roles);
    _assertSolvent();
  }

  /// @dev The deposit pause starts only with V2; withdrawals stay open during it
  function test_Step2_DepositPauseOnlyAfterV2() public {
    _upgradeToFixedV1();
    _snapshot();
    address a = _newDepositor('beforeV2', 300e6);
    vm.prank(a);
    _v().deposit(300e6); // fixed V1: open right after a snapshot
    _distribute();

    _upgradeToV2();
    _snapshot();
    (bool locked, uint256 unlocksAt) = EarnVaultV2(payable(VAULT)).depositsLocked();
    assertTrue(locked);
    address b = _newDepositor('afterV2', 300e6);
    vm.prank(b);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, unlocksAt));
    _v().deposit(300e6);

    // withdrawals keep working inside the pause
    uint256 bal = usdsc.balanceOf(a);
    vm.prank(a);
    _v().withdraw(100e6);
    assertGe(usdsc.balanceOf(a) - bal, 100e6);

    _distribute();
    vm.warp(unlocksAt);
    vm.prank(b);
    _v().deposit(300e6);
    assertEq(_v().principal(b), 300e6);
    _assertSolvent();
  }

  // =============================================================================================
  // The whole journey
  // =============================================================================================

  /// @dev Live V1 -> fixed V1 -> V2 with real activity at every stage: solvent after every step, and
  ///      at the end every tracked depositor and every new depositor exits in full
  function test_FullJourney_SolventThroughoutAndEveryoneExitsWhole() public {
    _assertSolvent();
    address early = _newDepositor('early', 1000e6);
    vm.prank(early);
    _v().deposit(1000e6);
    _realRound();
    _assertSolvent();

    // step 1
    _upgradeToFixedV1();
    _assertSolvent();
    vm.prank(OWNER_SAFE);
    _v().setBoostRewardKeeper(KMS_KEEPER);
    address mid = _newDepositor('mid', 2000e6);
    for (uint256 day = 0; day < 3; day++) {
      _fundedBoost(KMS_KEEPER, 50e6);
      _realRound();
      if (day == 0) {
        vm.prank(mid);
        _v().deposit(2000e6);
      }
      if (day == 1) {
        vm.prank(users[1]);
        try _v().claim() {} catch {}
      }
      _assertSolvent();
    }

    // step 2
    _upgradeToV2();
    _assertSolvent();
    address late = _newDepositor('late', 500e6);
    _unlockIfLocked();
    vm.prank(late);
    _v().deposit(500e6);
    for (uint256 day = 0; day < 3; day++) {
      _fundedBoost(KMS_KEEPER, 50e6);
      _realRound();
      _assertSolvent();
    }
    EarnVaultV2(payable(VAULT)).compoundMany(users);
    _assertSolvent();

    // everyone exits in full: payout = totalValue + claimable boost
    address[] memory all = new address[](users.length + 3);
    for (uint256 i = 0; i < users.length; i++) {
      all[i] = users[i];
    }
    (all[users.length], all[users.length + 1], all[users.length + 2]) = (early, mid, late);
    for (uint256 i = 0; i < all.length; i++) {
      _exitInFull(all[i]);
    }
    assertGt(usdsc.balanceOf(early), 1000e6, 'early depositor earned');
    _assertSolvent();
  }

  /// @dev If V2 ever had to be rolled back to the fixed V1, positions carry over and users exit in full
  function test_RollbackFromV2ToFixedV1KeepsUsersWhole() public {
    _upgradeToFixedV1();
    vm.prank(OWNER_SAFE);
    _v().setBoostRewardKeeper(KMS_KEEPER);
    _upgradeToV2();
    _fundedBoost(KMS_KEEPER, 50e6);
    _realRound();
    EarnVaultV2(payable(VAULT)).compoundMany(users);
    bytes memory valuesBefore = _values();

    address fixedV1 = address(new EarnVaultUpgradeable());
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), fixedV1, '');
    assertEq(_values(), valuesBefore, 'rollback changed a position');
    _assertSolvent();
    for (uint256 i = 0; i < users.length; i++) {
      _exitInFullV1(users[i]);
    }
    _assertSolvent();
  }

  // =============================================================================================
  // Emergency pause and rollback
  // =============================================================================================

  /// @dev Upgrade 1 undone: pause, boost reward keeper back to the treasury Safe (the live V1 does
  ///      not check boost funding), then the live implementation again. Storage is exactly as before
  ///      and everyone exits in full on the live code
  function test_Emergency_RollbackUpgrade1ToLiveV1() public {
    bytes memory original = _rawStorage();
    _upgradeToFixedV1();
    vm.prank(OWNER_SAFE);
    _v().setBoostRewardKeeper(KMS_KEEPER);
    _fundedBoost(KMS_KEEPER, 50e6);
    _realRound();

    vm.startPrank(OWNER_SAFE);
    _v().pause();
    _v().setBoostRewardKeeper(TREASURY_SAFE); // first: never leave the bot as keeper on the live V1
    vm.stopPrank();
    bytes memory storageBefore = _rawStorage();
    bytes memory valuesBefore = _values();
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), liveV1Impl, '');

    assertEq(address(uint160(uint256(vm.load(VAULT, IMPL_SLOT)))), liveV1Impl);
    assertEq(_rawStorage(), storageBefore, 'rollback changed storage');
    assertEq(_values(), valuesBefore, 'rollback moved a position');
    assertTrue(_v().paused(), 'still paused after the rollback');
    assertEq(_initializedVersion(), 1);
    (bool hasView,) = VAULT.staticcall(abi.encodeWithSignature('surplusUSDSC()'));
    assertFalse(hasView, 'live V1 code is back');
    assertTrue(keccak256(_rawStorage()) != keccak256(original)); // activity happened in between

    vm.prank(OWNER_SAFE);
    _v().unpause();
    // the rule the rollback relies on: the bot is no longer the keeper of the live V1 code
    assertEq(address(uint160(uint256(vm.load(VAULT, bytes32(uint256(VAULT_STORAGE) + 2))))), TREASURY_SAFE, 'keeper');
    vm.prank(KMS_KEEPER);
    vm.expectRevert(IEarnVaultEventsAndErrors.NotBoostRewardKeeper.selector);
    _v().onBoostReward(address(usdsc), 1);
    _realRound();
    for (uint256 i = 0; i < users.length; i++) {
      _exitInFullV1(users[i]);
    }
    _assertSolvent();
  }

  /// @dev At every stage a pause stops user actions and boosts without moving any principal, while
  ///      the redistributor's real rounds keep paying yield; unpausing restores everything
  function test_Emergency_PauseAtEveryStage() public {
    for (uint256 stage = 0; stage < 3; stage++) {
      if (stage == 1) _upgradeToFixedV1();
      if (stage == 2) _upgradeToV2();
      vm.prank(OWNER_SAFE);
      _v().pause();
      bytes memory principals = _principals();

      address u = users[0];
      vm.startPrank(u);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      _v().deposit(1e6);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      _v().withdraw(1);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      _v().claim();
      vm.stopPrank();
      address keeper = address(uint160(uint256(vm.load(VAULT, bytes32(uint256(VAULT_STORAGE) + 2)))));
      vm.prank(keeper);
      vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
      _v().onBoostReward(address(usdsc), 1);
      if (stage == 2) {
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        EarnVaultV2(payable(VAULT)).compoundMany(users);
        vm.prank(u);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        EarnVaultV2(payable(VAULT)).withdrawAll();
      }

      uint256 gi = _v().globalIndex();
      _realRound(); // snapshot + distribute through the live redistributor while paused
      assertGt(_v().globalIndex(), gi, 'yield must keep flowing while paused');
      assertEq(_principals(), principals, 'pause moved principal');
      _assertSolvent();
      vm.prank(OWNER_SAFE);
      _v().unpause();
    }
    for (uint256 i = 0; i < users.length; i++) {
      _exitInFull(users[i]);
    }
    _assertSolvent();
  }

  /// @dev The pause flag survives upgrades in both directions, so the vault can be paused first and
  ///      then upgraded or rolled back
  function test_Emergency_UpgradeAndRollbackWhilePaused() public {
    vm.prank(OWNER_SAFE);
    _v().pause();
    bytes memory valuesBefore = _values();
    _upgradeToFixedV1();
    assertTrue(_v().paused());
    _upgradeToV2();
    assertTrue(_v().paused());
    address fixedV1 = address(new EarnVaultUpgradeable());
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), fixedV1, '');
    assertTrue(_v().paused());
    assertEq(_values(), valuesBefore, 'a position moved while paused');
    vm.prank(OWNER_SAFE);
    _v().unpause();
    _reupgradeToV2();
    for (uint256 i = 0; i < users.length; i++) {
      _exitInFull(users[i]);
    }
    _assertSolvent();
  }

  /// @dev Upgrade 2 undone after V2-only activity: boost credits and compounded yield stay as
  ///      principal, the fixed V1 runs normally (no deposit pause, claims), and a later re-upgrade
  ///      with empty data carries on with the same config and cycle counter
  function test_Emergency_RollbackUpgrade2AfterCreditsAndCompounding() public {
    _upgradeToFixedV1();
    vm.prank(OWNER_SAFE);
    _v().setBoostRewardKeeper(KMS_KEEPER);
    _upgradeToV2();
    EarnVaultV2 v2 = EarnVaultV2(payable(VAULT));
    vm.prank(OWNER_SAFE);
    v2.setMaxBoostPerBatch(100e6);
    _realRound();
    _fundedCredit(1, 20e6);
    v2.compoundMany(users);
    _fundedBoost(KMS_KEEPER, 50e6);

    bytes memory valuesBefore = _values();
    address fixedV1 = address(new EarnVaultUpgradeable());
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), fixedV1, '');
    assertEq(_v().getVersion(), 'EarnVaultV1');
    assertEq(_values(), valuesBefore, 'rollback moved a position');
    _assertSolvent();

    // fixed V1 runs as before: open deposits right after a snapshot, funded boosts, claims
    _snapshot();
    address d = _newDepositor('afterRollback', 400e6);
    vm.prank(d);
    _v().deposit(400e6);
    _distribute();
    _fundedBoost(KMS_KEEPER, 50e6);
    vm.prank(users[1]);
    _v().claim();
    _assertSolvent();

    bytes memory mid = _values();
    _reupgradeToV2();
    assertEq(_values(), mid, 're-upgrade moved a position');
    assertEq(v2.boostKeeper(), OWNER_SAFE);
    assertEq(v2.maxBoostPerBatch(), 100e6);
    assertEq(v2.latestCycleId(), 1);
    address[] memory one = new address[](1);
    uint256[] memory amt = new uint256[](1);
    (one[0], amt[0]) = (users[0], 1e6);
    vm.prank(OWNER_SAFE);
    vm.expectRevert(EarnVaultV2.StaleCycle.selector);
    v2.onBoostCredit(1, one, amt); // a paid cycle cannot be paid twice
    _fundedCredit(2, 10e6);
    for (uint256 i = 0; i < users.length; i++) {
      _exitInFull(users[i]);
    }
    _exitInFull(d);
    _assertSolvent();
  }

  /// @dev Forward, back, forward: live V1 -> fixed -> live V1 -> fixed -> V2 -> fixed -> V2, with
  ///      real rounds in between. No switch moves a position; everyone exits in full at the end
  function test_Emergency_FullCycleForwardBackForward() public {
    for (uint256 step = 0; step < 6; step++) {
      _realRound();
      bytes memory before = _values();
      if (step == 0 || step == 2) {
        _upgradeToFixedV1();
      } else if (step == 1) {
        vm.prank(OWNER_SAFE);
        PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), liveV1Impl, '');
      } else if (step == 3) {
        _upgradeToV2();
      } else if (step == 4) {
        address fixedV1 = address(new EarnVaultUpgradeable());
        vm.prank(OWNER_SAFE);
        PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), fixedV1, '');
      } else {
        _reupgradeToV2();
      }
      assertEq(_values(), before, 'an upgrade or rollback moved a position');
      _assertSolvent();
    }
    for (uint256 i = 0; i < users.length; i++) {
      _exitInFull(users[i]);
    }
    _assertSolvent();
  }

  // =============================================================================================

  function _v() internal pure returns (EarnVaultUpgradeable) {
    return EarnVaultUpgradeable(payable(VAULT));
  }

  function _upgradeToFixedV1() internal returns (address impl) {
    impl = address(new EarnVaultUpgradeable());
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), impl, '');
  }

  /// @dev Exactly the production path: the upgrade script's pre-flight run as the owner Safe, then
  ///      one upgradeAndCall carrying initializeV2
  function _upgradeToV2() internal returns (address impl) {
    _unlockIfLocked();
    impl = address(new EarnVaultV2());
    new UpgradeEarnVaultToV2()
      .preflight(
        UpgradeEarnVaultToV2.Params({
        proxy: VAULT, expectedAdmin: address(PROXY_ADMIN), keeper: OWNER_SAFE, cap: BOOST_CAP_V2, implementation: impl
      }),
        OWNER_SAFE
      );
    bytes memory init = abi.encodeCall(EarnVaultV2.initializeV2, (OWNER_SAFE, BOOST_CAP_V2));
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), impl, init);
  }

  /// @dev Every vault struct field, plus each tracked user's mapping entries, plus the
  ///      OpenZeppelin namespaced slots that hold owner, pending owner and the paused flag
  function _rawStorage() internal view returns (bytes memory s) {
    for (uint256 i = 0; i < VAULT_STORAGE_FIELDS; i++) {
      s = abi.encode(s, vm.load(VAULT, bytes32(uint256(VAULT_STORAGE) + i)));
    }
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      s = abi.encode(
        s, _mapSlot(u, 11), _mapSlot(u, 12), _mapSlot(u, 13), _mapSlot(u, 6), _boostSlot(u, 16), _boostSlot(u, 17)
      );
    }
    s = abi.encode(s, _mapSlot(address(usdsc), 14), _mapSlot(address(usdsc), 15), _mapSlot(address(usdsc), 19));
    s = abi.encode(s, vm.load(VAULT, OWNABLE_SLOT), vm.load(VAULT, OWNABLE2STEP_SLOT), vm.load(VAULT, PAUSABLE_SLOT));
  }

  function _mapSlot(address key, uint256 field) internal view returns (bytes32) {
    return vm.load(VAULT, keccak256(abi.encode(key, bytes32(uint256(VAULT_STORAGE) + field))));
  }

  function _boostSlot(address user, uint256 field) internal view returns (bytes32) {
    bytes32 inner = keccak256(abi.encode(user, bytes32(uint256(VAULT_STORAGE) + field)));
    return vm.load(VAULT, keccak256(abi.encode(address(usdsc), inner)));
  }

  /// @dev Per-user values every implementation answers with the same meaning
  function _positions() internal view returns (bytes memory s) {
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      s = abi.encode(
        s,
        _v().principal(u),
        _v().accrued(u),
        _v().userIndex(u),
        _v().claimable(u),
        _v().totalValue(u),
        _v().getClaimableBoostReward(u, address(usdsc))
      );
    }
    s = abi.encode(s, _v().totalPrincipal(), _v().claimReserve(), _v().globalIndex(), usdsc.balanceOf(VAULT));
  }

  /// @dev Values whose meaning is the same on V1 and V2 (claimable() changes meaning on V2)
  function _values() internal view returns (bytes memory s) {
    for (uint256 i = 0; i < users.length; i++) {
      address u = users[i];
      s = abi.encode(
        s, _v().principal(u), _v().accrued(u), _v().totalValue(u), _v().getClaimableBoostReward(u, address(usdsc))
      );
    }
    s = abi.encode(s, _v().totalPrincipal(), _v().claimReserve(), _v().globalIndex(), usdsc.balanceOf(VAULT));
  }

  function _roles() internal view returns (bytes memory) {
    return abi.encode(
      _v().owner(),
      _v().pauser(),
      _v().treasury(),
      _v().yieldRedistributor(),
      _v().paused(),
      address(uint160(uint256(vm.load(VAULT, bytes32(uint256(VAULT_STORAGE) + 2))))) // boostRewardKeeper
    );
  }

  /// @dev A normal day: a yield round, a funded boost from the current keeper, a new deposit, claims,
  ///      a partial withdraw and a full exit. Returns every payout and the resulting state
  function _normalUseScenario() internal returns (bytes memory r) {
    address keeper = address(uint160(uint256(vm.load(VAULT, bytes32(uint256(VAULT_STORAGE) + 2)))));
    vm.recordLogs();
    _realRound();
    _fundedBoost(keeper, 50e6);
    address d = _newDepositor('scenario', 1000e6);
    vm.prank(d);
    _v().deposit(1000e6);
    // an existing depositor tops up after a yield round: their pending yield must be settled first
    address topUp = users[7];
    deal(address(usdsc), topUp, usdsc.balanceOf(topUp) + 250e6);
    vm.startPrank(topUp);
    usdsc.approve(VAULT, 250e6);
    _v().deposit(250e6);
    vm.stopPrank();
    _realRound();
    _fundedBoost(keeper, 50e6);
    address[2] memory extra = [d, topUp];
    for (uint256 i = 0; i < extra.length; i++) {
      address u = extra[i];
      r = abi.encode(
        r,
        _v().principal(u),
        _v().accrued(u),
        _v().claimable(u),
        _v().totalValue(u),
        _v().getClaimableBoostReward(u, address(usdsc))
      );
      uint256 b = usdsc.balanceOf(u);
      vm.prank(u);
      _v().claim(); // both have yield and boost to claim: must succeed
      r = abi.encode(r, usdsc.balanceOf(u) - b);
    }
    for (uint256 i = 0; i < 4; i++) {
      uint256 b = usdsc.balanceOf(users[i]);
      vm.prank(users[i]);
      (bool ok,) = VAULT.call(abi.encodeCall(EarnVaultUpgradeable.claim, ()));
      r = abi.encode(r, ok, usdsc.balanceOf(users[i]) - b);
    }
    uint256 b5 = usdsc.balanceOf(users[5]);
    uint256 p5 = _v().principal(users[5]);
    uint256 half = p5 == 0 ? 0 : p5 / 3 + 1; // odd split, exercises rounding
    if (half > 0) {
      vm.prank(users[5]);
      _v().withdraw(half);
    }
    r = abi.encode(r, usdsc.balanceOf(users[5]) - b5);
    uint256 b6 = usdsc.balanceOf(users[6]);
    uint256 p6 = _v().principal(users[6]);
    if (p6 > 0) {
      vm.prank(users[6]);
      _v().withdraw(p6);
    }
    r = abi.encode(r, usdsc.balanceOf(users[6]) - b6, _positions(), _vaultLogs());
  }

  /// @dev Every event the vault emitted since vm.recordLogs(), in order
  function _vaultLogs() internal returns (bytes memory e) {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == VAULT) e = abi.encode(e, logs[i].topics, logs[i].data);
    }
  }

  function _codeHasAddress(address target, address needle) internal view returns (bool) {
    bytes memory code = target.code;
    bytes20 n = bytes20(needle);
    for (uint256 i = 0; i + 20 <= code.length; i++) {
      bytes20 w;
      assembly {
        w := mload(add(add(code, 32), i))
      }
      if (w == n) return true;
    }
    return false;
  }

  function _permitSig(address signer, uint256 key, uint256 amount) internal view returns (uint8, bytes32, bytes32) {
    IPermit t = IPermit(address(usdsc));
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)'),
        signer,
        VAULT,
        amount,
        t.nonces(signer),
        block.timestamp + 1 hours
      )
    );
    return vm.sign(key, keccak256(abi.encodePacked('\x19\x01', t.DOMAIN_SEPARATOR(), structHash)));
  }

  /// @dev After a rollback the initialized version is already 2: the re-upgrade carries no data
  function _reupgradeToV2() internal {
    address impl = address(new EarnVaultV2());
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(VAULT), impl, '');
    assertEq(_v().getVersion(), 'EarnVaultV2');
  }

  /// @dev Boost credit from the boost keeper (the owner Safe until loyalty): funded first
  function _fundedCredit(uint256 cycleId, uint256 each) internal {
    _unlockIfLocked();
    address[] memory who = new address[](2);
    uint256[] memory amt = new uint256[](2);
    (who[0], who[1], amt[0], amt[1]) = (users[0], users[1], each, each);
    deal(address(usdsc), OWNER_SAFE, usdsc.balanceOf(OWNER_SAFE) + 2 * each);
    vm.startPrank(OWNER_SAFE);
    require(usdsc.transfer(VAULT, 2 * each), 'transfer failed');
    EarnVaultV2(payable(VAULT)).onBoostCredit(cycleId, who, amt);
    vm.stopPrank();
  }

  function _principals() internal view returns (bytes memory s) {
    for (uint256 i = 0; i < users.length; i++) {
      s = abi.encode(s, _v().principal(users[i]));
    }
    s = abi.encode(s, _v().totalPrincipal());
  }

  function _exitInFull(address u) internal {
    uint256 owed = _v().totalValue(u) + _v().getClaimableBoostReward(u, address(usdsc));
    if (_v().principal(u) + EarnVaultV2(payable(VAULT)).pendingYield(u) == 0) return;
    uint256 bal = usdsc.balanceOf(u);
    vm.prank(u);
    EarnVaultV2(payable(VAULT)).withdrawAll();
    assertEq(usdsc.balanceOf(u) - bal, owed, 'not paid in full');
    assertEq(_v().totalValue(u), 0);
    assertEq(_v().getClaimableBoostReward(u, address(usdsc)), 0);
  }

  function _exitInFullV1(address u) internal {
    uint256 owed = _v().totalValue(u) + _v().getClaimableBoostReward(u, address(usdsc));
    uint256 p = _v().principal(u);
    if (p == 0) return;
    uint256 bal = usdsc.balanceOf(u);
    vm.prank(u);
    _v().withdraw(p);
    assertEq(usdsc.balanceOf(u) - bal, owed, 'not paid in full after rollback');
    assertEq(_v().totalValue(u), 0);
  }

  function _fundedBoost(address keeper, uint256 amount) internal {
    deal(address(usdsc), keeper, usdsc.balanceOf(keeper) + amount);
    vm.startPrank(keeper);
    require(usdsc.transfer(VAULT, amount), 'transfer failed');
    _v().onBoostReward(address(usdsc), amount);
    vm.stopPrank();
  }

  /// @dev Advance 3 hours and run a real snapshot -> distribute, with fresh M yield to claim
  function _realRound() internal {
    _snapshot();
    _distribute();
  }

  function _snapshot() internal {
    uint128 index = M_TOKEN.currentIndex();
    vm.prank(M_PORTAL);
    M_TOKEN.updateIndex(index + index / 100_000);
    vm.warp(block.timestamp + 3 hours);
    vm.roll(block.number + 5400);
    vm.prank(KMS_KEEPER);
    RR.snapshotVaultTVLs();
  }

  function _distribute() internal {
    vm.roll(block.number + 2);
    vm.warp(block.timestamp + 4);
    vm.prank(KMS_KEEPER);
    RR.distribute();
    vm.warp(block.timestamp + RR.snapshotMaxAge() + 1); // past any deposit pause
  }

  function _unlockIfLocked() internal {
    (bool ok, bytes memory data) = VAULT.staticcall(abi.encodeWithSignature('depositsLocked()'));
    if (!ok || data.length < 64) return;
    (bool locked, uint256 unlocksAt) = abi.decode(data, (bool, uint256));
    if (locked) vm.warp(unlocksAt);
  }

  function _newDepositor(string memory name, uint256 amount) internal returns (address d) {
    d = makeAddr(name);
    deal(address(usdsc), d, amount);
    vm.prank(d);
    usdsc.approve(VAULT, type(uint256).max);
  }

  function _initializedVersion() internal view returns (uint64) {
    return uint64(uint256(vm.load(VAULT, INITIALIZABLE_SLOT)));
  }

  function _assertSolvent() internal view {
    uint256 owedBoost = uint256(_mapSlot(address(usdsc), 15)); // boostClaimReserve[USDSC]; no V1 view
    assertGe(usdsc.balanceOf(VAULT), _v().claimReserve() + owedBoost, 'vault under-reserved');
    assertGe(_v().claimReserve(), _v().totalPrincipal(), 'reserve below principal');
  }
}
