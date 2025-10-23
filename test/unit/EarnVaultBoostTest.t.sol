// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EarnVault} from '../../src/vaults/earn/EarnVault.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {Test} from 'lib/forge-std/src/Test.sol';

contract EarnVaultBoostTest is Test {
  EarnVault public earnVault;
  MockERC20 public usdsc;
  MockERC20 public astr;
  MockERC20 public dot;

  address public admin = makeAddr('admin');
  address public user1 = makeAddr('user1');
  address public user2 = makeAddr('user2');
  address public treasury = makeAddr('treasury');
  address public pauser = makeAddr('pauser');

  uint256 public constant INITIAL_SUPPLY = 1_000_000e6;
  uint256 public constant DEPOSIT_AMOUNT = 1000e6;
  uint256 public constant ASTR_REWARD = 100e18;
  uint256 public constant DOT_REWARD = 50e18;

  function setUp() public {
    // Deploy tokens
    usdsc = new MockERC20('USDSC Token', 'USDSC', 6);
    astr = new MockERC20('ASTR Token', 'ASTR', 18);
    dot = new MockERC20('DOT Token', 'DOT', 18);

    // Deploy EarnVault
    earnVault = new EarnVault(
      address(usdsc),
      admin,
      admin, // yield redistributor
      treasury,
      pauser
    );

    // Setup initial balances
    usdsc.mint(admin, INITIAL_SUPPLY);
    astr.mint(admin, ASTR_REWARD);
    dot.mint(admin, DOT_REWARD);

    // Setup users
    usdsc.mint(user1, DEPOSIT_AMOUNT * 3);
    usdsc.mint(user2, DEPOSIT_AMOUNT * 3);

    // Approve vault
    vm.startPrank(user1);
    usdsc.approve(address(earnVault), DEPOSIT_AMOUNT * 3);
    vm.stopPrank();

    vm.startPrank(user2);
    usdsc.approve(address(earnVault), DEPOSIT_AMOUNT * 3);
    vm.stopPrank();
  }

  /// @notice Test basic boost reward distribution between multiple users
  /// @dev Verifies that boost rewards are distributed proportionally based on principal
  /// @dev Tests the core boost reward distribution mechanism
  /// @dev Ensures equal users get equal boost rewards
  function test_BoostRewardDistribution() public {
    // =========================
    // Setup: Both users deposit equal amounts
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    vm.prank(user2);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // =========================
    // Action: Admin distributes ASTR boost rewards
    // =========================
    vm.startPrank(admin);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: Both users should have equal claimable ASTR rewards
    // =========================
    uint256 user1Claimable = earnVault.getClaimableBoostReward(user1, address(astr));
    uint256 user2Claimable = earnVault.getClaimableBoostReward(user2, address(astr));

    // Since both users have equal principal, they should get equal boost rewards
    assertEq(user1Claimable, ASTR_REWARD / 2, 'User1 should get half of ASTR rewards');
    assertEq(user2Claimable, ASTR_REWARD / 2, 'User2 should get half of ASTR rewards');

    // Total distributed should equal the original reward amount
    assertEq(user1Claimable + user2Claimable, ASTR_REWARD, 'Total rewards should equal original amount');
  }

  /// @notice Test proportional boost reward distribution based on principal amounts
  /// @dev Verifies that boost rewards are distributed proportionally based on user principal
  /// @dev Tests the mathematical correctness of proportional distribution
  /// @dev Ensures users with more principal get proportionally more boost rewards
  function test_ProportionalBoostDistribution() public {
    // =========================
    // Setup: Users deposit different amounts
    // =========================
    // User1 deposits 1000 USDSC (1/3 of total)
    vm.prank(user1);
    earnVault.deposit(1000e6);

    // User2 deposits 2000 USDSC (2/3 of total)
    vm.prank(user2);
    earnVault.deposit(2000e6);

    // =========================
    // Action: Admin distributes ASTR boost rewards
    // =========================
    vm.startPrank(admin);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: Proportional distribution based on principal
    // =========================
    uint256 user1Claimable = earnVault.getClaimableBoostReward(user1, address(astr));
    uint256 user2Claimable = earnVault.getClaimableBoostReward(user2, address(astr));

    // User1 has 1/3 of total principal, should get ~1/3 of rewards
    assertApproxEqAbs(user1Claimable, ASTR_REWARD / 3, 1, 'User1 should get ~1/3 of ASTR rewards');

    // User2 has 2/3 of total principal, should get ~2/3 of rewards
    assertApproxEqAbs(user2Claimable, (ASTR_REWARD * 2) / 3, 1, 'User2 should get ~2/3 of ASTR rewards');

    // Total should equal original reward amount (allowing for rounding)
    assertApproxEqAbs(user1Claimable + user2Claimable, ASTR_REWARD, 1, 'Total rewards should equal original amount');
  }

  /// @notice Test user claiming boost rewards through the unified claim() function
  /// @dev Verifies that users can successfully claim their boost rewards
  /// @dev Tests the claim() function's ability to claim boost rewards
  /// @dev Ensures proper balance updates after claiming
  function test_UserClaimBoostRewards() public {
    // =========================
    // Setup: User deposits principal
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // =========================
    // Action: Admin distributes ASTR boost rewards
    // =========================
    vm.startPrank(admin);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Action: User claims ASTR rewards via unified claim()
    // =========================
    uint256 initialBalance = astr.balanceOf(user1);

    vm.prank(user1);
    earnVault.claim();

    // =========================
    // Verification: User should receive the full ASTR reward
    // =========================
    uint256 finalBalance = astr.balanceOf(user1);
    assertEq(finalBalance - initialBalance, ASTR_REWARD, 'User should receive full ASTR reward');
  }

  /// @notice Test that claim() automatically claims both USDSC yield and boost rewards
  /// @dev Verifies the unified claim() function works for both USDSC and boost rewards
  /// @dev Tests the automatic claiming of all reward types in a single transaction
  /// @dev Ensures users get both USDSC yield and boost rewards when claiming
  function test_ClaimAutomaticallyClaimsAllRewards() public {
    // =========================
    // Setup: User deposits principal
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // =========================
    // Action: Admin distributes both USDSC yield and ASTR boost rewards
    // =========================
    vm.startPrank(admin);

    // Distribute USDSC yield
    usdsc.approve(address(earnVault), 100e6);
    bool success = usdsc.transfer(address(earnVault), 100e6);
    require(success, 'Transfer failed');
    earnVault.onYield(100e6);

    // Distribute ASTR boost rewards
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success2 = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success2, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);

    vm.stopPrank();

    // =========================
    // Action: User claims all rewards via unified claim()
    // =========================
    uint256 initialUSDSC = usdsc.balanceOf(user1);
    uint256 initialASTR = astr.balanceOf(user1);

    vm.prank(user1);
    earnVault.claim();

    // =========================
    // Verification: User should receive both USDSC yield and ASTR boost rewards
    // =========================
    uint256 finalUSDSC = usdsc.balanceOf(user1);
    uint256 finalASTR = astr.balanceOf(user1);

    // User should have received both types of rewards
    assertGt(finalUSDSC, initialUSDSC, 'User should receive USDSC yield');
    assertGt(finalASTR, initialASTR, 'User should receive ASTR boost rewards');
  }

  /// @notice Test multiple token boost rewards distribution and claiming
  /// @dev Verifies that users can receive boost rewards from multiple different tokens
  /// @dev Tests the unified claim() function that automatically claims all boost rewards
  /// @dev Ensures proper tracking of multiple active boost tokens
  function test_MultipleTokenBoostRewards() public {
    // =========================
    // Setup: User deposits principal
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // =========================
    // Action: Admin distributes multiple token rewards
    // =========================
    vm.startPrank(admin);

    // Distribute ASTR boost rewards
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);

    // Distribute DOT boost rewards
    dot.approve(address(earnVault), DOT_REWARD);
    bool success2 = dot.transfer(address(earnVault), DOT_REWARD);
    require(success2, 'Transfer failed');
    earnVault.onBoostReward(address(dot), DOT_REWARD);

    vm.stopPrank();

    // =========================
    // Verification: User claims all boost rewards
    // =========================
    // Record initial balances
    uint256 initialASTR = astr.balanceOf(user1);
    uint256 initialDOT = dot.balanceOf(user1);

    // User claims all boost rewards via unified claim() function
    // This should automatically claim both ASTR and DOT rewards
    vm.prank(user1);
    earnVault.claim();

    // Check final balances
    uint256 finalASTR = astr.balanceOf(user1);
    uint256 finalDOT = dot.balanceOf(user1);

    // Verify user received the full ASTR reward amount
    assertEq(finalASTR - initialASTR, ASTR_REWARD, 'User should receive full ASTR reward');

    // Verify user received the full DOT reward amount
    assertEq(finalDOT - initialDOT, DOT_REWARD, 'User should receive full DOT reward');
  }

  /// @notice Test that boost rewards are sent to treasury when no users have deposited
  /// @dev Verifies the treasury fallback mechanism for boost rewards
  /// @dev Tests the behavior when totalPrincipal is zero
  /// @dev Ensures boost rewards don't get stuck when no users are present
  function test_NoDepositsBoostRewardToTreasury() public {
    // =========================
    // Setup: No users have deposited (totalPrincipal = 0)
    // =========================
    uint256 initialTreasuryBalance = astr.balanceOf(treasury);

    // =========================
    // Action: Admin distributes boost rewards when no deposits exist
    // =========================
    vm.startPrank(admin);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: Treasury should receive the boost rewards
    // =========================
    uint256 finalTreasuryBalance = astr.balanceOf(treasury);
    assertEq(
      finalTreasuryBalance - initialTreasuryBalance,
      ASTR_REWARD,
      'Treasury should receive boost rewards when no deposits exist'
    );
  }
}
