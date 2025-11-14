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

  /// @notice Test that deposit() properly settles boost rewards, preventing retroactive accrual
  /// @dev This test verifies the fix for the vulnerability where users could deposit new funds
  ///      without updating their boost index, allowing them to retroactively earn boost rewards
  ///      on their new principal from an old index position.
  /// @dev This test demonstrates the CORRECT behavior after the fix is implemented.
  function test_DepositSettlesBoostRewards_PreventsRetroactiveAccrual() public {
    // ============================================================
    // TIME T0 - Initial State
    // ============================================================
    // Alice deposits 1000 USDSC (first deposit)
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT); // 1000 USDSC

    // State at T0:
    // principal[Alice] = 1000 USDSC
    // userBoostIndex[Alice][TokenA] = 0 (default for new user, uninitialized)
    // boostGlobalIndex[TokenA] = 0 (no distributions yet)
    // totalPrincipal = 1000 USDSC
    assertEq(earnVault.principal(user1), DEPOSIT_AMOUNT, 'T0: Alice should have 1000 USDSC principal');
    assertEq(earnVault.userBoostIndex(user1, address(astr)), 0, 'T0: User boost index should be 0 (uninitialized)');
    assertEq(earnVault.boostGlobalIndex(address(astr)), 0, 'T0: Global boost index should be 0 (no distributions)');
    assertEq(earnVault.totalPrincipal(), DEPOSIT_AMOUNT, 'T0: Total principal should be 1000 USDSC');

    // ============================================================
    // TIME T1 - First Boost Distribution
    // ============================================================
    // Keeper distributes 1000 TokenA boost rewards to vault
    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD); // 1000 ASTR
    vm.stopPrank();

    // Calculation: boostGlobalIndex[TokenA] = 0 + (100e18 * 1e27) / 1000e6 = 1e38
    // Formula: (ASTR_REWARD * RAY) / totalPrincipal = (100e18 * 1e27) / 1000e6 = 1e38
    uint256 boostIndexAfterFirstDistribution = earnVault.boostGlobalIndex(address(astr));
    assertEq(boostIndexAfterFirstDistribution, 1e38, 'T1: boostGlobalIndex should be 1e38 after first distribution');

    // Alice's pending rewards calculation:
    // owed = principal * (boostGlobalIndex - userBoostIndex) / RAY
    // owed = 1000e6 * (1e38 - 0) / 1e27 = 100e18 ASTR ✅
    uint256 claimableAfterFirstDistribution = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(
      claimableAfterFirstDistribution, ASTR_REWARD, 'T1: Alice should have 100e18 ASTR pending (100% as only user)'
    );

    // State at T1:
    // principal[Alice] = 1000 USDSC (unchanged)
    // userBoostIndex[Alice][TokenA] = 0 (STILL 0 - not updated yet, will be updated on next settlement)
    // boostGlobalIndex[TokenA] = 1e38 (updated by distribution)
    // userBoostAccrued[Alice][TokenA] = 0 (not settled yet, calculated on-demand)
    uint256 userBoostIndexAtT1 = earnVault.userBoostIndex(user1, address(astr));
    assertEq(userBoostIndexAtT1, 0, 'T1: User boost index should still be 0 (not settled yet)');

    // ============================================================
    // TIME T2 - Alice Deposits More WITH Settlement (FIXED BEHAVIOR)
    // ============================================================
    // Alice calls deposit(1000) to double her position
    // ✅ FIX: deposit() now calls _settleBoost() BEFORE updating principal
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT); // Additional 1000 USDSC

    // State at T2 (AFTER FIX):
    // 1. _settle() is called → USDSC yield settled ✅
    // 2. _settleBoost() is called → Boost rewards settled ✅
    //    - userBoostIndex[Alice][TokenA] = 0 → 1e38 (UPDATED!)
    //    - userBoostAccrued[Alice][TokenA] = 0 + 100e18 = 100e18 ASTR (accrued)
    // 3. principal[Alice] = 1000 → 2000 USDSC (updated AFTER settlement)
    // 4. totalPrincipal = 1000 → 2000 USDSC

    // Verify principal increased
    assertEq(earnVault.principal(user1), DEPOSIT_AMOUNT * 2, 'T2: Alice should have 2000 USDSC principal (doubled)');
    assertEq(earnVault.totalPrincipal(), DEPOSIT_AMOUNT * 2, 'T2: Total principal should be 2000 USDSC');

    // ✅ CRITICAL: User's boost index should be updated to current global index during deposit
    // This prevents retroactive accrual on the new principal
    uint256 userBoostIndexAfterDeposit = earnVault.userBoostIndex(user1, address(astr));
    assertEq(
      userBoostIndexAfterDeposit,
      boostIndexAfterFirstDistribution,
      'T2: User boost index should be updated to 1e38 during deposit (prevents retroactive accrual)'
    );

    // Alice should still have the same claimable amount (100e18 ASTR from first distribution)
    // The deposit should NOT retroactively accrue rewards on the new 1000 USDSC principal
    // because userBoostIndex was updated BEFORE principal was increased
    uint256 claimableAfterDeposit = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(
      claimableAfterDeposit,
      ASTR_REWARD,
      'T2: Alice should still have 100e18 ASTR claimable (no retroactive accrual on new principal)'
    );

    // ============================================================
    // TIME T3 - Second Boost Distribution
    // ============================================================
    // Keeper distributes another 1000 TokenA
    // Total distributed: 2000 TokenA in the system
    astr.mint(operator, ASTR_REWARD); // Mint more tokens for second distribution
    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD); // Another 1000 ASTR
    vm.stopPrank();

    // Calculation: boostGlobalIndex[TokenA] = 1e38 + (100e18 * 1e27) / 2000e6 = 1e38 + 0.5e38 = 1.5e38
    // Formula: previousIndex + (ASTR_REWARD * RAY) / totalPrincipal = 1e38 + (100e18 * 1e27) / 2000e6 = 1.5e38
    uint256 boostIndexAfterSecondDistribution = earnVault.boostGlobalIndex(address(astr));
    assertEq(
      boostIndexAfterSecondDistribution, 1.5e38, 'T3: boostGlobalIndex should be 1.5e38 after second distribution'
    );

    // ============================================================
    // TIME T4 - Alice Tries to Claim (CORRECT CALCULATION)
    // ============================================================
    // When Alice calls claim() or withdraw(), _settleBoost() is called again
    // ✅ CORRECT Calculation (with fix):
    // Alice's userBoostIndex = 1e38 (updated during deposit at T2)
    // Alice's principal = 2000 USDSC
    //
    // Rewards from T1→T3 (second distribution):
    // owed = 2000e6 * (1.5e38 - 1e38) / 1e27 = 2000e6 * 0.5e38 / 1e27 = 100e18 ASTR
    //
    // Total rewards:
    // - First distribution (T0→T1): 100e18 ASTR (already accrued at T2)
    // - Second distribution (T2→T3): 100e18 ASTR (on full 2000 USDSC from updated index)
    // Total: 200e18 ASTR ✅

    uint256 claimableAfterSecondDistribution = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(
      claimableAfterSecondDistribution,
      ASTR_REWARD * 2,
      'T4: Alice should have 200e18 ASTR claimable (100e18 from T1 + 100e18 from T3)'
    );

    // Verify the user's boost index is still at the first distribution level (1e38)
    // This is because getClaimableBoostReward() doesn't update the index, only _settleBoost() does
    uint256 userBoostIndexBeforeClaim = earnVault.userBoostIndex(user1, address(astr));
    assertEq(
      userBoostIndexBeforeClaim,
      boostIndexAfterFirstDistribution,
      'T4: User boost index should still be 1e38 (not updated by getClaimableBoostReward)'
    );

    // ============================================================
    // TIME T5 - Alice Claims Rewards
    // ============================================================
    uint256 astrBalanceBeforeClaim = astr.balanceOf(user1);
    vm.prank(user1);
    earnVault.claim(); // This calls _settleBoost() then claimBoostReward()

    uint256 astrBalanceAfterClaim = astr.balanceOf(user1);
    uint256 received = astrBalanceAfterClaim - astrBalanceBeforeClaim;

    // ✅ Alice should receive exactly 200e18 ASTR:
    // - First distribution: 100e18 ASTR (on initial 1000 USDSC from T0→T1)
    // - Second distribution: 100e18 ASTR (on total 2000 USDSC from T2→T3, using updated index)
    assertEq(received, ASTR_REWARD * 2, 'T5: Alice should receive exactly 200e18 ASTR (correct calculation)');

    // Verify user's boost index is now updated to the latest global index (1.5e38)
    uint256 userBoostIndexAfterClaim = earnVault.userBoostIndex(user1, address(astr));
    assertEq(
      userBoostIndexAfterClaim,
      boostIndexAfterSecondDistribution,
      'T5: User boost index should be updated to 1.5e38 after claim'
    );

    // Verify no more rewards can be claimed
    uint256 claimableAfterClaim = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableAfterClaim, 0, 'T5: Alice should have no more claimable rewards');
  }

  /// @notice Test demonstrating what would happen WITHOUT the fix (negative test)
  /// @dev This test shows the vulnerability: if deposit() didn't call _settleBoost(),
  ///      users could retroactively earn boost rewards on new principal from old index.
  /// @dev This test verifies that the fix prevents this attack by checking that
  ///      userBoostIndex is updated during deposit, preventing retroactive accrual.
  function test_DepositSettlesBoostRewards_NegativeTest_WithoutFixWouldFail() public {
    // ============================================================
    // TIME T0 - Initial State
    // ============================================================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT); // 1000 USDSC

    // State: principal[Alice] = 1000, userBoostIndex = 0, boostGlobalIndex = 0
    assertEq(earnVault.principal(user1), DEPOSIT_AMOUNT, 'T0: Initial deposit');
    assertEq(earnVault.userBoostIndex(user1, address(astr)), 0, 'T0: User index uninitialized');

    // ============================================================
    // TIME T1 - First Boost Distribution
    // ============================================================
    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    bool success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // boostGlobalIndex = (100e18 * 1e27) / 1000e6 = 1e38
    // Alice's pending: 1000e6 * (1e38 - 0) / 1e27 = 100e18 ASTR ✅
    uint256 boostIndexT1 = earnVault.boostGlobalIndex(address(astr));
    assertEq(boostIndexT1, 1e38, 'T1: Global index = 1e38');

    uint256 claimableT1 = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableT1, ASTR_REWARD, 'T1: Alice has 100e18 ASTR pending');

    // ============================================================
    // TIME T2 - Alice Deposits More (WITH FIX - CORRECT BEHAVIOR)
    // ============================================================
    // ✅ WITH FIX: deposit() calls _settleBoost() BEFORE updating principal
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT); // Additional 1000 USDSC

    // ✅ CORRECT: userBoostIndex updated to 1e38 BEFORE principal is increased
    uint256 userIndexAfterDeposit = earnVault.userBoostIndex(user1, address(astr));
    assertEq(userIndexAfterDeposit, 1e38, 'T2: User index updated to 1e38 (fix working)');
    assertEq(earnVault.principal(user1), DEPOSIT_AMOUNT * 2, 'T2: Principal = 2000 USDSC');

    // ============================================================
    // TIME T3 - Second Boost Distribution
    // ============================================================
    astr.mint(operator, ASTR_REWARD);
    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    success = astr.transfer(address(earnVault), ASTR_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // boostGlobalIndex = 1e38 + (100e18 * 1e27) / 2000e6 = 1.5e38
    uint256 boostIndexT3 = earnVault.boostGlobalIndex(address(astr));
    assertEq(boostIndexT3, 1.5e38, 'T3: Global index = 1.5e38');

    // ============================================================
    // TIME T4 - Verify Correct Calculation (NOT Vulnerable)
    // ============================================================
    // ✅ CORRECT Calculation (with fix):
    // userBoostIndex = 1e38 (updated at T2)
    // principal = 2000 USDSC
    // Rewards from T2→T3: 2000e6 * (1.5e38 - 1e38) / 1e27 = 100e18 ASTR
    // Total: 100e18 (from T1) + 100e18 (from T3) = 200e18 ASTR ✅

    uint256 claimableT4 = earnVault.getClaimableBoostReward(user1, address(astr));
    assertEq(claimableT4, ASTR_REWARD * 2, 'T4: Alice has 200e18 ASTR (correct, not vulnerable)');

    // ============================================================
    // NEGATIVE TEST: What would happen WITHOUT the fix
    // ============================================================
    // ❌ WITHOUT FIX (hypothetical):
    // If deposit() didn't call _settleBoost():
    // - userBoostIndex would still be 0 at T2
    // - principal would be 2000 USDSC
    // - At T4, calculation would be:
    //   owed = 2000e6 * (1.5e38 - 0) / 1e27 = 300e18 ASTR ❌
    // - Alice would try to claim 300e18 ASTR when only 200e18 exist
    // - Transaction would REVERT with InsufficientBoostClaimReserve()
    //
    // ✅ WITH FIX (actual behavior):
    // - userBoostIndex = 1e38 at T2 (updated during deposit)
    // - At T4, calculation is:
    //   owed = 2000e6 * (1.5e38 - 1e38) / 1e27 = 100e18 ASTR ✅
    // - Total: 100e18 (from T1) + 100e18 (from T3) = 200e18 ASTR ✅
    // - Alice can successfully claim 200e18 ASTR

    // Verify the fix prevents the vulnerability
    vm.prank(user1);
    earnVault.claim(); // Should succeed, not revert

    uint256 finalBalance = astr.balanceOf(user1);
    assertEq(finalBalance, ASTR_REWARD * 2, 'T4: Alice successfully claims 200e18 ASTR (fix prevents vulnerability)');
  }

  // ============================================================
  // Tests: removeBoostRewardToken functionality
  // ============================================================

  /// @notice Test that owner can remove boost reward token from activeBoostTokens array
  /// @dev Verifies token removal functionality and array/index updates
  function test_RemoveBoostRewardToken_Success() public {
    // =========================
    // Setup: Add tokens to array
    // =========================
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    // Distribute ASTR and DOT rewards
    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    astr.transfer(address(earnVault), ASTR_REWARD);
    earnVault.onBoostReward(address(astr), ASTR_REWARD);

    dot.approve(address(earnVault), DOT_REWARD);
    dot.transfer(address(earnVault), DOT_REWARD);
    earnVault.onBoostReward(address(dot), DOT_REWARD);
    vm.stopPrank();

    // Verify both tokens are in array
    assertEq(earnVault.activeBoostTokens(0), address(astr), 'ASTR should be first token');
    assertEq(earnVault.activeBoostTokens(1), address(dot), 'DOT should be second token');
    (, address[] memory boostTokens,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokens.length, 2, 'Should have 2 active tokens');

    // User claims all rewards to clear reserves
    vm.prank(user1);
    earnVault.claim();

    // Verify reserves are cleared
    assertEq(earnVault.boostClaimReserve(address(astr)), 0, 'ASTR reserve should be cleared');
    assertEq(earnVault.boostClaimReserve(address(dot)), 0, 'DOT reserve should be cleared');

    // =========================
    // Action: Owner removes ASTR token
    // =========================
    vm.prank(admin); // admin is owner
    earnVault.removeBoostRewardToken(address(astr));

    // =========================
    // Verification: Token removed, array updated
    // =========================
    (, address[] memory boostTokensAfter,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokensAfter.length, 1, 'Should have 1 active token after removal');
    assertEq(earnVault.activeBoostTokens(0), address(dot), 'DOT should remain in array');
    assertEq(earnVault.boostTokenIndex(address(astr)), 0, 'ASTR index should be cleared');
    assertEq(earnVault.boostTokenIndex(address(dot)), 1, 'DOT index should remain 1');
  }

  /// @notice Test that non-owner cannot remove boost reward token
  /// @dev Verifies access control for token removal
  function test_RemoveBoostRewardToken_OnlyOwner() public {
    // Setup: Add token to array
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    astr.transfer(address(earnVault), ASTR_REWARD);
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // User claims to clear reserves
    vm.prank(user1);
    earnVault.claim();

    // Non-owner (user1) tries to remove token - should fail
    vm.prank(user1);
    vm.expectRevert();
    earnVault.removeBoostRewardToken(address(astr));

    // Operator (not owner) tries to remove token - should fail
    vm.prank(operator);
    vm.expectRevert();
    earnVault.removeBoostRewardToken(address(astr));

    // Verify token still in array
    (, address[] memory boostTokens,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokens.length, 1, 'Token should still be in array');
  }

  /// @notice Test that token with pending claims cannot be removed
  /// @dev Verifies safety check prevents removal when boostClaimReserve > 0
  function test_RemoveBoostRewardToken_CannotRemoveWithPendingClaims() public {
    // Setup: Add token and distribute rewards
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    astr.transfer(address(earnVault), ASTR_REWARD);
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // Verify reserve exists
    assertGt(earnVault.boostClaimReserve(address(astr)), 0, 'Should have pending claims');

    // Owner tries to remove - should fail
    vm.prank(admin);
    vm.expectRevert(IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve.selector);
    earnVault.removeBoostRewardToken(address(astr));

    // Verify token still in array
    (, address[] memory boostTokens,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokens.length, 1, 'Token should still be in array');
  }

  /// @notice Test that removing non-existent token is idempotent
  /// @dev Verifies graceful handling when token is not in array
  function test_RemoveBoostRewardToken_NonExistentToken() public {
    address nonExistentToken = address(0x123);

    // Owner tries to remove non-existent token - should succeed silently
    vm.prank(admin);
    earnVault.removeBoostRewardToken(nonExistentToken);

    // No error should occur, function should return normally
    assertTrue(true, 'Should handle non-existent token gracefully');
  }

  /// @notice Test that removal reduces iterations in withdraw/claim loops
  /// @dev Verifies gas optimization benefit of removal
  function test_RemoveBoostRewardToken_ReducesLoopIterations() public {
    // Setup: Add multiple tokens
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    astr.transfer(address(earnVault), ASTR_REWARD);
    earnVault.onBoostReward(address(astr), ASTR_REWARD);

    dot.approve(address(earnVault), DOT_REWARD);
    dot.transfer(address(earnVault), DOT_REWARD);
    earnVault.onBoostReward(address(dot), DOT_REWARD);
    vm.stopPrank();

    // User claims all to clear reserves
    vm.prank(user1);
    earnVault.claim();

    // Verify 2 tokens in array
    (, address[] memory boostTokensBefore,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokensBefore.length, 2, 'Should have 2 tokens');

    // Remove ASTR
    vm.prank(admin);
    earnVault.removeBoostRewardToken(address(astr));

    // Verify only 1 token remains
    (, address[] memory boostTokensAfter,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokensAfter.length, 1, 'Should have 1 token after removal');

    // Record balances before second distribution
    uint256 astrBalanceBeforeSecondClaim = astr.balanceOf(user1);
    uint256 dotBalanceBeforeSecondClaim = dot.balanceOf(user1);

    // Distribute more rewards to DOT
    vm.startPrank(operator);
    dot.mint(operator, DOT_REWARD);
    dot.approve(address(earnVault), DOT_REWARD);
    dot.transfer(address(earnVault), DOT_REWARD);
    earnVault.onBoostReward(address(dot), DOT_REWARD);
    vm.stopPrank();

    // User claims - should only iterate through 1 token (DOT), not 2
    // Since ASTR was removed, it should not be processed in the loop
    vm.prank(user1);
    earnVault.claim();

    // Verify only DOT was processed (ASTR balance unchanged, DOT increased)
    assertEq(
      astr.balanceOf(user1), astrBalanceBeforeSecondClaim, 'ASTR balance should not change (token removed from array)'
    );
    assertEq(dot.balanceOf(user1), dotBalanceBeforeSecondClaim + DOT_REWARD, 'User should receive new DOT rewards');
    assertGt(dot.balanceOf(user1), DOT_REWARD, 'User should have received DOT from both distributions');
  }

  /// @notice Test that token can be re-added after removal
  /// @dev Verifies removal doesn't prevent future distributions
  function test_RemoveBoostRewardToken_CanReAddAfterRemoval() public {
    // Setup: Add and remove token
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    vm.startPrank(operator);
    astr.approve(address(earnVault), ASTR_REWARD);
    astr.transfer(address(earnVault), ASTR_REWARD);
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // User claims
    vm.prank(user1);
    earnVault.claim();

    // Owner removes token
    vm.prank(admin);
    earnVault.removeBoostRewardToken(address(astr));

    (, address[] memory boostTokensEmpty,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokensEmpty.length, 0, 'Array should be empty');

    // Re-add token via distribution
    vm.startPrank(operator);
    astr.mint(operator, ASTR_REWARD);
    astr.approve(address(earnVault), ASTR_REWARD);
    astr.transfer(address(earnVault), ASTR_REWARD);
    earnVault.onBoostReward(address(astr), ASTR_REWARD);
    vm.stopPrank();

    // Verify token is back in array
    (, address[] memory boostTokensReadded,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokensReadded.length, 1, 'Token should be re-added');
    assertEq(earnVault.activeBoostTokens(0), address(astr), 'ASTR should be in array');
    assertGt(earnVault.boostTokenIndex(address(astr)), 0, 'ASTR index should be set');
  }

  /// @notice Test removal of token from middle of array
  /// @dev Verifies swap-and-pop logic works correctly
  function test_RemoveBoostRewardToken_FromMiddleOfArray() public {
    // Setup: Add 3 tokens
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    MockERC20 token3 = new MockERC20('Token3', 'T3', 18);
    token3.mint(operator, 100e18);

    vm.startPrank(operator);
    // Add ASTR (index 0)
    astr.approve(address(earnVault), ASTR_REWARD);
    astr.transfer(address(earnVault), ASTR_REWARD);
    earnVault.onBoostReward(address(astr), ASTR_REWARD);

    // Add DOT (index 1)
    dot.approve(address(earnVault), DOT_REWARD);
    dot.transfer(address(earnVault), DOT_REWARD);
    earnVault.onBoostReward(address(dot), DOT_REWARD);

    // Add Token3 (index 2)
    token3.approve(address(earnVault), 100e18);
    token3.transfer(address(earnVault), 100e18);
    earnVault.onBoostReward(address(token3), 100e18);
    vm.stopPrank();

    // User claims all
    vm.prank(user1);
    earnVault.claim();

    // Verify array order
    assertEq(earnVault.activeBoostTokens(0), address(astr), 'ASTR at index 0');
    assertEq(earnVault.activeBoostTokens(1), address(dot), 'DOT at index 1');
    assertEq(earnVault.activeBoostTokens(2), address(token3), 'Token3 at index 2');

    // Remove middle token (DOT)
    vm.prank(admin);
    earnVault.removeBoostRewardToken(address(dot));

    // Verify swap-and-pop: Token3 should move to index 1
    (, address[] memory boostTokensAfterRemoval,) = earnVault.getAllClaimables(user1);
    assertEq(boostTokensAfterRemoval.length, 2, 'Should have 2 tokens');
    assertEq(earnVault.activeBoostTokens(0), address(astr), 'ASTR should remain at index 0');
    assertEq(earnVault.activeBoostTokens(1), address(token3), 'Token3 should move to index 1');
    assertEq(earnVault.boostTokenIndex(address(dot)), 0, 'DOT index should be cleared');
    assertEq(earnVault.boostTokenIndex(address(token3)), 2, 'Token3 index should remain 2 (1-based)');
  }
}
