// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVault} from '../../src/vaults/earn/EarnVault.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {StdStorage, Test, stdStorage} from 'lib/forge-std/src/Test.sol';

/// @dev Boost token whose transfer() behaviour is configurable, to cover every return shape a
///      non-standard ERC20 can produce
contract ConfigurableBoostToken {
  enum Mode {
    Normal, // returns true
    ReturnsFalse, // returns false, moves nothing
    Reverts, // reverts
    NoReturnData, // moves tokens, returns nothing (USDT-style)
    NonBoolWord, // moves nothing, returns the word 2
    LongReturnTrue // moves tokens, returns 64 bytes whose first word is 1
  }

  Mode public mode;
  mapping(address => uint256) public balanceOf;

  function setMode(Mode m) external {
    mode = m;
  }

  function mint(address to, uint256 amount) external {
    balanceOf[to] += amount;
  }

  function transfer(address to, uint256 amount) external {
    Mode m = mode;
    if (m == Mode.Reverts) revert('blocked');
    if (m == Mode.ReturnsFalse) {
      assembly {
        mstore(0, 0)
        return(0, 32)
      }
    }
    if (m == Mode.NonBoolWord) {
      assembly {
        mstore(0, 2)
        return(0, 32)
      }
    }
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    if (m == Mode.NoReturnData) {
      assembly {
        return(0, 0)
      }
    }
    if (m == Mode.LongReturnTrue) {
      assembly {
        mstore(0, 1)
        mstore(32, 7)
        return(0, 64)
      }
    }
    assembly {
      mstore(0, 1)
      return(0, 32)
    }
  }
}

/// @title Boost token edge cases on EarnVault (V2 proxy and the non-upgradeable twin)
/// @notice Boost payouts must cope with every transfer() return shape without blocking
///         withdraw()/claim().
contract EarnVaultBoostTokenEdgeCasesTest is Test {
  using stdStorage for StdStorage;

  EarnVaultV2 vault;
  MockUSDSC usdsc;

  address admin = makeAddr('admin');
  address owner = makeAddr('owner');
  address redistributor = makeAddr('redistributor');
  address treasury = makeAddr('treasury');
  address pauser = makeAddr('pauser');
  address keeper = makeAddr('boostRewardKeeper');
  address alice = makeAddr('alice');
  address bob = makeAddr('bob');

  uint256 constant DEPOSIT = 1000e6;

  function setUp() public {
    usdsc = new MockUSDSC();
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new EarnVaultUpgradeable()),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, keeper
      )
    );
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), adminSlot)))));
    address impl = address(new EarnVaultV2());
    vm.prank(admin);
    pa.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      impl,
      abi.encodeCall(EarnVaultV2.initializeV2, (makeAddr('boostKeeper'), type(uint256).max))
    );
    vault = EarnVaultV2(payable(address(proxy)));
    _deposit(alice, DEPOSIT);
  }

  // ---------------------------------------------------------------------------------------------
  // Boost payout return shapes
  // ---------------------------------------------------------------------------------------------

  function _boostWith(ConfigurableBoostToken.Mode mode) internal returns (ConfigurableBoostToken t) {
    t = new ConfigurableBoostToken();
    t.mint(address(vault), 100e18);
    vm.prank(keeper);
    vault.onBoostReward(address(t), 100e18);
    t.setMode(mode);
  }

  /// @dev Whatever the boost token does on transfer, alice gets her full USDSC principal back
  function _assertWithdrawReleasesPrincipal(ConfigurableBoostToken.Mode mode, bool boostShouldBePaid) internal {
    ConfigurableBoostToken t = _boostWith(mode);
    uint256 before = usdsc.balanceOf(alice);

    vm.prank(alice);
    vault.withdraw(DEPOSIT);

    assertEq(usdsc.balanceOf(alice) - before, DEPOSIT, 'principal not released');
    if (boostShouldBePaid) {
      assertEq(t.balanceOf(alice), 100e18, 'boost not paid');
      assertEq(vault.boostClaimReserve(address(t)), 0);
    } else {
      // failed payout: entitlement restored, still claimable later
      assertEq(t.balanceOf(alice), 0);
      assertEq(vault.getClaimableBoostReward(alice, address(t)), 100e18, 'entitlement lost');
      assertEq(vault.boostClaimReserve(address(t)), 100e18, 'reserve not restored');
    }
  }

  function test_Withdraw_BoostTokenReturnsTrue() public {
    _assertWithdrawReleasesPrincipal(ConfigurableBoostToken.Mode.Normal, true);
  }

  function test_Withdraw_BoostTokenReturnsFalse() public {
    _assertWithdrawReleasesPrincipal(ConfigurableBoostToken.Mode.ReturnsFalse, false);
  }

  function test_Withdraw_BoostTokenReverts() public {
    _assertWithdrawReleasesPrincipal(ConfigurableBoostToken.Mode.Reverts, false);
  }

  /// @dev USDT-style token: the transfer happens, there's just no return value
  function test_Withdraw_BoostTokenReturnsNoData() public {
    _assertWithdrawReleasesPrincipal(ConfigurableBoostToken.Mode.NoReturnData, true);
  }

  function test_Withdraw_BoostTokenReturnsNonBoolWord() public {
    _assertWithdrawReleasesPrincipal(ConfigurableBoostToken.Mode.NonBoolWord, false);
  }

  function test_Withdraw_BoostTokenReturnsLongData() public {
    _assertWithdrawReleasesPrincipal(ConfigurableBoostToken.Mode.LongReturnTrue, true);
  }

  function test_PaidPayoutEmitsClaimed() public {
    ConfigurableBoostToken t = _boostWith(ConfigurableBoostToken.Mode.Normal);
    vm.expectEmit(address(vault));
    emit IEarnVaultEventsAndErrors.BoostRewardClaimed(alice, address(t), 100e18);
    vm.prank(alice);
    vault.withdraw(DEPOSIT);
  }

  function test_FailedPayoutEmitsTransferFailed() public {
    ConfigurableBoostToken t = _boostWith(ConfigurableBoostToken.Mode.NonBoolWord);
    vm.expectEmit(address(vault));
    emit IEarnVaultEventsAndErrors.BoostRewardTransferFailed(alice, address(t), 100e18);
    vm.prank(alice);
    vault.withdraw(DEPOSIT);
  }

  /// @dev claim() with nothing actually paid still reverts NothingToClaim, and changes nothing
  function test_ClaimRevertsNothingToClaimWhenEveryPayoutFails() public {
    ConfigurableBoostToken t = _boostWith(ConfigurableBoostToken.Mode.NonBoolWord);
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.NothingToClaim.selector);
    vault.claim();
    assertEq(vault.getClaimableBoostReward(alice, address(t)), 100e18);
    assertEq(vault.boostClaimReserve(address(t)), 100e18);
  }

  /// @dev No depositors: the boost goes to the treasury, and any failed transfer reverts the call
  function _treasuryBoost(ConfigurableBoostToken.Mode mode) internal returns (ConfigurableBoostToken t) {
    vm.prank(alice);
    vault.withdraw(DEPOSIT);
    assertEq(vault.totalPrincipal(), 0);
    t = new ConfigurableBoostToken();
    t.mint(address(vault), 10e18);
    t.setMode(mode);
  }

  function test_NoDepositors_TreasuryReceivesBoost_NormalAndNoReturnData() public {
    ConfigurableBoostToken.Mode[2] memory paid =
      [ConfigurableBoostToken.Mode.Normal, ConfigurableBoostToken.Mode.NoReturnData];
    for (uint256 i = 0; i < 2; i++) {
      ConfigurableBoostToken t = _treasuryBoost(paid[i]);
      vm.expectEmit(address(vault));
      emit IEarnVaultEventsAndErrors.BoostRewardTransferredToTreasury(address(t), 10e18);
      vm.prank(keeper);
      vault.onBoostReward(address(t), 10e18);
      assertEq(t.balanceOf(treasury), 10e18);
      _deposit(alice, DEPOSIT); // restore for the next round
    }
  }

  function test_NoDepositors_FailedTreasuryTransferReverts() public {
    ConfigurableBoostToken.Mode[3] memory failing = [
      ConfigurableBoostToken.Mode.ReturnsFalse,
      ConfigurableBoostToken.Mode.Reverts,
      ConfigurableBoostToken.Mode.NonBoolWord
    ];
    for (uint256 i = 0; i < 3; i++) {
      ConfigurableBoostToken t = _treasuryBoost(failing[i]);
      vm.prank(keeper);
      vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostTokenBalance.selector);
      vault.onBoostReward(address(t), 10e18);
      assertEq(t.balanceOf(treasury), 0);
      _deposit(alice, DEPOSIT);
    }
  }

  /// @dev An address with no code can't be registered as a boost token at all
  function test_TokenWithoutCodeCannotBeRegistered() public {
    vm.prank(keeper);
    vm.expectRevert();
    vault.onBoostReward(makeAddr('noCode'), 1);
  }

  // ---------------------------------------------------------------------------------------------
  // Boost reserve smaller than what a user is owed (accounting out of balance)
  // ---------------------------------------------------------------------------------------------

  bytes32 constant EARN_VAULT_STORAGE = 0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;

  /// @dev Sets boostClaimReserve[token] directly (field 15 of the EarnVault storage struct)
  function _setBoostReserve(address token, uint256 value) internal {
    bytes32 slot = keccak256(abi.encode(token, bytes32(uint256(EARN_VAULT_STORAGE) + 15)));
    vm.store(address(vault), slot, bytes32(value));
  }

  /// @dev If the boost reserve can't cover a user's entitlement, the payout is skipped (entitlement
  ///      kept, shortfall event emitted) and withdraw() still releases the user's USDSC principal
  function test_BoostReserveShortfall_WithdrawStillReleasesPrincipal() public {
    ConfigurableBoostToken t = _boostWith(ConfigurableBoostToken.Mode.Normal);
    _setBoostReserve(address(t), 40e18); // alice is owed 100e18

    uint256 before = usdsc.balanceOf(alice);
    vm.expectEmit(address(vault));
    emit IEarnVaultEventsAndErrors.BoostRewardReserveShortfall(alice, address(t), 100e18, 40e18);
    vm.prank(alice);
    vault.withdraw(DEPOSIT);

    assertEq(usdsc.balanceOf(alice) - before, DEPOSIT, 'principal not released');
    assertEq(t.balanceOf(alice), 0, 'nothing paid from an under-funded reserve');
    assertEq(vault.getClaimableBoostReward(alice, address(t)), 100e18, 'entitlement kept');
    assertEq(vault.boostClaimReserve(address(t)), 40e18, 'reserve untouched');

    // claim() with nothing paid reverts NothingToClaim, as before
    vm.prank(alice);
    vm.expectRevert(IEarnVaultEventsAndErrors.NothingToClaim.selector);
    vault.claim();
  }

  /// @dev End to end: a removed boost token is distributed again while a new depositor joined in
  ///      between. Whatever the boost accounting says, the earlier holder can still exit with full
  ///      USDSC principal.
  function test_ReaddedBoostToken_EarlierHolderStillExitsWithPrincipal() public {
    MockUSDSC astr = new MockUSDSC();
    astr.mint(address(vault), 1e18); // 1e18 * RAY / 1_000e6 divides exactly: no dust
    vm.prank(keeper);
    vault.onBoostReward(address(astr), 1e18);
    vm.prank(alice);
    vault.claim(); // reserve reaches exactly 0
    vm.prank(owner);
    vault.removeBoostRewardToken(address(astr));

    _deposit(bob, DEPOSIT); // joins while the token is removed
    astr.mint(address(vault), 1e16);
    vm.prank(keeper);
    vault.onBoostReward(address(astr), 1e16); // re-added

    // bob is paid first (his entitlement exceeds the reserve), then alice exits
    vm.prank(bob);
    vault.withdraw(DEPOSIT);
    assertEq(usdsc.balanceOf(bob), DEPOSIT, 'bob principal');
    uint256 before = usdsc.balanceOf(alice);
    vm.prank(alice);
    vault.withdraw(DEPOSIT);
    assertEq(usdsc.balanceOf(alice) - before, DEPOSIT, 'alice principal');
  }

  function test_Twin_BoostReserveShortfall_WithdrawStillReleasesPrincipal() public {
    EarnVault twin = new EarnVault(address(usdsc), owner, redistributor, treasury, pauser, keeper);
    usdsc.mint(bob, DEPOSIT);
    vm.startPrank(bob);
    usdsc.approve(address(twin), DEPOSIT);
    twin.deposit(DEPOSIT);
    vm.stopPrank();
    ConfigurableBoostToken t = new ConfigurableBoostToken();
    t.mint(address(twin), 100e18);
    vm.prank(keeper);
    twin.onBoostReward(address(t), 100e18);
    stdstore.target(address(twin)).sig('boostClaimReserve(address)').with_key(address(t)).checked_write(uint256(40e18));

    vm.prank(bob);
    twin.withdraw(DEPOSIT);
    assertEq(usdsc.balanceOf(bob), DEPOSIT);
    assertEq(twin.getClaimableBoostReward(bob, address(t)), 100e18);
  }

  /// @dev The restored entitlement can be claimed once the token behaves again
  function test_FailedPayoutCanBeClaimedLater() public {
    ConfigurableBoostToken t = _boostWith(ConfigurableBoostToken.Mode.NonBoolWord);
    vm.prank(alice);
    vault.withdraw(DEPOSIT);
    assertEq(t.balanceOf(alice), 0);

    t.setMode(ConfigurableBoostToken.Mode.Normal);
    vm.prank(alice);
    vault.claim();
    assertEq(t.balanceOf(alice), 100e18);
    assertEq(vault.boostClaimReserve(address(t)), 0);
  }

  function test_Twin_WithdrawSurvivesNonBoolBoostToken() public {
    EarnVault twin = new EarnVault(address(usdsc), owner, redistributor, treasury, pauser, keeper);
    usdsc.mint(bob, DEPOSIT);
    vm.startPrank(bob);
    usdsc.approve(address(twin), DEPOSIT);
    twin.deposit(DEPOSIT);
    vm.stopPrank();

    ConfigurableBoostToken t = new ConfigurableBoostToken();
    t.mint(address(twin), 100e18);
    vm.prank(keeper);
    twin.onBoostReward(address(t), 100e18);
    t.setMode(ConfigurableBoostToken.Mode.NonBoolWord);

    vm.prank(bob);
    twin.withdraw(DEPOSIT);
    assertEq(usdsc.balanceOf(bob), DEPOSIT);
    assertEq(twin.getClaimableBoostReward(bob, address(t)), 100e18);
  }

  // ---------------------------------------------------------------------------------------------

  function _deposit(address user, uint256 amount) internal {
    usdsc.mint(user, amount);
    vm.startPrank(user);
    usdsc.approve(address(vault), amount);
    vault.deposit(amount);
    vm.stopPrank();
  }
}
