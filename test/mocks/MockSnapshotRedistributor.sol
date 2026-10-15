// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IRewardRedistributorSnapshot} from '../../src/interfaces/distributor/IRewardRedistributorSnapshot.sol';

/// @title MockSnapshotRedistributor
/// @notice Minimal stand-in for RewardRedistributor used only to drive EarnVaultV2's deposit
///         lock: exposes settable `lastSnapshotTimestamp`/`snapshotMaxAge`, with none of the real
///         contract's distribution logic. Tests set its address as the vault's
///         `yieldRedistributor` and prank as that address to call the vault's `onYield`.
contract MockSnapshotRedistributor is IRewardRedistributorSnapshot {
  uint256 public lastSnapshotTimestamp;
  uint256 public snapshotMaxAge;

  /// @param initialMaxAge Starting snapshotMaxAge; real RewardRedistributor defaults to 5 minutes
  ///        and bounds every later update to [1 minutes, 7 days] - not enforced here, since
  ///        tests deliberately also probe out-of-range values (e.g. type(uint256).max).
  constructor(uint256 initialMaxAge) {
    snapshotMaxAge = initialMaxAge;
  }

  /// @notice Records a snapshot at the given timestamp (not necessarily block.timestamp, so
  ///         tests can set up boundary scenarios directly).
  function setSnapshot(uint256 timestamp, uint256 maxAge) external {
    lastSnapshotTimestamp = timestamp;
    snapshotMaxAge = maxAge;
  }

  function setLastSnapshotTimestamp(uint256 timestamp) external {
    lastSnapshotTimestamp = timestamp;
  }

  function setSnapshotMaxAge(uint256 maxAge) external {
    snapshotMaxAge = maxAge;
  }
}

/// @notice Redistributor whose snapshot getters always revert - the vault must fail closed.
contract MockRevertingSnapshotRedistributor {
  error GetterReverted();

  function lastSnapshotTimestamp() external pure returns (uint256) {
    revert GetterReverted();
  }

  function snapshotMaxAge() external pure returns (uint256) {
    revert GetterReverted();
  }
}

/// @notice Contract redistributor that answers every call successfully but with empty return
///         data - the vault's ABI decode must fail, so the deposit reverts (fail closed).
contract MockEmptyReturnRedistributor {
  fallback() external {}
}

/// @notice Redistributor whose getter tries to write state. The vault calls the getters through
///         a `view` interface (STATICCALL), so the write must make the call - and the deposit -
///         revert: a redistributor cannot change state or re-enter through the lock check.
contract MockStateChangingSnapshotRedistributor {
  uint256 public calls;

  function lastSnapshotTimestamp() external returns (uint256) {
    calls++;
    return block.timestamp;
  }

  function snapshotMaxAge() external pure returns (uint256) {
    return 5 minutes;
  }
}
