// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVault} from '../../src/interfaces/vaults/earn/IEarnVault.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/// @title TestSnapshotRedistributor
/// @notice TEST NETWORKS ONLY. Stands in for RewardRedistributor as EarnVaultV2's
///         yieldRedistributor, so integrators can exercise the snapshot -> distribute cycle and the
///         JIT deposit lock. It mirrors exactly what EarnVaultV2 depends on:
///         - the `lastSnapshotTimestamp()` / `snapshotMaxAge()` getters the deposit lock reads;
///         - distribute() acceptance: a snapshot exists, at least one block has passed since it, and
///           it is no older than snapshotMaxAge (RewardRedistributor._validateSnapShotAge);
///         - snapshotMaxAge bounds [1 minutes, 7 days];
///         - the same VaultTVLsSnapshotCaptured / Distributed / SnapshotMaxAgeUpdated event signatures,
///           so an indexer built against these logs also decodes the real contract's.
///         Unlike the real contract it does not mint or split yield: distribute(amount) pulls
///         `amount` test USDSC from the caller and hands all of it to the vault via transfer ->
///         onYield. Not part of the audited contracts.
contract TestSnapshotRedistributor {
  using SafeERC20 for IERC20;

  error NotOperator();
  error LastSnapshotInvalid();
  error MustSnapshotInPreviousBlocks(uint256 lastSnapshotBlockNumber, uint256 currentBlockNumber);
  error SnapshotTooOld(uint256 lastSnapshotTimestamp, uint256 currentTimestamp, uint256 snapshotMaxAge);
  error InvalidSnapshotMaxAge(uint256 newSnapshotMaxAge, uint256 limit);

  event VaultTVLsSnapshotCaptured(
    uint256 lastSusdscTVL, uint256 lastEarnTVL, uint256 lastSnapshotTimestamp, uint256 lastSnapshotBlockNumber
  );
  event Distributed(
    uint256 minted,
    uint256 feeToStartale,
    uint256 toEarnVault,
    uint256 toSUSDSCVault,
    uint256 toStartaleExtra,
    uint256 S_base,
    uint256 T_earn,
    uint256 T_yield
  );
  event SnapshotMaxAgeUpdated(uint256 newSnapshotMaxAge);

  IERC20 public immutable USDSC;
  IEarnVault public immutable earnVault;
  address public operator;

  uint256 public lastEarnTVL;
  uint256 public lastSnapshotTimestamp;
  uint256 public lastSnapshotBlockNumber;
  uint256 public snapshotMaxAge;

  constructor(IERC20 usdsc, IEarnVault vault, address operator_, uint256 initialMaxAge) {
    USDSC = usdsc;
    earnVault = vault;
    operator = operator_;
    _setSnapshotMaxAge(initialMaxAge);
  }

  modifier onlyOperator() {
    if (msg.sender != operator) revert NotOperator();
    _;
  }

  function setOperator(address newOperator) external onlyOperator {
    operator = newOperator;
  }

  function setSnapshotMaxAge(uint256 newSnapshotMaxAge) external onlyOperator {
    _setSnapshotMaxAge(newSnapshotMaxAge);
  }

  /// @notice Same shape as RewardRedistributor.snapshotVaultTVLs(): records the EarnVault TVL now.
  function snapshotVaultTVLs() external onlyOperator {
    lastEarnTVL = earnVault.totalPrincipal();
    lastSnapshotTimestamp = block.timestamp;
    lastSnapshotBlockNumber = block.number;
    emit VaultTVLsSnapshotCaptured(0, lastEarnTVL, lastSnapshotTimestamp, lastSnapshotBlockNumber);
  }

  /// @notice Delivers `amount` test USDSC of yield to the vault (transfer -> onYield), under the
  ///         same snapshot rules as RewardRedistributor.distribute(). The caller must have approved
  ///         this contract for `amount`.
  function distribute(uint256 amount) external onlyOperator {
    if (lastSnapshotTimestamp == 0 || lastSnapshotBlockNumber == 0) revert LastSnapshotInvalid();
    if (block.number - lastSnapshotBlockNumber < 1) {
      revert MustSnapshotInPreviousBlocks(lastSnapshotBlockNumber, block.number);
    }
    if (block.timestamp - lastSnapshotTimestamp > snapshotMaxAge) {
      revert SnapshotTooOld(lastSnapshotTimestamp, block.timestamp, snapshotMaxAge);
    }
    if (amount > 0) {
      USDSC.safeTransferFrom(msg.sender, address(earnVault), amount);
      earnVault.onYield(amount);
    }
    emit Distributed(amount, 0, amount, 0, 0, 0, lastEarnTVL, 0);
  }

  function _setSnapshotMaxAge(uint256 newSnapshotMaxAge) internal {
    if (newSnapshotMaxAge < 1 minutes) revert InvalidSnapshotMaxAge(newSnapshotMaxAge, 1 minutes);
    if (newSnapshotMaxAge > 7 days) revert InvalidSnapshotMaxAge(newSnapshotMaxAge, 7 days);
    snapshotMaxAge = newSnapshotMaxAge;
    emit SnapshotMaxAgeUpdated(newSnapshotMaxAge);
  }
}
