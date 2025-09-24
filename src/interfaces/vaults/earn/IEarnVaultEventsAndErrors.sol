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
    
    /// @notice Emitted when pauser address is changed
    /// @param actor Address that initiated the change (msg.sender)
    /// @param oldPauser Previous pauser address
    /// @param newPauser New pauser address
    event PauserChanged(
        address indexed actor, 
        address indexed oldPauser, 
        address indexed newPauser
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

    /// @notice Emitted when yield is distributed and indexed to users
    /// @param amount Amount of yield distributed
    /// @param newGlobalIndex New global index after yield application
    /// @param newClaimReserve New claim reserve amount
    event YieldIndexed(uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
    
    /// @notice Emitted when yield is transferred to treasury (when totalPrincipal = 0)
    /// @param amount Amount of yield transferred to treasury
    event YieldTransferredToTreasury(uint256 amount);
    
    /// @notice Emitted when ERC20 tokens are recovered from the contract
    /// @param token Token address that was recovered
    /// @param to Address that received the tokens
    /// @param amount Amount of tokens recovered
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    
    /// @notice Emitted when surplus USDR is swept to treasury
    /// @param amount Amount of surplus swept to treasury
    event SurplusSweptToTreasury(uint256 amount);
    
    
    /// @notice Emitted when a user claims accrued interest
    /// @param user Address that claimed interest
    /// @param amount Amount of interest claimed
    event InterestClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when boost rewards are distributed and indexed to users
    /// @param token Token address that was distributed
    /// @param amount Amount of boost rewards distributed
    /// @param newGlobalIndex New global boost index after distribution
    /// @param newClaimReserve New boost claim reserve amount
    event BoostRewardIndexed(address indexed token, uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
    
    /// @notice Emitted when boost rewards are transferred to treasury (when totalPrincipal = 0)
    /// @param token Token address that was transferred
    /// @param amount Amount of boost rewards transferred to treasury
    event BoostRewardTransferredToTreasury(address indexed token, uint256 amount);
    
    /// @notice Emitted when a user claims accrued boost rewards
    /// @param user Address that claimed boost rewards
    /// @param token Token address that was claimed
    /// @param amount Amount of boost rewards claimed
    event BoostRewardClaimed(address indexed user, address indexed token, uint256 amount);

    // ========================================
    // Errors
    // ========================================
    
    /// @notice Thrown when caller is not the authorized yield redistributor
    error NotYieldRedistributor();
    
    /// @notice Thrown when caller is not authorized to pause/unpause the contract
    error NotAuthorizedToPause();
    
    /// @notice Thrown when permit operation fails (token may not support IERC20Permit)
    error PermitFailed();
    
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
