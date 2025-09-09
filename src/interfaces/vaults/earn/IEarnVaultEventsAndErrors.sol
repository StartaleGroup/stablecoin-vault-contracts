// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IEarnVaultEventsAndErrors
/// @notice Events and errors interface for EarnVault contracts
/// @dev Separates events and errors for cleaner code organization and reusability
interface IEarnVaultEventsAndErrors {
    
    // ========================================
    // Events
    // ========================================
    
    /// @notice Emitted when yield redistributor address is changed
    /// @param actor Address that initiated the change (msg.sender)
    /// @param oldRedistributor Previous yield redistributor address
    /// @param newRedistributor New yield redistributor address
    event YieldRedistributorChanged(
        address indexed actor, 
        address indexed oldRedistributor, 
        address indexed newRedistributor
    );
    
    /// @notice Emitted when treasury address is changed
    /// @param actor Address that initiated the change (msg.sender)
    /// @param oldTreasury Previous treasury address
    /// @param newTreasury New treasury address
    event TreasuryChanged(
        address indexed actor, 
        address indexed oldTreasury, 
        address indexed newTreasury
    );
    
    /// @notice Emitted when an address blacklist status is changed
    /// @param actor Address that initiated the change (msg.sender)
    /// @param user Address whose blacklist status was changed
    /// @param oldStatus Previous blacklist status
    /// @param newStatus New blacklist status
    event BlacklistStatusChanged(
        address indexed actor, 
        address indexed user, 
        bool oldStatus, 
        bool newStatus
    );

    /// @notice Emitted when a user deposits USDR tokens
    /// @param user Address that made the deposit
    /// @param amount Amount of USDR deposited
    event Deposit(address indexed user, uint256 amount);
    
    /// @notice Emitted when a user withdraws principal
    /// @param user Address that made the withdrawal
    /// @param amount Amount of principal withdrawn
    event Withdraw(address indexed user, uint256 amount);
    
    /// @notice Emitted when a user claims interest (legacy event for compatibility)
    /// @param user Address that claimed interest
    /// @param to Address that received the interest
    /// @param amount Amount of interest claimed
    event Claim(address indexed user, address indexed to, uint256 amount);

    /// @notice Emitted when yield is distributed and indexed to users
    /// @param amount Amount of yield distributed
    /// @param newGlobalIndex New global index after yield application
    /// @param newClaimReserve New claim reserve amount
    event YieldIndexed(uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
    
    /// @notice Emitted when yield is parked (when totalPrincipal = 0)
    /// @param amount Amount of yield parked
    /// @param totalParked Total amount of parked yield after this addition
    event YieldParked(uint256 amount, uint256 totalParked);
    
    /// @notice Emitted when previously parked yield is applied to users
    /// @param amountApplied Amount of parked yield that was applied
    /// @param remainingParked Amount of parked yield remaining (should be 0)
    event ParkedYieldApplied(uint256 amountApplied, uint256 remainingParked);
    
    /// @notice Emitted when a user claims accrued interest
    /// @param user Address that claimed interest
    /// @param amount Amount of interest claimed
    event InterestClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when emergency sweep is performed
    /// @param token Address of token that was swept
    /// @param to Address that received the swept tokens
    /// @param amount Amount of tokens swept
    event EmergencySweep(address indexed token, address indexed to, uint256 amount);

    // ========================================
    // Errors
    // ========================================
    
    /// @notice Thrown when caller is not the authorized yield redistributor
    error NotYieldRedistributor();
    
    /// @notice Thrown when attempting to interact with a blacklisted address
    error AddressBlacklisted();
    
    /// @notice Thrown when zero amount is provided where non-zero is required
    error ZeroAmount();
    
    /// @notice Thrown when attempting to withdraw more principal than available
    error InsufficientPrincipal();
    
    /// @notice Thrown when a zero address is provided where non-zero is required
    error CanNotBeZeroAddress();
    
    /// @notice Thrown when attempting to claim but no yield is available
    error NothingToClaim();
    
    /// @notice Thrown when vault has insufficient funds to fulfill claims/withdrawals
    error InsufficientFunding();
    
    /// @notice Thrown when arithmetic operation would overflow
    error ArithmeticOverflow();
    
    /// @notice Thrown when contract must be paused for operation but isn't
    error ContractNotPaused();
    
    /// @notice Thrown when emergency sweep amount exceeds available surplus
    error ExceedsSurplus();
    
    /// @notice Thrown when contract receives ETH but shouldn't accept it
    error EthNotAccepted();
}
