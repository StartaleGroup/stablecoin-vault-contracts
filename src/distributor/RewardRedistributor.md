# RewardRedistributor

## Overview

The **RewardRedistributor** is a core component of the USDR stablecoin ecosystem that manages the distribution of freshly minted USDR yield to eligible recipients. It pulls yield from the M0 extension (MYieldToOne), applies an optional fee to Startale, and allocates the remaining yield proportionally to two main vaults based on their share of the base USDR supply.

## Architecture

### Core Components

1. **USDR Extension (M0)**: Source of freshly minted yield via `claimYield()`
2. **EarnVault**: Checkbox OFF vault using index accounting (RAY precision)
3. **sUSDR Vault**: Checkbox ON ERC-4626 vault where donations increase PPS
4. **Treasury**: Recipient of fees and remainder yield

### Key Addresses

- `USDR_ADDRESS`: USDR token address implementing both IERC20 and IMYieldToOne interfaces (immutable)
- `treasury`: Treasury address (configurable)
- `earnVault`: EarnVault contract (configurable)
- `susdrVault`: sUSDR ERC-4626 vault contract (configurable)

### Interface Architecture

The RewardRedistributor uses a single USDR token address (`USDR_ADDRESS`) that implements both required interfaces:

- **IERC20 Interface**: Used for token transfers and supply queries
  - `IERC20(USDR_ADDRESS).totalSupply()` - Get total USDR supply
  - `IERC20(USDR_ADDRESS).safeTransfer()` - Transfer USDR tokens
  
- **IMYieldToOne Interface**: Used for yield operations
  - `IMYieldToOne(USDR_ADDRESS).claimYield()` - Mint fresh yield to contract
  - `IMYieldToOne(USDR_ADDRESS).yield()` - Preview pending yield

This design eliminates redundancy since both interfaces point to the same USDR token contract, while maintaining clear separation of concerns through explicit interface casting.

## Yield Distribution Algorithm

### Mathematical Formulas

The RewardRedistributor uses the following allocation formulas:

```solidity
// Base calculations
minted = IMYieldToOne(USDR_ADDRESS).claimYield()
feeToStartale = minted * fee_on_yield_bps / 10_000
net = minted - feeToStartale
S_base = IERC20(USDR_ADDRESS).totalSupply() - minted  // Supply BEFORE this mint

// TVL calculations
T_earn = earnVault.totalPrincipal()
T_yield = susdrVault.totalAssets()

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

1. **Claim Yield**: Call `IMYieldToOne(USDR_ADDRESS).claimYield()` to mint fresh yield of USDR
2. **Calculate Allocations**: Apply formulas with carry logic
3. **Transfer to Startale**: Send `feeToStartale + toStartaleExtra`
4. **Transfer to EarnVault**: Send `toEarn` amount first
5. **Call EarnVault.onYield()**: Trigger index update (funding invariant)
6. **Transfer to sUSDR Vault**: Send `toOn` amount (increases PPS)
7. **Update Carries**: Store remainder for next epoch
8. **Emit Event**: Log all distribution details

### Critical Ordering

The transfer→onYield ordering for EarnVault is **mandatory** to satisfy its funding invariant:
```
balance >= claimReserve + incomingYield
```

## Access Control & Security

### Roles

- **DEFAULT_ADMIN_ROLE**: Can update parameters, pause/unpause, manage roles
- **OPERATOR_ROLE**: Can call `distribute()` function (typically automated keeper)

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

Only `DEFAULT_ADMIN_ROLE` can update:
- Treasury address
- EarnVault address
- sUSDR vault address
- Fee on yield (within MAX_FEE_BPS limit)

## Events

### Distributed Event

```solidity
event Distributed(
    uint256 minted,          // Total USDR minted this epoch
    uint256 feeToStartale,   // Fee portion to Startale
    uint256 toEarnVault,     // Yield to EarnVault
    uint256 toSUSDRVault,    // Yield to sUSDR vault
    uint256 toStartaleExtra, // Remainder to Startale
    uint256 S_base,          // Base supply (before mint)
    uint256 T_earn,          // EarnVault TVL
    uint256 T_yield          // sUSDR vault TVL
);
```

### ParamsUpdated Event

```solidity
event ParamsUpdated(
    address startale,
    address earnVault,
    address susdrVault,
    uint16  fee_on_yield_bps
);
```

## Integration Points

### EarnVault Integration

- **TVL Source**: `earnVault.totalPrincipal()`
- **Yield Delivery**: Transfer → `earnVault.onYield(amount)`
- **Funding Invariant**: Must maintain sufficient balance for claims

### sUSDR Vault Integration

- **TVL Source**: `susdrVault.totalAssets()`
- **Yield Delivery**: Raw transfer (increases PPS)
- **ERC-4626 Standard**: Standard vault interface

### M0 Extension Integration

- **Yield Source**: `IMYieldToOne(USDR_ADDRESS).claimYield()`
- **Recipient Setup**: This contract must be set as `yieldRecipient`

## Invariants

### Conservation of Value
```
minted == feeToStartale + toEarnVault + toSUSDRVault + toStartaleExtra
```

### Correct Denominator
```
S_base == IERC20(USDR_ADDRESS).totalSupply() - minted
```

### Proportional Allocation (per epoch)
```
toEarnVault ≈ net * T_earn / S_base  (within rounding tolerance)
toSUSDRVault ≈ net * T_yield / S_base  (within rounding tolerance)
```

### Long-Run Fairness (across epochs)
```
|Σ(toEarnVault) - Σ(net * T_earn / S_base)| ≤ S_base - 1
|Σ(toSUSDRVault) - Σ(net * T_yield / S_base)| ≤ S_base - 1
```

### Post-Distribution State
```
IERC20(USDR_ADDRESS).balanceOf(address(this)) == 0  // No dust retention
```

## Usage Examples

### Basic Distribution

```solidity
// Automated keeper calls
rewardRedistributor.distribute();
```

### Parameter Update

```solidity
// Admin updates parameters
rewardRedistributor.setParams(
    newStartaleAddress,
    newEarnVaultAddress,
    newSUSDRVaultAddress,
    newFeeBps
);
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
// Note: Todo: USDR itself is MYieldToOne extension
1. Deploy USDR token contract (implements both IERC20 and IMYieldToOne)
2. Deploy EarnVault with proper initialization
3. Deploy sUSDR ERC-4626 vault
4. Set up Treasury address

### Initialization Steps
1. Deploy RewardRedistributor with USDR address and other parameters
2. Grant OPERATOR_ROLE to keeper/automation system
3. Set RewardRedistributor as yieldRecipient in USDR token contract
4. Configure fee parameters if needed
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

## Future Enhancements

### Upgrade Path
The contract uses standard OpenZeppelin patterns and could be made upgradeable using proxy patterns if needed. However, the current immutable design provides stronger security guarantees for the core yield distribution logic.
