# RewardRedistributor

## Overview

The **RewardRedistributor** is a core component of the USDSC stablecoin ecosystem that manages the distribution of freshly minted USDSC yield to eligible recipients. It pulls yield from the M0 extension (MYieldToOne), applies an optional fee to Startale, and allocates the remaining yield proportionally to two main vaults based on their share of the base USDSC supply.

> **Note**: This contract is **non-upgradeable** (immutable implementation). All logic and parameters must be carefully verified before deployment as they cannot be changed afterward.

## Architecture

### Core Components

1. **USDSC Extension (M0)**: Source of freshly minted yield via `claimYield()`
2. **EarnVault**: Checkbox OFF vault using index accounting (RAY precision)
3. **sUSDSC Vault**: Checkbox ON ERC-4626 vault where donations increase PPS
4. **Treasury**: Recipient of fees and remainder yield

### Key Addresses

- `USDSC_ADDRESS`: USDSC token address implementing both IERC20 and IMYieldToOne interfaces (immutable)
- `treasury`: Treasury address (configurable)
- `earnVault`: EarnVault contract (configurable)
- `susdscVault`: sUSDSC ERC-4626 vault contract (configurable)

### Interface Architecture

The RewardRedistributor uses a single USDSC token address (`USDSC_ADDRESS`) that implements both required interfaces:

- **IERC20 Interface**: Used for token transfers and supply queries
  - `IERC20(USDSC_ADDRESS).totalSupply()` - Get total USDSC supply
  - `IERC20(USDSC_ADDRESS).safeTransfer()` - Transfer USDSC tokens
  
- **IMYieldToOne Interface**: Used for yield operations
  - `IMYieldToOne(USDSC_ADDRESS).claimYield()` - Mint fresh yield to contract
  - `IMYieldToOne(USDSC_ADDRESS).yield()` - Preview pending yield that could be minted in USDSC

This design eliminates redundancy since both interfaces point to the same USDSC token contract, while maintaining clear separation of concerns through explicit interface casting.

## Preview Functions

The RewardRedistributor provides three preview functions for different use cases:

### previewSplit(uint256 minted)
- **Purpose**: Preview allocation for a hypothetical yield amount
- **Parameters**: `minted` - hypothetical yield amount to allocate
- **S_base Calculation**: Uses current total supply (since `minted` is hypothetical)
- **Carry Logic**: No carries (pure mathematical preview)
- **Use Case**: "What if we had X amount of yield to distribute?"

### previewSplitCurrent()
- **Purpose**: Preview allocation using current pending yield from extension
- **Parameters**: None (reads `IMYieldToOne(USDSC_ADDRESS).yield()`)
- **S_base Calculation**: Uses current total supply (since yield is pending, not yet minted)
- **Carry Logic**: No carries (pure mathematical preview)
- **Use Case**: "What would the current pending yield allocation look like?"

### previewDistribute()
- **Purpose**: Exact dry-run of actual `distribute()` function
- **Parameters**: None (reads `IMYieldToOne(USDSC_ADDRESS).yield()`)
- **S_base Calculation**: Uses current total supply (since yield is pending, not yet minted)
- **Carry Logic**: Includes carries (exact simulation of real distribution)
- **Use Case**: "What would happen if we called `distribute()` right now?"

### Key Distinction: S_base Calculation

All preview functions now use consistent `S_base` calculation:

```solidity
// All preview functions (previewSplit, previewSplitCurrent, previewDistribute)
S_base = IERC20(USDSC_ADDRESS).totalSupply()  // Current supply

// Distribution functions (distribute)  
S_base = IERC20(USDSC_ADDRESS).totalSupply() - minted  // Supply before mint
```

This distinction is important because:
- **Preview functions** deal with pending/hypothetical yield that hasn't been minted yet
- **Distribution functions** deal with actual minted yield that increases total supply

## Yield Distribution Algorithm

### Mathematical Formulas

The RewardRedistributor uses the following allocation formulas:

```solidity
// Base calculations
minted = IMYieldToOne(USDSC_ADDRESS).claimYield()
feeToStartale = minted * fee_on_yield_bps / 10_000
net = minted - feeToStartale

// S_base calculation depends on context:
// - For actual distribution: S_base = totalSupply() - minted (supply BEFORE mint)
// - For preview functions: S_base = totalSupply() (current supply, since yield is pending)

S_base = IERC20(USDSC_ADDRESS).totalSupply() - minted  // For actual distribution

// TVL calculations
T_earn = earnVault.totalPrincipal()
T_yield = susdscVault.totalAssets()

// Basic allocation (without carry)
toEarn_basic = (net * T_earn) / S_base
toOn_basic = (net * T_yield) / S_base
toStartaleExtra = net - (toEarn_basic + toOn_basic)
```

### Carry Logic for Long-Run Fairness

To eliminate systematic rounding bias over multiple epochs, the contract maintains carry accumulators:

```solidity
// With carry logic
numEarn = net * T_earn + carryEarn
toEarn = numEarn / S_base
carryEarn = numEarn % S_base  // Updated for next epoch

// yield means 4626 vault
numYield = net * T_yield + carryYield
toYield = numYield / S_base
carryYield = numYield % S_base  // Updated for next epoch

toStartaleExtra = net - (toEarn + toYield)
```

### Edge Cases

1. **Zero Base Supply** (`S_base == 0`): All net yield goes to Startale
2. **Zero TVL**: If a vault has zero TVL, its allocation is zero
3. **Insufficient Yield**: Minimum viable amounts are handled gracefully

## Distribution Process

### Step-by-Step Flow

1. **Claim Yield**: Call `IMYieldToOne(USDSC_ADDRESS).claimYield()` to mint fresh yield of USDSC
2. **Calculate Allocations**: Apply formulas with carry logic
3. **Transfer to Startale**: Send `feeToStartale + toStartaleExtra`
4. **Transfer to EarnVault**: Send `toEarn` amount first
5. **Call EarnVault.onYield()**: Trigger index update (funding invariant)
6. **Transfer to sUSDSC Vault**: Send `toOn` amount (increases PPS)
7. **Update Carries**: Store remainder for next epoch
8. **Emit Event**: Log all distribution details

### Critical Ordering

The transfer→onYield ordering for EarnVault is **mandatory** to satisfy its funding invariant:
```
balance >= claimReserve + incomingYield
```

## Access Control & Security

### Roles

- **DEFAULT_ADMIN_ROLE**: Granted to admin address in constructor. Can update parameters, pause/unpause, manage roles
- **OPERATOR_ROLE**: Granted to keeper address in constructor. Can call `distribute()` function (typically automated keeper system)

### Security Features

- **Pausable**: Admin can pause distributions during emergencies
- **ReentrancyGuard**: Prevents reentrancy attacks
- **Access Control**: Role-based permissions
- **Parameter Validation**: Fee caps and address validation

## Configuration

### Fee Management

```solidity
uint16 public fee_on_yield_bps = 0;        // Default: 0%
uint16 public constant MAX_FEE_BPS = 2000; // Maximum: 20%
```

### Parameter Updates

Only `DEFAULT_ADMIN_ROLE` can update parameters via separate setter functions:

- `setTreasury(address)`: Update Treasury address
- `setEarnVault(IEarnVault)`: Update EarnVault address
- `setSusdscVault(IERC4626)`: Update sUSDSC vault address
- `setFeeBps(uint16)`: Update fee on yield (within MAX_FEE_BPS limit)

Each setter function only updates its specific parameter, allowing gas-efficient updates without overwriting other values.

## Events

### Distributed Event

```solidity
event Distributed(
    uint256 minted,          // Total USDSC minted this epoch
    uint256 feeToStartale,   // Fee portion to Startale
    uint256 toEarnVault,     // Yield to EarnVault
    uint256 toSUSDSCVault,    // Yield to sUSDSC vault
    uint256 toStartaleExtra, // Remainder to Startale
    uint256 S_base,          // Base supply (before mint)
    uint256 T_earn,          // EarnVault TVL
    uint256 T_yield          // sUSDSC vault TVL
);
```

### Parameter Update Events

```solidity
event TreasuryUpdated(address treasury);
event EarnVaultUpdated(address earnVault);
event SusdscVaultUpdated(address susdscVault);
event FeeUpdated(uint16 fee_on_yield_bps);
```

Each setter function emits its corresponding event, making it easy to track individual parameter changes.

## Integration Points

### EarnVault Integration

- **TVL Source**: `earnVault.totalPrincipal()`
- **Yield Delivery**: Transfer → `earnVault.onYield(amount)`
- **Funding Invariant**: Must maintain sufficient balance for claims

### sUSDSC Vault Integration

- **TVL Source**: `susdscVault.totalAssets()`
- **Yield Delivery**: Raw transfer (increases PPS)
- **ERC-4626 Standard**: Standard vault interface

### M0 Extension Integration

- **Yield Source**: `IMYieldToOne(USDSC_ADDRESS).claimYield()`
- **Recipient Setup**: This contract must be set as `yieldRecipient`

## Invariants

### Conservation of Value
```
minted == feeToStartale + toEarnVault + toSUSDSCVault + toStartaleExtra
```

### Correct Denominator
```
// For actual distribution functions (distribute)
S_base == IERC20(USDSC_ADDRESS).totalSupply() - minted

// For all preview functions (previewSplit, previewSplitCurrent, previewDistribute)  
S_base == IERC20(USDSC_ADDRESS).totalSupply()  // Current supply
```

### Proportional Allocation (per epoch)
```
toEarnVault ≈ net * T_earn / S_base  (within rounding tolerance)
toSUSDSCVault ≈ net * T_yield / S_base  (within rounding tolerance)
```

### Long-Run Fairness (across epochs)
```
|Σ(toEarnVault) - Σ(net * T_earn / S_base)| ≤ S_base - 1
|Σ(toSUSDSCVault) - Σ(net * T_yield / S_base)| ≤ S_base - 1
```

### Post-Distribution State
```
IERC20(USDSC_ADDRESS).balanceOf(address(this)) == 0  // No dust retention
```


## Usage Examples

### Preview Functions Usage

```solidity
// Preview hypothetical yield allocation
(uint256 feeToStartale, uint256 toEarn, uint256 toOn, uint256 toStartaleExtra, uint256 S_base, uint256 T_earn, uint256 T_yield) = 
    rewardRedistributor.previewSplit(1000e6);  // 1000 USDSC hypothetical yield

// Preview current pending yield allocation  
(uint256 couldBeMinted, uint256 feeToStartale, uint256 toEarn, uint256 toOn, uint256 toStartaleExtra, uint256 S_base, uint256 T_earn, uint256 T_yield) = 
    rewardRedistributor.previewSplitCurrent();

// Preview exact distribution (dry-run)
(uint256 couldBeMinted, uint256 feeToStartale, uint256 toEarn, uint256 toOn, uint256 toStartaleExtra, uint256 S_base, uint256 T_earn, uint256 T_yield) = 
    rewardRedistributor.previewDistribute();
```

### Basic Distribution

```solidity
// Automated keeper calls
rewardRedistributor.distribute();
```

### Parameter Updates

```solidity
// Admin updates treasury address
rewardRedistributor.setTreasury(newTreasuryAddress);

// Admin updates EarnVault address
rewardRedistributor.setEarnVault(newEarnVaultAddress);

// Admin updates sUSDSC vault address
rewardRedistributor.setSusdscVault(newSUSDSCVaultAddress);

// Admin updates fee on yield
rewardRedistributor.setFeeBps(newFeeBps);
```

### Emergency Controls

```solidity
// Pause distributions
rewardRedistributor.pause();

// Resume distributions
rewardRedistributor.unpause();
```

## Testing Coverage

The RewardRedistributor has comprehensive test coverage including:

### Unit Tests (21 tests)
- Mathematical formulas and carry logic
- Access control and pause functionality
- Edge cases and error conditions
- Event emission and parameter validation

### Integration Tests (12 tests)
- Real vault interactions and ordering
- User deposit/withdrawal flows
- Multiple distribution scenarios
- System invariant preservation
- Large-scale and edge case scenarios

### Key Test Scenarios
- **Conservation**: All minted yield is properly allocated
- **Proportionality**: Allocations match expected ratios
- **Fairness**: Carry logic eliminates long-term bias
- **Ordering**: EarnVault funding invariant maintained
- **User Experience**: Proper yield accrual and withdrawal
- **System Resilience**: Continued operation after user actions

## Deployment Considerations

### Prerequisites
1. Deploy USDSC token contract (implements both IERC20 and IMYieldToOne)
2. Deploy EarnVault with proper initialization
3. Deploy sUSDSC ERC-4626 vault
4. Set up Treasury address

### Initialization Steps
1. Deploy RewardRedistributor with USDSC address, vault addresses, admin address, and keeper address (keeper receives OPERATOR_ROLE)
2. Set RewardRedistributor as yieldRecipient in USDSC token contract
3. Set RewardRedistributor as yieldRedistributor in EarnVault
4. Configure fee parameters if needed using `setFeeBps()`
5. Verify all integrations work correctly

### Operational Requirements
- Automated keeper system with OPERATOR_ROLE
- Monitoring for failed distributions
- Admin access for parameter updates and emergency controls
- Regular verification of system invariants

## Security Considerations

### Potential Risks
- **Oracle Dependency**: TVL calculations depend on vault state
- **Keeper Reliability**: Distribution frequency affects user experience
- **Parameter Changes**: Admin key security is critical
- **Integration Failures**: Vault contract upgrades could break compatibility

### Mitigation Strategies
- Comprehensive testing of all integration points
- Emergency pause functionality
- Role-based access control with multi-sig admin
- Regular monitoring and alerting
- Gradual parameter changes with community oversight

## Recent Fixes

### External claimYield() Handling Fix

**Fix**: Modified `distribute()` to use `gross = balanceBefore + minted` approach. This elegantly handles both normal flow and external `claimYield()` calls in a single code path, ensuring all yield is always distributed.

**Impact**: Ensures yield is always distributed regardless of whether `claimYield()` was called externally or by the keeper.

### previewDistribute() S_base Calculation Fix

**Fix**: Changed `previewDistribute()` to use `preMint = true`, making it consistent with other preview functions. Now all preview functions use `S_base = totalSupply()` (current supply), while only the actual `distribute()` function uses `S_base = totalSupply() - minted` (supply before mint).

Ensures that `previewDistribute()` is a true dry-run of `distribute()`, providing accurate predictions of distribution behavior.
