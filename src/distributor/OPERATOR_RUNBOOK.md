# RewardRedistributor Operator Runbook

## Overview

This document describes the standard operating procedures for the operator role in the RewardRedistributor contract. The operator is responsible for capturing TVL snapshots and distributing yield to vaults.

## Standard Workflow

### Normal Distribution Cycle

1. **Take Snapshot** (`snapshotSusdscTVL()`)
   - Call this first to capture the current sUSDSC vault TVL
   - Must be called by operator with `OPERATOR_ROLE`
   - Contract must not be paused
   - Emits `SusdscTVLSnapshotCaptured` event

2. **Wait for Cooldown Period**
   - Minimum wait time: `snapShotCutoffPeriod` (default: 15 minutes)
   - This prevents same-block TVL manipulation attacks
   - You can check `lastSnapshotTimestamp()` to see when snapshot was taken

3. **Distribute Yield** (`distribute()`)
   - Call after cooldown period has elapsed
   - Must be called by operator with `OPERATOR_ROLE`
   - Contract must not be paused
   - Automatically claims yield from extension and distributes to vaults
   - Emits `Distributed` event

4. **Repeat for Next Cycle**
   - For each new distribution, take a fresh snapshot first
   - Wait for cooldown, then distribute

### Example Timeline

```
T=0:    snapshotSusdscTVL()     [Snapshot taken]
T=15m:  distribute()            [Cooldown elapsed, distribution succeeds]
T=30m:  snapshotSusdscTVL()     [New snapshot for next distribution]
T=45m:  distribute()            [Next distribution]
```

## Configuration Parameters

### Default Values
- **Cooldown Period** (`snapShotCutoffPeriod`): 15 minutes
- **Maximum Age** (`snapshotMaxAge`): 4 hours

### Valid Windows
- Snapshot must be **at least** `snapShotCutoffPeriod` old (e.g., 15 minutes)
- Snapshot must be **at most** `snapshotMaxAge` old (e.g., 4 hours)
- Valid window: Between cooldown and max age

## Failure Scenarios & Recovery

### Scenario 1: No Snapshot Taken

**Symptom:**
```
Error: SnapShotCutoffPeriodNotElapsed(0, <current_timestamp>, <cooldown_period>)
```

**Cause:**
- Operator called `distribute()` without taking a snapshot first
- `lastSnapshotTimestamp` is 0

**Recovery:**
1. Call `snapshotSusdscTVL()` immediately
2. Wait for cooldown period (15 minutes default)
3. Call `distribute()`

**Prevention:**
- Always take snapshot before distributing
- Use monitoring to alert if `lastSnapshotTimestamp == 0`

---

### Scenario 2: Snapshot Too Recent (Cooldown Not Elapsed)

**Symptom:**
```
Error: SnapShotCutoffPeriodNotElapsed(<snapshot_timestamp>, <current_timestamp>, <cooldown_period>)
```

**Cause:**
- Operator called `distribute()` too soon after taking snapshot
- Less than `snapShotCutoffPeriod` has elapsed

**Recovery:**
1. Wait until `block.timestamp - lastSnapshotTimestamp >= snapShotCutoffPeriod`
2. Call `distribute()` again

**Prevention:**
- Always wait at least the cooldown period after snapshot
- Check `lastSnapshotTimestamp()` before calling `distribute()`
- Use monitoring to track time elapsed since snapshot

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
2. Wait for cooldown period (15 minutes default)
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
3. Wait for cooldown period
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
- Check `previewDistribute()` before calling `distribute()`
- Monitor extension's pending yield
- Only call `distribute()` when yield is available

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
3. Wait for cooldown
4. Distribute: `distribute()`

**Prevention:**
- Take fresh snapshot before any planned pause
- Monitor snapshot age during pause periods
- Have unpause procedure documented

---

#### State 2: Cooldown > Max Age (Configuration Error)

**Situation:**
- Admin misconfigured: `snapShotCutoffPeriod >= snapshotMaxAge`
- No valid window exists
- All distributions will fail

**Recovery:**
1. Admin fixes configuration:
   - Reduce cooldown: `setSnapShotCutoffPeriod(<value < maxAge>)`
   - OR increase max age: `setSnapshotMaxAge(<value > cooldown>)`
2. Operator takes fresh snapshot
3. Wait for cooldown
4. Distribute

**Prevention:**
- Contract validates: `cooldown < maxAge` on both setters
- Monitor configuration changes
- Test configuration changes in staging first

---

#### State 3: Operator Role Lost + No Backup

**Situation:**
- Operator's role was revoked
- No backup operator configured
- Cannot take snapshots or distribute

**Recovery:**
1. Admin grants role to new operator: `grantRole(OPERATOR_ROLE, <new_operator>)`
2. New operator takes fresh snapshot
3. Wait for cooldown
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

2. **Time Since Last Distribution**
   - Alert if no distribution in 24 hours (configurable)

3. **Contract State**
   - Monitor pause status
   - Monitor operator role status
   - Monitor yield recipient address

4. **Configuration**
   - Alert on cooldown/max age changes
   - Verify: `cooldown < maxAge` after any change

### Key Metrics to Track

- `lastSnapshotTimestamp` - When was last snapshot taken?
- `snapShotCutoffPeriod` - What's the cooldown requirement?
- `snapshotMaxAge` - What's the maximum age?
- `paused()` - Is contract paused?
- `hasRole(OPERATOR_ROLE, <operator>)` - Does operator have role?

## Best Practices

### ✅ DO

- Always take snapshot before distributing
- Wait for cooldown period before distributing
- Take fresh snapshot for each distribution cycle
- Monitor snapshot age and contract state
- Have backup operator configured
- Test procedures in staging environment
- Document any deviations from standard workflow

### ❌ DON'T

- Don't call `distribute()` without snapshot
- Don't call `distribute()` before cooldown elapses
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
   - Check configuration: `snapShotCutoffPeriod()`, `snapshotMaxAge()`

3. **Take Corrective Action**
   - Follow recovery steps for identified scenario
   - If unclear, contact admin

4. **Verify Fix**
   - Use `previewDistribute()` to verify before actual distribution
   - Check that all validations would pass

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
   - Wait for cooldown
   - Resume distributions

## Preview Functions (Before Distributing)

### Check Distribution Before Executing

Before calling `distribute()`, you can preview what will happen:

**`previewDistribute()`** - Preview the exact distribution that would occur
- Returns: `(couldBeMinted, feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield)`
- Shows what would be distributed without actually executing
- Requires valid snapshot (same validation as `distribute()`)

**`previewSplitCurrent()`** - Preview split with current carries
- Returns same values but includes carry calculations
- Useful for understanding carry accumulation

**Best Practice:**
```solidity
// Before distributing, check preview
(uint256 minted, uint256 fee, uint256 toEarn, uint256 toOn, ...) = rr.previewDistribute();

// Verify values look reasonable
if (minted > 0) {
    // Proceed with distribution
    rr.distribute();
}
```

## Quick Reference

### Function Call Order
```
1. snapshotSusdscTVL()  [Wait cooldown]  2. distribute()
```

### Time Requirements
- **Minimum wait**: `snapShotCutoffPeriod` (default: 15 minutes)
- **Maximum age**: `snapshotMaxAge` (default: 4 hours)
- **Valid window**: Between minimum and maximum

### Common Errors
| Error | Cause | Fix |
|-------|-------|-----|
| `SnapShotCutoffPeriodNotElapsed(0, ...)` | No snapshot | Take snapshot |
| `SnapShotCutoffPeriodNotElapsed(t, ...)` | Too recent | Wait for cooldown |
| `SnapshotTooOld(...)` | Too old | Take fresh snapshot |
| `EnforcedPause()` | Contract paused | Admin unpause |
| `AccessControlUnauthorizedAccount(...)` | No role | Admin grant role |

## What Happens If Operator Misses Calls?

### Missed Snapshot Before Distribution

**If operator forgets to take snapshot:**
- `distribute()` will revert with `SnapShotCutoffPeriodNotElapsed(0, ...)`
- **Recovery**: Take snapshot, wait cooldown, then distribute
- **Impact**: Distribution delayed by cooldown period (~15 minutes)

### Missed Distribution

**If operator forgets to distribute:**
- Yield accumulates in extension
- No immediate impact (yield is safe)
- **Recovery**: Take fresh snapshot (if old one expired), wait cooldown, distribute
- **Impact**: Users don't receive yield until next distribution

### Missed Snapshot Refresh (Snapshot Expired)

**If operator forgets to take new snapshot and old one expires:**
- `distribute()` will revert with `SnapshotTooOld(...)`
- **Recovery**: Take fresh snapshot, wait cooldown, then distribute
- **Impact**: Distribution delayed by cooldown period (~15 minutes)

### Multiple Missed Cycles

**If operator misses multiple distributions:**
- Yield continues accumulating in extension
- Each missed cycle requires: fresh snapshot → wait cooldown → distribute
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

