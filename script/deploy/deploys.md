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
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable --sig "simulateDeploy()" --rpc-url $SEPOLIA_RPC_URL -vv
```

### Simulate2
```bash
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable --rpc-url $SEPOLIA_RPC_URL -vv
```

### Deploy
```bash
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable \
  --rpc-url $SEP_RPC \
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
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable --sig "simulateDeploy()" --rpc-url $SEP_RPC -vv
```

### Simulate2
```bash
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable --rpc-url $SEP_RPC -vv
```

### Deploy
```bash
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable \
  --rpc-url $SEP_RPC \
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
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor --sig "simulateDeploy()" --rpc-url $SEP_RPC -vv
```

### Simulate2
```bash
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor --rpc-url $SEP_RPC -vv
```

### Deploy
```bash
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor \
  --rpc-url $SEP_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

---

## Post-Deployment

Update EarnVault's yieldRedistributor if placeholder was used:

```bash
cast send <EARN_VAULT_PROXY> "setYieldRedistributor(address)" <REWARD_REDISTRIBUTOR> --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
cast send 0x5F022ebd58F9aD9E425E06Ce6DD3f7924cc0F722 "setYieldRedistributor(address)" 0x49A441D35d3305dE31398BA62fdeAD474c10b466 --rpc-url $SEP_RPC --private-key $PRIVATE_KEY
```

---

## Sepolia deployment info

✅ SUSDSCVault

Implementation: 0x56bf6ed4689c3a2d0cE75aB1cC57EC080dBaB1B4

Proxy: 0x97Bf9acfD3A4D0Fcee3bd86BCa1FdD5617925fd0


✅ EarnVault

BoostRewardsLib: 0x5CB235474Bd0125a362A12B3922361eD42cb4843

Implementation: 0x7043E917373Ce7a50A18885fD897D48D5686bd80

Proxy: 0x5F022ebd58F9aD9E425E06Ce6DD3f7924cc0F722

ProxyAdmin: 0xC0DF3EB4B7707907e73e8ba1245434F1Eb9FaE97



✅ RewardRedistributor

Contract: 0x49A441D35d3305dE31398BA62fdeAD474c10b466

