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
  /// @param T_earn            EarnVault TVL used for allocation (i.e., `earnVault.totalPrincipal()`).
  /// @param T_yield              sUSDSCVault TVL used for allocation (i.e., `susdscVault.totalAssets()`).
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

  /// @notice Emitted when sUSDSC TVL snapshot is captured.
  /// @param lastSusdscTVL         Latest sUSDSC vault TVL snapshot.
  /// @param lastSnapshotTimestamp Timestamp when the snapshot was captured.
  event SusdscTVLSnapshotCaptured(uint256 lastSusdscTVL, uint256 lastSnapshotTimestamp);

  /// @notice Emitted when snapshot cutoff period is updated.
  /// @param newSnapShotCutoffPeriod New snapshot cutoff period value.
  event SnapShotCutoffPeriodUpdated(uint256 newSnapShotCutoffPeriod);

  /// @notice Emitted when snapshot maximum age is updated.
  /// @param newSnapshotMaxAge New snapshot maximum age value.
  event SnapshotMaxAgeUpdated(uint256 newSnapshotMaxAge);

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

  /// @notice Thrown when snapshot cutoff period is outside valid range
  /// @param newSnapShotCutoffPeriod The invalid snapshot cutoff period value
  error InvalidSnapShotCutoffPeriod(uint256 newSnapShotCutoffPeriod);

  /// @notice Thrown when snapshot cutoff period has not elapsed or snapshot not taken
  /// @param lastSnapshotTimestamp The timestamp of the last snapshot
  /// @param currentTimestamp The current block timestamp
  /// @param snapShotCutoffPeriod The required cutoff period
  error SnapShotCutoffPeriodNotElapsed(
    uint256 lastSnapshotTimestamp, uint256 currentTimestamp, uint256 snapShotCutoffPeriod
  );

  /// @notice Thrown when snapshot maximum age is invalid
  /// @param newSnapshotMaxAge The invalid snapshot maximum age value
  /// @param cooldownPeriod The current cooldown period (for context)
  error InvalidSnapshotMaxAge(uint256 newSnapshotMaxAge, uint256 cooldownPeriod);

  /// @notice Thrown when snapshot is too old
  /// @param lastSnapshotTimestamp The timestamp of the last snapshot
  /// @param currentTimestamp The current block timestamp
  /// @param snapshotMaxAge The maximum allowed age
  error SnapshotTooOld(
    uint256 lastSnapshotTimestamp, uint256 currentTimestamp, uint256 snapshotMaxAge
  );
}
