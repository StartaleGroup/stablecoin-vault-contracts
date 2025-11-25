# Deployment Scripts Reference

( Earlier script version )
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
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable --rpc-url $SONEIUM_RPC_URL -vv
```

### Deploy
```bash
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable \
  --rpc-url $SONEIUM_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --slow \
  --verify \
  -vvvv
```
---

## 2. DeployEarnVaultUpgradable.s.sol (Deploy SECOND)

Deploy EarnVault - Independent (use placeholder for YIELD_REDISTRIBUTOR).

### Simulate
```bash
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable --rpc-url $SONEIUM_RPC_URL -vv
```

### Deploy
```bash
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable \
  --rpc-url $SONEIUM_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --slow \
  --verify \
  -vvvv
```
---

## 3. DeployRewardRedistributor.s.sol (Deploy LAST)

Deploy RewardRedistributor - Requires EARN_VAULT_ADDRESS and SUSDSC_VAULT_ADDRESS.

### Simulate
```bash
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor --rpc-url $SONEIUM_RPC_URL -vv
```

### Deploy
```bash
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor \
  --rpc-url $SONEIUM_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

---

## Sepolia deployment info

( Latest 07-11-2025)

✅ SUSDSCVaultUpgradeable

  Implementation: 0xdE13186F7ff1173628Ed5e15173d9E78e10Ad6Bb

  Proxy (SUSDSCVault): 0x938bca6c4281313Baa82154745E4d020E85E7340


✅ EarnVault EarnVaultUpgradeable


  Implementation: 0x7dCA02767dfD57888CE087900f9cfDf3D9a2af6f

  Proxy (EarnVault): 0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0


✅ RewardRedistributor

Contract: 0xFee1467934428Df54C696B36a4747c5Be86674CC

---

## Salt strings and calculated salt

EarnVaultUpgradeable proxy salt 0x111d4f7f87754e05e66689be7d672d1299f3a8bb004e1cab70ac2568bcfa48b7

RewardRedistributor salt 0x111d4f7f87754e05e66689be7d672d1299f3a8bb00eb96670b1b53534e05a7b0

SUSDSCVaultUpgradeable proxy salt 0x111d4f7f87754e05e66689be7d672d1299f3a8bb00f7d9a433ec92de4cb6761a

EarnVaultUpgradeable_Proxy_112025

SUSDSCVaultUpgradeable_Proxy_112025

RewardRedistributor_112025