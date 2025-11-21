// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IEarnVault {
  // ---- TVL & asset introspection ----
  function totalPrincipal() external view returns (uint256);
  function asset() external view returns (address); // address(USDSC)
  function claimable(address user) external view returns (uint256);

  // ---- Enhanced view functions ----
  function totalValue(address user) external view returns (uint256);
  function getUserInfo(address user)
    external
    view
    returns (uint256 userPrincipal, uint256 userClaimable, uint256 userTotal, uint256 userLastIndex);
  function getVaultStats()
    external
    view
    returns (
      uint256 vaultTotalPrincipal,
      uint256 vaultClaimReserve,
      uint256 vaultGlobalIndex,
      uint256 vaultBalance,
      uint256 vaultCarryRay
    );

  // ---- Boost reward view functions ----
  function getClaimableBoostReward(address user, address token) external view returns (uint256);
  function getAllClaimables(address user)
    external
    view
    returns (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts);

  // ---- user flows (OFF path) ----
  function deposit(uint256 amount) external;
  function depositWithPermit(address tokenOwner, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;

  /// @notice Withdraw any amount up to total value (principal + accrued interest)
  function withdraw(uint256 amountPrincipal) external;

  /// @notice Claim all accrued USDSC interest to msg.sender
  function claim() external;

  // ---- yield redistributor hook ----
  /// @notice MUST be called AFTER transferring `amount` of USDSC to the vault.
  /// Access-controlled (yieldRedistributor only).
  function onYield(uint256 amount) external;

  /// @notice Sweep excess USDSC yield to treasury (when vault has surplus above reserves)
  function sweepSurplusToTreasury() external;

  /// @notice Recover ERC20 tokens sent to this contract (admin only)
  function recoverERC20(address token, address to, uint256 amount) external;

  /// @notice Set the pauser address (admin only)
  function setPauser(address who) external;
}
