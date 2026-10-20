# EarnVaultV2: integration guide (backend, keepers, indexer)

> **Status: audit remediations applied** (branch `earn-v2-remediations`; audited commit `5326a7d3824e9c78ae292b248e25720469b5f310`). Anything that changes before the upgrade will be flagged here.
>
> **Changed since the audited commit:**
> - `onBoostCredit` is blocked during the deposit-lock window, like deposits (section 5).
> - `onBoostCredit` funding is checked after the batch, against what is actually credited: skipped entries need no funding, and the vault must still cover `claimReserve + boostClaimReserve(USDSC)` (section 3).
> - `getAllClaimables(user).usdscClaimable` is now exactly what `claim()` pays (legacy accrued only). Read pending yield from `pendingYield(user)`.
> - New `withdrawAll()`: a full exit, including yield compounded by the call itself.
> - New views `surplusUSDSC()` and `boostClaimReserve(token)`.
> - `onBoostReward` accepts only USDSC (`BoostTokenNotUSDSC` otherwise); `removeBoostRewardToken` was removed.
> - New `depositWithAuthorization()`: gasless deposits through USDSC's ERC-3009 `receiveWithAuthorization`, including ERC-1271 smart wallets (section 2a). Use it instead of `depositWithPermit`.
> - `depositWithPermit` still goes ahead when the permit was already used, if the existing allowance covers the amount. Kept for compatibility only.

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
| **Users / frontend** | `deposit`, `depositWithAuthorization` (gasless, via a relayer), `withdraw`, `withdrawAll`, `claim` | `claim()` pays USDSC boost rewards and any legacy V1 `accrued` USDSC. Base yield auto-compounds into principal. For a full exit use `withdrawAll()`: `withdraw(principal(user))` quoted before the call leaves the yield compounded by that call behind as principal. |
| **Owner (Safe)** | `setBoostKeeper`, `setMaxBoostPerBatch`, `setBlacklisted`, pause / unpause, sweep / recover | Admin only. |

### 2a. Gasless deposits (`depositWithAuthorization`)

The user signs USDSC's ERC-3009 `ReceiveWithAuthorization` message made out to the vault; any relayer submits it:

```
depositWithAuthorization(address from, uint256 amount, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes signature)
```

- **EIP-712 domain** (read `eip712Domain()` on USDSC): name `Startale USD`, version `1`, chainId `1868` (Soneium), verifyingContract = the USDSC address.
- **Type:** `ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)` with `to` = the vault and `value` = `amount`. Type hash `0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8`.
- **Signature:** 65-byte `r‖s‖v` from an EOA, or whatever the user's ERC-1271 smart wallet accepts. No approval is needed.
- **Validity:** valid strictly after `validAfter` and strictly before `validBefore`. Pick a random 32-byte `nonce` per authorization.
- **Who can submit:** anyone, but only through the vault (USDSC rejects anyone else as the receiver), and only exactly as signed: the deposit always goes to `from`. If someone else submits it first, the user's deposit has happened and your copy reverts `AuthorizationAlreadyUsed`. Check `authorizationState(from, nonce)` on USDSC and simulate the call before sending.
- **Same rules as `deposit`:** reverts while paused, for a blacklisted `from`, for a zero amount, and during the deposit-lock window (`DepositsLockedForDistribution(unlocksAt)`; nothing is consumed, so resend the same signature from `unlocksAt`).
- **Cancel:** the user can cancel an unused authorization on USDSC with `cancelAuthorization`.
- **USDSC errors you may see:** `AuthorizationAlreadyUsed(address,bytes32)`, `AuthorizationExpired(uint256,uint256)`, `AuthorizationNotYetValid(uint256,uint256)`, `SignerMismatch()` (wrong signer, amount, payee or field), `InvalidSignatureLength()`.

---

## 3. Boost credit (reward engine and boost keeper)

### Flow for each cycle

1. **Read** `latestCycleId()` from the chain, rather than deriving cycle IDs from dates. Record your own date → `cycleId` mapping when you submit.
2. **Choose the cycle ID:**
   - more batches for the *current* cycle use `cycleId = latestCycleId`;
   - opening the *next* cycle uses `cycleId = latestCycleId + 1`.
3. **Check** `depositsLocked()` on the vault. If it is locked, wait until `unlocksAt` (section 5).
4. **Fund:** transfer the batch's credited total in USDSC to the vault, just before the call. Entries that will be skipped need no funding. After crediting, the vault checks that its balance still covers `claimReserve + boostClaimReserve(USDSC)`; `claimReserve` has grown by the credited amounts. `surplusUSDSC()` shows how much is already free.
5. **Call** `onBoostCredit(cycleId, users[], amounts[])` from the boost keeper.
6. **Reconcile** using `BoostCycleCredited`, plus one `BoostCredited` or `BoostCreditSkipped` per entry.

### Rules

- **Cycle window.** Only `latestCycleId` or `latestCycleId + 1` is accepted.
  - A closed cycle reverts `CycleIdTooOld`.
  - Skipping ahead reverts `CycleIdTooFarAhead`.
  - `0` reverts `ZeroCycleId`.
  - `latestCycleId` advances only when a batch actually credits something.
  - Cycles can be opened back to back; after downtime, **catch up one cycle per missed day**. Don't roll several days into one cycle.
- **Replay guard.** Each address can be credited at most once per cycle. Its `cycleId` must be greater than `lastCreditedCycle(user)`, or the batch reverts `StaleCycle`. A duplicate address inside one batch also reverts.
- **Per-batch cap.** If the credited total (skipped entries excluded) exceeds `maxBoostPerBatch()`, the whole batch reverts `BoostBatchCapExceeded(credited, max)`. Split large cycles into several batches; each batch can use the full cap.
- **All-or-nothing reverts:** the deposit-lock window, insufficient funding, a bad cycle, a stale cycle or duplicate, a zero address, a length mismatch, an empty batch, or exceeding the cap.
- **Per-entry skips** (the batch continues): the vault's own address, blacklisted addresses, and zero amounts.
  - The event is `BoostCreditSkipped(user, amount, cycleId, reason)`, with `reason` 0 = VaultAddress, 1 = Blacklisted, 2 = ZeroAmount.
  - A skipped entry can be re-credited **only while that cycle is current**; after that, roll the amount into a later cycle.
  - Skipped entries need no funding; USDSC sent for one stays in the vault as surplus.
- **Addresses must be AA wallets** (v1 policy). Exactly one address per user is guaranteed off-chain, by the engine.
- **Deposit-lock window** (section 5). `onBoostCredit` reverts `DepositsLockedForDistribution(unlocksAt)` during it, with no side effects: nothing is credited and the cycle doesn't move. Resend the same batch unchanged from `unlocksAt`.

### Batch sizing

Gas figures are measured with `forge test --isolate` (each batch pays its own cold storage access, as a real transaction does), with USDSC as the one active boost token, against Soneium's 40M block limit. Target at most 60% of the block, about 24M gas, per transaction. Details: `src/vaults/earn/base-tier-auto-compounding.md`.

| State of the credited addresses | Gas per entry | Entries per batch (≤ 24M gas) |
|---|---|---|
| Worst-case cold (first credit, never settled since the boost token was activated) | ~89k | **~265** |
| Already settled by `compoundMany` | ~41k | ~580 |
| Warm (later cycles) | ~38k | ~630 |

A batch that runs out of gas reverts whole; split it and resubmit with the same `cycleId`.

### Errors: what to do

| Error | Meaning | Action |
|---|---|---|
| `CycleIdTooOld(cycleId, latest)` | The cycle is closed | Re-read `latestCycleId`; roll the amounts into the current or next cycle |
| `CycleIdTooFarAhead(cycleId, latest)` | Skipped ahead | Use `latest` or `latest + 1` |
| `StaleCycle()` | An address was already credited for this cycle, or appears twice in the batch | Drop the duplicates. It's already credited, so don't resend. |
| `DepositsLockedForDistribution(unlocksAt)` | A redistributor snapshot is still usable by `distribute()` | Resend the same batch from `unlocksAt` |
| `InsufficientFunding()` | After crediting, the balance wouldn't cover `claimReserve + boostClaimReserve(USDSC)` | Transfer the rest of the credited total and retry |
| `BoostBatchCapExceeded(credited, max)` | The batch is over the cap | Split it. If the amounts look wrong, stop: this cap exists to catch engine bugs. |
| `EmptyBatch()` / `LengthMismatch()` | Malformed input | Fix the engine |
| `NotBoostKeeper()` | Wrong sender | Use the configured keeper |
| `EnforcedPause()` | The vault is paused | Wait |

**Key handling:** a credit can only use USDSC above both reserves (`surplusUSDSC()`). Fund each batch just in time, keep the keeper key dedicated to this, and rotate it with `setBoostKeeper` if needed.

---

## 4. Compound keeper

- Call `compoundMany(users)` **daily**, for depositors with `pendingYield(user) > 0`. More frequent calls add nothing: yield only moves when `onYield` runs.
- It's permissionless, never moves tokens, and emits `Compounded(user, amount)` for each address with something to fold in.
- **Batch sizing** (`--isolate`, USDSC boost token active):
  - about 63k gas per address on a first, cold touch, so about 380 addresses per 24M-gas transaction (once per address);
  - about 28.5k gas per address in steady state, about 830 per transaction.
- **Right after the V2 upgrade, before the first snapshot:** compound every depositor once, then keep the daily cadence.
- Skip addresses with zero principal or zero pending yield.

---

## 5. Deposit lock (frontend and keepers)

- **When it applies:** deposits (`deposit`, `depositWithPermit`) revert with `DepositsLockedForDistribution(unlocksAt)` while the redistributor's latest snapshot can still be distributed, i.e. while `block.timestamp - lastSnapshotTimestamp <= snapshotMaxAge`.
- **Frontend:** read `depositsLocked()`, which returns `(bool locked, uint256 unlocksAt)`. While it's locked, disable the deposit button and show a countdown to `unlocksAt`.
- **Also blocked:** `onBoostCredit` (section 3), with the same error and `unlocksAt`.
- **What stays open:** withdrawals, claims and compounding keep working during the lock.
- **Length:** the window lasts up to `snapshotMaxAge` after each snapshot (read it from the redistributor); it is planned at 1–2 minutes.

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
| `BoostRewardTokenRemoved` (no longer emitted: `removeBoostRewardToken` was removed; historical only) | `indexed address token` | `0xdd18b1b6c924f120e23d57a55960d7afa02f173e92665c132cd294390e8b5093` |
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
| `BoostTokenNotUSDSC()` | `0x8a75f013` |
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
| `getAllClaimables(user)` | `(usdscClaimable, boostTokens[], boostAmounts[])`: exactly what `claim()` pays now. `usdscClaimable` is legacy accrued only; pending yield is in `pendingYield(user)` |
| `surplusUSDSC()` | USDSC above `claimReserve + boostClaimReserve(USDSC)`, floored at 0: what a sweep would send, and the most a boost credit can use without new funding |
| `boostClaimReserve(token)` | Boost rewards owed and not yet claimed, for `token` |
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
