# IdentityRegistry — Implementation Spec

For the coding agent working in the vaults repo. Self-contained: you shouldn't need the surrounding design docs to build from this. Companion: `4-review-checklist-open-loose-ends.md` (open items), `3-contract-implementation-design.md` (system architecture).

Last updated: 2026-09-17 (status note and §10 revised 2026-09-23).

> **Status (2026-09-23):** this is the pre-implementation spec `IdentityRegistry.sol` was built from, kept for design rationale. **Where the two differ, the contract and its NatSpec are authoritative.** Known divergences:
>
> - **§1, §6, §9, §11 — no `VipBoostDistributor`.** It was dropped; boost is pushed as principal by `EarnVaultV2.onBoostCredit()`, which calls `registeredAddress()` once per batch entry. §11's "the vault never calls this contract" no longer holds.
> - **§4, §5.4 — signer set, not one signer.** `backendSigners` is a bounded set (`MAX_BACKEND_SIGNERS = 10`, any one signature suffices), managed via `addBackendSigner`/`removeBackendSigner`. Storage also gained `batchNonce` and the pending-recovery mappings.
> - **§5.1 — only the registry itself is reserved.** The registry does not track the EarnVault address. The "can't pay the vault itself" guard lives solely in `EarnVaultV2.onBoostCredit()` (`user == address(this)` reverts the whole batch), in the contract that would be harmed, with no extra storage, setter or deployment-ordering constraint here. Binding the vault's address needs a backend signature (`switchAddress` can't: the vault cannot produce a valid signature, having no `isValidSignature` and a reverting fallback).
> - **§5.2 — `switchAddress` IS `msg.sender`-gated** to the current registered address, reversing "do not gate on `msg.sender`": `identityId` is public, so a signature-only design let anyone redirect any identity to an address they control. The `newAddr` signature is still required on top, as squatting prevention. AA gas sponsorship is unaffected (the AA itself is `msg.sender`).
> - **§5.3 — recovery cancellation.** Added owner-only `cancelRecovery`; `switchAddress` and `migrationCorrection` also cancel a pending recovery.
> - **§7 — grace window is a separate function.** Because of the §5.2 gate, a user whose backfilled address is wrong cannot call `switchAddress` at all, so the one-time correction is a backend-signed `migrationCorrection()` (once per identity, while `migrationGraceEnd` is open) instead of a cooldown-exempt `switchAddress`.
> - **§10 — rewritten below** for the current contracts.
>
> The companion docs referenced below are not in this repo.

---

## 1. What this contract is for

Maps one **loyalty identity** to one **payout address**. That address serves two roles simultaneously:

1. **Where principal counts** — the off-chain reward engine reads `EarnVault.principal()` at this address to compute boost eligibility.
2. **Where boost is paid** — `VipBoostDistributor.claim()` calls `registeredAddress(identityId)` to resolve the payout destination at claim time.

The registry holds **no tier data, no thresholds, no rates, no principal**. `EarnVault` never reads it. It is a pure identity↔address binding.

### Why it exists at all (context the implementation depends on)

Boost is banded per tier — e.g. Basic `first $500 @ 5.5%, next $1,000 @ 4.5%, rest at base rate`. Bands are computed **entirely off-chain** by the reward engine and paid as a fixed amount per identity per cycle via a Merkle root.

**The banded structure is what makes identity uniqueness load-bearing.** Under a flat-rate boost, splitting a balance across N addresses earns exactly the same total — splitting gains nothing. Under bands, the first band carries the best rate in the system, so splitting lets a holder **re-capture the top band repeatedly**. The loyalty spec quantifies this: because gas is sponsored, one holder with $500,000 split across 250 accounts at a $2,000 cap captures ~57% of the annual boost budget. Hence: the cap must be enforced per identity, never per address, and every depositor (including Basic tier) must be registered.

This is worth flagging to whoever owns KYC as an explicit "how confident are we in identity uniqueness" conversation — bands made that assumption substantially more load-bearing than the earlier flat-rate design did.

---

## 2. Decisions already made — do not relitigate

| Decision | Rationale |
|---|---|
| Key by `identityId`, not by address | The key must be the one thing that never changes. If keyed by AA address, a recovery/key-loss/AA-migration event orphans `VipBoostDistributor`'s `claimed[cycleId][identityId]` watermarks and every unclaimed root pointing at the old address — requiring an admin `migrateIdentity()` with real power over payout state. With a stable key, the same event is one write and watermarks are untouched. AA-address permanence is not safe to assume. |
| `identityId = keccak256(abi.encodePacked(userId, salt))` — **salted** | Unsalted was considered and rejected. UUIDv4 has 128 bits of entropy, so unsalted would be unlinkable *if* the UUID existed only inside the erasure boundary — but it does not: the frontend holds it, and it plausibly reaches API logs, analytics and support tooling. Anyone retaining a pre-erasure copy could recompute an unsalted hash and re-link on-chain activity, making erasure paper-only. A salt held in exactly one narrow access-controlled service makes erasure "delete the one secret that was never anywhere else," independent of where the UUID travelled. |
| `register()` authorized by **backend EIP-712 signature**, not by a caller role | Separates the signing key from the hot submitting key. If the relayer key is compromised, an attacker still cannot forge registrations without the separate signing key. A role-gated design collapses both into one key — the wrong direction given a prior AA exploit. Costs nothing operationally: the same backend can submit the transaction and trivially produce the signature. |
| Reverse index `identityOf[address]`, enforced | WL-4: nothing otherwise stops two identities binding the same address. This is a write-time integrity check and needs the reverse map on-chain regardless of which way the primary key runs. |
| One AA wallet per user | Removes multi-wallet farming and any ambiguity about which address to register. Does **not** remove the need for switch/recovery — an AA can still be lost or need migrating. |

### Salt operational requirements (new single point of failure — handle deliberately)

- Lives in **one** access-controlled service. Never sent to the frontend, never logged, never in analytics.
- **If the salt is lost, every on-chain mapping becomes unrecoverable at once.** Needs a real backup/escrow story before launch.
- Treat as **never rotated**. Rotation = re-deriving every `identityId` = full re-registration of the entire user base. Document it as non-rotatable rather than leaving it implied.
- Same salt across all environments, or explicitly different per environment with the difference documented — a silent mismatch means every identity resolves to nothing.

---

## 3. Blocking pre-work (must be settled before Phase 1)

- [ ] **Freeze the `identityId` derivation spec and commit test vectors.** Exact input encoding — canonical lowercase hyphenated UUID string (`"609a8f70-a660-41fd-84e4-347fd536addc"`) vs. raw 16 bytes — plus salt concatenation order and hash function. `keccak256("609a8f70-…")` ≠ `keccak256(0x609a8f70…)`. If backend and engine disagree on this detail, **every identity silently mismatches and boost pays to nobody**. One fixture file in the repo, consumed by both contract tests and the engine.
- [ ] **Upgradeability decision, coupled to the distributor.** `VipBoostDistributor` holds `IIdentityRegistry public immutable REGISTRY`, so replacing the registry requires redeploying the distributor. Either make the registry upgradeable, or make `REGISTRY` settable there. Pick one — do not ship both immutable.
- [ ] **Legal sign-off on the salted-hash approach** (Entra Law, PDPA/APPI). Put both framings to them: unsalted is simpler and sufficient *if* the UUID never persists outside the erasure boundary; salted costs operational overhead but doesn't depend on that guarantee. Default to salted pending their answer.
- [ ] **Lost-wallet recovery: launch or defer?** If deferred, the app hides any re-link path and support handles it manually — write that down explicitly.
- [ ] **Confirm the migration source list** — largest-principal address per identity at a snapshot block (see §7).
- [ ] **Confirm `switchAddress` signer**: new address, old address, or both (see §5.2).

---

## 4. Storage

```solidity
mapping(bytes32 identityId => address) public registeredAddress;  // forward
mapping(address => bytes32 identityId) public identityOf;         // reverse, WL-4
mapping(bytes32 identityId => uint256) public nonces;             // WL-7 replay guard
mapping(bytes32 identityId => uint64) public lastSwitchAt;        // cooldown anchor
mapping(bytes32 identityId => bool) public migrationGraceUsed;    // see §7

address public backendSigner;   // EIP-712 signer for register / recovery
address public pauser;
uint64  public switchCooldown;  // 48 hours at launch
uint64  public migrationGraceEnd; // timestamp; see §7
```

Ownable2Step for ownership, Pausable for pause, EIP-712 domain (name, version, chainId, verifyingContract).

---

## 5. Functions

### 5.1 `register`

```solidity
function register(
  bytes32 identityId,
  address addr,
  uint256 nonce,
  uint64 expiry,
  bytes calldata signature
) external whenNotPaused;
```

- **Permissionless to submit.** Authorization is entirely the `backendSigner` EIP-712 signature. `msg.sender` is not checked.
- No signature from the target address (WL-5 carve-out): at signup the AA is Startale-created; at migration the address already holds the user's principal. Requiring a target signature here would make the ~12k backfill and signup auto-registration impossible.
- Revert if: identity already registered, `addr` is zero, `addr` already bound to a different identity (WL-4), `addr` is the vault / distributor / this registry, nonce mismatch, expired, bad signature.
- Increment `nonces[identityId]`. Set `lastSwitchAt[identityId] = block.timestamp`.

### 5.1b `registerBatch`

```solidity
function registerBatch(
  bytes32[] calldata identityIds,
  address[] calldata addrs,
  uint64 expiry,
  bytes calldata signature
) external whenNotPaused;
```

**One signature over the whole batch**, not per entry — sign `keccak256(abi.encode(identityIds, addrs, expiry, batchNonce))`. This preserves the key-separation property at near-zero marginal cost. Per-entry signatures would add ~65 bytes calldata and ~3k gas each; across ~11,838 identities that's ~780KB of extra calldata and ~36M extra gas for no additional security.

**Batch sizing:** two cold zero→nonzero SSTOREs per identity (~40k) plus overhead ≈ **~48k gas per identity**. At ~11,838 identities that's ~570M gas total → roughly **440 per batch at 50% of Soneium's 40M block limit, so ~27 one-time transactions**, ~28KB calldata each. Confirm against a real `forge` gas snapshot before sizing for production.

### 5.2 `switchAddress`

```solidity
function switchAddress(
  bytes32 identityId,
  address newAddr,
  uint256 nonce,
  uint64 expiry,
  bytes calldata signature
) external whenNotPaused;
```

- **Permissionless to submit** so a relayer can pay gas; authorization is the signature alone. Do **not** gate on `msg.sender`.
- Verify via OpenZeppelin **`SignatureChecker`** (ECDSA + EIP-1271), never raw `ecrecover` — roughly half the user base is AA wallets and `ecrecover` would silently exclude them (WL-8). Skip ERC-6492: a depositing AA is already deployed.
- EIP-712 struct binds `identityId`, `newAddr`, `nonce`, `expiry`, `chainId`, `verifyingContract` (WL-7).
- **Signer: the new address** — recommended, pending the Phase-0 confirmation. The risk being defended is boost paid to an address the user doesn't control, so proving control of the *destination* is what matters. Requiring both old and new is the belt-and-braces variant if product wants it.
- Enforce `block.timestamp >= lastSwitchAt[identityId] + switchCooldown`, **except** during the migration grace window (§7).
- Revert if `newAddr` is zero, equals the current address, or is bound to another identity.
- **Update both mappings atomically and delete the stale reverse entry.** An add-without-delete leaves the old address still resolving to the identity — recreating the exact stale-eligibility bug the reverse index exists to prevent.

### 5.3 Recovery (only if Phase 0 says launch)

```solidity
function initiateRecovery(bytes32 identityId, address newAddr, ...) external;  // backendSigner-signed
function finalizeRecovery(bytes32 identityId) external;                        // after 72h delay
function cancelRecovery(bytes32 identityId) external;                          // onlyOwner escape hatch
```

`cancelRecovery` exists because a pending recovery can otherwise deadlock: `initiateRecovery` refuses while one is pending, and `finalizeRecovery` reverts forever if the target was bound elsewhere or became reserved during the delay (or ops simply picked the wrong target).

Separate from `switchAddress` — different threat model, different authorization. Emits on initiation so the app can notify the old address. 72h delay is independent of the 48h switch cooldown; both clocks coexist.

### 5.4 Admin

`setBackendSigner`, `setSwitchCooldown`, `setPauser`, `setMigrationGraceEnd` — all `onlyOwner`, all emit before/after values.

### 5.5 Views

`registeredAddress(bytes32)`, `identityOf(address)`, `isRegistered(address)`, `nonces(bytes32)`.

---

## 6. Pause semantics

Pause blocks `register`, `registerBatch`, `switchAddress`, recovery. **Pause must never block any view.** `VipBoostDistributor.claim()` calls `registeredAddress()` and is deliberately never pause-gated — if a paused registry could brick that view, pausing the registry would freeze claims indirectly, which is exactly the behavior the distributor's design rejects.

---

## 7. Migration backfill

**Default to the address holding that identity's largest principal at a snapshot block — not blindly the AA.** Roughly half of vault principal sits in EOAs; defaulting those users to their AA would silently drop them to base rate on day one with no action from them.

**Grace window for the backfill's own imperfection:** the snapshot heuristic will pick the wrong address for some users. Give one cooldown-exempt correction shortly after migration via `migrationGraceEnd` + `migrationGraceUsed` — during the window, an identity's first `switchAddress` skips the cooldown check and sets `migrationGraceUsed`. Without this, the backfill's heuristic can trap a user in a suboptimal registration for the full cooldown through no fault of their own.

---

## 8. Invariants (assert in tests)

- `registeredAddress[id] == a` ⟺ `identityOf[a] == id`, always, after every operation.
- No address ever maps to two identities; no identity ever maps to two addresses.
- `nonces[id]` strictly increases; no signature is ever valid twice.
- Views never revert, in any state, paused or not.
- After a switch, the old address resolves to `bytes32(0)` via `identityOf`.

---

## 9. Test requirements

**Unit:** every revert path in §5; cooldown boundaries (exact second before/after); expired, replayed, wrong-signer, malformed signatures; self-switch; switch to an address bound elsewhere; EIP-1271 signer (deploy a mock AA); migration grace consumed once only.

**Fuzz:** random sequences of register/switch across many identities, asserting the §8 invariants hold throughout.

**Integration with `VipBoostDistributor`:** claim after a switch pays the new address; claim for an unregistered identity reverts cleanly with `IdentityNotRegistered`; claim while the registry is paused still succeeds.

**Gas:** `forge` snapshot for `register`, `registerBatch` at several sizes, `switchAddress` for both ECDSA and EIP-1271 signers.

---

## 10. Deployment and integration order

1. Deploy `IdentityRegistry(owner, backendSigners, pauser, switchCooldown)`. It holds no vault reference, so there is nothing to wire before the backfill.
2. Upgrade the proxy to `EarnVaultV2` with **one** `ProxyAdmin.upgradeAndCall(proxy, v2Impl, initializeV2(boostKeeper, registry))`. `initializeV2` only accepts the ProxyAdmin as caller, so it cannot be run any other way; if an upgrade lands without it, boost credit is disabled (no boostKeeper) until you repeat `upgradeAndCall` to the same implementation with it, or the owner calls `setBoostKeeper`/`setIdentityRegistry`.
   - *Fresh deploy instead (no V1 history):* construct the proxy with the base `initialize()`, then `upgradeAndCall` to the same implementation with `initializeV2`. It cannot go in the proxy's constructor calldata: OZ v5 runs that before the ProxyAdmin exists, so it reverts `NotProxyAdmin`.
3. **Run the full backfill (`registerBatch`) before the first `onBoostCredit`** — an unregistered identity reverts the whole credit batch.
4. Hand the engine team the event ABI (registration/switch/recovery events for attribution; `BoostCredited`/`BoostCycleCredited` for reconciliation). The engine must drop zero-amount entries before batching: a zero entry still consumes that identity's `cycleId`.

---

## 11. Explicitly out of scope

No tier data. No thresholds, rates, or bands. No principal or balance tracking. No boost computation. No relationship to `EarnVault` in either direction — the vault never calls this contract and this contract never calls the vault. Multi-identity (sybil) defense lives in the off-chain KYC layer, not here.
