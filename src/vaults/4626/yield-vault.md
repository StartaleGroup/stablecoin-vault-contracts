# sUSDR Vault - ERC4626 Passive Yield Vault

## Overview

The `SUSDRVault` is a passive ERC4626-compliant vault that allows users to deposit USDR tokens and receive sUSDR shares in return. This vault implements a simple yield mechanism where external asset inflows automatically increase the price per share (PPS) for all holders.

## Key Features

- **ERC4626 Compliance**: Full compatibility with the ERC4626 tokenized vault standard
- **Passive Strategy**: No active yield-generating strategy - relies on external yield inflow of the vault asset USDR.
- **Access Control**: Role-based permissions for administrative functions
- **Pausable**: Can be paused/unpaused by authorized accounts
- **Reentrancy Protection**: All critical functions are protected against reentrancy attacks

## Contract Details

### Token Information
- **Name**: Staked USDR
- **Symbol**: sUSDR
- **Underlying Asset**: USDR token

### Roles
- `DEFAULT_ADMIN_ROLE`: Can grant/revoke other roles
- `PAUSER_ROLE`: Can pause/unpause the vault operations

## Yield Mechanism

The vault uses OpenZeppelin's default `totalAssets()` implementation which returns `asset.balanceOf(address(this))`. This means:

1. When users deposit USDR, they receive sUSDR shares based on the current exchange rate
2. External parties can send USDR directly to the vault contract
3. These "donations" increase the total assets without changing the share supply
4. This automatically increases the price per share for all existing holders
5. When users withdraw, they receive more USDR than they originally deposited

## Core Functions

### Deposit Functions
- `deposit(uint256 assets, address receiver)`: Deposit USDR assets for sUSDR shares
- `mint(uint256 shares, address receiver)`: Mint specific amount of sUSDR shares

### Withdrawal Functions  
- `withdraw(uint256 assets, address receiver, address owner)`: Withdraw specific USDR amount
- `redeem(uint256 shares, address receiver, address owner)`: Redeem sUSDR shares for USDR

### Administrative Functions
- `pause(bool p)`: Pause or unpause vault operations (PAUSER_ROLE only)

## Security Features

- **Pausable**: All user-facing functions can be paused in emergencies
- **ReentrancyGuard**: Protection against reentrancy attacks
- **Access Control**: Role-based permissions for sensitive operations
- **Non-upgradeable**: Fixed implementation for security and transparency

## Usage Example

```solidity
// Deploy vault
SUSDRVault vault = new SUSDRVault(usdrToken, admin, pauser);

// User deposits 1000 USDR
uint256 shares = vault.deposit(1000e18, userAddress);

// External yield is added (increases PPS)
usdrToken.transfer(address(vault), 100e18);

// User can now withdraw more than they deposited
uint256 assets = vault.redeem(shares, userAddress, userAddress);
// assets will be > 1000e18 due to yield accrual
```