# EarnVaultV2 Operations Runbook

## Overview

Standard operating procedures for every role that keeps `EarnVaultV2` running: the RewardRedistributor operator, the boost credit keeper, the boost reward keeper, the compound keeper, and the Safes that hold the admin roles. It covers the daily schedule, what each keeper checks before it sends a transaction, what to monitor, and how to respond when something looks wrong.

Design background lives elsewhere and is linked rather than repeated:

- `base-tier-auto-compounding.md`: compounding, `onBoostCredit` batch sizing, the trust model and cap sizing, and the JIT deposit lock
- `earn-vault.md`: the vault's accounting, roles and boost rewards
- `../../distributor/OPERATOR_RUNBOOK.md`: RewardRedistributor snapshot and distribute procedures

## Roles

| Role | Set by | Calls | Holder guidance |
| --- | --- | --- | --- |
| Owner | two-step ownership transfer | `setBoostKeeper`, `setMaxBoostPerBatch`, `setBoostRewardKeeper`, `setPauser`, `setYieldRedistributor`, `setTreasury`, blacklist, `sweepSurplusToTreasury`, `recoverERC20` | Multisig |
| ProxyAdmin owner | ProxyAdmin | upgrades; `initializeV2` (once, inside `upgradeAndCall`) | Multisig |
| Pauser | owner | `pause` / `unpause` | Multisig |
| Boost credit keeper (`boostKeeper`) | `initializeV2`, then owner | `onBoostCredit` | Dedicated key, used for nothing else; holds only the next batch's funding |
| Boost reward keeper (`boostRewardKeeper`) | owner | `onBoostReward` (USDSC only) | Multisig, sending funding and the call as one batched transaction |
| Compound keeper | anyone (permissionless) | `compound`, `compoundMany` | Any funded key; it can only fold a user's own yield into their own principal |
| RewardRedistributor operator | RewardRedistributor admin | `snapshotVaultTVLs`, `distribute` | Dedicated key; its snapshot timing controls the deposit lock |
| RewardRedistributor admin | RewardRedistributor | `setSnapshotMaxAge`, `pause`, role grants | Multisig |

## The snapshot window

Every `snapshotVaultTVLs()` opens a window that lasts until `lastSnapshotTimestamp + snapshotMaxAge`. During that window the vault rejects anything that adds new principal, because the next `distribute()` is sized from the snapshot and new principal would share it:

| Call | During the window |
| --- | --- |
| `deposit`, `depositWithPermit` | Reverts `DepositsLockedForDistribution(unlocksAt)` |
| `onBoostCredit` | Reverts `DepositsLockedForDistribution(unlocksAt)`. Nothing is credited and the cycle does not move, so the same batch can be resent unchanged |
| `withdraw`, `claim` | Allowed |
| `compound`, `compoundMany` | Allowed (they fold already-owed yield only; see "Compound keeper") |
| `onYield`, `onBoostReward` | Allowed |

`depositsLocked()` returns `(locked, unlocksAt)`; `unlocksAt` is the first second at which the calls above succeed again. Every keeper and the frontend read it before sending.

**Keep the window short.** It is both the deposit pause and the operator's deadline to call `distribute()`. Set `snapshotMaxAge` to 1–2 minutes (RewardRedistributor admin, `setSnapshotMaxAge`). At 300 s and a snapshot every 3 hours, deposits are paused for about 40 minutes a day; at 60 s, about 8 minutes.

## Daily schedule

Run the jobs so they never overlap the snapshot window:

```
snapshot → distribute        (operator, every 3 h, inside snapshotMaxAge)
          ↓ window closes (unlocksAt)
compoundMany batches          (compound keeper, daily)
fund + onBoostCredit batches  (boost credit keeper, daily cycle)
fund + onBoostReward          (boost reward keeper, one batched transaction, daily)
          ↓
next snapshot only after the jobs above have landed
```

If a job is still running when the next snapshot is due, the operator delays the snapshot, rather than the job sending into the window.

## RewardRedistributor operator

1. `snapshotVaultTVLs()`.
2. `distribute()` in a later block, as soon as possible and within `snapshotMaxAge`.
3. On `SnapshotTooOld`, take a fresh snapshot and distribute again. Never leave a snapshot without a distribute, and never snapshot more often than the schedule: each snapshot restarts the deposit lock.
4. If TVL moves materially between snapshot and distribute (large withdrawals), take a fresh snapshot before distributing.

Full procedure and error table: `../../distributor/OPERATOR_RUNBOOK.md`.

## Boost credit keeper (`onBoostCredit`)

Before each batch:

1. Call `depositsLocked()`. If `locked`, wait until `unlocksAt`. A batch that still lands in a window (a snapshot mined just before it) reverts `DepositsLockedForDistribution(unlocksAt)` with no side effects. Resend it unchanged from `unlocksAt`.
2. Read `latestCycleId` from chain. Use it for more batches of the current cycle, or `latestCycleId + 1` to open the next one. Do not derive cycle IDs from dates; record the engine's own date → cycleId mapping when submitting.
3. Keep each batch's credited total at or below `maxBoostPerBatch`, and the batch within the gas budget (sizing table in `base-tier-auto-compounding.md`; size the first cycle by the cold-storage row).
4. Transfer the batch total in USDSC to the vault **immediately before** the batch. The call reverts `InsufficientFunding` unless the vault's USDSC covers `claimReserve + boostClaimReserve(USDSC) + batch total`.

After each batch:

5. Reconcile `BoostCredited`, `BoostCreditSkipped` and `BoostCycleCredited` against the engine's expected totals.
6. A skipped entry (vault address, blacklisted, zero amount) can be credited again under the same `cycleId` only while that cycle is still current. Once the next cycle opens, roll the amount forward into a later cycle.
7. After downtime, catch up one cycle per missed day rather than rolling several days into one cycle, so batch totals stay under the cap.

**Key handling.** The cap is per batch, not per cycle or per day, so the contract alone does not bound how much a misused keeper key can credit across many batches. What bounds it is the USDSC available above both reserves. Keep it small:

- the keeper key holds only the next batch's funding, topped up per cycle, never several cycles' worth;
- funding is sent just before the batch that uses it, so it does not sit in the vault as surplus;
- the owner sweeps surplus regularly (`sweepSurplusToTreasury`), but never between a funding transfer and the batch that uses it;
- the key is used for nothing else and can be rotated with `setBoostKeeper` at any time.

## Boost reward keeper (`onBoostReward`)

`onBoostReward` accepts only USDSC (`BoostTokenNotUSDSC` otherwise) and requires the vault's USDSC to already cover `claimReserve + boostClaimReserve(USDSC) + amount`.

1. Build one batched transaction (Safe MultiSend): transfer the USDSC amount to the vault, then `onBoostReward(USDSC, amount)`. Never send the call without its funding, or the funding without the call.
2. Send it outside the snapshot window.
3. Confirm `BoostRewardIndexed` and that the free USDSC (see "Monitoring") is unchanged.

`onBoostReward` splits the reward by principal at the moment of the call, so deposits just before it and withdrawals just after it are worth watching (see "Monitoring").

## Compound keeper (`compound`, `compoundMany`)

**Right after the V2 upgrade, before the first snapshot:** run `compoundMany` over every depositor (addresses from `Deposit` events, plus `BoostCredited` recipients once credits start). This folds the yield carried over from V1 into principal before any V2 distribution is sized.

**Then daily**, outside the snapshot window. Compounding more often than `onYield` runs gains nothing (the index only moves on `onYield`). Batch sizes and measured gas are in `base-tier-auto-compounding.md` ("Cadence and gas sizing"). Already-settled addresses are cheap but not free, so filter them off-chain when possible.

Compounding during the window is allowed by design: it only folds a user's own owed yield, adds no new funds, and shifts at most about one day's yield within one distribution. Running the daily batches outside the window keeps that shift at zero.

## Safe procedures

| Action | Who | Notes |
| --- | --- | --- |
| Lower `snapshotMaxAge` to 1–2 min | RewardRedistributor admin | Confirm the operator can distribute within it first |
| Rotate the boost credit keeper | Owner, `setBoostKeeper` | The old key stops working in the same transaction |
| Change `maxBoostPerBatch` | Owner, `setMaxBoostPerBatch` | Size with headroom over one day's largest legitimate batch; never raise it under pressure during an incident |
| Sweep surplus | Owner, `sweepSurplusToTreasury` | Only USDSC above `claimReserve + boostClaimReserve(USDSC)` can leave; schedule it outside boost credit runs |
| Pause | Pauser, `pause` | Stops deposits, withdrawals, claims, compounding and both boost entry points. `onYield` keeps working |
| Upgrade | ProxyAdmin owner | `script/upgrade/UpgradeEarnVaultToV2.s.sol`, then `VerifyEarnVaultV2Upgrade.s.sol` against the live chain. Execute away from a snapshot |

## Monitoring

The single solvency number is the **free USDSC**: `USDSC.balanceOf(vault) - claimReserve - boostClaimReserve(USDSC)`. It must never go below zero.

| Watch | Source | Alert when |
| --- | --- | --- |
| Free USDSC | vault balance, `claimReserve`, `boostClaimReserve(USDSC)` | Below 0, or a drop not explained by a sweep or a credit |
| Snapshot cadence | RewardRedistributor `VaultTVLsSnapshotCaptured` | More snapshots than scheduled, or a snapshot with no `Distributed` after it |
| Deposit lock | `depositsLocked()` | Locked for longer than `snapshotMaxAge` plus one block |
| Distribution | `Distributed`, vault `YieldIndexed` | Missed slot, or a large TVL change between snapshot and distribute |
| Boost credit cycles | `BoostCredited`, `BoostCreditSkipped`, `BoostCycleCredited` | Totals differ from the engine's expected totals; credits to unexpected addresses; skips not retried within the cycle; more batches per cycle than planned |
| Boost credit keeper balance | USDSC balance of the keeper key | More than the next cycle's funding |
| Daily boost reward | `BoostRewardIndexed` | Missing for a day, or an amount different from plan |
| Boost payout failures | `BoostRewardTransferFailed` | Any occurrence |
| Deposits around boosts | `Deposit`, `Withdraw` near `BoostRewardIndexed` | Large deposit just before and withdrawal just after a boost |
| Role and config changes | `OwnershipTransferred`, `BoostKeeperChanged`, `MaxBoostPerBatchChanged`, `BoostRewardKeeperChanged`, `PauserChanged`, `YieldRedistributorChanged`, `TreasuryChanged`, `Paused` / `Unpaused`; RewardRedistributor `RoleGranted` / `RoleRevoked`, `SnapshotMaxAgeUpdated` | Any change that was not approved in advance |
| Treasury movements | `SurplusSweptToTreasury`, `TokenRecovered` | Any occurrence not matching an approved change |

## Incident response

| Situation | Response |
| --- | --- |
| Boost credit keeper key suspected exposed, or credits that do not match the engine | Stop funding the keeper. Owner calls `setBoostKeeper` to a fresh key (or pauser pauses the vault first if credits are landing). Sweep any surplus. Reconcile every credit since the last good cycle |
| Free USDSC below 0 | Pauser pauses the vault. Stop all boost rewards and credits. Investigate before unpausing |
| Deposits stay locked (snapshots more often than scheduled) | RewardRedistributor admin revokes `OPERATOR_ROLE` or pauses the RewardRedistributor. Deposits unlock once the last snapshot passes `unlocksAt` |
| `distribute()` reverts `SnapshotTooOld` | Operator re-snapshots and distributes within `snapshotMaxAge` |
| `onBoostCredit` reverts `DepositsLockedForDistribution` | Expected if a snapshot landed first. Resend the same batch from `unlocksAt` |
| `onBoostCredit` reverts `InsufficientFunding` | Funding transfer missing or short. Send the batch total, then resend |
| `onBoostCredit` reverts `BoostBatchCapExceeded` | Split the batch. Raise the cap only through a planned owner change |
| `onBoostCredit` reverts `CycleIdTooOld` / `StaleCycle` | The cycle already moved on. Re-read `latestCycleId` and move the remaining entries to the current or next cycle |
| Unexpected role or config change | Treat it as unauthorized until confirmed. Owner (or RewardRedistributor admin) reverts it, and rotates the affected key |
