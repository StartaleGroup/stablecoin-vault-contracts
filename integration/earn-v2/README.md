# EarnVaultV2: integration guide (backend, keepers, indexer)

> **Status: pre-audit.** The contracts are at the audit commit `5326a7d3824e9c78ae292b248e25720469b5f310` (PR #84, which includes PR #83). Signatures and semantics may still change with audit findings; any change will be flagged here.

This guide covers what the reward engine, keepers, frontend and indexer need in order to integrate with `EarnVaultV2`. The design rationale is in `src/vaults/earn/base-tier-auto-compounding.md`. The full ABI is in [`EarnVaultV2.abi.json`](EarnVaultV2.abi.json).

All USDSC amounts are in **6-decimal base units** (`1 USDSC = 1_000_000`).

---

## 1. Contracts and environments

### Production (Soneium, chain 1868): V1 today, V2 after the upgrade

| Contract | Address |
|---|---|
| EarnVault proxy (the vault address; it stays the same after the upgrade) | `0xFdeB7e9F59cad080D9158ff850Ce79bCf6cdd5f0` |
| RewardRedistributor (the vault's `yieldRedistributor`) | `0xda798684ffD5eb509c2Ab7b8352EC55B31F18201` |
| ProxyAdmin | `0xDBc42e5c7E6BF89886F2f359F9b0BB9344824066` |
| Owner of the vault and ProxyAdmin, and pauser (Safe, 3 of 5) | `0x3C27038D9906caa5D68355B1800625EAcaCd93dA` |
| Redistributor operator (snapshot / distribute) | `0x86bE13a26d548FA5407Ee3E5a8321B4E1019333C` |

The boost keeper address and the `maxBoostPerBatch` value are set at upgrade time; both are still to be decided.

### Test stack

`script/testnet/DeployEarnVaultV2TestStack.s.sol` deploys a self-contained stack on any chain with the CreateX factory (Base Sepolia, Soneium Minato, and others):
- `TestUSDSC`, a 6-decimal token with an open faucet;
- `TestSnapshotRedistributor`, which has the same snapshot rules and event signatures as the real RewardRedistributor;
- the EarnVault V1 proxy, upgraded to V2 through the same `upgradeAndCall(initializeV2)` path production will use.

All salts are tagged `TEST_…`, so test addresses can never coincide with production ones.

| Contract | Address (fill in after deploying) |
|---|---|
| EarnVault proxy (V2) | |
| TestUSDSC | |
| TestSnapshotRedistributor | |

---

## 2. Roles: who calls what

| Actor | Calls | Notes |
|---|---|---|
| **Boost keeper** (reward engine) | `onBoostCredit(cycleId, users, amounts)` | Only the address set as `boostKeeper`. It must fund the vault first. |
| **Compound keeper** | `compoundMany(users)` / `compound(user)` | Permissionless; any address can call them. It only grows each user's own principal. Run it daily. |
| **Redistributor operator** | `RewardRedistributor.snapshotVaultTVLs()`, then `distribute()` | Existing flow. It now opens and closes the deposit lock (section 5). |
| **Users / frontend** | `deposit`, `depositWithPermit`, `withdraw`, `claim` | `claim()` pays boost-token rewards and any legacy V1 `accrued` USDSC. Base yield auto-compounds into principal. |
| **Owner (Safe)** | `setBoostKeeper`, `setMaxBoostPerBatch`, `setBlacklisted`, pause / unpause, sweep / recover | Admin only. |

---

## 3. Boost credit (reward engine and boost keeper)

### Flow for each cycle

1. **Read** `latestCycleId()` from the chain, rather than deriving cycle IDs from dates. Record your own date → `cycleId` mapping when you submit.
2. **Choose the cycle ID:**
   - more batches for the *current* cycle use `cycleId = latestCycleId`;
   - opening the *next* cycle uses `cycleId = latestCycleId + 1`.
3. **Fund:** transfer the batch's total USDSC to the vault. The vault checks `balance >= claimReserve + sum(amounts)` before crediting anything.
4. **Call** `onBoostCredit(cycleId, users[], amounts[])` from the boost keeper.
5. **Reconcile** using `BoostCycleCredited`, plus one `BoostCredited` or `BoostCreditSkipped` per entry.

### Rules

- **Cycle window.** Only `latestCycleId` or `latestCycleId + 1` is accepted.
  - A closed cycle reverts `CycleIdTooOld`.
  - Skipping ahead reverts `CycleIdTooFarAhead`.
  - `0` reverts `ZeroCycleId`.
  - `latestCycleId` advances only when a batch actually credits something.
  - Cycles can be opened back to back; after downtime, **catch up one cycle per missed day**. Don't roll several days into one cycle.
- **Replay guard.** Each address can be credited at most once per cycle. Its `cycleId` must be greater than `lastCreditedCycle(user)`, or the batch reverts `StaleCycle`. A duplicate address inside one batch also reverts.
- **Per-batch cap.** If the credited total (skipped entries excluded) exceeds `maxBoostPerBatch()`, the whole batch reverts `BoostBatchCapExceeded(credited, max)`. Split large cycles into several batches; each batch can use the full cap.
- **All-or-nothing reverts:** insufficient funding, a bad cycle, a stale cycle or duplicate, a zero address, a length mismatch, an empty batch, or exceeding the cap.
- **Per-entry skips** (the batch continues): the vault's own address, blacklisted addresses, and zero amounts.
  - The event is `BoostCreditSkipped(user, amount, cycleId, reason)`, with `reason` 0 = VaultAddress, 1 = Blacklisted, 2 = ZeroAmount.
  - A skipped entry can be re-credited **only while that cycle is current**; after that, roll the amount into a later cycle.
  - Skipped funding stays in the vault as surplus.
- **Addresses must be AA wallets** (v1 policy). Exactly one address per user is guaranteed off-chain, by the engine.
- **Avoid the deposit-lock window** (section 5). Boost credit isn't blocked during it, but scheduling it outside the window keeps the yield split clean.

### Batch sizing

Gas figures assume 2 active boost tokens, against Soneium's 40M block limit. Target at most 60% of the block, about 24M gas, per transaction.

| State of the credited addresses | Gas per entry | Entries per batch (≤ 24M gas) |
|---|---|---|
| Worst-case cold (first credit, never settled since the boost tokens were activated) | ~124k | **~190** |
| Already settled by `compoundMany` | ~32k | ~700 |
| Warm (later cycles) | ~13.5k | ~1,700 |

A batch that runs out of gas reverts whole; split it and resubmit with the same `cycleId`.

### Errors: what to do

| Error | Meaning | Action |
|---|---|---|
| `CycleIdTooOld(cycleId, latest)` | The cycle is closed | Re-read `latestCycleId`; roll the amounts into the current or next cycle |
| `CycleIdTooFarAhead(cycleId, latest)` | Skipped ahead | Use `latest` or `latest + 1` |
| `StaleCycle()` | An address was already credited for this cycle, or appears twice in the batch | Drop the duplicates. It's already credited, so don't resend. |
| `InsufficientFunding()` | The vault's balance doesn't cover `claimReserve + total` | Transfer the shortfall and retry |
| `BoostBatchCapExceeded(credited, max)` | The batch is over the cap | Split it. If the amounts look wrong, stop: this cap exists to catch engine bugs. |
| `EmptyBatch()` / `LengthMismatch()` | Malformed input | Fix the engine |
| `NotBoostKeeper()` | Wrong sender | Use the configured keeper |
| `EnforcedPause()` | The vault is paused | Wait |

**Security budget:** a compromised keeper key can credit at most the keeper wallet's balance plus the vault's accumulated surplus. Fund the keeper per batch, just in time; don't let it hold several cycles' worth.

---

## 4. Compound keeper

- Call `compoundMany(users)` **daily**, for depositors with `pendingYield(user) > 0`. More frequent calls add nothing: yield only moves when `onYield` runs.
- It's permissionless, never moves tokens, and emits `Compounded(user, amount)` for each address with something to fold in.
- **Batch sizing**, with 2 active boost tokens:
  - about 98k gas per address on a first, cold touch, so about 245 addresses per 24M-gas transaction;
  - about 10k gas per address once warm.
- Skip addresses with zero principal or zero pending yield.

---

## 5. Deposit lock (frontend and keepers)

- **When it applies:** deposits (`deposit`, `depositWithPermit`) revert with `DepositsLockedForDistribution(unlocksAt)` while the redistributor's latest snapshot can still be distributed, i.e. while `block.timestamp - lastSnapshotTimestamp <= snapshotMaxAge`.
- **Frontend:** read `depositsLocked()`, which returns `(bool locked, uint256 unlocksAt)`. While it's locked, disable the deposit button and show a countdown to `unlocksAt`.
- **What stays open:** withdrawals, claims, compounding and boost credit all keep working during the lock.
- **Timing:** production snapshots every 3 hours, with distribute about 2 blocks later. The window will be `snapshotMaxAge`, planned at 1–2 minutes (300 s today).

---

## 6. Events reference

`topic0` = keccak256 of the signature. Indexed parameters are topics 1–3.

| Event | Parameters | topic0 |
|---|---|---|
| `BlacklistStatusChanged` | `indexed address actor, indexed address user, bool oldStatus, bool newStatus` | `0x4e739a739fb04ed726c17b0cdbaf4d798d189e8a1a39af0676c5cc1d41ed17a4` |
| `BoostCreditSkipped` | `indexed address user, uint256 amount, indexed uint256 cycleId, uint8 reason` | `0xcd145266c9f30affe8acc18ae523659697da4fdaf6c0cace7bc87da6440b4a4f` |
| `BoostCredited` | `indexed address user, uint256 amount, indexed uint256 cycleId` | `0x43efb6303cc428e68d84bb0a11b786d71038f4db9292d03259badab9ed4c99bd` |
| `BoostCycleCredited` | `indexed uint256 cycleId, uint256 entryCount, uint256 total, uint256 skippedCount, uint256 skippedTotal` | `0xfcfeadc47b6f229feab53d631d0520663d39f824f4dc8da5daf6111cd6046284` |
| `BoostKeeperChanged` | `indexed address actor, indexed address oldKeeper, indexed address newKeeper` | `0x049af1310d75284a5c25b2557f327ce9bddba992cbe9b22394b3d21c3f2de103` |
| `BoostRewardClaimed` | `indexed address user, indexed address token, uint256 amount` | `0x5067b8d3d7328cfa98f1d5bcde56df4a932194ace52c93533b6aba32b4e22c97` |
| `BoostRewardIndexed` | `indexed address token, uint256 amount, uint256 newBoostGlobalIndex, uint256 newBoostClaimReserve` | `0xa6af4a53ae10af55ff356b23cf67c68343989261f6ace83d43b0814ce72f1a34` |
| `BoostRewardKeeperChanged` | `indexed address actor, indexed address oldKeeper, indexed address newKeeper` | `0xc6f105194d811b08428a21e30997b460c7d01bb5f68a869662bb873430e39de9` |
| `BoostRewardTokenRemoved` | `indexed address token` | `0xdd18b1b6c924f120e23d57a55960d7afa02f173e92665c132cd294390e8b5093` |
| `BoostRewardTransferFailed` | `indexed address user, indexed address token, uint256 amount` | `0x9c7ef1c0e986b07dc9bc2a8b866b6a41e6fdcfe33a39d017330aa28d5209c54d` |
| `BoostRewardTransferredToTreasury` | `indexed address token, uint256 amount` | `0x7c8e680a23779f800f1077d42406dbbabb471014fd800563135ea769426a4e32` |
| `Compounded` | `indexed address user, uint256 amount` | `0xc16de066392da7e40ceccb739c331fc48a2e76bf147449613c48023d960eec32` |
| `Deposit` | `indexed address user, uint256 amount` | `0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c` |
| `Initialized` | `uint64 version` | `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` |
| `InterestClaimed` | `indexed address user, uint256 amount` | `0xf9984c8173c4b4ff9cc454f76ed19c053f4490ccb224fd9ddffeb4ef4bea3530` |
| `MaxBoostPerBatchChanged` | `indexed address actor, uint256 oldMax, uint256 newMax` | `0x79e3478bc85947cbd82b8c7a2c80c6d284c1a859860a10b00f8a02c68a85eb23` |
| `NativeSwept` | `indexed address to, uint256 amount` | `0x958f215bc1323fd729311cf10da76fff907207d3a7473dd1e6a9ddd45fcc4e34` |
| `OwnershipTransferStarted` | `indexed address previousOwner, indexed address newOwner` | `0x38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e22700` |
| `OwnershipTransferred` | `indexed address previousOwner, indexed address newOwner` | `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` |
| `Paused` | `address account` | `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` |
| `PauserChanged` | `indexed address actor, indexed address oldPauser, indexed address newPauser` | `0x8b1ee37fa817a066fe12c7c9bf109c0c9f8f03ef0a5cfe0c03d5196e8c2e4657` |
| `SurplusSweptToTreasury` | `uint256 amount` | `0x0a2038cb559ae30ad95d550ef6843ff91ec62fe4303dcf1d0a157b01796ffdad` |
| `TokenRecovered` | `indexed address token, indexed address to, uint256 amount` | `0x879f92dded0f26b83c3e00b12e0395dc72cfc3077343d1854ed6988edd1f9096` |
| `TreasuryChanged` | `indexed address actor, indexed address oldTreasury, indexed address newTreasury` | `0x749a8050935feb73a55ab4641c867c4dacc84430990fcaada1d12ba9072ad02e` |
| `Unpaused` | `address account` | `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` |
| `Withdraw` | `indexed address user, uint256 amount` | `0x884edad9ce6fa2440d8a54cc123490eb96d2768479d49ff9c7366125a9424364` |
| `YieldIndexed` | `uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve` | `0xe8fb6cb7fa78097fad255d48c196acc4ca83a26fceba46ab2fc411175fa160ac` |
| `YieldRedistributorChanged` | `indexed address actor, indexed address oldRedistributor, indexed address newRedistributor` | `0x1ab6fe0cc09ca16ccef101680758d4f626efa8458d844570ead60a38707a1c72` |
| `YieldTransferredToTreasury` | `uint256 amount` | `0x798710febd3c6ee836a5b5b6a0220c01a969e80e06d795e0375e5f0c1b346da2` |

**Key events by consumer:**
- **Balances:**
  - `Deposit`, `Withdraw`;
  - `Compounded` (yield folded into principal);
  - `BoostCredited` (boost credited as principal);
  - `InterestClaimed` (legacy accrued paid out);
  - `BoostRewardClaimed`.

  After any of these events, `principal(user)` is the user's current principal.
- **Reward engine reconciliation:**
  - `BoostCycleCredited(cycleId, entryCount, total, skippedCount, skippedTotal)`. `total` includes skipped amounts, so the amount credited is `total - skippedTotal`;
  - plus one `BoostCredited` or `BoostCreditSkipped` per entry.
- **Vault-wide yield:** `YieldIndexed(amount, newGlobalIndex, newClaimReserve)` on each distribution, and `BoostRewardIndexed` for boost tokens.
- **Config changes:** `BoostKeeperChanged`, `MaxBoostPerBatchChanged`, `BlacklistStatusChanged`, `Paused` / `Unpaused`, and the `*Changed` role events.
- **Redistributor events** (on the RewardRedistributor, or on `TestSnapshotRedistributor` in the test stack; signatures and topics are identical, verified):

  | Event | topic0 |
  |---|---|
  | `VaultTVLsSnapshotCaptured(uint256 lastSusdscTVL, uint256 lastEarnTVL, uint256 lastSnapshotTimestamp, uint256 lastSnapshotBlockNumber)`: deposits lock from here | `0x45ab00eeb8cdb789bcd9bd7ff7d33c27e3f4ba7ad8ac49be117bccccc3047e15` |
  | `Distributed(uint256 minted, uint256 feeToStartale, uint256 toEarnVault, uint256 toSUSDSCVault, uint256 toStartaleExtra, uint256 S_base, uint256 T_earn, uint256 T_yield)` | `0xb0f6cb92613f539c9994bd9a3e58e6148dd29ea75941f831362f737ba5fdffb0` |
  | `SnapshotMaxAgeUpdated(uint256 newSnapshotMaxAge)` | `0xb5c9fe7c0494c6c1caa396400121e6351c5c65a4ba86c548c57e9aee9ace2222` |

## 7. Errors reference

| Error | Selector |
|---|---|
| `AddressBlacklisted()` | `0x1f7b776b` |
| `ArithmeticOverflow()` | `0xe47ec074` |
| `BoostBatchCapExceeded(uint256,uint256)` | `0xce421015` |
| `CanNotBeZeroAddress()` | `0x45281e4c` |
| `ContractNotPaused()` | `0xdcdde9dd` |
| `CycleIdTooFarAhead(uint256,uint256)` | `0xc9592673` |
| `CycleIdTooOld(uint256,uint256)` | `0x02fab5db` |
| `DepositsLockedForDistribution(uint256)` | `0xeb3962dc` |
| `EmptyBatch()` | `0xc2e5347d` |
| `EnforcedPause()` | `0xd93c0665` |
| `EthNotAccepted()` | `0x60f8f321` |
| `ExceedsSurplus()` | `0xe442f2c4` |
| `ExpectedPause()` | `0x8dfc202b` |
| `InsufficientBoostClaimReserve()` | `0x874ca4f6` |
| `InsufficientBoostTokenBalance()` | `0x1a0d138e` |
| `InsufficientFunding()` | `0x57e000b1` |
| `InsufficientPrincipal()` | `0xd24a69a5` |
| `InvalidInitialization()` | `0xf92ee8a9` |
| `LengthMismatch()` | `0xff633a38` |
| `NotAuthorizedToPause()` | `0x030b8ca4` |
| `NotBoostKeeper()` | `0xd421c73b` |
| `NotBoostRewardKeeper()` | `0xf5518543` |
| `NotInitializing()` | `0xd7e6bcf8` |
| `NotProxyAdmin()` | `0x507f487a` |
| `NotYieldRedistributor()` | `0xdea199ff` |
| `NothingToClaim()` | `0x969bf728` |
| `OwnableInvalidOwner(address)` | `0x1e4fbdf7` |
| `OwnableUnauthorizedAccount(address)` | `0x118cdaa7` |
| `OwnershipRenunciationDisabled()` | `0x43a0f09c` |
| `PermitFailed()` | `0xb78cb0dd` |
| `ReentrancyGuardReentrantCall()` | `0x3ee5aeb5` |
| `SafeERC20FailedOperation(address)` | `0x5274afe7` |
| `StaleCycle()` | `0xeb2cd311` |
| `SweepFailed()` | `0x9eec2ff8` |
| `TooManyBoostTokens()` | `0x1ff50315` |
| `ZeroAmount()` | `0x1f2a2005` |
| `ZeroCycleId()` | `0xa65f49eb` |
| `ZeroMaxBoostPerBatch()` | `0x131c8a02` |

## 8. Useful views

| View | Returns |
|---|---|
| `principal(user)` | Principal, including compounded yield and credited boost |
| `pendingYield(user)` | Yield not yet compounded (it folds into principal on the user's next interaction or a `compound`) |
| `totalValue(user)` | Principal + pending yield + legacy accrued |
| `getUserInfo(user)` | `(userPrincipal, userClaimable, userTotal, userLastIndex)` |
| `getAllClaimables(user)` | `(usdscClaimable, boostTokens[], boostAmounts[])` |
| `getVaultStats()` | `(vaultTotalPrincipal, vaultClaimReserve, vaultGlobalIndex, vaultBalance, vaultCarryRay)` |
| `latestCycleId()`, `lastCreditedCycle(user)`, `maxBoostPerBatch()`, `boostKeeper()` | Boost-credit state |
| `depositsLocked()` | `(locked, unlocksAt)` |

## 9. Using the test stack

```
# deploy (any chain with CreateX). Every variable is TEST_-prefixed so the production .env can't leak in.
TEST_DEPLOYER_PRIVATE_KEY=<test key> TEST_SALT_TAG=<e.g. 20261005> \
  forge script script/testnet/DeployEarnVaultV2TestStack.s.sol:DeployEarnVaultV2TestStack \
  --rpc-url <rpc> --broadcast --sender <test deployer address>

# faucet
cast send <TestUSDSC> "mint(address,uint256)" <you> 1000000000000 --rpc-url <rpc> --private-key <key>

# simulate a distribution (operator = deployer by default); the deposit lock is active between these two calls
cast send <TestSnapshotRedistributor> "snapshotVaultTVLs()" ...
cast send <TestUSDSC> "approve(address,uint256)" <TestSnapshotRedistributor> <amount> ...
cast send <TestSnapshotRedistributor> "distribute(uint256)" <amount> ...   # at least 1 block later, within snapshotMaxAge
```

Optional variables: `TEST_OWNER_ADDRESS`, `TEST_BOOST_KEEPER_ADDRESS`, `TEST_REDISTRIBUTOR_OPERATOR`, `TEST_MAX_BOOST_PER_BATCH` (default 50,000e6), `TEST_SNAPSHOT_MAX_AGE` (default 60 s), `TEST_USDSC_ADDRESS`. Chain 1868 (Soneium mainnet) also requires `ALLOW_SONEIUM_MAINNET_TEST=true`.
