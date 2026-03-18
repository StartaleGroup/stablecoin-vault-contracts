# RewardRedistributor Operator Runbook

## Overview

This document describes the standard operating procedures for the operator role in the RewardRedistributor contract. The operator is responsible for capturing TVL snapshots and distributing yield to vaults.

## Standard Workflow

### Normal Distribution Cycle

1. **Take Snapshot** (`snapshotVaultTVLs()` — preferred, or `snapshotSusdscTVL()`)
   - Call this first to capture **both** EarnVault and sUSDSC vault TVLs, timestamp, and block number
   - **Preferred:** `snapshotVaultTVLs()` snapshots both vaults in one call (Phase 1)
   - Legacy: `snapshotSusdscTVL()` also snapshots both; use either. Must be called by operator with `OPERATOR_ROLE`
   - Contract must not be paused
   - Emits `EarnVaultTVLSnapshotCaptured` (and `SusdscTVLSnapshotCaptured`) with TVLs, timestamp, block number

2. **Wait for Next Block — minimise window**
   - **Requirement**: Must be in a different block than the snapshot (block.number > lastSnapshotBlockNumber)
   - **Best practice:** Call `distribute()` in the **next block** (or as soon as possible after) to minimise the window for post-snapshot deposits
   - This prevents same-block TVL manipulation and reduces JIT capture opportunity
   - Current block number must be `> lastSnapshotBlockNumber`

3. **Distribute Yield** (`distribute()`)
   - Call after snapshot is in a previous block (ideally next block)
   - Must be called by operator with `OPERATOR_ROLE`
   - Contract must not be paused
   - Automatically claims yield from extension and distributes to vaults using **snapshot** TVLs for the split
   - Emits `Distributed` event

4. **Repeat for Next Cycle**
   - For each new distribution, take a fresh snapshot first (`snapshotVaultTVLs()` or `snapshotSusdscTVL()`)
   - Wait for next block, then distribute

### Example Timeline

```
Block N:   snapshotVaultTVLs()     [Snapshot both vaults in block N]
Block N+1: distribute()            [Distribution in next block — minimal window]
Block M:   snapshotVaultTVLs()     [New snapshot for next distribution]
Block M+1: distribute()            [Next distribution]
```

## Configuration Parameters

### Default Values
- **Maximum Age** (`snapshotMaxAge`): 4 hours

### Valid Windows
- Snapshot must be in a **previous block** (block.number > lastSnapshotBlockNumber)
- Snapshot must be **at most** `snapshotMaxAge` old (e.g., 4 hours)
- Valid window: Previous block and within max age

## Failure Scenarios & Recovery

### Scenario 1: No Snapshot Taken

**Symptom:**
```
Error: LastSnapshotInvalid()
```

**Cause:**
- Operator called `distribute()` without taking a snapshot first
- `lastSnapshotTimestamp` is 0 or `lastSnapshotBlockNumber` is 0

**Recovery:**
1. Call `snapshotVaultTVLs()` (or `snapshotSusdscTVL()`) immediately
2. Wait for next block (advance to block.number + 1)
3. Call `distribute()`

**Prevention:**
- Always take snapshot before distributing (prefer `snapshotVaultTVLs()` to capture both vaults)
- Use monitoring to alert if `lastSnapshotTimestamp == 0` or `lastSnapshotBlockNumber == 0`

---

### Scenario 2: Snapshot in Same Block

**Symptom:**
```
Error: MustSnapshotInPreviousBlocks(<lastSnapshotBlockNumber>, <currentBlockNumber>)
```

**Cause:**
- Operator called `distribute()` in the same block as the snapshot
- `block.number == lastSnapshotBlockNumber`

**Recovery:**
1. Wait for next block (advance to block.number + 1)
2. Call `distribute()` again

**Prevention:**
- Always wait for next block after snapshot
- Check `lastSnapshotBlockNumber()` before calling `distribute()`
- Use monitoring to track block number difference

---

### Scenario 3: Snapshot Too Old (Past Maximum Age)

**Symptom:**
```
Error: SnapshotTooOld(<snapshot_timestamp>, <current_timestamp>, <max_age>)
```

**Cause:**
- Operator forgot to take a new snapshot
- More than `snapshotMaxAge` (default: 4 hours) has elapsed since last snapshot
- Snapshot is stale and no longer valid

**Recovery:**
1. Call `snapshotSusdscTVL()` to take a fresh snapshot
2. Wait for next block
3. Call `distribute()`

**Prevention:**
- Take fresh snapshot before each distribution
- Monitor `lastSnapshotTimestamp` and alert if approaching max age
- Set up automated alerts when snapshot age > 3 hours (75% of 4 hour max)

---

### Scenario 4: Contract Paused

**Symptom:**
```
Error: EnforcedPause()
```

**Cause:**
- Admin paused the contract
- Both `snapshotSusdscTVL()` and `distribute()` require contract to be unpaused

**Recovery:**
1. Contact admin to unpause: `pause(false)`
2. After unpause, take fresh snapshot: `snapshotSusdscTVL()`
3. Wait for next block
4. Call `distribute()`

**Prevention:**
- Monitor contract pause status
- Have admin contact information ready
- Plan for pause scenarios in operations

---

### Scenario 5: Operator Role Revoked

**Symptom:**
```
Error: AccessControlUnauthorizedAccount(<operator_address>, OPERATOR_ROLE)
```

**Cause:**
- Admin revoked operator's `OPERATOR_ROLE`
- Operator can no longer call `snapshotSusdscTVL()` or `distribute()`

**Recovery:**
1. Contact admin to restore `OPERATOR_ROLE`
2. Admin must call: `grantRole(OPERATOR_ROLE, <operator_address>)`
3. Resume normal workflow

**Prevention:**
- Monitor operator role status
- Have backup operator with `OPERATOR_ROLE`
- Document role management procedures

---

## Truly Irreversible States (Theoretical)

### ⚠️ These states are prevented by contract design but worth understanding

#### State 1: All Admins Lose Access (Prevented)

**Theoretical Situation:**
- All admin addresses lose private keys
- No one can modify configuration or manage roles
- Contract becomes ungovernable

**Prevention:**
- Contract prevents removing last admin: `CannotRemoveLastAdmin` error
- Admin role cannot be renounced if it's the last one
- **This state is prevented by design**

**If it somehow occurred:**
- Contract would continue operating normally
- But no configuration changes possible
- No role management possible
- Would require contract upgrade (if upgradeable) or redeployment

---

#### State 2: Contract Permanently Paused (Recoverable)

**Situation:**
- Contract is paused
- All admins lose access (see State 1)
- Cannot unpause

**Prevention:**
- Multiple admins with secure key management
- Backup admin addresses
- Multi-sig for admin operations

**Recovery:**
- If contract is upgradeable, upgrade could add new admin
- Otherwise, would require redeployment

---

#### State 3: Extension Contract Becomes Unusable (External Dependency)

**Situation:**
- Extension contract (USDSC) becomes permanently broken
- Cannot claim yield
- Cannot distribute

**Prevention:**
- Monitor extension contract health
- Have upgrade path for extension
- Design extension with fail-safes

**Recovery:**
- Depends on extension contract design
- May require extension upgrade or replacement

---

### Summary: Are There Truly Irreversible States?

**Short Answer: No, with proper design.**

All states are recoverable if:
1. ✅ At least one admin has access (protected by contract)
2. ✅ Contract is not permanently paused (admin can unpause)
3. ✅ Extension contract is functional (external dependency)

**The contract is designed to prevent irreversible states:**
- Last admin cannot be removed
- Admin can always unpause
- Configuration can always be fixed
- Roles can always be managed

**However, operator errors are recoverable:**
- Missed snapshots → Take new snapshot
- Missed distributions → Resume workflow
- Stale snapshots → Take fresh snapshot
- All operator errors have clear recovery paths

---

### Scenario 6: Yield Recipient Changed

**Symptom:**
```
Error: YieldRecipientChanged(<current_recipient>)
```

**Cause:**
- Extension's `yieldRecipient` was changed to a different address
- RewardRedistributor is no longer the yield recipient

**Recovery:**
1. Contact admin to restore yield recipient
2. Admin must call on extension: `setYieldRecipient(<reward_redistributor_address>)`
3. Resume normal workflow

**Prevention:**
- Monitor extension's `yieldRecipient` address
- Set up alerts for recipient changes
- Document extension configuration

---

### Scenario 7: No Pending Yield

**Symptom:**
- `distribute()` succeeds but no transfers occur
- No events emitted (or `Distributed` event with all zeros)

**Cause:**
- No pending yield available to distribute
- Extension has no yield to claim

**Recovery:**
- This is normal - no action needed
- Wait for yield to accumulate
- Retry `distribute()` later

**Prevention:**
- Check `previewDistribute()` before calling `distribute()` to see expected yield
- Monitor extension's pending yield
- Only call `distribute()` when yield is available
- **Note**: `previewDistribute()` shows calculations but doesn't validate snapshot validity

---

## Critical Troubleshooting States

### ⚠️ These states require admin intervention and can block operations

#### State 1: Snapshot Expired + System Paused

**Situation:**
- Snapshot is older than `snapshotMaxAge`
- Contract is paused
- Cannot take new snapshot (requires unpause)
- Cannot distribute (requires valid snapshot)

**Recovery:**
1. Admin unpauses: `pause(false)`
2. Operator takes fresh snapshot: `snapshotSusdscTVL()`
3. Wait for next block
4. Distribute: `distribute()`

**Prevention:**
- Take fresh snapshot before any planned pause
- Monitor snapshot age during pause periods
- Have unpause procedure documented

---

#### State 2: Operator Role Lost + No Backup

**Situation:**
- Operator's role was revoked
- No backup operator configured
- Cannot take snapshots or distribute

**Recovery:**
1. Admin grants role to new operator: `grantRole(OPERATOR_ROLE, <new_operator>)`
2. New operator takes fresh snapshot
3. Wait for next block
4. Distribute

**Prevention:**
- Always have at least 2 operators with `OPERATOR_ROLE`
- Document role management procedures
- Monitor operator role status

---

## Monitoring & Alerts

### Recommended Monitoring

1. **Snapshot Age**
   - Alert when: `block.timestamp - lastSnapshotTimestamp > snapshotMaxAge * 0.75`
   - Critical when: `block.timestamp - lastSnapshotTimestamp > snapshotMaxAge`

2. **Block Number Difference**
   - Alert if: `block.number == lastSnapshotBlockNumber` (same block)
   - Verify: `block.number > lastSnapshotBlockNumber` before distributing

3. **Time Since Last Distribution**
   - Alert if no distribution in 24 hours (configurable)

4. **Contract State**
   - Monitor pause status
   - Monitor operator role status
   - Monitor yield recipient address

5. **Configuration**
   - Alert on max age changes
   - Verify max age is reasonable (1 minute to 7 days)

### Key Metrics to Track

- `lastSnapshotTimestamp` - When was last snapshot taken?
- `lastSnapshotBlockNumber` - Which block was snapshot taken in?
- `snapshotMaxAge` - What's the maximum age?
- `paused()` - Is contract paused?
- `hasRole(OPERATOR_ROLE, <operator>)` - Does operator have role?

## Best Practices

### ✅ DO

- Always take snapshot before distributing
- Wait for next block before distributing
- Take fresh snapshot for each distribution cycle
- Monitor snapshot age and contract state
- Have backup operator configured
- Test procedures in staging environment
- Document any deviations from standard workflow

### ❌ DON'T

- Don't call `distribute()` without snapshot
- Don't call `distribute()` in same block as snapshot
- Don't use stale snapshots (older than max age)
- Don't assume snapshot is still valid after long pause
- Don't operate without monitoring/alerting
- Don't have only one operator (single point of failure)

## Emergency Procedures

### If Distribution Fails Repeatedly

1. **Check Error Message**
   - Identify which validation is failing
   - Refer to failure scenarios above

2. **Verify Contract State**
   - Check if paused: `paused()`
   - Check operator role: `hasRole(OPERATOR_ROLE, <operator>)`
   - Check snapshot timestamp: `lastSnapshotTimestamp()`
   - Check snapshot block: `lastSnapshotBlockNumber()`
   - Check configuration: `snapshotMaxAge()`

3. **Take Corrective Action**
   - Follow recovery steps for identified scenario
   - If unclear, contact admin

4. **Verify Fix**
   - Use `previewDistribute()` to verify calculations before actual distribution
   - **Note**: `previewDistribute()` doesn't validate snapshot, so verify snapshot validity separately
   - Check that `block.number > lastSnapshotBlockNumber` and snapshot is not too old

### If System Needs to be Paused

1. **Before Pause:**
   - Take fresh snapshot if possible
   - Complete any in-progress distributions
   - Document current state

2. **During Pause:**
   - Monitor snapshot age
   - Plan for fresh snapshot after unpause

3. **After Unpause:**
   - Take fresh snapshot immediately
   - Wait for next block
   - Resume distributions

## Preview Functions (Before Distributing)

### Check Distribution Before Executing

Before calling `distribute()`, you can preview what will happen:

**`previewDistribute()`** - Preview the exact distribution that would occur
- Returns: `(couldBeMinted, feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield)`
- Shows what would be distributed without actually executing
- Uses snapshot TVL (`lastSusdscTVL`) for calculations
- **Note**: Does NOT validate snapshot age/block number (unlike `distribute()`)
- Safe to call even if snapshot is stale - it will show what distribution would look like with current snapshot

**`previewSplitCurrent()`** - Preview split with current carries
- Returns same values but includes carry calculations
- Useful for understanding carry accumulation

**Best Practice:**
```solidity
// Before distributing, check preview
(uint256 minted, uint256 fee, uint256 toEarn, uint256 toOn, ...) = rr.previewDistribute();

// Verify values look reasonable
if (minted > 0) {
    // IMPORTANT: Ensure snapshot is valid before distributing
    // - block.number > lastSnapshotBlockNumber
    // - block.timestamp - lastSnapshotTimestamp <= snapshotMaxAge
    // Then proceed with distribution
    rr.distribute();
}
```

**Important Notes:**
- `previewDistribute()` uses the snapshot TVL for calculations, so it reflects what distribution would look like with the current snapshot
- However, `previewDistribute()` does NOT validate snapshot age or block number
- Always verify snapshot validity separately before calling `distribute()`

## Quick Reference

### Function Call Order
```
1. snapshotVaultTVLs()  (or snapshotSusdscTVL())  [Wait for next block — minimise window]
2. distribute()
```

### Block Requirements
- **Block requirement**: Must be in different block (block.number > lastSnapshotBlockNumber)
- **Maximum age**: `snapshotMaxAge` (default: 4 hours) - time-based limit to prevent stale snapshots
- **Valid window**: Previous block (block-based) AND within max age (time-based)

### Common Errors
| Error | Cause | Fix |
|-------|-------|-----|
| `LastSnapshotInvalid()` | No snapshot | Take snapshot |
| `MustSnapshotInPreviousBlocks(...)` | Same block | Wait for next block |
| `SnapshotTooOld(...)` | Too old | Take fresh snapshot |
| `EnforcedPause()` | Contract paused | Admin unpause |
| `AccessControlUnauthorizedAccount(...)` | No role | Admin grant role |

## What Happens If Operator Misses Calls?

### Missed Snapshot Before Distribution

**If operator forgets to take snapshot:**
- `distribute()` will revert with `LastSnapshotInvalid()`
- **Recovery**: Take snapshot, wait for next block, then distribute
- **Impact**: Distribution delayed by one block (block time depends on network, typically 12 seconds on Ethereum)

### Missed Distribution

**If operator forgets to distribute:**
- Yield accumulates in extension
- No immediate impact (yield is safe)
- **Recovery**: Take fresh snapshot (if old one expired), wait for next block, distribute
- **Impact**: Users don't receive yield until next distribution

### Missed Snapshot Refresh (Snapshot Expired)

**If operator forgets to take new snapshot and old one expires:**
- `distribute()` will revert with `SnapshotTooOld(...)`
- **Recovery**: Take fresh snapshot, wait for next block, then distribute
- **Impact**: Distribution delayed by one block (block time depends on network, typically 12 seconds on Ethereum)

### Multiple Missed Cycles

**If operator misses multiple distributions:**
- Yield continues accumulating in extension
- Each missed cycle requires: fresh snapshot → wait for next block → distribute
- **Recovery**: Resume normal workflow (one cycle at a time)
- **Impact**: Users receive accumulated yield when distribution resumes

## Support

For issues requiring admin intervention:
- Contact admin to modify configuration
- Contact admin to manage roles
- Contact admin to pause/unpause

For operational issues:
- Check this runbook first
- Verify contract state
- Review recent transactions
- Check monitoring/alerting
