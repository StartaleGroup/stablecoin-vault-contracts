// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from 'lib/openzeppelin-contracts/contracts/utils/math/Math.sol';

/// @title BoostRewardsLib - Library for handling boost rewards distribution
/// @notice Handles boost rewards logic separately from main EarnVault contract
/// @dev Uses same logic as USDSC yield - distributed proportionally based on principal
library BoostRewardsLib {
  using SafeERC20 for IERC20;

  // -------- Constants --------
  uint256 public constant RAY = 1e27;
  uint256 public constant MAX_BOOST_TOKENS = 10;

  /// @notice Distribute boost rewards to vault users
  /// @dev Uses same logic as USDSC yield - distributed proportionally based on principal
  /// @param token Token address to distribute as boost rewards
  /// @param amount Amount of boost tokens to distribute
  /// @param totalPrincipal Total principal amount in vault
  /// @param treasury Treasury address for when no deposits exist
  /// @param boostGlobalIndex Global boost index for this token
  /// @param boostClaimReserve Claimable boost reserves for this token
  /// @param activeBoostTokens Array of active boost tokens
  /// @param boostTokenIndex Mapping of token to index in activeBoostTokens array
  function distributeBoostReward(
    address token,
    uint256 amount,
    uint256 totalPrincipal,
    address treasury,
    mapping(address => uint256) storage boostGlobalIndex,
    mapping(address => uint256) storage boostClaimReserve,
    address[] storage activeBoostTokens,
    mapping(address => uint256) storage boostTokenIndex
  ) internal {
    if (token == address(0)) {
      revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    }
    if (amount == 0) return;

    // Verify actual balance before updating accounting
    uint256 bal = IERC20(token).balanceOf(address(this));

    if (totalPrincipal == 0) {
      // No deposits: transfer to treasury
      if (bal < amount) revert IEarnVaultEventsAndErrors.InsufficientBoostTokenBalance();

      try IERC20(token).transfer(treasury, amount) returns (bool success) {
        if (!success) {
          revert IEarnVaultEventsAndErrors.InsufficientBoostTokenBalance();
        }
        emit IEarnVaultEventsAndErrors.BoostRewardTransferredToTreasury(token, amount);
        return;
      } catch {
        // Transfer failed (token may be frozen, paused, etc.)
        // Revert the operation - treasury transfer failure should be handled by keeper
        revert IEarnVaultEventsAndErrors.InsufficientBoostTokenBalance();
      }
    }

    // Deposits exist: distribute proportionally based on principal (same as USDSC yield)
    if (bal < boostClaimReserve[token] + amount) revert IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve();

    // Update boost global index for this token (same logic as USDSC yield)
    uint256 carryRay = 0; // We use 0 for boost rewards as precision loss is negligible
    unchecked {
      uint256 num = amount * RAY + carryRay;
      uint256 delta = num / totalPrincipal;
      boostGlobalIndex[token] += delta;
    }

    boostClaimReserve[token] += amount;

    // Track active boost tokens (only add if not already tracked)
    if (boostTokenIndex[token] == 0) {
      // Check maximum limit before adding new token
      if (activeBoostTokens.length >= MAX_BOOST_TOKENS) {
        revert IEarnVaultEventsAndErrors.TooManyBoostTokens();
      }
      // Token not tracked yet, add to array and set index
      activeBoostTokens.push(token);
      boostTokenIndex[token] = activeBoostTokens.length; // 1-based index
    }

    emit IEarnVaultEventsAndErrors.BoostRewardIndexed(token, amount, boostGlobalIndex[token], boostClaimReserve[token]);
  }

  /// @notice Claim boost rewards for a specific token
  /// @param user User address claiming rewards
  /// @param token Token address to claim boost rewards for
  /// @param principal User's principal amount
  /// @param userBoostIndex User's last boost index for this token
  /// @param boostGlobalIndex Global boost index for this token
  /// @param userBoostAccrued User's accrued boost rewards for this token
  /// @param boostClaimReserve Claimable boost reserves for this token
  function claimBoostReward(
    address user,
    address token,
    uint256 principal,
    uint256 userBoostIndex,
    uint256 boostGlobalIndex,
    mapping(address => mapping(address => uint256)) storage userBoostAccrued,
    mapping(address => uint256) storage boostClaimReserve
  ) internal returns (uint256 claimedAmount) {
    if (token == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();

    // Settle user's boost rewards
    if (principal == 0) {
      // User has no principal, just return accrued amount
      claimedAmount = userBoostAccrued[user][token];
    } else {
      uint256 ui = userBoostIndex;
      uint256 gi = boostGlobalIndex;
      if (gi > ui) {
        uint256 owed = Math.mulDiv(principal, gi - ui, RAY);
        userBoostAccrued[user][token] += owed;
      }
      claimedAmount = userBoostAccrued[user][token];
    }

    if (claimedAmount == 0) return 0;
    if (boostClaimReserve[token] < claimedAmount) revert IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve();

    userBoostAccrued[user][token] = 0;
    boostClaimReserve[token] -= claimedAmount;

    try IERC20(token).transfer(user, claimedAmount) returns (bool success) {
      if (!success) {
        // Transfer returned false - revert accounting changes
        userBoostAccrued[user][token] = claimedAmount;
        boostClaimReserve[token] += claimedAmount;
        emit IEarnVaultEventsAndErrors.BoostRewardTransferFailed(user, token, claimedAmount);
        return 0;
      }
      emit IEarnVaultEventsAndErrors.BoostRewardClaimed(user, token, claimedAmount);
      return claimedAmount;
    } catch {
      // Transfer failed (token may be frozen, paused, etc.)
      // Revert accounting changes to maintain consistency
      userBoostAccrued[user][token] = claimedAmount;
      boostClaimReserve[token] += claimedAmount;

      // Emit failure event for monitoring
      emit IEarnVaultEventsAndErrors.BoostRewardTransferFailed(user, token, claimedAmount);

      // Returning 0 to indicate failure, allowing other tokens to still be claimed
      return 0;
    }
  }

  /// @notice Get user's claimable boost rewards for a specific token
  /// @param user User address to check
  /// @param token Token address to check boost rewards for
  /// @param principal User's principal amount
  /// @param userBoostIndex User's last boost index for this token
  /// @param boostGlobalIndex Global boost index for this token
  /// @param userBoostAccrued User's accrued boost rewards for this token
  function getClaimableBoostReward(
    address user,
    address token,
    uint256 principal,
    uint256 userBoostIndex,
    uint256 boostGlobalIndex,
    mapping(address => mapping(address => uint256)) storage userBoostAccrued
  ) internal view returns (uint256) {
    if (principal == 0) {
      return userBoostAccrued[user][token];
    }
    if (boostGlobalIndex > userBoostIndex) {
      uint256 owed = Math.mulDiv(principal, boostGlobalIndex - userBoostIndex, RAY);
      return userBoostAccrued[user][token] + owed;
    }
    return userBoostAccrued[user][token];
  }

  /// @notice Settle user's accrued boost rewards for a specific token
  /// @param user User address to settle
  /// @param token Token address to settle boost rewards for
  /// @param principal User's principal amount
  /// @param userBoostIndex User's last boost index for this token
  /// @param boostGlobalIndex Global boost index for this token
  /// @param userBoostAccrued User's accrued boost rewards for this token
  function settleBoost(
    address user,
    address token,
    uint256 principal,
    uint256 userBoostIndex,
    uint256 boostGlobalIndex,
    mapping(address => mapping(address => uint256)) storage userBoostAccrued
  ) internal {
    if (principal == 0) {
      // User has no principal, nothing to settle
      return;
    }
    if (boostGlobalIndex > userBoostIndex) {
      uint256 owed = Math.mulDiv(principal, boostGlobalIndex - userBoostIndex, RAY);
      userBoostAccrued[user][token] += owed;
    }
    // Note: User's boost index update is handled by the calling contract
  }
}
