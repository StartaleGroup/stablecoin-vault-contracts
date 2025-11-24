# Startale Stablecoin Contracts

A comprehensive smart contract system for managing USDSC stablecoin yield distribution across multiple vault strategies. This repository contains upgradeable vault contracts and a yield redistribution system that enables users to earn yield through different mechanisms.

## Overview

This system consists of three main components:

1. **RewardRedistributor**: A non-upgradeable contract that claims yield from the USDSC token (M0 extension) and distributes it proportionally to two vault types based on their total value locked (TVL).

2. **EarnVault**: An upgradeable vault where users deposit USDSC and earn claimable yield. Users maintain full control over their principal and can withdraw anytime, with all accrued rewards automatically claimed on withdrawal. Supports dual rewards: USDSC yield + boost rewards in other tokens (ASTR, DOT, etc.).

3. **sUSDSC Vault**: An ERC-4626 compliant passive yield vault where users deposit USDSC and receive sUSDSC shares. External yield inflows automatically increase the price per share (PPS) for all holders.

## Architecture

### System Flow

```
USDSC Token (M0 Extension)
    ↓ claimYield()
RewardRedistributor
    ↓ distribute()
    ├─→ EarnVault (proportional to TVL)
    │   └─→ Users claim yield + boost rewards
    └─→ sUSDSC Vault (proportional to TVL)
        └─→ PPS increases automatically
```

### Key Features

- **Proportional Yield Distribution**: Yield is split between vaults based on their TVL with rounding-carry logic for long-run fairness
- **Dual Vault Strategy**: Two different yield mechanisms (claimable vs. automatic PPS increase)
- **Upgradeable Vaults**: EarnVault and sUSDSC Vault use transparent proxy pattern for future upgrades
- **Boost Rewards**: EarnVault supports additional rewards in multiple ERC20 tokens
- **Access Control**: Role-based permissions for all administrative functions
- **Emergency Controls**: Pause mechanisms and emergency recovery functions

## Contracts

### RewardRedistributor

**Location**: `src/distributor/RewardRedistributor.sol`

**Type**: Non-upgradeable (immutable)

**Purpose**: Claims yield from USDSC token and distributes it to vaults proportionally.

**Key Functions**:
- `distribute()`: Claims yield and distributes to vaults (OPERATOR_ROLE)
- `previewDistribute()`: Preview distribution without executing
- `setTreasury()`, `setEarnVault()`, `setSusdscVault()`, `setFeeBps()`: Configuration (ADMIN_ROLE)

**Documentation**: See [RewardRedistributor.md](src/distributor/RewardRedistributor.md) and [OPERATOR_RUNBOOK.md](src/distributor/OPERATOR_RUNBOOK.md)

### EarnVault / EarnVaultUpgradeable

**Location**: `src/vaults/earn/EarnVaultUpgradeable.sol`

**Type**: Upgradeable (transparent proxy)

**Purpose**: Users deposit USDSC and earn claimable yield with boost rewards support.

**Key Features**:
- Index-based yield accounting with RAY precision (1e27)
- Automatic reward claiming on withdrawal
- Multi-token boost rewards (ASTR, DOT, etc.)
- Principal protection with full withdrawal control

**Key Functions**:
- `deposit(uint256 amount)`: Deposit USDSC
- `withdraw(uint256 amount)`: Withdraw principal (auto-claims all rewards)
- `claim()`: Claim all accrued rewards without withdrawing
- `onYield(uint256 amount)`: Receive yield distribution (YIELD_REDISTRIBUTOR only)
- `onBoostReward(address token, uint256 amount)`: Receive boost rewards (BOOST_REWARD_KEEPER only)

**Documentation**: See [earn-vault.md](src/vaults/earn/earn-vault.md) and [earn-vault-upgradeable.md](src/vaults/earn/earn-vault-upgradeable.md)

### SUSDSCVault / SUSDSCVaultUpgradable

**Location**: `src/vaults/4626/SUSDSCVaultUpgradable.sol`

**Type**: Upgradeable (transparent proxy)

**Purpose**: ERC-4626 compliant vault where yield increases price per share automatically.

**Key Features**:
- Full ERC-4626 standard compliance
- Passive yield mechanism (external transfers increase PPS)
- No active strategy required

**Key Functions**:
- `deposit(uint256 assets, address receiver)`: Deposit USDSC for sUSDSC shares
- `withdraw(uint256 assets, address receiver, address owner)`: Withdraw USDSC
- `redeem(uint256 shares, address receiver, address owner)`: Redeem shares for USDSC

**Documentation**: See [yield-vault.md](src/vaults/4626/yield-vault.md)

## Prerequisites

### Required Tools

- [Foundry](https://github.com/foundry-rs/foundry) - For compiling, testing, and deploying contracts
- [Node.js](https://nodejs.org/) >= 18 - For package management and scripts
- [Yarn](https://yarnpkg.com/) - Package manager (or npm)

### Optional Tools

- [lcov](https://github.com/linux-test-project/lcov) - For generating HTML coverage reports
- [slither](https://github.com/crytic/slither) - For static analysis

### Installation

1. **Install Foundry** (if not already installed):
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

2. **Clone the repository**:
```bash
git clone https://github.com/StartaleGroup/stablecoin-contracts.git
cd stablecoin-contracts
```

3. **Install dependencies**:
```bash
yarn install
```

4. **Install Foundry dependencies**:
```bash
forge install
```

5. **Set up environment variables**:
```bash
cp .env.example .env
# Edit .env with your configuration
```

## Development

### Compile Contracts

```bash
# Using yarn script
yarn compile

# Or using forge directly
forge build
```

### Run Tests

```bash
# Run all tests
yarn test

# Run tests with gas report
yarn test-gas

# Run specific test file
forge test --match-path test/unit/RewardRedistributor.t.sol

# Run specific test function
forge test --match-test test_Distribute

# Run with higher verbosity
./test.sh -v

# Run fuzz tests
yarn test-fuzz

# Run integration tests
yarn test-integration

# Run invariant tests
yarn test-invariant
```

### Code Coverage

```bash
# Generate coverage report (lcov format)
yarn coverage

# Generate coverage with exclusions (filters out test/mock/script files)
make coverage-exclude

# Generate HTML coverage report
make coverage-html
# Opens coverage-html/index.html in browser

# View coverage summary
./scripts/coverage-summary.sh lcov.info
```

### Code Quality

```bash
# Format code with Prettier
yarn prettier

# Lint Solidity files
yarn solhint

# Fix solhint errors
yarn solhint-fix

# Run Slither static analysis
yarn slither
```

### Generate Documentation

```bash
# Generate and serve documentation
yarn doc
# Opens http://localhost:4000
```

## Deployment

### Deployment Order

Contracts must be deployed in the following order:

1. **SUSDSCVault** (1st) - Independent, no dependencies
2. **EarnVault** (2nd) - Independent (use placeholder or deterministic address for YIELD_REDISTRIBUTOR initially)
3. **RewardRedistributor** (3rd) - Requires both vault addresses

### Environment Setup

Before deploying, ensure your `.env` file contains:

```bash
# Network Configuration
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
DEPLOYER_PRIVATE_KEY=0x...

# Contract Addresses (for RewardRedistributor deployment)
USDSC_ADDRESS=0x...
TREASURY_ADDRESS=0x...
EARN_VAULT_ADDRESS=0x...
SUSDSC_VAULT_ADDRESS=0x...
ADMIN_ADDRESS=0x...
KEEPER_ADDRESS=0x...

# Vault-specific addresses
OWNER_ADDRESS=0x...
YIELD_REDISTRIBUTOR_ADDRESS=0x...  # Set after RewardRedistributor deployment
PAUSER_ADDRESS=0x...
BOOST_REWARD_KEEPER_ADDRESS=0x...
PROXY_ADMIN_OWNER=0x...  # Optional, defaults to admin/owner
```

### Deploy to Sepolia Testnet

#### 1. Deploy SUSDSCVault

```bash
# Simulate deployment
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable \
  --rpc-url $SEPOLIA_RPC_URL -vv

# Deploy
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

#### 2. Deploy EarnVault

```bash
# Simulate deployment
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable \
  --rpc-url $SEPOLIA_RPC_URL -vv

# Deploy (use placeholder for YIELD_REDISTRIBUTOR_ADDRESS)
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

#### 3. Deploy RewardRedistributor

```bash
# Update .env with EARN_VAULT_ADDRESS and SUSDSC_VAULT_ADDRESS from previous steps

# Simulate deployment
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor \
  --rpc-url $SEPOLIA_RPC_URL -vv

# Deploy
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

#### 4. Post-Deployment Configuration

After deploying RewardRedistributor:

1. **Set RewardRedistributor as yield recipient in USDSC token**:
   ```solidity
   USDSC.setYieldRecipient(rewardRedistributorAddress)
   ```

2. **Set RewardRedistributor as yield redistributor in EarnVault**:
   ```solidity
   EarnVault.setYieldRedistributor(rewardRedistributorAddress)
   ```

3. **Verify keeper has OPERATOR_ROLE** (automatically granted during deployment)

### Deploy to Local Network

```bash
# Start local Anvil node
anvil

# In another terminal, deploy
yarn deploy-local
```

### Deployment Scripts

All deployment scripts use **CREATE3** for deterministic addresses. See [deploys.md](script/deploy/deploys.md) for detailed deployment information.

## Testing

### Test Structure

```
test/
├── unit/          # Unit tests for individual contracts
├── integration/   # Integration tests for contract interactions
├── invariants/    # Invariant tests for system properties
├── fork/          # Fork tests against mainnet/testnet
└── mocks/         # Mock contracts for testing
```

### Running Tests

```bash
# All tests
yarn test

# Specific test directory
./test.sh -d test/unit

# Specific test pattern
./test.sh -t test_Distribute

# With gas reporting
yarn test-gas

# Fuzz tests
yarn test-fuzz

# Integration tests
yarn test-integration

# Invariant tests
yarn test-invariant
```

### Test Profiles

The project uses Foundry profiles for different test configurations:

- `default`: Standard testing (5,000 fuzz runs, 512 invariant runs)
- `ci`: CI-optimized (100 fuzz runs, 50 invariant runs)
- `production`: Production builds with optimizations

```bash
# Use specific profile
./test.sh -p ci
```

## Project Structure

```
stablecoin-contracts/
├── src/
│   ├── distributor/          # RewardRedistributor contract
│   │   ├── RewardRedistributor.sol
│   │   ├── RewardRedistributor.md
│   │   └── OPERATOR_RUNBOOK.md
│   ├── vaults/
│   │   ├── earn/             # EarnVault contracts
│   │   │   ├── EarnVaultUpgradeable.sol
│   │   │   ├── earn-vault.md
│   │   │   └── earn-vault-upgradeable.md
│   │   └── 4626/             # sUSDSC Vault contracts
│   │       ├── SUSDSCVaultUpgradable.sol
│   │       └── yield-vault.md
│   └── interfaces/           # Contract interfaces
├── script/
│   └── deploy/               # Deployment scripts
│       ├── DeploySUSDSCUpgradable.sol
│       ├── DeployEarnVaultUpgradable.s.sol
│       ├── DeployRewardRedistributor.s.sol
│       └── deploys.md
├── test/                     # Test files
├── lib/                      # External dependencies
├── foundry.toml             # Foundry configuration
├── package.json             # Node.js dependencies and scripts
├── Makefile                 # Build automation
└── README.md               # This file
```

## Available Scripts

### Build & Compile

- `yarn build` - Build contracts for production
- `yarn compile` - Compile contracts
- `yarn clean` - Clean build artifacts

### Testing

- `yarn test` - Run all tests
- `yarn test-gas` - Run tests with gas report
- `yarn test-fuzz` - Run fuzz tests
- `yarn test-integration` - Run integration tests
- `yarn test-invariant` - Run invariant tests

### Coverage

- `yarn coverage` - Generate coverage report (lcov)
- `yarn coverage:filtered` - Generate filtered coverage
- `yarn coverage:html` - Generate HTML coverage report

### Code Quality

- `yarn prettier` - Format code
- `yarn solhint` - Lint Solidity files
- `yarn solhint-fix` - Fix solhint errors
- `yarn slither` - Run static analysis

### Deployment

- `yarn deploy-local` - Deploy to local network
- `yarn deploy-sepolia` - Deploy to Sepolia testnet

### Documentation

- `yarn doc` - Generate and serve documentation

## Configuration

### Foundry Configuration

See `foundry.toml` for Foundry settings including:
- Solidity version: `0.8.30`
- EVM version: `prague`
- Optimizer: Enabled with 999,999 runs
- Test profiles for different environments

### Coverage Exclusions

Coverage excludes test files, mocks, scripts, and interfaces. See `Makefile` for the exclusion pattern.

## Security

### Audit Status

✅ **This codebase has been audited by Quantstamp.**

The audit report is available in the [`audits/`](audits/) directory. Please review the audit findings before deploying to production.

### Security Features

- Reentrancy guards on all critical functions
- Access control with role-based permissions
- Pause mechanisms for emergency stops
- Input validation and overflow protection
- Comprehensive test coverage

### Reporting Security Issues

Please report security issues to the repository maintainers privately before public disclosure.

## Documentation

### Contract Documentation

- [RewardRedistributor](src/distributor/RewardRedistributor.md) - Detailed contract documentation
- [RewardRedistributor Operator Runbook](src/distributor/OPERATOR_RUNBOOK.md) - Operational procedures
- [EarnVault](src/vaults/earn/earn-vault.md) - EarnVault documentation
- [EarnVault Upgradeable](src/vaults/earn/earn-vault-upgradeable.md) - Upgrade procedures
- [sUSDSC Vault](src/vaults/4626/yield-vault.md) - ERC-4626 vault documentation

### Security Documentation

- [Audit Reports](audits/) - Quantstamp security audit reports

### Deployment Documentation

- [Deployment Guide](script/deploy/deploys.md) - Deployment procedures and addresses

## Deployed Addresses

<!-- TODO: Add deployed contract addresses for each network -->

### Sepolia Testnet

_Addresses will be added after deployment_

### Mainnet

_Addresses will be added after deployment_

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

## License

[Add license information]

## Support

For questions and support:
- Open an issue on GitHub
- Contact the development team

## Acknowledgments

Built with:
- [Foundry](https://github.com/foundry-rs/foundry)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Solady](https://github.com/Vectorized/solady)
