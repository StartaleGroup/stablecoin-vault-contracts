# EarnVault - Claimable Yield Vault Documentation

## Overview

The **EarnVault** is a smart contract that allows users to deposit USDR tokens and earn claimable yield over time. Users maintain full control over their principal and can claim accrued interest separately or automatically on full withdrawal.

## Key Features

- **Principal Protection**: Users can withdraw their original deposit anytime
- **Claimable Yield**: Interest accrues continuously and can be claimed separately
- **Auto-Claim on Full Withdrawal**: Complete withdrawals automatically claim all accrued interest
- **Proportional Distribution**: Yield is distributed proportionally based on deposit amounts
- **Global Index Accounting**: Efficient gas usage through mathematical index-based calculations
- **Yield Parking**: Handles yield distribution even when no deposits exist

## Architecture

### State Variables

```solidity
// Core accounting
uint256 public totalPrincipal;       // Sum of all user deposits
uint256 public globalIndex = 1e18;   // Global yield index (1e18 precision)
uint256 public claimReserve;         // Total assets available for claims/withdrawals
uint256 public parkedYield;          // Yield received when no deposits exist

// User state mappings
mapping(address => uint256) public principal;   // User's deposited amount
mapping(address => uint256) public userIndex;  // User's last settled index
mapping(address => uint256) public accrued;    // User's claimable interest
```

### Global Index Mechanism

The vault uses a **global index pattern** for efficient yield distribution:

1. **Global Index**: Tracks cumulative yield per unit deposited
2. **User Index**: Records the global index when user last settled
3. **Settlement**: Calculates owed yield as `principal × (globalIndex - userIndex)`

## Core Functions

### Deposit Functions

#### `deposit(uint256 amount)`
Deposits USDR tokens into the vault.

**Process:**
1. Settles any pending yield for the user
2. Transfers USDR from user to vault
3. Updates user's principal and total principal
4. Adds amount to claim reserve (1:1 backing)

#### `depositWithPermit(...)`
Same as deposit but uses EIP-2612 permit for gasless approvals.

### Withdrawal Functions

#### `withdraw(uint256 amount)`
Withdraws principal (and auto-claims interest on full withdrawal).

**Partial Withdrawal:**
- Withdraws specified amount of principal
- Interest remains claimable separately

**Full Withdrawal (amount == user's total principal):**
- Withdraws all principal
- **Automatically claims all accrued interest**
- User receives `principal + interest` in one transaction

### Claim Functions

#### `claim()`
Claims all accrued interest to `msg.sender`.

#### `claimTo(address to)`
Claims all accrued interest to specified address.

### Yield Distribution

#### `onYield(uint256 amount)`
Called by authorized distributor after transferring yield to the vault.

**With Active Deposits:**
```solidity
// Calculate index increase
uint256 delta = (amount * 1e18) / totalPrincipal;
globalIndex += delta;
claimReserve += amount;
```

**No Active Deposits (Parking):**
```solidity
// Park yield until deposits exist
claimReserve += amount;
// globalIndex remains unchanged
```

#### `applyParkedYield()`
Applies previously parked yield once deposits exist.

## Mathematical Examples

### Example 1: Basic Yield Distribution

**Setup:**
- Alice deposits 1,000 USDR
- `totalPrincipal = 1,000`
- `globalIndex = 1e18`
- `userIndex[Alice] = 1e18`

**Yield Event:**
- 100 USDR yield arrives
- `delta = (100 * 1e18) / 1,000 = 0.1e18`
- `globalIndex = 1e18 + 0.1e18 = 1.1e18`

**Alice's Settlement:**
```solidity
owed = (1,000 * (1.1e18 - 1e18)) / 1e18 = 100 USDR
accrued[Alice] += 100
userIndex[Alice] = 1.1e18
```

**Result:** Alice has 100 USDR claimable

### Example 2: Proportional Distribution

**Setup:**
- Alice deposits 1,000 USDR (25% of total)
- Bob deposits 3,000 USDR (75% of total)
- `totalPrincipal = 4,000`

**Yield Event:**
- 400 USDR yield arrives
- `delta = (400 * 1e18) / 4,000 = 0.1e18`
- `globalIndex = 1e18 + 0.1e18 = 1.1e18`

**Settlement:**
- **Alice:** `(1,000 * 0.1e18) / 1e18 = 100 USDR` (25% of yield)
- **Bob:** `(3,000 * 0.1e18) / 1e18 = 300 USDR` (75% of yield)

**Result:** Yield distributed proportionally to deposit amounts

### Example 3: Dynamic Principal Changes

**Timeline:**

**Week 1:**
- Alice deposits 1,000 USDR
- `principal[Alice] = 1,000`, `userIndex[Alice] = 1e18`

**Week 1 Yield:**
- 100 USDR yield on 1,000 total
- `globalIndex = 1.1e18`
- Alice has 100 USDR claimable (not yet settled)

**Week 2 - Alice Deposits More:**
```solidity
// _settle() is called first:
owed = (1,000 * (1.1e18 - 1e18)) / 1e18 = 100 USDR
accrued[Alice] = 100  // Previous yield credited
userIndex[Alice] = 1.1e18  // Index updated

// Then deposit continues:
principal[Alice] = 1,000 + 1,000 = 2,000
```

**Week 2 Yield:**
- 200 USDR yield on 2,000 total
- `globalIndex = 1.1e18 + 0.1e18 = 1.2e18`

**Alice's New Claimable:**
```solidity
settled = 100  // From week 1
new = (2,000 * (1.2e18 - 1.1e18)) / 1e18 = 200 USDR
total = 100 + 200 = 300 USDR
```

## User Journey Examples

### Journey 1: Simple Deposit → Yield → Claim

```solidity
// 1. Alice deposits 1,000 USDR
vault.deposit(1000e18);
// principal[Alice] = 1000, userIndex[Alice] = 1e18

// 2. 100 USDR yield distributed
// globalIndex becomes 1.1e18

// 3. Alice checks claimable
vault.claimable(Alice); // Returns 100e18

// 4. Alice claims
vault.claim();
// Alice receives 100 USDR, accrued[Alice] = 0
```

### Journey 2: Multiple Users with Different Timings

```solidity
// 1. Alice deposits early
vault.deposit(1000e18);  // Alice: 1000 USDR

// 2. First yield (Alice gets all)
// 100 USDR yield → Alice gets 100 USDR claimable

// 3. Bob joins later
vault.deposit(1000e18);  // Bob: 1000 USDR, total: 2000

// 4. Second yield (Alice and Bob split 50/50)
// 200 USDR yield → Alice gets +100, Bob gets +100
// Alice total: 200 USDR, Bob total: 100 USDR
```

### Journey 3: Full Withdrawal with Auto-Claim

```solidity
// 1. Setup: Alice has 1000 principal + 150 claimable

// 2. Alice withdraws all principal
vault.withdraw(1000e18);

// Result: Alice receives 1150 USDR (1000 + 150)
// Events: Withdraw(1000) + InterestClaimed(150)
```

## Yield Parking Example

**Scenario:** Yield arrives when no one has deposited

```solidity
// 1. No deposits exist (totalPrincipal = 0)

// 2. 500 USDR yield arrives
vault.onYield(500e18);
// globalIndex remains 1e18 (no change)
// claimReserve += 500 (yield is parked)

// 3. Alice deposits 1000 USDR later
vault.deposit(1000e18);
// Alice gets no immediate benefit from parked yield
// claimReserve = 500 + 1000 = 1500

// 4. Apply parked yield (optional)
vault.applyParkedYield();
// globalIndex = 1e18 + (500 * 1e18) / 1000 = 1.5e18
// Alice now has 500 USDR claimable
```

## Gas Optimization

The global index pattern provides significant gas savings:

- **O(1) yield distribution**: Single storage update regardless of user count
- **Lazy settlement**: Users only pay gas when they interact
- **Batch operations**: Multiple yield events update same storage slot

## Security Features

### Access Control
- **Owner**: Can pause, set distributor, emergency sweep
- **Distributor**: Can call `onYield()` and `applyParkedYield()`
- **Users**: Can only interact with their own deposits/claims

### Invariant Protection
```solidity
// Funding invariant
USDR.balanceOf(vault) >= claimReserve + parkedYield
```

### Pause Mechanism
- Owner can pause all user operations during emergencies
- Admin functions remain available for recovery

## Events

```solidity
event Deposit(address indexed user, uint256 amount);
event Withdraw(address indexed user, uint256 amount);
event InterestClaimed(address indexed user, uint256 amount);
event YieldIndexed(uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
event YieldParked(uint256 amount, uint256 totalParked);
```

## Error Conditions

- `ZeroAmount()`: Attempting operations with zero amounts
- `InsufficientPrincipal()`: Withdrawing more than deposited
- `NothingToClaim()`: Claiming when no yield is available
- `NotDistributor()`: Unauthorized yield distribution calls
- `InvariantFunding()`: Insufficient vault balance for operations

## Integration Guide

### For Distributors

```solidity
// 1. Transfer yield to vault
USDR.transfer(vault, yieldAmount);

// 2. Notify vault of yield
vault.onYield(yieldAmount);
```

### For Frontend Integration

```solidity
// Check user's claimable amount
uint256 claimable = vault.claimable(user);

// Check user's principal
uint256 deposited = vault.principal(user);

// Check if user has settled recent yield
uint256 userLastIndex = vault.userIndex(user);
uint256 currentIndex = vault.globalIndex();
bool hasUnsettledYield = currentIndex > userLastIndex && deposited > 0;
```

## Comparison with Traditional Vaults

| Feature | EarnVault | Traditional Vault |
|---------|-----------|-------------------|
| **Principal Control** | ✅ Withdraw anytime | ❌ Often locked |
| **Yield Access** | ✅ Claim separately | ❌ Compound only |
| **Gas Efficiency** | ✅ O(1) distribution | ❌ O(n) loops |
| **Flexibility** | ✅ Partial operations | ❌ All-or-nothing |
| **Auto-compound** | ❌ Manual claims | ✅ Automatic |

## Best Practices

### For Users
1. **Monitor claimable**: Check `claimable()` regularly
2. **Gas optimization**: Batch operations when possible
3. **Full withdrawals**: Use for automatic interest claiming

### For Integrators
1. **Settlement aware**: UI should reflect unsettled yield
2. **Event monitoring**: Track user activities via events
3. **Error handling**: Handle all custom errors gracefully

### For Distributors
1. **Funding first**: Always transfer before calling `onYield()`
2. **Batch yields**: Combine multiple distributions when possible
3. **Parking awareness**: Use `applyParkedYield()` when appropriate

## Conclusion

The EarnVault provides a flexible, gas-efficient solution for yield-bearing deposits with user-controlled principal and claimable interest. Its global index mechanism ensures fair distribution while maintaining excellent performance characteristics even with large user bases.