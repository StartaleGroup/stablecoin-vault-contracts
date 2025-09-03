# EarnVault - Claimable Yield Vault

## Overview

Users deposit USDR tokens and earn claimable yield over time. Users maintain full control over their principal and can claim accrued interest separately or automatically on full withdrawal.

## Key Features

- **Principal Protection**: Withdraw original deposit anytime
- **Claimable Yield**: Interest accrues continuously, claim separately
- **Auto-Claim on Full Withdrawal**: Complete withdrawals automatically claim all interest
- **Proportional Distribution**: Yield distributed based on deposit amounts
- **RAY Precision**: 1e27 precision for zero yield loss (MakerDAO standard)
- **Blacklist Support**: Optional compliance controls

## Core Functions

### User Functions
```solidity
// Write functions
deposit(uint256 amount)                    // Deposit USDR
withdraw(uint256 amount)                   // Withdraw principal (auto-claims on full withdrawal)
claim()                                    // Claim all accrued interest
claimTo(address to)                        // Claim interest to specific address

// Read functions
claimable(address user) → uint256          // View claimable interest amount
totalValue(address user) → uint256         // View total value (principal + claimable)
getUserInfo(address user) → (uint256 principal, uint256 claimable, uint256 total, uint256 lastIndex)
```

### Admin Functions
```solidity
// Yield distribution
onYield(uint256 amount)                    // Distribute yield (distributor only)
applyParkedYield()                         // Apply previously parked yield (distributor only)

// Access control
setBlacklisted(address who, bool status)   // Manage blacklist (owner only)
pause() / unpause()                        // Emergency controls (owner only)

// Vault statistics
getVaultStats() → (uint256 totalPrincipal, uint256 claimReserve, uint256 parkedYield, uint256 globalIndex, uint256 balance)
```

## How It Works

### Global Index Accounting
The vault uses a **global index pattern** for gas-efficient yield distribution:

1. **Global Index**: Tracks cumulative yield per unit deposited (RAY precision)
2. **User Index**: Records when user last settled
3. **Settlement Formula**: `owed = principal × (globalIndex - userIndex) / RAY`

### Yield Parking
When yield arrives with no deposits (`totalPrincipal = 0`):
- Yield is "parked" until deposits exist
- Use `applyParkedYield()` to distribute to depositors
- Prevents first depositor from getting free yield

### Security Features
- **Funding Verification**: All yield functions verify actual token balance
- **Overflow Protection**: Safe arithmetic on all index operations  
- **Complete Blacklist**: All user functions respect blacklist
- **Reentrancy Protection**: All state-changing functions protected
- **Pause Mechanism**: Emergency stop for all operations

## Examples

### Example 1: Basic User Flow
```solidity
// Alice deposits 1000 USDR
vault.deposit(1000e18);
// Result: principal[alice] = 1000, userIndex[alice] = 1e27

// 100 USDR yield is distributed
distributor.transfer(address(vault), 100e18);
vault.onYield(100e18);
// Result: globalIndex = 1.1e27

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

### Example 4: Yield Parking
```solidity
// Yield arrives when no one has deposited
vault.onYield(500e18);    // Yield gets parked
vault.parkedYield();      // Returns 500e18

// Later, Alice deposits
vault.deposit(1000e18);   
vault.claimable(alice);   // Returns 0 (doesn't get parked yield)

// Admin applies parked yield
vault.applyParkedYield();
vault.claimable(alice);   // Returns 500e18 (gets the parked yield)
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

// Get vault statistics
(uint256 tvl, uint256 reserves, uint256 parked, uint256 index, uint256 balance) = vault.getVaultStats();
```

## Error Conditions

- `ZeroAmount()`: Zero amount operations
- `InsufficientPrincipal()`: Withdrawing more than deposited  
- `NothingToClaim()`: No yield available to claim
- `AddressBlacklisted()`: Blacklisted address attempting deposit
- `InvariantFunding()`: Insufficient vault balance
- `ArithmeticOverflow()`: Integer overflow in calculations

## Technical Notes

- **Gas Cost**: ~200k for yield distribution regardless of user count
- **Compatibility**: ERC20-compliant M^0 USDR token required