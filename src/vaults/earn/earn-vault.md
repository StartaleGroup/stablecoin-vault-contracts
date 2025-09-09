# EarnVault - Claimable Yield Vault

## Overview

Users deposit USDR tokens and earn claimable yield over time. Users maintain full control over their principal and can claim accrued interest separately or automatically on full withdrawal.

## Key Features

- **Principal Protection**: Withdraw original deposit anytime
- **Claimable Yield**: Interest accrues continuously, claim separately
- **Auto-Claim on Full Withdrawal**: Complete withdrawals automatically claim all interest
- **Proportional Distribution**: Yield distributed based on deposit amounts
- **RAY Precision**: 1e27 precision for zero yield loss (MakerDAO standard)
- **Automatic Parked Yield**: Auto-applies parked yield on first deposit
- **Role-Based Access Control**: Separate roles for different operations
- **Blacklist Support**: Simple compliance controls
- **Enhanced Security**: Overflow protection, reentrancy guards, pause mechanism

## Core Functions

### User Functions
```solidity
// Write functions
deposit(uint256 amount)                    // Deposit USDR
depositWithPermit(...)                     // Deposit with permit (gasless approval)
withdraw(uint256 amount)                   // Withdraw principal (auto-claims on full withdrawal)
claim()                                    // Claim all accrued interest

// Read functions
claimable(address user) → uint256          // View claimable interest amount
totalValue(address user) → uint256         // View total value (principal + claimable)
getUserInfo(address user) → (uint256 principal, uint256 claimable, uint256 total, uint256 lastIndex)
```

### Admin Functions
```solidity
// Yield distribution (yieldRedistributor only)
onYield(uint256 amount)                    // Distribute yield
applyParkedYield()                         // Apply previously parked yield

// Access control (owner only)
setYieldRedistributor(address who)         // Update yield redistributor
setTreasury(address who)                   // Update treasury address
setPauser(address who)                     // Update pauser address
setBlacklisted(address who, bool status)   // Manage blacklist

// Emergency controls (owner or pauser)
pause() / unpause()                        // Emergency stop/resume

// Treasury operations (owner only, when paused)
sweepSurplusToTreasury()                  // Sweep excess funds to treasury
emergencySweep(address token, address to, uint256 amount)  // Emergency token recovery

// Vault statistics
getVaultStats() → (uint256 totalPrincipal, uint256 claimReserve, uint256 parkedYield, uint256 globalIndex, uint256 pendingDelta, uint256 balance)
```

## How It Works

### Global Index Accounting
The vault uses a **global index pattern** for gas-efficient yield distribution:

1. **Global Index**: Tracks cumulative yield per unit deposited (RAY precision)
2. **User Index**: Records when user last settled
3. **Settlement Formula**: `owed = principal × (globalIndex - userIndex) / RAY`

### Pending Delta Accumulation
Small yield amounts are accumulated to prevent precision loss:
- **Problem**: Very small yields might round to zero delta
- **Solution**: `pendingDelta` accumulates small deltas until `>= 1e18` threshold
- **Result**: No yield is ever lost, even with tiny distributions

### Automatic Parked Yield Application
When yield arrives with no deposits (`totalPrincipal = 0`):
- Yield is "parked" until deposits exist
- **Automatically applied** when first user deposits
- Prevents first depositor from getting unfair yield advantage

### Role-Based Security
- **Owner**: Full administrative control, emergency functions
- **YieldRedistributor**: Can distribute yield, apply parked yield
- **Pauser**: Can pause/unpause for emergency response
- **Treasury**: Receives swept surplus funds

## Security Features

- **Funding Verification**: All yield functions verify actual token balance
- **Overflow Protection**: Safe arithmetic using `Math.mulDiv` for 512-bit precision
- **Complete Blacklist**: All user functions respect blacklist status
- **Reentrancy Protection**: All state-changing functions protected
- **Pause Mechanism**: Emergency stop for all operations
- **Permit Safety**: Graceful handling of tokens that don't support permit
- **Settlement Ordering**: Critical `_settle()` called before state changes
- **ETH Safety**: Contract rejects ETH to prevent accidental loss

## Examples

### Example 1: Basic User Flow
```solidity
// Alice deposits 1000 USDR
vault.deposit(1000e18);
// Result: principal[alice] = 1000, userIndex[alice] = 1e27

// 100 USDR yield is distributed
yieldRedistributor.transfer(address(vault), 100e18);
vault.onYield(100e18);
// Result: globalIndex increases proportionally

// Alice checks and claims her yield
uint256 claimable = vault.claimable(alice);  // Returns 100e18
vault.claim();
// Result: Alice receives 100 USDR, principal stays 1000
```

### Example 2: Multiple Users
```solidity
// Alice deposits 1000 USDR (25%), Bob deposits 3000 USDR (75%)
vault.deposit(1000e18);  // Alice
vault.deposit(3000e18);  // Bob

// 400 USDR yield arrives
vault.onYield(400e18);

// Proportional distribution:
vault.claimable(alice);  // Returns 100e18 (25% of 400)
vault.claimable(bob);    // Returns 300e18 (75% of 400)
```

### Example 3: Full Withdrawal (Auto-Claim)
```solidity
// Alice has 1000 principal + 50 claimable
vault.principal(alice);   // 1000e18
vault.claimable(alice);   // 50e18

// Full withdrawal automatically claims interest
vault.withdraw(1000e18);  
// Result: Alice receives 1050 USDR (1000 + 50)
```

### Example 4: Automatic Parked Yield
```solidity
// Yield arrives when no one has deposited
vault.onYield(500e18);    // Yield gets parked
vault.parkedYield();      // Returns 500e18

// Later, Alice deposits (auto-applies parked yield)
vault.deposit(1000e18);   
vault.claimable(alice);   // Returns 500e18 (automatically gets parked yield!)
```

### Example 5: Role Management
```solidity
// Owner sets up roles
vault.setYieldRedistributor(distributorAddress);
vault.setPauser(emergencyResponder);
vault.setTreasury(treasuryAddress);

// Emergency response
pauser.pause();           // Emergency stop
owner.sweepSurplusToTreasury();  // Move excess funds
pauser.unpause();         // Resume operations
```

## Integration

### For Yield Distributors
```solidity
// 1. Transfer yield to vault
USDR.transfer(vault, yieldAmount);

// 2. Notify vault
vault.onYield(yieldAmount);
```

### For Frontend
```solidity
// Get all user info in one call (gas efficient)
(uint256 principal, uint256 claimable, uint256 total, uint256 lastIndex) = vault.getUserInfo(user);

// Or individual calls
uint256 claimable = vault.claimable(user);           // Interest only
uint256 total = vault.totalValue(user);             // Principal + interest
uint256 deposited = vault.principal(user);          // Principal only
bool blocked = vault.isBlacklisted(user);           // Blacklist status

// Get vault statistics (including pendingDelta)
(uint256 tvl, uint256 reserves, uint256 parked, uint256 index, uint256 pending, uint256 balance) = vault.getVaultStats();
```

### For Permit-Enabled Tokens
```solidity
// Gasless deposit (if USDR supports permit)
try vault.depositWithPermit(amount, deadline, v, r, s) {
    // Success - no prior approval needed
} catch PermitFailed {
    // Fallback to regular approval + deposit
    usdr.approve(vault, amount);
    vault.deposit(amount);
}
```

## Error Conditions

### User Errors
- `ZeroAmount()`: Zero amount operations
- `InsufficientPrincipal()`: Withdrawing more than deposited  
- `NothingToClaim()`: No yield available to claim
- `AddressBlacklisted()`: Blacklisted address attempting operation

### Access Control Errors
- `NotYieldRedistributor()`: Unauthorized yield distribution
- `NotAuthorizedToPause()`: Unauthorized pause/unpause attempt
- `CanNotBeZeroAddress()`: Zero address provided where invalid

### System Errors
- `InsufficientFunding()`: Vault cannot fulfill claims/withdrawals
- `ArithmeticOverflow()`: Integer overflow in calculations
- `ContractNotPaused()`: Operation requires paused state
- `ExceedsSurplus()`: Amount exceeds available surplus
- `EthNotAccepted()`: Contract doesn't accept ETH
- `PermitFailed()`: Permit operation failed (token may not support it)

## Technical Notes

### Gas Efficiency
- **Yield Distribution**: ~200k gas regardless of user count
- **pendingDelta**: Prevents gas waste on tiny yield amounts
- **getUserInfo**: Inlined calculations avoid external calls

### Precision & Safety
- **RAY Precision**: 1e27 prevents rounding errors
- **Math.mulDiv**: 512-bit intermediate precision prevents overflows
- **Delta Accumulation**: No yield lost to rounding
- **Funding Invariant**: `USDR.balance >= claimReserve + parkedYield`

### Compatibility
- **ERC20**: Works with any standard ERC20 token
- **Permit**: Safely handles tokens with/without permit support
- **Upgradeable**: Owner can be transferred to governance/multisig

## Role Hierarchy

```
Owner (Full Control)
├── Set all role addresses
├── Emergency sweep operations
├── Blacklist management
└── Treasury operations

YieldRedistributor (Yield Operations)
├── Distribute yield via onYield()
└── Apply parked yield

Pauser (Emergency Response)
├── Pause contract operations
└── Unpause contract operations

Treasury (Fund Recipient)
└── Receives swept surplus funds
```

## Deployment Parameters

```solidity
constructor(
    address usdr,                    // USDR token contract
    address owner,                   // Initial owner (should be multisig)
    address yieldRedistributorAddr,  // Yield distribution contract
    address treasuryAddr,            // Treasury for surplus funds
    address pauserAddr               // Emergency pause authority
)
```

All addresses must be non-zero and carefully chosen for production deployment.