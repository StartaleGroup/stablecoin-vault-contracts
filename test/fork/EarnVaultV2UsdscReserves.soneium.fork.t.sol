// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UpgradeEarnVaultToV2} from '../../script/upgrade/UpgradeEarnVaultToV2.s.sol';
import {RewardRedistributor} from '../../src/distributor/RewardRedistributor.sol';
import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test, console2} from 'forge-std/Test.sol';

/// @title USDSC reserve accounting on the live vault after the V2 upgrade
/// @notice Forks Soneium, upgrades the live EarnVault to EarnVaultV2 through the owner Safe
///         (ProxyAdmin.upgradeAndCall), then checks that every USDSC funding and surplus check
///         keeps both reserves covered: claimReserve and boostClaimReserve[USDSC].
/// @dev Opt-in (needs an RPC; state moves with the chain):
///        RUN_SONEIUM_FORK=true forge test --match-path test/fork/EarnVaultV2UsdscReserves.soneium.fork.t.sol \
///          --libraries src/vaults/earn/BoostRewardsLib.sol:BoostRewardsLib:0x674894C99714bf7E6Acdd9a73d46c6f9EACe66CE -vv
contract EarnVaultV2UsdscReservesSoneiumFork is Test {
  EarnVaultV2 constant VAULT = EarnVaultV2(payable(0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0));
  ProxyAdmin constant PROXY_ADMIN = ProxyAdmin(0xDBc42e5c7E6BF89886F2f359F9b0BB9344824066);
  address constant OWNER_SAFE = 0x3C27038D9906caa5D68355B1800625EAcaCd93dA;
  RewardRedistributor constant RR = RewardRedistributor(0xda798684ffD5eb509c2Ab7b8352EC55B31F18201);
  address constant RR_OPERATOR = 0x86bE13a26d548FA5407Ee3E5a8321B4E1019333C;
  address constant WHALE = 0xAfC03035BDe20071BC930eE8112a7B4b683Cff49;
  bytes32 constant EARN_VAULT_STORAGE = 0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;

  IERC20 usdsc;
  address boostRewardKeeper; // read from live storage (no public getter)
  address boostKeeper = makeAddr('boostKeeper');

  function setUp() public {
    if (!vm.envOr('RUN_SONEIUM_FORK', false)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(vm.envOr('SONEIUM_RPC_URL', string('https://rpc.soneium.org')));
    usdsc = IERC20(VAULT.asset());
    boostRewardKeeper = address(uint160(uint256(vm.load(address(VAULT), bytes32(uint256(EARN_VAULT_STORAGE) + 2)))));

    address impl = address(new EarnVaultV2());

    // The upgrade script's own pre-flight must pass on today's live state, run as the owner Safe:
    // admin slot, ownership, V1 + init version, redistributor getters, and USDSC-only boost tokens.
    new UpgradeEarnVaultToV2()
      .preflight(
        UpgradeEarnVaultToV2.Params({
        proxy: address(VAULT),
        expectedAdmin: address(PROXY_ADMIN),
        keeper: boostKeeper,
        cap: 10_000e6,
        implementation: impl
      }),
        OWNER_SAFE
      );

    vm.prank(OWNER_SAFE);
    PROXY_ADMIN.upgradeAndCall(
      ITransparentUpgradeableProxy(address(VAULT)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (boostKeeper, 10_000e6))
    );
    console2.log('free USDSC after upgrade', _free());
  }

  // ---------------------------------------------------------------------------------------------
  // Live state is consistent before anything happens
  // ---------------------------------------------------------------------------------------------

  function test_LiveVaultCoversBothReserves() public view {
    assertGt(VAULT.boostClaimReserve(address(usdsc)), 0, 'live vault has USDSC owed as boost');
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------
  // Boost rewards are USDSC-only, and boost tokens can't be removed
  // ---------------------------------------------------------------------------------------------

  function test_LiveVaultHasOnlyUsdscAsBoostToken() public view {
    (, address[] memory tokens,) = VAULT.getAllClaimables(WHALE);
    assertEq(tokens.length, 1);
    assertEq(tokens[0], address(usdsc));
  }

  function test_NonUsdscBoostRevertsEvenWhenFunded() public {
    address other = address(new FundedToken());
    FundedToken(other).mint(address(VAULT), 1e18);
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.BoostTokenNotUSDSC.selector);
    VAULT.onBoostReward(other, 1e18);
  }

  function test_RemoveBoostRewardTokenNoLongerExists() public {
    // A never-registered token: the old removeBoostRewardToken() returned early with success for it,
    // so this call can only fail because the function is gone
    vm.prank(OWNER_SAFE);
    (bool ok,) = address(VAULT).call(abi.encodeWithSignature('removeBoostRewardToken(address)', address(0xdEaD)));
    assertFalse(ok, 'removeBoostRewardToken still exists');
    (, address[] memory tokens,) = VAULT.getAllClaimables(WHALE);
    assertEq(tokens.length, 1, 'USDSC still registered');
  }

  // ---------------------------------------------------------------------------------------------
  // onBoostReward(USDSC)
  // ---------------------------------------------------------------------------------------------

  function test_UnfundedBoostReverts() public {
    uint256 amount = _free() + 1;
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    VAULT.onBoostReward(address(usdsc), amount);
  }

  function test_BoostAgainstWholeBalanceReverts() public {
    uint256 amount = usdsc.balanceOf(address(VAULT)) - VAULT.boostClaimReserve(address(usdsc));
    vm.prank(boostRewardKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    VAULT.onBoostReward(address(usdsc), amount);
  }

  /// @dev A keeper that also deposits still can't index more than it funded, and gains nothing
  function test_DepositingKeeperStillNeedsFundedBoost() public {
    uint256 keeperDeposit = VAULT.totalPrincipal();
    deal(address(usdsc), boostRewardKeeper, keeperDeposit);
    vm.startPrank(boostRewardKeeper);
    usdsc.approve(address(VAULT), keeperDeposit);
    VAULT.deposit(keeperDeposit);
    uint256 amount = usdsc.balanceOf(address(VAULT)) - VAULT.boostClaimReserve(address(usdsc));
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    VAULT.onBoostReward(address(usdsc), amount);
    uint256 p = VAULT.principal(boostRewardKeeper);
    VAULT.withdraw(p);
    vm.stopPrank();

    assertLe(usdsc.balanceOf(boostRewardKeeper), keeperDeposit, 'keeper gained nothing');
    _assertSolvent();
    _whaleExitsInFull();
  }

  /// @dev The daily round as the Safe sends it (transfer, then index) keeps working
  function test_FundedDailyBoostRoundWorks() public {
    uint256 reserve = VAULT.boostClaimReserve(address(usdsc));
    uint256 free = _free();
    deal(address(usdsc), boostRewardKeeper, 50e6);
    vm.startPrank(boostRewardKeeper);
    usdsc.transfer(address(VAULT), 50e6);
    VAULT.onBoostReward(address(usdsc), 50e6);
    vm.stopPrank();
    assertEq(VAULT.boostClaimReserve(address(usdsc)), reserve + 50e6);
    assertEq(_free(), free, 'free USDSC unchanged by a funded round');
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------
  // onBoostCredit
  // ---------------------------------------------------------------------------------------------

  function test_UnfundedBoostCreditReverts() public {
    (address[] memory users, uint256[] memory amounts) = _oneEntry(WHALE, _free() + 1);
    vm.prank(boostKeeper);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    VAULT.onBoostCredit(1, users, amounts);
  }

  /// @dev A credit inside the real redistributor's snapshot window reverts; the same batch goes
  ///      through once the window has passed
  function test_BoostCreditLockedDuringSnapshotWindow() public {
    (address[] memory users, uint256[] memory amounts) = _oneEntry(WHALE, 25e6);
    deal(address(usdsc), boostKeeper, 25e6);
    vm.prank(boostKeeper);
    usdsc.transfer(address(VAULT), 25e6);

    vm.warp(block.timestamp + 1 hours); // let any live snapshot window lapse first
    vm.roll(block.number + 1800);
    vm.prank(RR_OPERATOR);
    RR.snapshotVaultTVLs();
    (bool locked, uint256 unlocksAt) = VAULT.depositsLocked();
    assertTrue(locked);

    vm.prank(boostKeeper);
    vm.expectRevert(abi.encodeWithSelector(EarnVaultV2.DepositsLockedForDistribution.selector, unlocksAt));
    VAULT.onBoostCredit(1, users, amounts);

    // the operator distributes inside the window as usual
    vm.roll(block.number + 2);
    vm.warp(block.timestamp + 4);
    vm.prank(RR_OPERATOR);
    RR.distribute();

    vm.warp(unlocksAt);
    uint256 before = VAULT.principal(WHALE) + VAULT.pendingYield(WHALE);
    vm.prank(boostKeeper);
    VAULT.onBoostCredit(1, users, amounts);
    assertEq(VAULT.principal(WHALE), before + 25e6);
    _assertSolvent();
  }

  function test_FundedBoostCreditWorks() public {
    (address[] memory users, uint256[] memory amounts) = _oneEntry(WHALE, 25e6);
    uint256 before = VAULT.principal(WHALE) + VAULT.pendingYield(WHALE);
    deal(address(usdsc), boostKeeper, 25e6);
    vm.startPrank(boostKeeper);
    usdsc.transfer(address(VAULT), 25e6);
    VAULT.onBoostCredit(1, users, amounts);
    vm.stopPrank();
    assertEq(VAULT.principal(WHALE), before + 25e6);
    _assertSolvent();
  }

  /// @dev Funding covers only what is credited: a skipped entry (the vault's own address) larger
  ///      than the whole free USDSC needs none. The credited amount uses up the existing free USDSC
  ///      plus 25 USDSC sent in, so one unit less reverts and the exact amount succeeds.
  function test_BoostCreditFundingCoversOnlyCreditedAmount() public {
    uint256 credit = _free() + 25e6;
    address[] memory users = new address[](2);
    uint256[] memory amounts = new uint256[](2);
    (users[0], amounts[0]) = (WHALE, credit);
    (users[1], amounts[1]) = (address(VAULT), credit + 1000e6);
    uint256 before = VAULT.principal(WHALE) + VAULT.pendingYield(WHALE);

    deal(address(usdsc), boostKeeper, 25e6);
    vm.startPrank(boostKeeper);
    usdsc.transfer(address(VAULT), 25e6 - 1);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    VAULT.onBoostCredit(1, users, amounts);

    usdsc.transfer(address(VAULT), 1);
    VAULT.onBoostCredit(1, users, amounts);
    vm.stopPrank();

    assertEq(VAULT.principal(WHALE), before + credit);
    assertEq(_free(), 0, 'credited exactly up to the free USDSC');
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------
  // onYield, through the real RewardRedistributor
  // ---------------------------------------------------------------------------------------------

  function test_UnfundedYieldReverts() public {
    uint256 amount = _free() + 1;
    vm.prank(address(RR));
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientFunding.selector);
    VAULT.onYield(amount);
  }

  function test_RealDistributionRoundsWork() public {
    uint256 gi = VAULT.globalIndex();
    for (uint256 r = 0; r < 3; r++) {
      vm.warp(block.timestamp + 3 hours);
      vm.roll(block.number + 5400);
      vm.prank(RR_OPERATOR);
      RR.snapshotVaultTVLs();
      vm.roll(block.number + 2);
      vm.warp(block.timestamp + 4);
      vm.prank(RR_OPERATOR);
      RR.distribute();
      _assertSolvent();
    }
    assertGt(VAULT.globalIndex(), gi, 'no yield indexed');
    _whaleExitsInFull();
  }

  // ---------------------------------------------------------------------------------------------
  // Surplus: sweep and recover take only USDSC above both reserves
  // ---------------------------------------------------------------------------------------------

  function test_SweepTakesOnlyFreeUsdsc() public {
    address treasury = VAULT.treasury();
    uint256 free = _free();
    uint256 before = usdsc.balanceOf(treasury);
    vm.prank(OWNER_SAFE);
    VAULT.sweepSurplusToTreasury();
    assertEq(usdsc.balanceOf(treasury) - before, free);
    assertEq(_free(), 0);
    _assertSolvent();
  }

  function test_RecoverTakesOnlyFreeUsdsc() public {
    address treasury = VAULT.treasury();
    uint256 free = _free();
    vm.startPrank(OWNER_SAFE);
    VAULT.pause();
    vm.expectRevert(IEarnVaultEventsAndErrors.ExceedsSurplus.selector);
    VAULT.recoverERC20(address(usdsc), treasury, free + 1);
    VAULT.recoverERC20(address(usdsc), treasury, free);
    VAULT.unpause();
    vm.stopPrank();
    _assertSolvent();
  }

  // ---------------------------------------------------------------------------------------------

  function _required() internal view returns (uint256) {
    return VAULT.claimReserve() + VAULT.boostClaimReserve(address(usdsc));
  }

  function _free() internal view returns (uint256) {
    uint256 bal = usdsc.balanceOf(address(VAULT));
    uint256 req = _required();
    return bal > req ? bal - req : 0;
  }

  function _assertSolvent() internal view {
    assertGe(usdsc.balanceOf(address(VAULT)), _required(), 'vault under-reserved');
  }

  function _whaleExitsInFull() internal {
    uint256 owed = VAULT.totalValue(WHALE) + VAULT.getClaimableBoostReward(WHALE, address(usdsc));
    uint256 all = VAULT.principal(WHALE) + VAULT.pendingYield(WHALE);
    uint256 before = usdsc.balanceOf(WHALE);
    vm.prank(WHALE);
    VAULT.withdraw(all);
    assertEq(usdsc.balanceOf(WHALE) - before, owed, 'whale not paid in full');
    _assertSolvent();
  }

  function _oneEntry(address user, uint256 amount) internal pure returns (address[] memory u, uint256[] memory a) {
    u = new address[](1);
    a = new uint256[](1);
    (u[0], a[0]) = (user, amount);
  }
}

/// @dev A plain ERC20-shaped token with a working transfer, to show funding doesn't matter
contract FundedToken {
  mapping(address => uint256) public balanceOf;

  function mint(address to, uint256 amount) external {
    balanceOf[to] += amount;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    return true;
  }
}
