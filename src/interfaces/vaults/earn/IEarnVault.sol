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
        uint256 vaultParkedYield,
        uint256 vaultGlobalIndex,
        uint256 vaultBalance
    );

    // ---- user flows (OFF path) ----
    function deposit(uint256 amount) external;
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external;

    function withdraw(uint256 amountPrincipal) external;

    /// @notice Claim all accrued USDR interest to msg.sender
    function claim() external;
    
    /// @notice Claim all accrued USDR interest to specified address
    /// @param to        Receiver of the claimed USDR.
    function claimTo(address to) external;

    // ---- splitter / redistributor hook ----
    /// @notice MUST be called AFTER transferring `amount` of USDR to the vault.
    /// Access-controlled (distributor/owner).
    function onYield(uint256 amount) external;

    /// @notice Applies previously parked yield once deposits exist (optional but useful).
    function applyParkedYield() external;
}
