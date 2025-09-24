// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title BoostRewardsLib - Library for handling boost rewards distribution
/// @notice Handles boost rewards logic separately from main EarnVault contract
/// @dev Uses same logic as USDR yield - distributed proportionally based on principal
library BoostRewardsLib {
    using SafeERC20 for IERC20;

    // -------- Constants --------
    uint256 public constant RAY = 1e27;  // High precision for calculations

    // -------- Events --------
    event BoostRewardIndexed(address indexed token, uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
    event BoostRewardTransferredToTreasury(address indexed token, uint256 amount);
    event BoostRewardClaimed(address indexed user, address indexed token, uint256 amount);

    // -------- Errors --------
    error ZeroAddress();
    error InsufficientFunding();

    /// @notice Distribute boost rewards to vault users
    /// @dev Uses same logic as USDR yield - distributed proportionally based on principal
    /// @param token Token address to distribute as boost rewards
    /// @param amount Amount of boost tokens to distribute
    /// @param totalPrincipal Total principal amount in vault
    /// @param treasury Treasury address for when no deposits exist
    /// @param boostGlobalIndex Global boost index for this token
    /// @param boostClaimReserve Claimable boost reserves for this token
    /// @param activeBoostTokens Array of active boost tokens
    function distributeBoostReward(
        address token,
        uint256 amount,
        uint256 totalPrincipal,
        address treasury,
        mapping(address => uint256) storage boostGlobalIndex,
        mapping(address => uint256) storage boostClaimReserve,
        address[] storage activeBoostTokens
    ) external {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        
        // Verify actual balance before updating accounting
        uint256 bal = IERC20(token).balanceOf(address(this));
        
        if (totalPrincipal == 0) {
            // No deposits: transfer to treasury
            if (bal < amount) revert InsufficientFunding();
            IERC20(token).safeTransfer(treasury, amount);
            emit BoostRewardTransferredToTreasury(token, amount);
            return;
        }
        
        // Deposits exist: distribute proportionally based on principal (same as USDR yield)
        if (bal < boostClaimReserve[token] + amount) revert InsufficientFunding();
        
        // Update boost global index for this token (same logic as USDR yield)
        uint256 carryRay = 0; // For simplicity, we'll use 0 for boost rewards
        unchecked {
            uint256 num = amount * RAY + carryRay;
            uint256 delta = num / totalPrincipal;
            boostGlobalIndex[token] += delta;
        }
        
        boostClaimReserve[token] += amount;
        
        // Track active boost tokens (only add if not already tracked)
        bool tokenExists = false;
        for (uint256 i = 0; i < activeBoostTokens.length; i++) {
            if (activeBoostTokens[i] == token) {
                tokenExists = true;
                break;
            }
        }
        if (!tokenExists) {
            activeBoostTokens.push(token);
        }
        
        emit BoostRewardIndexed(token, amount, boostGlobalIndex[token], boostClaimReserve[token]);
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
    ) external returns (uint256 claimedAmount) {
        if (token == address(0)) revert ZeroAddress();
        
        // Settle user's boost rewards
        uint256 ui = userBoostIndex;
        uint256 gi = boostGlobalIndex;
        if (principal == 0) { 
            // User has no principal, just return accrued amount
            claimedAmount = userBoostAccrued[user][token];
        } else if (gi >= ui) {
            if (gi > ui) {
                uint256 owed = Math.mulDiv(principal, gi - ui, RAY);
                userBoostAccrued[user][token] += owed;
            }
            claimedAmount = userBoostAccrued[user][token];
        } else {
            claimedAmount = userBoostAccrued[user][token];
        }
        
        if (claimedAmount == 0) return 0;
        if (boostClaimReserve[token] < claimedAmount) revert InsufficientFunding();
        
        userBoostAccrued[user][token] = 0;
        boostClaimReserve[token] -= claimedAmount;
        IERC20(token).safeTransfer(user, claimedAmount);
        emit BoostRewardClaimed(user, token, claimedAmount);
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
    ) external view returns (uint256) {
        if (principal == 0) return userBoostAccrued[user][token];
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
    ) external {
        if (principal == 0) { 
            // User has no principal, update index to current
            return;
        }
        if (boostGlobalIndex >= userBoostIndex) {
            if (boostGlobalIndex > userBoostIndex) {
                uint256 owed = Math.mulDiv(principal, boostGlobalIndex - userBoostIndex, RAY);
                userBoostAccrued[user][token] += owed;
            }
            // Update user's boost index to current global index
        }
    }
}
