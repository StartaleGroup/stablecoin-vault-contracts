# EarnVaultUpgradeable - Upgradeable Claimable Yield Vault with Boost Rewards

## Overview

The `EarnVaultUpgradeable` is an upgradeable version of the EarnVault that maintains all core functionality while enabling seamless upgrades through OpenZeppelin's transparent proxy pattern. This allows for future enhancements, bug fixes, and feature additions without disrupting existing user funds or state.

## Key Features

All features from the base EarnVault plus:

- **Upgradeable Architecture**: Transparent proxy pattern with ProxyAdmin control
- **State Preservation**: All user funds, balances, and configurations preserved across upgrades
- **Version Management**: Support for V1, V2, V3+ upgrade paths with initialization
- **ETH Safety**: Explicit ETH rejection with owner-controlled recovery via `sweepNative`
- **Re-initialization Protection**: Prevents accidental re-initialization after upgrades
- **Comprehensive Testing**: Extensive upgrade testing covering all scenarios

## Architecture

### Proxy Pattern Implementation

```solidity
// Deployment structure
TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
    implementation,    // Current implementation contract
    admin,            // ProxyAdmin owner
    initData          // Initialization data
);

ProxyAdmin proxyAdmin = new ProxyAdmin();
```

### Storage Layout

The contract uses **ERC7201 namespaced storage** to prevent storage collisions:

```solidity
// Base storage (V1)
bytes32 private constant EARN_VAULT_STORAGE_LOCATION = 
    0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;

// V2 storage extension
bytes32 private constant EARN_VAULT_V2_STORAGE_LOCATION = 
    0x234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1;

// V3 storage extension  
bytes32 private constant EARN_VAULT_V3_STORAGE_LOCATION = 
    0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
```

## Upgrade Process

### V1 → V2 Upgrade Example

```solidity
// Deploy V2 implementation
EarnVaultV2 v2Impl = new EarnVaultV2();

// Upgrade with initialization
proxyAdmin.upgradeAndCall(
    ITransparentUpgradeableProxy(address(proxy)),
    address(v2Impl),
    abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
);
```

### V2 → V3 Upgrade Example

```solidity
// Deploy V3 implementation
EarnVaultV3 v3Impl = new EarnVaultV3();

// Upgrade with initialization
proxyAdmin.upgradeAndCall(
    ITransparentUpgradeableProxy(address(proxy)),
    address(v3Impl),
    abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
);
```

## Version-Specific Features

### V1 (Base EarnVaultUpgradeable)
- Core yield vault functionality
- Boost rewards system
- All base features from EarnVault

### V2 (EarnVaultV2)
- **Emergency Yield Multiplier**: Configurable yield multiplier for emergency scenarios
- **Emergency Mode**: Toggle for emergency operations
- **Backward Compatibility**: All V1 functionality preserved

```solidity
// V2 specific functions
function getEmergencyYieldMultiplier() external view returns (uint256);
function isEmergencyModeActive() external view returns (bool);
function setEmergencyYieldMultiplier(uint256 multiplier) external onlyOwner;
function setEmergencyMode(bool active) external onlyOwner;
```

### V3 (EarnVaultV3)
- **Performance Fees**: Configurable performance fee collection
- **Management Fees**: Ongoing management fee system
- **Auto-Compounding**: Automatic yield reinvestment
- **Fee Collection**: Automatic fee transfer to treasury
- **Backward Compatibility**: All V1 and V2 functionality preserved

```solidity
// V3 specific functions
function getPerformanceFeeRate() external view returns (uint256);
function getManagementFeeRate() external view returns (uint256);
function isAutoCompoundEnabled() external view returns (bool);
function executeAutoCompound(address user) external;
function setPerformanceFeeRate(uint256 rate) external onlyOwner;
function setManagementFeeRate(uint256 rate) external onlyOwner;
function setAutoCompoundEnabled(bool enabled) external onlyOwner;
```

## Access Control & Administration

### Proxy Administration

```solidity
// ProxyAdmin controls upgrades
ProxyAdmin proxyAdmin = new ProxyAdmin();

// Only ProxyAdmin owner can upgrade
proxyAdmin.upgradeAndCall(proxy, newImplementation, initData);
```

### Role Hierarchy

```
ProxyAdmin Owner (Upgrade Control)
├── Upgrade implementation contracts
├── Transfer ProxyAdmin ownership
└── Delegate to vault owner for vault operations

Vault Owner (Vault Administration)
├── Set yield redistributor, treasury, pauser
├── Manage blacklist
├── Emergency operations (when paused)
├── Sweep native ETH via sweepNative()
└── V2/V3 specific configurations

Yield Redistributor (Yield Operations)
├── Distribute yield via onYield()
├── Distribute boost rewards via onBoostReward()
└── Transfer to treasury

Pauser (Emergency Response)
├── Pause contract operations
└── Unpause contract operations
```

## ETH Safety & Recovery

### ETH Rejection

The contract explicitly rejects ETH transfers to prevent accidental loss:

```solidity
receive() external payable {
    revert EthNotAccepted();
}

fallback() external payable {
    revert EthNotAccepted();
}
```

### ETH Recovery

Owner can recover accidentally sent ETH (e.g., via `selfdestruct`):

```solidity
function sweepNative(address payable to, uint256 amount) external onlyOwner {
    if (to == address(0)) revert CanNotBeZeroAddress();
    
    (bool success,) = to.call{value: amount}("");
    if (!success) revert SweepFailed();
    
    emit NativeSwept(to, amount);
}
```

### ETH Safety Scenarios

1. **Direct ETH Transfer**: Reverts with `EthNotAccepted()`
2. **ETH via `receive()`**: Reverts with `EthNotAccepted()`
3. **ETH via `fallback()`**: Reverts with `EthNotAccepted()`
4. **ETH via `selfdestruct`**: ETH accumulates, recoverable via `sweepNative()`

## Initialization & Re-initialization Protection

### Initialization Process

```solidity
// V1 initialization
function initialize(
    address usdsc,
    address owner,
    address yieldRedistributor,
    address treasury,
    address pauser
) public initializer {
    // Initialize base contract
}

// V2 initialization (reinitializer(2))
function initializeV2() public reinitializer(2) {
    // Set V2 defaults
    emergencyYieldMultiplier = 10000;
    emergencyMode = false;
}

// V3 initialization (reinitializer(3))
function initializeV3() public reinitializer(3) {
    // Set V3 defaults
    performanceFeeRate = 200;
    managementFeeRate = 50;
    autoCompoundEnabled = false;
}
```

### Re-initialization Protection

OpenZeppelin's `reinitializer` modifier prevents accidental re-initialization:

```solidity
// This will revert with InvalidInitialization()
vaultV2.initializeV2(); // Already initialized, cannot re-initialize
```

## State Preservation Across Upgrades

### Core State Preserved

All user and vault state is preserved across upgrades:

```solidity
// User state
mapping(address => uint256) public principal;           // User deposits
mapping(address => uint256) public accrued;             // Accrued yield
mapping(address => uint256) public userIndex;           // Last settlement index
mapping(address => bool) public isBlacklisted;          // Blacklist status

// Vault state
uint256 public totalPrincipal;                         // Total deposits
uint256 public globalIndex;                            // Global yield index
uint256 public claimReserve;                          // Available for claims
address public yieldRedistributor;                     // Yield distributor
address public treasury;                              // Treasury address
address public pauser;                                // Pauser address
```

### Upgrade Verification

After each upgrade, verify state preservation:

```solidity
// Verify core state preserved
assertEq(vaultV2.totalPrincipal(), totalPrincipalBefore);
assertEq(vaultV2.globalIndex(), globalIndexBefore);
assertEq(vaultV2.claimReserve(), claimReserveBefore);

// Verify user state preserved
assertEq(vaultV2.principal(alice), alicePrincipalBefore);
assertEq(vaultV2.claimable(alice), aliceClaimableBefore);

// Verify roles preserved
assertEq(vaultV2.treasury(), treasuryBefore);
assertEq(vaultV2.pauser(), pauserBefore);
```

## Testing & Verification

### Comprehensive Test Coverage

The upgradeable vault includes extensive testing:

- **Basic Upgrade Tests**: V1→V2→V3 upgrade chains
- **State Preservation**: All state preserved across upgrades
- **Functionality Tests**: All functions work before and after upgrades
- **ETH Safety**: ETH rejection and recovery testing
- **Re-initialization Protection**: Cannot re-initialize after upgrade
- **Complex Scenarios**: Multi-user, multi-yield, multi-upgrade testing

### Test Files

- `test/unit/EarnVaultUpgradeableSimple.t.sol` - Comprehensive upgrade testing
- `test/unit/EarnVaultUpgrades.t.sol` - Focused upgrade scenarios
- `test/unit/EarnVaultUpgradeableUsingOz.t.sol` - OpenZeppelin Foundry Upgrades integration

### Key Test Scenarios

```solidity
// Multi-version upgrade chain
test_V1ToV2ToV3ChainUpgrade()

// State preservation across upgrades
test_ComplexStatePreservationAcrossUpgrades()

// ETH safety and recovery
test_SweepNativeWorks()
test_CannotSendETHToVault()

// Re-initialization protection
test_CannotReinitializeV2()
test_CannotReinitializeV3()

// Functionality stability
test_OnYieldStabilityAcrossUpgrades()
test_OnBoostRewardStabilityAcrossUpgrades()
```

## Deployment & Integration

### Using OpenZeppelin Foundry Upgrades

```solidity
import {Upgrades, UnsafeUpgrades} from "lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

// Deploy upgradeable proxy
vault = EarnVaultUpgradeable(payable(
    UnsafeUpgrades.deployTransparentProxy(
        address(implementation),
        admin, // ProxyAdmin owner
        abi.encodeWithSelector(
            EarnVaultUpgradeable.initialize.selector,
            address(usdsc),
            owner,
            yieldRedistributor,
            treasury,
            pauser
        )
    )
));

// Upgrade to V2
UnsafeUpgrades.upgradeProxy(
    address(vault),
    address(v2Implementation),
    abi.encodeWithSelector(EarnVaultV2.initializeV2.selector),
    admin // ProxyAdmin owner
);
```

### Manual Proxy Management

```solidity
// Deploy ProxyAdmin
ProxyAdmin proxyAdmin = new ProxyAdmin();

// Deploy proxy
TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
    address(implementation),
    address(proxyAdmin),
    initData
);

// Upgrade
proxyAdmin.upgradeAndCall(
    ITransparentUpgradeableProxy(address(proxy)),
    address(newImplementation),
    upgradeInitData
);
```

## Security Considerations

### Upgrade Security

1. **ProxyAdmin Ownership**: Only trusted multisig should own ProxyAdmin
2. **Implementation Verification**: Verify implementation contracts before upgrade
3. **Storage Layout**: Use ERC7201 namespaced storage to prevent collisions
4. **Initialization Safety**: Use `reinitializer` modifier for upgrade initialization

### ETH Safety

1. **Explicit Rejection**: Contract rejects all ETH transfers
2. **Owner Recovery**: Only owner can recover accidentally sent ETH
3. **Selfdestruct Handling**: ETH from `selfdestruct` can be recovered

### State Integrity

1. **Settlement Ordering**: `_settle()` called before all state changes
2. **Funding Invariants**: Maintained across all upgrades
3. **Access Control**: Roles and permissions preserved

## Migration from Non-Upgradeable

### Key Differences

| Feature | Non-Upgradeable | Upgradeable |
|---------|----------------|-------------|
| Constructor | `constructor(...)` | `initialize(...)` |
| Storage | Direct variables | ERC7201 namespaced |
| ETH Handling | `receive()` reverts | `receive()` + `fallback()` revert |
| ETH Recovery | Not available | `sweepNative()` function |
| Upgrade Path | Not possible | V1→V2→V3+ supported |

### Migration Steps

1. Deploy `EarnVaultUpgradeable` implementation
2. Deploy `TransparentUpgradeableProxy` with initialization
3. Deploy `ProxyAdmin` and transfer ownership to multisig
4. Migrate user funds from old vault to new vault
5. Update integrations to use new proxy address

## Best Practices

### For Developers

1. **Always use `upgradeAndCall`** with initialization data
2. **Test upgrades thoroughly** before mainnet deployment
3. **Verify state preservation** after each upgrade
4. **Use ERC7201 storage** for new storage variables
5. **Implement `reinitializer`** for upgrade initialization

### For Administrators

1. **Secure ProxyAdmin ownership** with multisig
2. **Verify implementation contracts** before upgrade
3. **Test upgrades on testnet** first
4. **Monitor for ETH accumulation** and sweep if needed
5. **Document upgrade procedures** and rollback plans

### For Users

1. **No action required** - upgrades are transparent
2. **All funds preserved** across upgrades
3. **Functionality unchanged** unless explicitly enhanced
4. **ETH transfers rejected** - use `sweepNative()` if needed

## Future Upgrade Paths

### Planned Enhancements

- **V4**: Advanced yield strategies
- **V5**: Cross-chain yield distribution
- **V6**: Governance integration
- **V7**: MEV protection mechanisms

### Upgrade Compatibility

Each version maintains backward compatibility while adding new features:

- **V1**: Core functionality
- **V2**: Emergency features
- **V3**: Fee management and auto-compounding
- **V4+**: Advanced features (planned)

## Conclusion

The `EarnVaultUpgradeable` provides a robust, secure, and future-proof foundation for yield vault operations. With comprehensive upgrade testing, state preservation guarantees, and clear upgrade paths, it enables continuous improvement while maintaining user fund safety and operational continuity.

The upgradeable architecture ensures that the vault can evolve with changing requirements while preserving the trust and reliability that users expect from a yield-generating protocol.