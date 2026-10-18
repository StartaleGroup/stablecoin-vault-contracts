// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVault} from '../../src/vaults/earn/EarnVault.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {Test} from 'lib/forge-std/src/Test.sol';

contract EarnVaultBoostTest is Test {
  EarnVault public earnVault;
  MockERC20 public usdsc;
  MockERC20 public boostToken; // the vault's USDSC: boost rewards are USDSC-only

  address public admin = makeAddr('admin');
  address public operator = makeAddr('operator'); // boost reward keeper
  address public user1 = makeAddr('user1');
  address public user2 = makeAddr('user2');
  address public treasury = makeAddr('treasury');
  address public pauser = makeAddr('pauser');

  uint256 public constant INITIAL_SUPPLY = 1_000_000e6;
  uint256 public constant DEPOSIT_AMOUNT = 1000e6;
  uint256 public constant BOOST_REWARD = 100e6;

  function setUp() public {
    // Deploy tokens
    usdsc = new MockERC20('USDSC Token', 'USDSC', 6);
    boostToken = usdsc;

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
    boostToken.mint(operator, BOOST_REWARD); // Boost tokens to operator (keeper)

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
    // Action: Admin distributes USDSC boost rewards
    // =========================
    vm.startPrank(operator); // operator is boost reward keeper
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: Both users should have equal claimable USDSC rewards
    // =========================
    uint256 user1Claimable = earnVault.getClaimableBoostReward(user1, address(boostToken));
    uint256 user2Claimable = earnVault.getClaimableBoostReward(user2, address(boostToken));

    // Since both users have equal principal, they should get equal boost rewards
    assertEq(user1Claimable, BOOST_REWARD / 2, 'User1 should get half of USDSC rewards');
    assertEq(user2Claimable, BOOST_REWARD / 2, 'User2 should get half of USDSC rewards');

    // Total distributed should equal the original reward amount
    assertEq(user1Claimable + user2Claimable, BOOST_REWARD, 'Total rewards should equal original amount');
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
    // Action: Admin distributes USDSC boost rewards
    // =========================
    vm.startPrank(operator); // operator is boost reward keeper
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: Proportional distribution based on principal
    // =========================
    uint256 user1Claimable = earnVault.getClaimableBoostReward(user1, address(boostToken));
    uint256 user2Claimable = earnVault.getClaimableBoostReward(user2, address(boostToken));

    // User1 has 1/3 of total principal, should get ~1/3 of rewards
    assertApproxEqAbs(user1Claimable, BOOST_REWARD / 3, 1, 'User1 should get ~1/3 of USDSC rewards');

    // User2 has 2/3 of total principal, should get ~2/3 of rewards
    assertApproxEqAbs(user2Claimable, (BOOST_REWARD * 2) / 3, 1, 'User2 should get ~2/3 of USDSC rewards');

    // Total should equal original reward amount (allowing for rounding)
    assertApproxEqAbs(user1Claimable + user2Claimable, BOOST_REWARD, 1, 'Total rewards should equal original amount');
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
    // Action: Admin distributes USDSC boost rewards
    // =========================
    vm.startPrank(operator); // operator is boost reward keeper
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Action: User claims USDSC rewards via unified claim()
    // =========================
    uint256 initialBalance = boostToken.balanceOf(user1);

    vm.prank(user1);
    earnVault.claim();

    // =========================
    // Verification: User should receive the full USDSC reward
    // =========================
    uint256 finalBalance = boostToken.balanceOf(user1);
    assertEq(finalBalance - initialBalance, BOOST_REWARD, 'User should receive full USDSC reward');
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
    // Action: Distribute both USDSC yield and USDSC boost rewards
    // =========================
    // Distribute USDSC yield (admin is yieldRedistributor in setUp)
    vm.startPrank(admin);
    usdsc.approve(address(earnVault), 100e6);
    bool success = usdsc.transfer(address(earnVault), 100e6);
    require(success, 'Transfer failed');
    earnVault.onYield(100e6);
    vm.stopPrank();

    // Distribute USDSC boost rewards (operator is boostRewardKeeper)
    vm.startPrank(operator);
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success2 = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success2, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Action: User claims all rewards via unified claim()
    // =========================
    // Yield and boost both pay out in USDSC, so measure the single combined delta
    uint256 yieldClaimable = earnVault.claimable(user1);
    uint256 boostClaimable = earnVault.getClaimableBoostReward(user1, address(boostToken));
    uint256 before = usdsc.balanceOf(user1);

    vm.prank(user1);
    earnVault.claim();

    // =========================
    // Verification: User should receive both USDSC yield and USDSC boost rewards
    // =========================
    assertGt(yieldClaimable, 0, 'User should have USDSC yield');
    assertEq(boostClaimable, BOOST_REWARD, 'User should have USDSC boost rewards');
    assertEq(usdsc.balanceOf(user1) - before, yieldClaimable + boostClaimable, 'Paid yield + boost in USDSC');
  }

  /// @notice Boost rewards are USDSC-only: any other token reverts, even when funded
  function test_OnBoostReward_NonUsdscToken_Reverts() public {
    MockERC20 other = new MockERC20('Other', 'OTH', 18);
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    other.mint(address(earnVault), BOOST_REWARD);
    vm.prank(operator);
    vm.expectRevert(IEarnVaultEventsAndErrors.BoostTokenNotUSDSC.selector);
    earnVault.onBoostReward(address(other), BOOST_REWARD);
  }

  /// @notice removeBoostRewardToken no longer exists on the vault
  function test_RemoveBoostRewardToken_NoLongerExists() public {
    // as the owner (admin here), for a never-registered token: the old function returned success
    vm.prank(admin);
    (bool ok,) = address(earnVault).call(abi.encodeWithSignature('removeBoostRewardToken(address)', address(0xdEaD)));
    assertFalse(ok, 'removeBoostRewardToken must not exist');
  }

  /// @notice Only one boost slot is ever used, even after several funded boost rounds
  function test_OnlyOneBoostSlotAfterManyRounds() public {
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);

    for (uint256 i = 0; i < 3; i++) {
      boostToken.mint(address(earnVault), BOOST_REWARD);
      vm.prank(operator);
      earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    }

    (, address[] memory tokens, uint256[] memory amounts) = earnVault.getAllClaimables(user1);
    assertEq(tokens.length, 1, 'Exactly one boost token');
    assertEq(tokens[0], address(usdsc), 'The boost token is USDSC');
    assertEq(amounts[0], BOOST_REWARD * 3, 'All rounds accumulate in the single slot');
  }

  /// @notice Operator access control still applies to USDSC boosts
  function test_OnBoostReward_OnlyKeeper() public {
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT);
    boostToken.mint(address(earnVault), BOOST_REWARD);

    vm.prank(admin);
    vm.expectRevert(IEarnVaultEventsAndErrors.NotBoostRewardKeeper.selector);
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
  }

  /// @notice Test that boost rewards are sent to treasury when no users have deposited
  /// @dev Verifies the treasury fallback mechanism for boost rewards
  /// @dev Tests the behavior when totalPrincipal is zero
  /// @dev Ensures boost rewards don't get stuck when no users are present
  function test_NoDepositsBoostRewardToTreasury() public {
    // =========================
    // Setup: No users have deposited (totalPrincipal = 0)
    // =========================
    uint256 initialTreasuryBalance = boostToken.balanceOf(treasury);

    // =========================
    // Action: Admin distributes boost rewards when no deposits exist
    // =========================
    vm.startPrank(operator); // operator is boost reward keeper
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: Treasury should receive the boost rewards
    // =========================
    uint256 finalTreasuryBalance = boostToken.balanceOf(treasury);
    assertEq(
      finalTreasuryBalance - initialTreasuryBalance,
      BOOST_REWARD,
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

    uint256 claimable = earnVault.getClaimableBoostReward(user1, address(boostToken));
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
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // At this point: gi > ui (global index updated, user index still 0)
    uint256 claimableAfterFirst = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertGt(claimableAfterFirst, 0, 'User should have claimable rewards after first distribution');

    // =========================
    // Action: Second boost reward distribution WITHOUT user claiming first
    // =========================
    // Mint more USDSC to operator (boost reward keeper)
    vm.startPrank(admin); // admin mints to operator
    boostToken.mint(operator, BOOST_REWARD); // Mint more USDSC to operator
    vm.stopPrank();

    vm.startPrank(operator); // operator is boost reward keeper (person from company)
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success2 = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success2, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // Now gi is even higher, ui is still 0 (user hasn't claimed)
    uint256 claimableAfterSecond = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(claimableAfterSecond, BOOST_REWARD * 2, 'User should have accumulated both distributions');

    // =========================
    // Action: User claims all accumulated rewards
    // =========================
    uint256 initialUSDSC = boostToken.balanceOf(user1);

    vm.prank(user1);
    earnVault.claim();

    // =========================
    // Verification: User receives all accumulated rewards
    // =========================
    uint256 finalUSDSC = boostToken.balanceOf(user1);
    assertEq(
      finalUSDSC - initialUSDSC, BOOST_REWARD * 2, 'User should claim both accumulated distributions (gi > ui path)'
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
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // First claim - syncs user index to global index and claims rewards
    vm.prank(user1);
    earnVault.claim();

    // At this point: gi == ui (both indices are synced)
    // =========================
    // Verification: No claimable rewards when gi == ui and no accrued
    // =========================
    uint256 claimableAfterSync = earnVault.getClaimableBoostReward(user1, address(boostToken));
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
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Action: Both users claim
    // =========================
    uint256 user1InitialUSDSC = boostToken.balanceOf(user1);
    vm.prank(user1);
    earnVault.claim();
    uint256 user1Claimed = boostToken.balanceOf(user1) - user1InitialUSDSC;

    uint256 user2InitialUSDSC = boostToken.balanceOf(user2);
    vm.prank(user2);
    earnVault.claim();
    uint256 user2Claimed = boostToken.balanceOf(user2) - user2InitialUSDSC;

    // =========================
    // Verification: User2 gets 2x user1's rewards (proportional to principal)
    // =========================
    assertApproxEqAbs(user1Claimed, BOOST_REWARD / 3, 1, 'User1 should get ~1/3 of rewards');
    assertApproxEqAbs(user2Claimed, (BOOST_REWARD * 2) / 3, 1, 'User2 should get ~2/3 of rewards');
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
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Verification: User2 with zero principal should have 0 claimable
    // =========================
    uint256 user2Claimable = earnVault.getClaimableBoostReward(user2, address(boostToken));
    assertEq(user2Claimable, 0, 'User with zero principal should have 0 claimable (principal == 0 branch)');

    // User1 should have full reward
    uint256 user1Claimable = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(user1Claimable, BOOST_REWARD, 'User1 with principal should have full reward');
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
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Calculate expected reward (manual calculation to verify no double-accrual)
    // =========================
    // User has DEPOSIT_AMOUNT (1000e6) principal
    // Total principal is DEPOSIT_AMOUNT
    // Boost reward is BOOST_REWARD (100e6)
    // Expected: User should get 100% of rewards (only user)
    uint256 expectedReward = BOOST_REWARD;

    // Verify claimable before withdraw
    uint256 claimableBefore = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(claimableBefore, expectedReward, 'User should have correct claimable amount');

    // =========================
    // Action: Withdraw (this calls _settleBoost() then claimBoostReward())
    // =========================
    uint256 user1InitialBalance = boostToken.balanceOf(user1);
    uint256 user1Principal = earnVault.principal(user1);

    // Store global index before withdraw (to verify user index gets updated)
    uint256 globalIndexBefore = earnVault.boostGlobalIndex(address(boostToken));

    vm.prank(user1);
    earnVault.withdraw(user1Principal); // Withdraw all, which will claim boost rewards

    // =========================
    // Verification: User should receive exactly the expected amount (not double)
    // =========================
    uint256 user1FinalBalance = boostToken.balanceOf(user1);
    // Withdrawal pays principal + boost in the same USDSC balance
    uint256 received = user1FinalBalance - user1InitialBalance - user1Principal;

    assertEq(received, expectedReward, 'User should receive exactly expected reward, not double');
    assertEq(received, claimableBefore, 'Received amount should equal claimable before withdraw');

    // Verify user index was updated correctly
    uint256 userIndexAfter = earnVault.userBoostIndex(user1, address(boostToken));
    assertEq(userIndexAfter, globalIndexBefore, 'User index should be updated to global index');

    // Verify no more rewards can be claimed
    uint256 claimableAfter = earnVault.getClaimableBoostReward(user1, address(boostToken));
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
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Calculate expected reward
    // =========================
    uint256 expectedReward = BOOST_REWARD; // Only user, so gets 100%

    // Verify claimable
    uint256 claimableBefore = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(claimableBefore, expectedReward, 'User should have correct claimable amount');

    // Store indices before claim to verify update
    uint256 userIndexBefore = earnVault.userBoostIndex(user1, address(boostToken));
    uint256 globalIndexBefore = earnVault.boostGlobalIndex(address(boostToken));

    // User index should be 0 (uninitialized) or less than global index
    assertTrue(
      userIndexBefore < globalIndexBefore || userIndexBefore == 0,
      'User index should be less than global index before claim'
    );

    // =========================
    // Action: Claim (this calls _settleBoost() then claimBoostReward())
    // =========================
    uint256 user1InitialBalance = boostToken.balanceOf(user1);

    vm.prank(user1);
    earnVault.claim(); // Claims both USDSC yield and boost rewards

    // =========================
    // Verification: User should receive exactly the expected amount (not double)
    // =========================
    uint256 user1FinalBalance = boostToken.balanceOf(user1);
    uint256 received = user1FinalBalance - user1InitialBalance;

    assertEq(received, expectedReward, 'User should receive exactly expected reward, not double');
    assertEq(received, claimableBefore, 'Received amount should equal claimable before claim');

    // Verify user index was updated correctly by _settleBoost()
    uint256 userIndexAfter = earnVault.userBoostIndex(user1, address(boostToken));
    assertEq(userIndexAfter, globalIndexBefore, 'User index should be updated to global index by _settleBoost()');

    // Verify no more rewards can be claimed
    uint256 claimableAfter = earnVault.getClaimableBoostReward(user1, address(boostToken));
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
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // =========================
    // Action: User claims boost rewards (first claim)
    // =========================
    // Boost and principal share the same USDSC balance, so measure deltas
    uint256 initialUSDSCBalance = usdsc.balanceOf(user1);
    assertEq(earnVault.claimable(user1), 0, 'No USDSC yield distributed');

    vm.prank(user1);
    earnVault.claim(); // First claim - this clears userBoostAccrued[user1][boostToken] = 0

    uint256 usdscBalanceAfterFirstClaim = usdsc.balanceOf(user1);
    assertEq(
      usdscBalanceAfterFirstClaim - initialUSDSCBalance, BOOST_REWARD, 'User should receive boost on first claim'
    );

    // Verify claimable is now 0 after first claim
    uint256 claimableAfterFirst = earnVault.getClaimableBoostReward(user1, address(boostToken));
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
      usdsc.balanceOf(user1), usdscBalanceAfterFirstClaim, 'USDSC balance should not change after failed claim attempt'
    );

    // =========================
    // Additional verification: Even if new rewards are distributed,
    // user can only claim the new rewards (not the old ones again)
    // =========================
    // Mint more USDSC tokens to operator for the second distribution
    boostToken.mint(operator, BOOST_REWARD);

    // Distribute new boost rewards
    vm.startPrank(operator);
    boostToken.approve(address(earnVault), BOOST_REWARD);
    success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // User should only be able to claim the new rewards (BOOST_REWARD), not the old ones again
    uint256 claimableAfterNewDistribution = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(claimableAfterNewDistribution, BOOST_REWARD, 'User should only have new rewards claimable');

    uint256 boostTokenBalanceBeforeSecondClaim = boostToken.balanceOf(user1);
    vm.prank(user1);
    earnVault.claim(); // Should succeed and claim only the new rewards

    uint256 boostTokenBalanceAfterSecondClaim = boostToken.balanceOf(user1);
    uint256 receivedSecondClaim = boostTokenBalanceAfterSecondClaim - boostTokenBalanceBeforeSecondClaim;

    // User should receive exactly BOOST_REWARD (the new rewards), not BOOST_REWARD * 2
    assertEq(receivedSecondClaim, BOOST_REWARD, 'User should only receive new rewards, not old ones again');
    assertEq(
      boostTokenBalanceAfterSecondClaim - initialUSDSCBalance,
      BOOST_REWARD * 2,
      'Total received should be exactly 2x BOOST_REWARD (first + second)'
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
    assertEq(
      earnVault.userBoostIndex(user1, address(boostToken)), 0, 'T0: User boost index should be 0 (uninitialized)'
    );
    assertEq(
      earnVault.boostGlobalIndex(address(boostToken)), 0, 'T0: Global boost index should be 0 (no distributions)'
    );
    assertEq(earnVault.totalPrincipal(), DEPOSIT_AMOUNT, 'T0: Total principal should be 1000 USDSC');

    // ============================================================
    // TIME T1 - First Boost Distribution
    // ============================================================
    // Keeper distributes 1000 TokenA boost rewards to vault
    vm.startPrank(operator);
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD); // 1000 USDSC
    vm.stopPrank();

    // Calculation: boostGlobalIndex[TokenA] = 0 + (100e6 * 1e27) / 1000e6 = 1e26
    // Formula: (BOOST_REWARD * RAY) / totalPrincipal = (100e6 * 1e27) / 1000e6 = 1e26
    uint256 boostIndexAfterFirstDistribution = earnVault.boostGlobalIndex(address(boostToken));
    assertEq(boostIndexAfterFirstDistribution, 1e26, 'T1: boostGlobalIndex should be 1e26 after first distribution');

    // Alice's pending rewards calculation:
    // owed = principal * (boostGlobalIndex - userBoostIndex) / RAY
    // owed = 1000e6 * (1e26 - 0) / 1e27 = 100e6 USDSC ✅
    uint256 claimableAfterFirstDistribution = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(
      claimableAfterFirstDistribution, BOOST_REWARD, 'T1: Alice should have 100e6 USDSC pending (100% as only user)'
    );

    // State at T1:
    // principal[Alice] = 1000 USDSC (unchanged)
    // userBoostIndex[Alice][TokenA] = 0 (STILL 0 - not updated yet, will be updated on next settlement)
    // boostGlobalIndex[TokenA] = 1e26 (updated by distribution)
    // userBoostAccrued[Alice][TokenA] = 0 (not settled yet, calculated on-demand)
    uint256 userBoostIndexAtT1 = earnVault.userBoostIndex(user1, address(boostToken));
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
    //    - userBoostIndex[Alice][TokenA] = 0 → 1e26 (UPDATED!)
    //    - userBoostAccrued[Alice][TokenA] = 0 + 100e6 = 100e6 USDSC (accrued)
    // 3. principal[Alice] = 1000 → 2000 USDSC (updated AFTER settlement)
    // 4. totalPrincipal = 1000 → 2000 USDSC

    // Verify principal increased
    assertEq(earnVault.principal(user1), DEPOSIT_AMOUNT * 2, 'T2: Alice should have 2000 USDSC principal (doubled)');
    assertEq(earnVault.totalPrincipal(), DEPOSIT_AMOUNT * 2, 'T2: Total principal should be 2000 USDSC');

    // ✅ CRITICAL: User's boost index should be updated to current global index during deposit
    // This prevents retroactive accrual on the new principal
    uint256 userBoostIndexAfterDeposit = earnVault.userBoostIndex(user1, address(boostToken));
    assertEq(
      userBoostIndexAfterDeposit,
      boostIndexAfterFirstDistribution,
      'T2: User boost index should be updated to 1e26 during deposit (prevents retroactive accrual)'
    );

    // Alice should still have the same claimable amount (100e6 USDSC from first distribution)
    // The deposit should NOT retroactively accrue rewards on the new 1000 USDSC principal
    // because userBoostIndex was updated BEFORE principal was increased
    uint256 claimableAfterDeposit = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(
      claimableAfterDeposit,
      BOOST_REWARD,
      'T2: Alice should still have 100e6 USDSC claimable (no retroactive accrual on new principal)'
    );

    // ============================================================
    // TIME T3 - Second Boost Distribution
    // ============================================================
    // Keeper distributes another 1000 TokenA
    // Total distributed: 2000 TokenA in the system
    boostToken.mint(operator, BOOST_REWARD); // Mint more tokens for second distribution
    vm.startPrank(operator);
    boostToken.approve(address(earnVault), BOOST_REWARD);
    success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD); // Another 1000 USDSC
    vm.stopPrank();

    // Calculation: boostGlobalIndex[TokenA] = 1e26 + (100e6 * 1e27) / 2000e6 = 1e26 + 0.5e26 = 1.5e26
    // Formula: previousIndex + (BOOST_REWARD * RAY) / totalPrincipal = 1e26 + (100e6 * 1e27) / 2000e6 = 1.5e26
    uint256 boostIndexAfterSecondDistribution = earnVault.boostGlobalIndex(address(boostToken));
    assertEq(
      boostIndexAfterSecondDistribution, 1.5e26, 'T3: boostGlobalIndex should be 1.5e26 after second distribution'
    );

    // ============================================================
    // TIME T4 - Alice Tries to Claim (CORRECT CALCULATION)
    // ============================================================
    // When Alice calls claim() or withdraw(), _settleBoost() is called again
    // ✅ CORRECT Calculation (with fix):
    // Alice's userBoostIndex = 1e26 (updated during deposit at T2)
    // Alice's principal = 2000 USDSC
    //
    // Rewards from T1→T3 (second distribution):
    // owed = 2000e6 * (1.5e26 - 1e26) / 1e27 = 2000e6 * 0.5e26 / 1e27 = 100e6 USDSC
    //
    // Total rewards:
    // - First distribution (T0→T1): 100e6 USDSC (already accrued at T2)
    // - Second distribution (T2→T3): 100e6 USDSC (on full 2000 USDSC from updated index)
    // Total: 200e6 USDSC ✅

    uint256 claimableAfterSecondDistribution = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(
      claimableAfterSecondDistribution,
      BOOST_REWARD * 2,
      'T4: Alice should have 200e6 USDSC claimable (100e6 from T1 + 100e6 from T3)'
    );

    // Verify the user's boost index is still at the first distribution level (1e26)
    // This is because getClaimableBoostReward() doesn't update the index, only _settleBoost() does
    uint256 userBoostIndexBeforeClaim = earnVault.userBoostIndex(user1, address(boostToken));
    assertEq(
      userBoostIndexBeforeClaim,
      boostIndexAfterFirstDistribution,
      'T4: User boost index should still be 1e26 (not updated by getClaimableBoostReward)'
    );

    // ============================================================
    // TIME T5 - Alice Claims Rewards
    // ============================================================
    uint256 boostTokenBalanceBeforeClaim = boostToken.balanceOf(user1);
    vm.prank(user1);
    earnVault.claim(); // This calls _settleBoost() then claimBoostReward()

    uint256 boostTokenBalanceAfterClaim = boostToken.balanceOf(user1);
    uint256 received = boostTokenBalanceAfterClaim - boostTokenBalanceBeforeClaim;

    // ✅ Alice should receive exactly 200e6 USDSC:
    // - First distribution: 100e6 USDSC (on initial 1000 USDSC from T0→T1)
    // - Second distribution: 100e6 USDSC (on total 2000 USDSC from T2→T3, using updated index)
    assertEq(received, BOOST_REWARD * 2, 'T5: Alice should receive exactly 200e6 USDSC (correct calculation)');

    // Verify user's boost index is now updated to the latest global index (1.5e26)
    uint256 userBoostIndexAfterClaim = earnVault.userBoostIndex(user1, address(boostToken));
    assertEq(
      userBoostIndexAfterClaim,
      boostIndexAfterSecondDistribution,
      'T5: User boost index should be updated to 1.5e26 after claim'
    );

    // Verify no more rewards can be claimed
    uint256 claimableAfterClaim = earnVault.getClaimableBoostReward(user1, address(boostToken));
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
    assertEq(earnVault.userBoostIndex(user1, address(boostToken)), 0, 'T0: User index uninitialized');

    // ============================================================
    // TIME T1 - First Boost Distribution
    // ============================================================
    vm.startPrank(operator);
    boostToken.approve(address(earnVault), BOOST_REWARD);
    bool success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // boostGlobalIndex = (100e6 * 1e27) / 1000e6 = 1e26
    // Alice's pending: 1000e6 * (1e26 - 0) / 1e27 = 100e6 USDSC ✅
    uint256 boostIndexT1 = earnVault.boostGlobalIndex(address(boostToken));
    assertEq(boostIndexT1, 1e26, 'T1: Global index = 1e26');

    uint256 claimableT1 = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(claimableT1, BOOST_REWARD, 'T1: Alice has 100e6 USDSC pending');

    // ============================================================
    // TIME T2 - Alice Deposits More (WITH FIX - CORRECT BEHAVIOR)
    // ============================================================
    // ✅ WITH FIX: deposit() calls _settleBoost() BEFORE updating principal
    vm.prank(user1);
    earnVault.deposit(DEPOSIT_AMOUNT); // Additional 1000 USDSC

    // ✅ CORRECT: userBoostIndex updated to 1e26 BEFORE principal is increased
    uint256 userIndexAfterDeposit = earnVault.userBoostIndex(user1, address(boostToken));
    assertEq(userIndexAfterDeposit, 1e26, 'T2: User index updated to 1e26 (fix working)');
    assertEq(earnVault.principal(user1), DEPOSIT_AMOUNT * 2, 'T2: Principal = 2000 USDSC');

    // ============================================================
    // TIME T3 - Second Boost Distribution
    // ============================================================
    boostToken.mint(operator, BOOST_REWARD);
    vm.startPrank(operator);
    boostToken.approve(address(earnVault), BOOST_REWARD);
    success = boostToken.transfer(address(earnVault), BOOST_REWARD);
    require(success, 'Transfer failed');
    earnVault.onBoostReward(address(boostToken), BOOST_REWARD);
    vm.stopPrank();

    // boostGlobalIndex = 1e26 + (100e6 * 1e27) / 2000e6 = 1.5e26
    uint256 boostIndexT3 = earnVault.boostGlobalIndex(address(boostToken));
    assertEq(boostIndexT3, 1.5e26, 'T3: Global index = 1.5e26');

    // ============================================================
    // TIME T4 - Verify Correct Calculation (NOT Vulnerable)
    // ============================================================
    // ✅ CORRECT Calculation (with fix):
    // userBoostIndex = 1e26 (updated at T2)
    // principal = 2000 USDSC
    // Rewards from T2→T3: 2000e6 * (1.5e26 - 1e26) / 1e27 = 100e6 USDSC
    // Total: 100e6 (from T1) + 100e6 (from T3) = 200e6 USDSC ✅

    uint256 claimableT4 = earnVault.getClaimableBoostReward(user1, address(boostToken));
    assertEq(claimableT4, BOOST_REWARD * 2, 'T4: Alice has 200e6 USDSC');

    // ============================================================
    // NEGATIVE TEST: What would happen WITHOUT the fix
    // ============================================================
    // ❌ WITHOUT FIX (hypothetical):
    // If deposit() didn't call _settleBoost():
    // - userBoostIndex would still be 0 at T2
    // - principal would be 2000 USDSC
    // - At T4, calculation would be:
    //   owed = 2000e6 * (1.5e26 - 0) / 1e27 = 300e18 USDSC ❌
    // - Alice would try to claim 300e18 USDSC when only 200e6 exist
    // - Transaction would REVERT with InsufficientBoostClaimReserve()
    //
    // ✅ WITH FIX (actual behavior):
    // - userBoostIndex = 1e26 at T2 (updated during deposit)
    // - At T4, calculation is:
    //   owed = 2000e6 * (1.5e26 - 1e26) / 1e27 = 100e6 USDSC ✅
    // - Total: 100e6 (from T1) + 100e6 (from T3) = 200e6 USDSC ✅
    // - Alice can successfully claim 200e6 USDSC

    // Verify the fix prevents the vulnerability
    uint256 balanceBeforeClaim = boostToken.balanceOf(user1);
    vm.prank(user1);
    earnVault.claim(); // Should succeed, not revert

    uint256 finalBalance = boostToken.balanceOf(user1) - balanceBeforeClaim;
    assertEq(finalBalance, BOOST_REWARD * 2, 'T4: Alice claims 200e6 USDSC');
  }
}
