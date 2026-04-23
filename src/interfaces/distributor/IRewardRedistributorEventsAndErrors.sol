// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IRewardRedistributorEventsAndErrors
/// @notice Events and errors interface for RewardRedistributor contract
interface IRewardRedistributorEventsAndErrors {
  // ========================================
  // Events
  // ========================================

  /// @notice Emitted after each distribution.
  /// @param minted            Total USDSC freshly minted by the extension in this call.
  /// @param feeToStartale     Fee portion (bps of minted) sent to Startale.
  /// @param toEarnVault            Net yield sent to EarnVault (checkbox OFF).
  /// @param toSUSDSCVault      Net yield sent to sUSDSC ERC-4626 vault (checkbox ON).
  /// @param toStartaleExtra   Remainder of net yield: ineligible cohorts (wallets/LP/points) + rounding dust.
  /// @param S_base            Total USDSC supply **before** this mint (denominator for allocation).
  /// @param T_earn            EarnVault TVL used for allocation (from snapshot: lastEarnTVL).
  /// @param T_yield            sUSDSCVault TVL used for allocation (from snapshot: lastSusdscTVL).
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

  /// @notice Emitted when Startale/earn/sUSDSC addresses or fee are updated.
  /// @param treasury          New Treasury address.
  /// @param earnVault         New EarnVault address.
  /// @param susdscVault        New sUSDSC (ERC-4626) vault address.
  /// @param fee_on_yield_bps  New fee on yield (bps).
  event ParamsUpdated(address treasury, address earnVault, address susdscVault, uint16 fee_on_yield_bps);

  /// @notice Emitted when Treasury address is updated.
  /// @param treasury          New Treasury address.
  event TreasuryUpdated(address treasury);

  /// @notice Emitted when EarnVault address is updated.
  /// @param earnVault         New EarnVault address.
  event EarnVaultUpdated(address earnVault);

  /// @notice Emitted when sUSDSC vault address is updated.
  /// @param susdscVault        New sUSDSC (ERC-4626) vault address.
  event SusdscVaultUpdated(address susdscVault);

  /// @notice Emitted when fee on yield is updated.
  /// @param fee_on_yield_bps  New fee on yield (bps).
  event FeeUpdated(uint16 fee_on_yield_bps);

  /// @notice Emitted when both vault TVLs are captured by snapshotVaultTVLs().
  /// @param lastSusdscTVL         Latest sUSDSC vault TVL snapshot.
  /// @param lastEarnTVL           Latest EarnVault TVL (totalPrincipal) snapshot.
  /// @param lastSnapshotTimestamp Timestamp when the snapshot was captured.
  /// @param lastSnapshotBlockNumber Block number when the snapshot was captured.
  event VaultTVLsSnapshotCaptured(
    uint256 lastSusdscTVL,
    uint256 lastEarnTVL,
    uint256 lastSnapshotTimestamp,
    uint256 lastSnapshotBlockNumber
  );

  /// @notice Emitted when snapshot maximum age is updated.
  /// @param newSnapshotMaxAge New snapshot maximum age value.
  event SnapshotMaxAgeUpdated(uint256 newSnapshotMaxAge);

  /// @notice Emitted when donations are recovered.
  /// @param balance Amount of USDSC recovered.
  event DonationsRecovered(uint256 balance);

  // ========================================
  // Errors
  // ========================================

  /// @notice Thrown when an attempt is made to remove (via revoke or renounce) the last DEFAULT_ADMIN_ROLE.
  error CannotRemoveLastAdmin();

  /// @notice Thrown when a parameter is set to zero
  /// @param parameterName Name of the parameter that is zero
  error ZeroAddress(string parameterName);

  /// @notice Thrown when fee is too high
  /// @param feeBps Requested fee in basis points
  /// @param maxFeeBps Maximum allowed fee in basis points
  error FeeTooHigh(uint16 feeBps, uint16 maxFeeBps);

  /// @notice Thrown when the yield recipient has changed
  /// @param currentRecipient The current yield recipient address
  error YieldRecipientChanged(address currentRecipient);

  /// @notice Thrown when USDSC address does not implement required interfaces
  /// @param missingInterface Description of which interface is missing (e.g., "IERC20" or "IMYieldToOne")
  error InvalidUSDSC(string missingInterface);

  /// @notice Thrown when attempting to distribute with zero yield
  error ZeroYield();

  /// @notice Thrown when the last snapshot is invalid
  error LastSnapshotInvalid();

  /// @notice Thrown when snapshot maximum age is invalid
  /// @param newSnapshotMaxAge The invalid snapshot maximum age value
  /// @param limit The limit that was violated (minimum or maximum)
  error InvalidSnapshotMaxAge(uint256 newSnapshotMaxAge, uint256 limit);

  /// @notice Thrown when attempting to distribute in the same block as the snapshot
  /// @param lastSnapshotBlockNumber The block number of the last snapshot
  /// @param currentBlockNumber The current block number
  error MustSnapshotInPreviousBlocks(uint256 lastSnapshotBlockNumber, uint256 currentBlockNumber);

  /// @notice Thrown when snapshot is too old
  /// @param lastSnapshotTimestamp The timestamp of the last snapshot
  /// @param currentTimestamp The current block timestamp
  /// @param snapshotMaxAge The maximum allowed age
  error SnapshotTooOld(uint256 lastSnapshotTimestamp, uint256 currentTimestamp, uint256 snapshotMaxAge);
}
