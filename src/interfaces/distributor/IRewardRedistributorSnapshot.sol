// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IRewardRedistributorSnapshot
/// @notice Minimal read-only view onto a yield redistributor's latest TVL snapshot - exactly the
///         two getters EarnVaultV2 needs to compute its JIT deposit lock (see
///         EarnVaultV2._depositLockState()). Matches RewardRedistributor's public
///         `lastSnapshotTimestamp` / `snapshotMaxAge` state-variable getters name-for-name and
///         type-for-type; kept deliberately minimal so a non-RewardRedistributor contract set as
///         yieldRedistributor (e.g. in a test) has the smallest possible surface to implement.
interface IRewardRedistributorSnapshot {
  /// @notice Timestamp of the redistributor's most recent snapshotVaultTVLs() call, or 0 if none yet.
  function lastSnapshotTimestamp() external view returns (uint256);

  /// @notice Maximum age (seconds) within which distribute() still accepts the latest snapshot.
  ///         Bounded to [1 minutes, 7 days] by RewardRedistributor.setSnapshotMaxAge().
  function snapshotMaxAge() external view returns (uint256);
}
