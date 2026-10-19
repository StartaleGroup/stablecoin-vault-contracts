// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {RewardRedistributor} from '../../src/distributor/RewardRedistributor.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {EarnVaultV3FromV2} from '../mocks/EarnVaultV3FromV2.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

/// @dev The live M token's index and its portal-only update (a bridge index message)
interface IMTokenIndex {
  function currentIndex() external view returns (uint128);
  function updateIndex(uint128 index) external;
}

/// @title Live V1 -> V2 -> V3 upgrade path
/// @notice Forks Soneium, upgrades the live EarnVault to the current EarnVaultV2 through the owner Safe,
///         runs real V2 activity, then upgrades the same proxy to EarnVaultV3FromV2 (a V3 that inherits
///         the current V2) retiring onBoostReward. Live state must carry over unchanged and V3 must keep
///         working with the real RewardRedistributor.
/// @dev Opt-in:
///        RUN_SONEIUM_FORK=true forge test --match-path test/fork/EarnVaultV3UpgradePath.soneium.fork.t.sol \
///          --libraries src/vaults/earn/BoostRewardsLib.sol:BoostRewardsLib:0x674894C99714bf7E6Acdd9a73d46c6f9EACe66CE -vv
contract EarnVaultV3UpgradePathSoneiumFork is Test {
  EarnVaultV2 constant VAULT = EarnVaultV2(payable(0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0));
  ProxyAdmin constant PROXY_ADMIN = ProxyAdmin(0xDBc42e5c7E6BF89886F2f359F9b0BB9344824066);
  address constant OWNER_SAFE = 0x3C27038D9906caa5D68355B1800625EAcaCd93dA;
  RewardRedistributor constant RR = RewardRedistributor(0xda798684ffD5eb509c2Ab7b8352EC55B31F18201);
  address constant RR_OPERATOR = 0x86bE13a26d548FA5407Ee3E5a8321B4E1019333C;
  address constant WHALE = 0xAfC03035BDe20071BC930eE8112a7B4b683Cff49;
  bytes32 constant EARN_VAULT_STORAGE = 0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;
  bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
  IMTokenIndex constant M_TOKEN = IMTokenIndex(0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b);
  address constant M_PORTAL = 0xD925C84b55E4e44a53749fF5F2a5A13F63D128fd;

  IERC20 usdsc;
  address boostRewardKeeper;
  address boostKeeper = makeAddr('boostKeeper');
  address creditee = makeAddr('creditee');

  function setUp() public {
    if (!vm.envOr('RUN_SONEIUM_FORK', false)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(vm.envOr('SONEIUM_RPC_URL', string('https://rpc.soneium.org')));
    usdsc = IERC20(VAULT.asset());
    boostRewardKeeper = _boostRewardKeeper();

    // V1 -> V2, exactly as production will do it
    address v2 = address(new EarnVaultV2());
    bytes memory init2 = abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, 10_000e6));
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(address(VAULT)), v2, init2);

    // real V2 activity: a distribution round, a boost credit cycle, a daily USDSC boost reward
    _realRound();
    _credit(1, creditee, 25e6);
    deal(address(usdsc), boostRewardKeeper, 50e6);
    vm.startPrank(boostRewardKeeper);
    require(usdsc.transfer(address(VAULT), 50e6), 'transfer failed');
    VAULT.onBoostReward(address(usdsc), 50e6);
    vm.stopPrank();
    _assertSolvent();
  }

  function test_LiveUpgradeToV3_StateCarriesOverUnchanged() public {
    bytes memory before = _state();
    _upgradeToV3(true);
    assertEq(_state(), before, 'live state changed across V2 -> V3');
    assertEq(VAULT.getVersion(), 'EarnVaultV3');
    assertEq(uint64(uint256(vm.load(address(VAULT), INITIALIZABLE_SLOT))), 3);
    assertEq(_boostRewardKeeper(), address(0), 'onBoostReward retired');
  }

  /// @dev After V3: the deposit lock still follows the real redistributor, a real round still indexes
  ///      yield, onBoostCredit opens the next cycle, onBoostReward is closed, and the whale exits whole
  function test_LiveV3_KeepsWorkingWithTheRealRedistributor() public {
    _upgradeToV3(true);

    // deposit lock still follows a real snapshot
    _accrueMYield();
    vm.warp(block.timestamp + 3 hours);
    vm.roll(block.number + 5400);
    vm.prank(RR_OPERATOR);
    RR.snapshotVaultTVLs();
    (bool locked, uint256 unlocksAt) = VAULT.depositsLocked();
    assertTrue(locked);
    deal(address(usdsc), WHALE, 1e6);
    vm.startPrank(WHALE);
    usdsc.approve(address(VAULT), 1e6);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, unlocksAt));
    VAULT.deposit(1e6);
    vm.stopPrank();

    uint256 gi = VAULT.globalIndex();
    vm.roll(block.number + 2);
    vm.warp(block.timestamp + 4);
    vm.prank(RR_OPERATOR);
    RR.distribute();
    assertGt(VAULT.globalIndex(), gi, 'no yield indexed after V3');
    vm.warp(unlocksAt);

    // onBoostCredit: next cycle
    uint256 p = VAULT.principal(creditee) + VAULT.pendingYield(creditee);
    _credit(2, creditee, 10e6);
    assertEq(VAULT.principal(creditee), p + 10e6);

    // onBoostReward: retired
    deal(address(usdsc), address(VAULT), usdsc.balanceOf(address(VAULT)) + 50e6);
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.NotBoostRewardKeeper.selector);
    VAULT.onBoostReward(address(usdsc), 50e6);

    // the whale exits whole, owed boost included
    uint256 owed = VAULT.totalValue(WHALE) + VAULT.getClaimableBoostReward(WHALE, address(usdsc));
    uint256 bal = usdsc.balanceOf(WHALE);
    vm.prank(WHALE);
    VAULT.withdrawAll();
    assertEq(usdsc.balanceOf(WHALE) - bal, owed, 'whale not paid in full');
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------

  function _upgradeToV3(bool retire) internal {
    address v3 = address(new EarnVaultV3FromV2());
    bytes memory init3 = abi.encodeCall(EarnVaultV3FromV2.initializeV3, (1, retire));
    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(ITransparentUpgradeableProxy(address(VAULT)), v3, init3);
  }

  function _state() internal view returns (bytes memory) {
    address[2] memory us = [WHALE, creditee];
    bytes memory s;
    for (uint256 i = 0; i < us.length; i++) {
      s = abi.encode(
        s,
        VAULT.principal(us[i]),
        VAULT.pendingYield(us[i]),
        VAULT.accrued(us[i]),
        VAULT.totalValue(us[i]),
        VAULT.getClaimableBoostReward(us[i], address(usdsc)),
        VAULT.lastCreditedCycle(us[i])
      );
    }
    return abi.encode(
      s,
      VAULT.totalPrincipal(),
      VAULT.claimReserve(),
      VAULT.boostClaimReserve(address(usdsc)),
      VAULT.globalIndex(),
      VAULT.surplusUSDSC(),
      VAULT.latestCycleId(),
      VAULT.boostKeeper(),
      VAULT.maxBoostPerBatch(),
      VAULT.owner(),
      VAULT.yieldRedistributor()
    );
  }

  function _realRound() internal {
    _accrueMYield();
    vm.warp(block.timestamp + 3 hours);
    vm.roll(block.number + 5400);
    vm.prank(RR_OPERATOR);
    RR.snapshotVaultTVLs();
    vm.roll(block.number + 2);
    vm.warp(block.timestamp + 4);
    vm.prank(RR_OPERATOR);
    RR.distribute();
    vm.warp(block.timestamp + RR.snapshotMaxAge() + 1);
  }

  /// @dev The M portal pushes a slightly higher index, so a round always has yield to claim
  function _accrueMYield() internal {
    uint128 index = M_TOKEN.currentIndex();
    vm.prank(M_PORTAL);
    M_TOKEN.updateIndex(index + index / 100_000);
  }

  function _credit(uint256 cycleId, address user, uint256 amount) internal {
    address[] memory u = new address[](1);
    uint256[] memory a = new uint256[](1);
    (u[0], a[0]) = (user, amount);
    deal(address(usdsc), boostKeeper, amount);
    vm.startPrank(boostKeeper);
    require(usdsc.transfer(address(VAULT), amount), 'transfer failed');
    VAULT.onBoostCredit(cycleId, u, a);
    vm.stopPrank();
  }

  function _boostRewardKeeper() internal view returns (address) {
    return address(uint160(uint256(vm.load(address(VAULT), bytes32(uint256(EARN_VAULT_STORAGE) + 2)))));
  }

  function _assertSolvent() internal view {
    assertGe(
      usdsc.balanceOf(address(VAULT)),
      VAULT.claimReserve() + VAULT.boostClaimReserve(address(usdsc)),
      'vault under-reserved'
    );
  }
}
