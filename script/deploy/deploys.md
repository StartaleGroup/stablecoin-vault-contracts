# Deployment Scripts Reference

**Deployment Order**: SUSDSCVault (1st) → EarnVault (2nd) → RewardRedistributor (3rd)

## Prerequisites

Load environment variables before running any script:

```bash
set -a && source .env && set +a
```

---

## 1. DeploySUSDSCUpgradable.sol (Deploy FIRST)

Deploy SUSDSCVault - Independent, no dependencies.

### Simulate
```bash
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable --rpc-url $SEPOLIA_RPC_URL -vv
```

### Deploy
```bash
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

// Note: After having Create3 predicted address (and fixed salt string) we would have this in advance
**Save proxy address as** `SUSDSC_VAULT_ADDRESS` in `.env`

---

## 2. DeployEarnVaultUpgradable.s.sol (Deploy SECOND)

Deploy EarnVault - Independent (use placeholder for YIELD_REDISTRIBUTOR).

### Simulate
```bash
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable --rpc-url $SEPOLIA_RPC_URL -vv
```

### Deploy
```bash
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

**Save proxy address as** `EARN_VAULT_ADDRESS` in `.env`

---

## 3. DeployRewardRedistributor.s.sol (Deploy LAST)

Deploy RewardRedistributor - Requires EARN_VAULT_ADDRESS and SUSDSC_VAULT_ADDRESS.

### Simulate
```bash
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor --rpc-url $SEPOLIA_RPC_URL -vv
```

### Deploy
```bash
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

---

## Post-Deployment

#### // NotE: We would not need to do below once we use pre-mined addresses using Create3 salt and CreateX Factory.
Update EarnVault's yieldRedistributor if placeholder was used:

```bash
cast send <EARN_VAULT_PROXY> "setYieldRedistributor(address)" <REWARD_REDISTRIBUTOR> --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
cast send 0x5F022ebd58F9aD9E425E06Ce6DD3f7924cc0F722 "setYieldRedistributor(address)" 0x49A441D35d3305dE31398BA62fdeAD474c10b466 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

---

## Sepolia deployment info

( Latest 03-11-2025)

✅ SUSDSCVault

Implementation: 0xAd66e2C9732c8a29a96c3ddacc7ad82cc5492F99

Proxy: 0x58f54D5B3F72cC9fF35d5bD950319E46d294A40c


✅ EarnVault


Implementation: 0xA3B1A989AEDa56fFF76777C9dC708F88190A37Ed

Proxy: 0x40eA9e92d55C1c49c6D2061E74ec60bb48f8C61f


✅ RewardRedistributor

Contract: 0xA8B3DBB860A0Aa77Fe04E83a7334de9f6E97C18b

=== Deployment Summary ===
  Contract: RewardRedistributor
  Address: 0xA8B3DBB860A0Aa77Fe04E83a7334de9f6E97C18b
  USDSC Token: 0x7E426d026f604d1c47b50059752122d8ab1E2C28
  Treasury: 0x77001610a4fD68548B80E49226c02a99c3b6Ae14
  EarnVault: 0x40eA9e92d55C1c49c6D2061E74ec60bb48f8C61f
  sUSDSC Vault: 0x58f54D5B3F72cC9fF35d5bD950319E46d294A40c
  Admin: 0x77001610a4fD68548B80E49226c02a99c3b6Ae14
  Keeper: 0x77001610a4fD68548B80E49226c02a99c3b6Ae14
  Fee (bps): 0
  Max Fee (bps): 2000

