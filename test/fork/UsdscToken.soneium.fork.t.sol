// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UsdscToken} from '../../src/coin/UsdscToken.sol';
import {RewardRedistributor} from '../../src/distributor/RewardRedistributor.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

/// @dev The live M token's index and its portal-only update (a bridge index message)
interface IMTokenIndex {
  function currentIndex() external view returns (uint128);
  function updateIndex(uint128 index) external;
}

/// @title The repo's UsdscToken behaves as the live USDSC implementation
/// @notice Forks Soneium and runs the same actions twice from the same state: once with the live
///         implementation behind the USDSC proxy, once with this repo's UsdscToken (built with the live
///         constructor arguments) placed at the implementation address. Results must match.
/// @dev Opt-in:
///        RUN_SONEIUM_FORK=true forge test --match-path test/fork/UsdscToken.soneium.fork.t.sol -vv
contract UsdscTokenSoneiumFork is Test {
  address constant USDSC_PROXY = 0x3f99231dD03a9F0E7e3421c92B7b90fbe012985a;
  address constant LIVE_IMPL = 0x38E4713a896EfCF253430efD6292515Dc13489A1;
  address constant M_TOKEN = 0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b;
  address constant SWAP_FACILITY = 0xB6807116b3B1B321a390594e31ECD6e0076f6278;
  RewardRedistributor constant RR = RewardRedistributor(0xda798684ffD5eb509c2Ab7b8352EC55B31F18201);
  address constant RR_OPERATOR = 0x86bE13a26d548FA5407Ee3E5a8321B4E1019333C;
  address constant EARN_VAULT = 0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0;
  address constant M_PORTAL = 0xD925C84b55E4e44a53749fF5F2a5A13F63D128fd;

  UsdscToken constant USDSC = UsdscToken(USDSC_PROXY);
  bytes repoCode;

  function setUp() public {
    if (!vm.envOr('RUN_SONEIUM_FORK', false)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(vm.envOr('SONEIUM_RPC_URL', string('https://rpc.soneium.org')));
    repoCode = address(new UsdscToken(M_TOKEN, SWAP_FACILITY)).code;
  }

  function test_LiveProxyPointsAtTheVerifiedImplementation() public view {
    bytes32 slot = bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1);
    assertEq(address(uint160(uint256(vm.load(USDSC_PROXY, slot)))), LIVE_IMPL);
  }

  function test_ViewsMatchLive() public {
    bytes memory live = _views();
    _useRepoCode();
    assertEq(_views(), live);
  }

  function test_TransferMatchesLive() public {
    uint256 id = vm.snapshotState();
    bytes memory live = _transfer();
    vm.revertToState(id);
    _useRepoCode();
    assertEq(_transfer(), live);
  }

  /// @dev claimYield() is gated to YIELD_CLAIMER_ROLE in both
  function test_ClaimYieldGateMatchesLive() public {
    _expectClaimYieldGated();
    _useRepoCode();
    _expectClaimYieldGated();
  }

  /// @dev A real snapshot -> distribute round (the redistributor holds YIELD_CLAIMER_ROLE and calls
  ///      claimYield()) leaves identical balances under either implementation
  function test_RealDistributionMatchesLive() public {
    uint256 id = vm.snapshotState();
    bytes memory live = _distributionRound();
    vm.revertToState(id);
    _useRepoCode();
    assertEq(_distributionRound(), live);
  }

  // ---------------------------------------------------------------------------------------------

  function _useRepoCode() internal {
    vm.etch(LIVE_IMPL, repoCode);
  }

  function _views() internal view returns (bytes memory) {
    return abi.encode(
      USDSC.name(),
      USDSC.symbol(),
      USDSC.decimals(),
      USDSC.totalSupply(),
      USDSC.yieldRecipient(),
      USDSC.yield(),
      USDSC.balanceOf(EARN_VAULT),
      USDSC.YIELD_CLAIMER_ROLE(),
      USDSC.hasRole(USDSC.YIELD_CLAIMER_ROLE(), address(RR)),
      USDSC.mToken(),
      USDSC.swapFacility()
    );
  }

  function _transfer() internal returns (bytes memory) {
    address to = makeAddr('to');
    vm.prank(EARN_VAULT);
    require(IERC20(USDSC_PROXY).transfer(to, 1e6), 'transfer failed');
    return abi.encode(USDSC.balanceOf(EARN_VAULT), USDSC.balanceOf(to), USDSC.totalSupply());
  }

  function _expectClaimYieldGated() internal {
    address stranger = makeAddr('stranger');
    bytes32 role = USDSC.YIELD_CLAIMER_ROLE();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
    vm.prank(stranger);
    USDSC.claimYield();
  }

  function _distributionRound() internal returns (bytes memory) {
    vm.warp(block.timestamp + 3 hours);
    vm.roll(block.number + 5400);
    // the M portal pushes a slightly higher index, so the round has real yield to claim
    uint128 index = IMTokenIndex(M_TOKEN).currentIndex();
    vm.prank(M_PORTAL);
    IMTokenIndex(M_TOKEN).updateIndex(index + index / 100_000);
    uint256 yield_ = USDSC.yield();
    assertGt(yield_, 0, 'no USDSC yield to claim');
    vm.prank(RR_OPERATOR);
    RR.snapshotVaultTVLs();
    vm.roll(block.number + 2);
    vm.warp(block.timestamp + 4);
    vm.prank(RR_OPERATOR);
    RR.distribute();
    assertEq(USDSC.yield(), 0, 'round claimed the yield');
    return abi.encode(
      yield_,
      USDSC.totalSupply(),
      USDSC.balanceOf(EARN_VAULT),
      USDSC.balanceOf(address(RR)),
      USDSC.balanceOf(RR.treasury())
    );
  }
}
