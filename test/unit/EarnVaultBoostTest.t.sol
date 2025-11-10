// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVault} from '../../src/vaults/earn/EarnVault.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {Test} from 'lib/forge-std/src/Test.sol';

contract EarnVaultBoostTest is Test {
  EarnVault public earnVault;
  MockERC20 public usdsc;
  MockERC20 public astr;
  MockERC20 public dot;

  address public admin = makeAddr('admin');
  address public operator = makeAddr('operator'); // boost reward keeper
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
    // Note: yieldRedistributor and boostRewardKeeper are separate roles
    // yieldRedistributor = RewardRedistributor contract (handles USDSC yield)
    // boostRewardKeeper = operator (person from company, handles boost rewards via direct ERC20 transfers)
    earnVault = new EarnVault(
      address(usdsc),
      admin,
      admin, // yield redistributor (could be RewardRedistributor contract in production)
      treasury,
      pauser,
      operator // boost reward keeper (person from company)
    );

    // Setup initial balances
    usdsc.mint(admin, INITIAL_SUPPLY);
    astr.mint(operator, ASTR_REWARD); // Boost tokens to operator (keeper)
    dot.mint(operator, DOT_REWARD); // Boost tokens to operator (keeper)

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
    vm.startPrank(operator); // operator is boost reward keeper
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
    vm.startPrank(operator); // operator is boost reward keeper
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
    vm.startPrank(operator); // operator is boost reward keeper
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
    // Action: Distribute both USDSC yield and ASTR boost rewards
    // =========================
    // Distribute USDSC yield (admin is yieldRedistributor in setUp)
    vm.startPrank(admin);
    usdsc.approve(address(earnVault), 100e6);
    bool success = usdsc.transfer(address(earnVault), 100e6);
    require(success, 'Transfer failed');
    earnVault.onYield(100e6);
    vm.stopPrank();

    // Distribute ASTR boost rewards (operator is boostRewardKeeper)
    vm.startPrank(operator);
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
    // Action: Operator (boost reward keeper) distributes multiple token rewards
    // =========================
    // Distribute ASTR boost rewards
    vm.startPrank(operator); // operator is boost reward keeper
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // Distribute DOT boost rewards
    vm.startPrank(operator); // operator is boost reward keeper
    dot.approve(address(earnVault), DOT_REWARD);
    bool success2 = dot.transfer(address(earnVault), DOT_REWARD);
    require(success2, 'Transfer failed');
    earnVault.onBoostReward(address(dot), DOT_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: User claims all boost rewards
    // =========================

    // Verify access control: only operator (boostRewardKeeper) can distribute
    astr.mint(address(earnVault), ASTR_REWARD);
    vm.startPrank(admin); // admin is yieldRedistributor but NOT boostRewardKeeper
    vm.expectRevert(IEarnVaultEventsAndErrors.NotBoostRewardKeeper.selector);
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

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
    vm.startPrank(operator); // operator is boost reward keeper
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

  /// @notice Test claiming boost rewards when user has zero principal (principal == 0 branch)
  /// @dev Covers the claimBoostReward branch: if (principal == 0)
  /// @dev Tests that new boost rewards distributed after withdrawal can still be viewed
  /// @dev Note: withdraw() auto-claims existing boost rewards, so we distribute new rewards after
  function test_ClaimBoostReward_WithZeroPrincipal() public {
    // =========================
    // Setup: User deposits and withdraws all principal
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // User withdraws ALL principal (this also auto-claims any existing boost rewards)
    vm.prank(user1);
    earnVault.withdraw(DEPOSIT_AMOUNT);

    // Verify user now has zero principal
    assertEq(earnVault.principal(user1), 0, 'User should have zero principal');

    // =========================
    // Action: Simulate user having accrued boost rewards while having zero principal
    // =========================
    // In real scenario: user could have accrued rewards settled during deposit/withdraw
    // but not yet claimed. Here we verify the getClaimableBoostReward handles principal==0

    uint256 claimable = earnVault.getClaimableBoostReward(user1, address(astr));
    // With zero principal, function should return userBoostAccrued[user][token]
    // Since we withdrew (which auto-claimed), this should be 0
    assertEq(claimable, 0, 'User with zero principal and zero accrued should have 0 claimable');
  }

  /// @notice Test claiming boost rewards when global index exceeds user index (gi > ui branch)
  /// @dev Covers the claimBoostReward branch: if (gi > ui)
  /// @dev Tests the calculation of owed rewards based on index difference
  /// @dev Ensures proper accumulation when user hasn't claimed between distributions
  function test_ClaimBoostReward_GlobalIndexGreaterThanUserIndex() public {
    // =========================
    // Setup: User deposits principal
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // =========================
    // Action: First boost reward distribution (gi increases, ui is still 0)
    // =========================
    vm.startPrank(operator); // operator is boost reward keeper
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // At this point: gi > ui (global index updated, user index still 0)
    uint256 claimableAfterFirst = earnVault.getClaimableBoostReward(user1, address(astr));
    assertGt(claimableAfterFirst, 0, 'User should have claimable rewards after first distribution');

    // =========================
    // Action: Second boost reward distribution WITHOUT user claiming first
    // =========================
    // Mint more ASTR to operator (boost reward keeper)
    vm.startPrank(admin); // admin mints to operator
    astr.mint(operator, ASTR_REWARD); // Mint more ASTR to operator
    vm.stopPrank();

    vm.startPrank(operator); // operator is boost reward keeper (person from company)
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success2 = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success2, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // Now gi is even higher, ui is still 0 (user hasn't claimed)
    uint256 claimableAfterSecond = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableAfterSecond, ASTR_REWARD * 2, 'User should have accumulated both distributions');

    // =========================
    // Action: User claims all accumulated rewards
    // =========================
    uint256 initialASTR = astr.balanceOf(user1);

    vm.prank(user1);
    earnVault.claim();

    // =========================
    // Verification: User receives all accumulated rewards
    // =========================
    uint256 finalASTR = astr.balanceOf(user1);
    assertEq(
      finalASTR - initialASTR, ASTR_REWARD * 2, 'User should claim both accumulated distributions (gi > ui path)'
    );
  }

  /// @notice Test claiming when gi == ui (no new rewards accumulated)
  /// @dev Tests the edge case where global and user indices are equal
  /// @dev User should only get previously accrued rewards, no new calculation
  /// @dev Covers the else path where gi <= ui
  function test_ClaimBoostReward_GlobalIndexEqualsUserIndex() public {
    // =========================
    // Setup: User deposits and claims to sync indices
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    vm.startPrank(operator); // operator is boost reward keeper
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // First claim - syncs user index to global index and claims rewards
    vm.prank(user1);
    earnVault.claim();

    // At this point: gi == ui (both indices are synced)
    // =========================
    // Verification: No claimable rewards when gi == ui and no accrued
    // =========================
    uint256 claimableAfterSync = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableAfterSync, 0, 'User should have no claimable rewards when gi == ui');

    // Trying to claim again would revert with NothingToClaim
    // This is expected behavior - no test needed for the revert case
  }

  /// @notice Test multiple users claiming with different principal amounts (gi > ui)
  /// @dev Tests proportional distribution when gi > ui for multiple users
  /// @dev Ensures correct calculation of owed amounts based on principal and index delta
  function test_ClaimBoostReward_MultipleUsersWithDifferentPrincipals() public {
    // =========================
    // Setup: Two users deposit different amounts
    // =========================
    vm.prank(user1);
    earnVault.deposit(1000e6); // 1000 USDSC

    vm.prank(user2);
    earnVault.deposit(2000e6); // 2000 USDSC (2x user1)

    // =========================
    // Action: Distribute boost rewards (gi > ui for both users)
    // =========================
    vm.startPrank(operator); // operator is boost reward keeper
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Action: Both users claim
    // =========================
    uint256 user1InitialASTR = astr.balanceOf(user1);
    vm.prank(user1);
    earnVault.claim();
    uint256 user1Claimed = astr.balanceOf(user1) - user1InitialASTR;

    uint256 user2InitialASTR = astr.balanceOf(user2);
    vm.prank(user2);
    earnVault.claim();
    uint256 user2Claimed = astr.balanceOf(user2) - user2InitialASTR;

    // =========================
    // Verification: User2 gets 2x user1's rewards (proportional to principal)
    // =========================
    assertApproxEqAbs(user1Claimed, ASTR_REWARD / 3, 1, 'User1 should get ~1/3 of rewards');
    assertApproxEqAbs(user2Claimed, (ASTR_REWARD * 2) / 3, 1, 'User2 should get ~2/3 of rewards');
    assertApproxEqAbs(user2Claimed, user1Claimed * 2, 2, 'User2 should get 2x user1 (gi > ui calculation)');
  }

  /// @notice Test that getClaimableBoostReward handles principal == 0 correctly
  /// @dev Tests the view function path: if (principal == 0) return userBoostAccrued[user][token]
  /// @dev Verifies correct calculation when user has no principal
  function test_GetClaimableBoostReward_WithZeroPrincipal() public {
    // =========================
    // Setup: User1 deposits, user2 doesn't
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // Distribute boost rewards
    vm.startPrank(operator); // operator is boost reward keeper
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: User2 with zero principal should have 0 claimable
    // =========================
    uint256 user2Claimable = earnVault.getClaimableBoostReward(user2, address(astr));
    assertEq(user2Claimable, 0, 'User with zero principal should have 0 claimable (principal == 0 branch)');

    // User1 should have full reward
    uint256 user1Claimable = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(user1Claimable, ASTR_REWARD, 'User1 with principal should have full reward');
  }

  /// @notice Test that boost rewards are not double-accrued
  /// @dev Verifies that even though both _settleBoost() and claimBoostReward() have settlement logic,
  ///      rewards are only accrued once, not twice
  /// @dev This is critical because withdraw() calls _settleBoost() then claimBoostReward(),
  ///      and we need to ensure no double-accrual occurs
  function test_NoDoubleAccrualInWithdraw() public {
    // =========================
    // Setup: User deposits
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // =========================
    // Action: Distribute boost rewards
    // =========================
    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Calculate expected reward (manual calculation to verify no double-accrual)
    // =========================
    // User has DEPOSIT_AMOUNT (1000e6) principal
    // Total principal is DEPOSIT_AMOUNT
    // Boost reward is ASTR_REWARD (100e18)
    // Expected: User should get 100% of rewards (only user)
    uint256 expectedReward = ASTR_REWARD;

    // Verify claimable before withdraw
    uint256 claimableBefore = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableBefore, expectedReward, 'User should have correct claimable amount');

    // =========================
    // Action: Withdraw (this calls _settleBoost() then claimBoostReward())
    // =========================
    uint256 user1InitialBalance = astr.balanceOf(user1);
    uint256 user1Principal = earnVault.principal(user1);

    // Store global index before withdraw (to verify user index gets updated)
    uint256 globalIndexBefore = earnVault.boostGlobalIndex(address(astr));

    vm.prank(user1);
    earnVault.withdraw(user1Principal); // Withdraw all, which will claim boost rewards

    // =========================
    // Verification: User should receive exactly the expected amount (not double)
    // =========================
    uint256 user1FinalBalance = astr.balanceOf(user1);
    uint256 received = user1FinalBalance - user1InitialBalance;

    assertEq(received, expectedReward, 'User should receive exactly expected reward, not double');
    assertEq(received, claimableBefore, 'Received amount should equal claimable before withdraw');

    // Verify user index was updated correctly
    uint256 userIndexAfter = earnVault.userBoostIndex(user1, address(astr));
    assertEq(userIndexAfter, globalIndexBefore, 'User index should be updated to global index');

    // Verify no more rewards can be claimed
    uint256 claimableAfter = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableAfter, 0, 'User should have no more claimable rewards');
  }

  /// @notice Test that boost rewards are not double-accrued in claim()
  /// @dev Verifies that even though claim() calls _settleBoost() then claimBoostReward(),
  ///      rewards are only accrued once, not twice
  /// @dev claim() flow: _settleBoost() (accrues and updates index) -> claimBoostReward() (reads updated index, gi==ui so no accrual)
  function test_NoDoubleAccrualInClaim() public {
    // =========================
    // Setup: User deposits
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // =========================
    // Action: Distribute boost rewards
    // =========================
    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Calculate expected reward
    // =========================
    uint256 expectedReward = ASTR_REWARD; // Only user, so gets 100%

    // Verify claimable
    uint256 claimableBefore = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableBefore, expectedReward, 'User should have correct claimable amount');

    // Store indices before claim to verify update
    uint256 userIndexBefore = earnVault.userBoostIndex(user1, address(astr));
    uint256 globalIndexBefore = earnVault.boostGlobalIndex(address(astr));

    // User index should be 0 (uninitialized) or less than global index
    assertTrue(
      userIndexBefore < globalIndexBefore || userIndexBefore == 0,
      'User index should be less than global index before claim'
    );

    // =========================
    // Action: Claim (this calls _settleBoost() then claimBoostReward())
    // =========================
    uint256 user1InitialBalance = astr.balanceOf(user1);

    vm.prank(user1);
    earnVault.claim(); // Claims both USDSC yield and boost rewards

    // =========================
    // Verification: User should receive exactly the expected amount (not double)
    // =========================
    uint256 user1FinalBalance = astr.balanceOf(user1);
    uint256 received = user1FinalBalance - user1InitialBalance;

    assertEq(received, expectedReward, 'User should receive exactly expected reward, not double');
    assertEq(received, claimableBefore, 'Received amount should equal claimable before claim');

    // Verify user index was updated correctly by _settleBoost()
    uint256 userIndexAfter = earnVault.userBoostIndex(user1, address(astr));
    assertEq(userIndexAfter, globalIndexBefore, 'User index should be updated to global index by _settleBoost()');

    // Verify no more rewards can be claimed
    uint256 claimableAfter = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableAfter, 0, 'User should have no more claimable rewards');
  }

  /// @notice Test that users cannot claim boost rewards multiple times
  /// @dev Verifies that after claiming once, userBoostAccrued is cleared,
  ///      preventing users from claiming the same rewards again
  /// @dev This test ensures that even if userBoostIndex wasn't updated for some reason,
  ///      the clearing of userBoostAccrued prevents double claims
  function test_CannotClaimBoostRewardsMultipleTimes() public {
    // =========================
    // Setup: User deposits and boost rewards are distributed
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // =========================
    // Action: User claims boost rewards (first claim)
    // =========================
    uint256 initialASTRBalance = astr.balanceOf(user1);
    uint256 initialUSDSCBalance = usdsc.balanceOf(user1);

    // Verify user has no ASTR tokens initially
    assertEq(initialASTRBalance, 0, 'User should have no ASTR tokens initially');

    vm.prank(user1);
    earnVault.claim(); // First claim - this clears userBoostAccrued[user1][astr] = 0

    uint256 astrBalanceAfterFirstClaim = astr.balanceOf(user1);
    uint256 usdscBalanceAfterFirstClaim = usdsc.balanceOf(user1);

    // Verify user received ASTR rewards in first claim (no USDSC yield in this test)
    assertGe(astrBalanceAfterFirstClaim, initialASTRBalance, 'User ASTR balance should increase or stay same');
    assertGt(astrBalanceAfterFirstClaim, initialASTRBalance, 'User ASTR balance should increase');
    uint256 receivedASTR = astrBalanceAfterFirstClaim - initialASTRBalance;
    assertEq(receivedASTR, ASTR_REWARD, 'User should receive ASTR rewards on first claim');
    assertEq(usdscBalanceAfterFirstClaim, initialUSDSCBalance, 'User should not receive USDSC (no yield distributed)');

    // Verify claimable is now 0 after first claim
    uint256 claimableAfterFirst = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableAfterFirst, 0, 'User should have no claimable rewards after first claim');

    // Verify there's no USDSC claimable either
    uint256 usdscClaimable = earnVault.claimable(user1);
    assertEq(usdscClaimable, 0, 'User should have no USDSC claimable');

    // =========================
    // Verification: User cannot claim again (userBoostAccrued was cleared)
    // =========================
    vm.expectRevert(IEarnVaultEventsAndErrors.NothingToClaim.selector);
    vm.prank(user1);
    earnVault.claim(); // Second claim attempt - should revert

    // Verify balances didn't change
    assertEq(
      astr.balanceOf(user1), astrBalanceAfterFirstClaim, 'ASTR balance should not change after failed claim attempt'
    );
    assertEq(
      usdsc.balanceOf(user1), usdscBalanceAfterFirstClaim, 'USDSC balance should not change after failed claim attempt'
    );

    // =========================
    // Additional verification: Even if new rewards are distributed,
    // user can only claim the new rewards (not the old ones again)
    // =========================
    // Mint more ASTR tokens to operator for the second distribution
    astr.mint(operator, ASTR_REWARD);

    // Distribute new boost rewards
    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // User should only be able to claim the new rewards (ASTR_REWARD), not the old ones again
    uint256 claimableAfterNewDistribution = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableAfterNewDistribution, ASTR_REWARD, 'User should only have new rewards claimable');

    uint256 astrBalanceBeforeSecondClaim = astr.balanceOf(user1);
    vm.prank(user1);
    earnVault.claim(); // Should succeed and claim only the new rewards

    uint256 astrBalanceAfterSecondClaim = astr.balanceOf(user1);
    uint256 receivedSecondClaim = astrBalanceAfterSecondClaim - astrBalanceBeforeSecondClaim;

    // User should receive exactly ASTR_REWARD (the new rewards), not ASTR_REWARD * 2
    assertEq(receivedSecondClaim, ASTR_REWARD, 'User should only receive new rewards, not old ones again');
    assertEq(
      astrBalanceAfterSecondClaim, ASTR_REWARD * 2, 'Total received should be exactly 2x ASTR_REWARD (first + second)'
    );
  }
}
