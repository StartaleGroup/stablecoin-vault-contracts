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
set -a && source .env && set +a
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable --sig "simulateDeploy()" --rpc-url $SEPOLIA_RPC_URL -vv
```

### Simulate2
```bash
set -a && source .env && set +a
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable --rpc-url $SEPOLIA_RPC_URL -vv
```

### Deploy
```bash
set -a && source .env && set +a
forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
```

**Save proxy address as** `SUSDSC_VAULT_ADDRESS` in `.env`

---

## 2. DeployEarnVaultUpgradable.s.sol (Deploy SECOND)

Deploy EarnVault - Independent (use placeholder for YIELD_REDISTRIBUTOR).

### Simulate
```bash
set -a && source .env && set +a
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable --sig "simulateDeploy()" --rpc-url $SEP_RPC -vv
```

### Simulate2
```bash
set -a && source .env && set +a
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable --rpc-url $SEP_RPC -vv
```

### Deploy
```bash
set -a && source .env && set +a
forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable --rpc-url $SEP_RPC --broadcast --verify -vvvv
```

**Save proxy address as** `EARN_VAULT_ADDRESS` in `.env`

---

## 3. DeployRewardRedistributor.s.sol (Deploy LAST)

Deploy RewardRedistributor - Requires EARN_VAULT_ADDRESS and SUSDSC_VAULT_ADDRESS.

### Simulate
```bash
set -a && source .env && set +a
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor --sig "simulateDeploy()" --rpc-url $SEP_RPC -vv
```

### Simulate2
```bash
set -a && source .env && set +a
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor --rpc-url $SEP_RPC -vv
```

### Deploy
```bash
set -a && source .env && set +a
forge script script/deploy/DeployRewardRedistributor.s.sol:DeployRewardRedistributor --rpc-url $SEP_RPC --broadcast --verify -vvvv
```

---

## Post-Deployment

Update EarnVault's yieldRedistributor if placeholder was used:

```bash
cast send <EARN_VAULT_PROXY> "setYieldRedistributor(address)" <REWARD_REDISTRIBUTOR> --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

---

## Documentation

- SUSDSCVault: [DEPLOY_SUSDSC_VAULT_UPGRADEABLE.md](./DEPLOY_SUSDSC_VAULT_UPGRADEABLE.md)
- EarnVault: [DEPLOY_EARN_VAULT_UPGRADEABLE.md](./DEPLOY_EARN_VAULT_UPGRADEABLE.md)
- RewardRedistributor: [DEPLOY_REWARD_REDISTRIBUTOR.md](./DEPLOY_REWARD_REDISTRIBUTOR.md)
