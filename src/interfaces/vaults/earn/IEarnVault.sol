// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IEarnVault {
    // ---- TVL & asset introspection ----
    function totalPrincipal() external view returns (uint256);
    function asset() external view returns (address);           // address(USDR)
    function claimable(address user) external view returns (uint256);
    
    // ---- Enhanced view functions ----
    function totalValue(address user) external view returns (uint256);
    function getUserInfo(address user) external view returns (
        uint256 userPrincipal,
        uint256 userClaimable, 
        uint256 userTotal,
        uint256 userLastIndex
    );
    function getVaultStats() external view returns (
        uint256 vaultTotalPrincipal,
        uint256 vaultClaimReserve,
        uint256 vaultGlobalIndex,
        uint256 vaultPendingDelta,
        uint256 vaultBalance
    );

    // ---- user flows (OFF path) ----
    function deposit(uint256 amount) external;
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external;

    /// @notice Withdraw any amount up to total value (principal + accrued interest)
    function withdraw(uint256 amountPrincipal) external;

    /// @notice Withdraw all funds (principal + all accrued interest)
    function withdrawAll() external;

    /// @notice Claim all accrued USDR interest to msg.sender
    function claim() external;

    // ---- yield redistributor hook ----
    /// @notice MUST be called AFTER transferring `amount` of USDR to the vault.
    /// Access-controlled (yieldRedistributor only).
    function onYield(uint256 amount) external;

    
    /// @notice Sweep excess USDR yield to treasury (when vault has surplus above reserves)
    function sweepSurplusToTreasury() external;
    
    /// @notice Set the pauser address (owner only)
    function setPauser(address who) external;

    /// @notice Set the treasury boost address (owner only)
    function setTreasuryBoost(address who) external;
}
