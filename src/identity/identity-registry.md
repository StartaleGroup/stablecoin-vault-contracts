# IdentityRegistry — Implementation Spec

For the coding agent working in the vaults repo. Self-contained: you shouldn't need the surrounding design docs to build from this. Companion: `4-review-checklist-open-loose-ends.md` (open items), `3-contract-implementation-design.md` (system architecture).

Last updated: 2026-09-17 (status note and §10 revised 2026-09-23).

> **UNWIRED (2026-09-23): `IdentityRegistry` is not deployed, not in audit scope, and must be audited before any use.** Boost is AA-wallet-only for v1: the backend holds the user → AA-address mapping, and `EarnVaultV2.onBoostCredit(cycleId, address[] users, amounts)` credits addresses directly — nothing on-chain reads this registry. The contract and its unit tests stay in the repo as the starting point if on-chain identity mapping is ever wanted (see §10, "If reinstated"). Everything below is the registry's own design, kept for that purpose; statements about the vault calling `registeredAddress()` describe the wired design, not the current vault.

> **Status (2026-09-23):** this is the pre-implementation spec `IdentityRegistry.sol` was built from, kept for design rationale. **Where the two differ, the contract and its NatSpec are authoritative.** Known divergences:
>
> - **§1, §6, §9, §11 — no `VipBoostDistributor`.** It was dropped. In the wired design, boost was pushed as principal by an `onBoostCredit()` that called `registeredAddress()` once per batch entry; that version is no longer in the vault (it credits addresses directly — see the UNWIRED banner).
> - **§4, §5.4 — signer set, not one signer.** `backendSigners` is a bounded set (`MAX_BACKEND_SIGNERS = 10`, any one signature suffices), managed via `addBackendSigner`/`removeBackendSigner`. Storage also gained `batchNonce`.
> - **§5.1 — only the registry itself is reserved.** The registry does not track the EarnVault address. The vault's own guard (skip any credit entry that is `address(this)`) lives in `EarnVaultV2.onBoostCredit()`. In the wired design a user could bind their identity to the vault's address via `switchAddress` (see §5.2) and the credit would be skipped; blacklisted addresses are skipped the same way.
> - **§5.2 — `switchAddress(identityId, newAddr)` is `msg.sender`-gated only**, reversing "do not gate on `msg.sender`": `identityId` is public, so a signature-only design let anyone redirect any identity to an address they control. There is no `newAddr` signature, nonce or expiry (see §5.2 for the accepted consequences). AA gas sponsorship is unaffected (the AA itself is `msg.sender`).
> - **§5.3, §7 — no recovery and no migration correction (deliberate).** The only write paths are `register`, `registerBatch` and `switchAddress`, and `switchAddress` is the only rebind. Consequences, accepted: a user who loses their key stays bound to a dead address and can never earn boost on future deposits (they cannot get a second identity); and an identity the backfill registers to the wrong address stays there, since `switchAddress` can only be called from the registered address. If that becomes unacceptable, the minimal restoration is a single `forceRebind(identityId, newAddr)` with an event, not the old two-phase recovery. Intended shape: gated by `onlyOwner` or a dedicated recoverer role. It is a rare, deliberate, human-initiated action with no automation behind it, so it needs no hot key. Not needed now.
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
| Key by `identityId`, not by address | The key must be the one thing that never changes. If keyed by AA address, a switch/key-loss/AA-migration event orphans `VipBoostDistributor`'s `claimed[cycleId][identityId]` watermarks and every unclaimed root pointing at the old address — requiring an admin `migrateIdentity()` with real power over payout state. With a stable key, the same event is one write and watermarks are untouched. AA-address permanence is not safe to assume. |
| `identityId = keccak256(abi.encodePacked(userId, salt))` — **salted** | Unsalted was considered and rejected. UUIDv4 has 128 bits of entropy, so unsalted would be unlinkable *if* the UUID existed only inside the erasure boundary — but it does not: the frontend holds it, and it plausibly reaches API logs, analytics and support tooling. Anyone retaining a pre-erasure copy could recompute an unsalted hash and re-link on-chain activity, making erasure paper-only. A salt held in exactly one narrow access-controlled service makes erasure "delete the one secret that was never anywhere else," independent of where the UUID travelled. |
| `register()` authorized by **backend EIP-712 signature**, not by a caller role | Separates the signing key from the hot submitting key. If the relayer key is compromised, an attacker still cannot forge registrations without the separate signing key. A role-gated design collapses both into one key — the wrong direction given a prior AA exploit. Costs nothing operationally: the same backend can submit the transaction and trivially produce the signature. |
| Reverse index `identityOf[address]`, enforced | WL-4: nothing otherwise stops two identities binding the same address. This is a write-time integrity check and needs the reverse map on-chain regardless of which way the primary key runs. |
| One AA wallet per user | Removes multi-wallet farming and any ambiguity about which address to register. Does **not** remove the need for `switchAddress` — an AA can still need migrating. (A lost AA is not recoverable in this version; see the status note.) |

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
- [x] **Lost-wallet recovery: launch or defer?** Decided: not implemented (see the status note). The app must not offer a re-link path for lost keys.
- [ ] **Confirm the migration source list** — largest-principal address per identity at a snapshot block (see §7).
- [ ] **Confirm `switchAddress` signer**: new address, old address, or both (see §5.2).

---

## 4. Storage

```solidity
mapping(bytes32 identityId => address) public registeredAddress;  // forward
mapping(address => bytes32 identityId) public identityOf;         // reverse, WL-4
mapping(bytes32 identityId => uint256) public nonces;             // WL-7 replay guard
mapping(bytes32 identityId => uint64) public lastSwitchAt;        // cooldown anchor

address public backendSigner;   // EIP-712 signer for register / registerBatch
address public pauser;
uint64  public switchCooldown;  // 48 hours at launch
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
- No signature from the target address (WL-5 carve-out): at signup the AA is Startale-created; at migration the address already holds the user's principal. Requiring a target signature here would make the ~12k backfill and signup auto-registration impractical (every backfilled user would have to sign first).
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
function switchAddress(bytes32 identityId, address newAddr) external whenNotPaused;
```

- Callable **only** by the identity's current registered address (`msg.sender == registeredAddress[identityId]`, which also rejects unregistered identities). `identityId` is public, so this gate is what prevents hijacking. AA wallets work unchanged: the AA calling via its own `execute()` is `msg.sender`, regardless of who sponsored gas.
- **No consent check on `newAddr`** and no signature, nonce or expiry — nothing signed, so nothing to replay. The frontend is expected to verify the user controls `newAddr`.
- Enforce `block.timestamp >= lastSwitchAt[identityId] + switchCooldown`.
- Revert if `newAddr` is zero, equals the current address, is bound to another identity, or is this registry.
- **Update both mappings atomically and delete the stale reverse entry.** An add-without-delete leaves the old address still resolving to the identity — recreating the exact stale-eligibility bug the reverse index exists to prevent.

### 5.3 Recovery — not implemented

Removed deliberately; see the status note for the accepted consequences and the minimal restoration path.

### 5.4 Admin

`addBackendSigner`/`removeBackendSigner`, `setSwitchCooldown`, `setPauser` — all `onlyOwner`, all emit an event.

### 5.5 Views

`registeredAddress(bytes32)`, `identityOf(address)`, `isRegistered(address)`, `nonces(bytes32)`.

---

## 6. Pause semantics

Pause blocks `register`, `registerBatch`, `switchAddress`. **Pause must never block any view.** `VipBoostDistributor.claim()` calls `registeredAddress()` and is deliberately never pause-gated — if a paused registry could brick that view, pausing the registry would freeze claims indirectly, which is exactly the behavior the distributor's design rejects.

---

## 7. Migration backfill

**Default to the address holding that identity's largest principal at a snapshot block — not blindly the AA.** Roughly half of vault principal sits in EOAs; defaulting those users to their AA would silently drop them to base rate on day one with no action from them.

**No correction path for the backfill:** there is no grace window or `migrationCorrection`. An identity backfilled to the wrong address stays there (see the status note), so the snapshot heuristic has to be right before `registerBatch` runs.

---

## 8. Invariants (assert in tests)

- `registeredAddress[id] == a` ⟺ `identityOf[a] == id`, always, after every operation.
- No address ever maps to two identities; no identity ever maps to two addresses.
- `nonces[id]` strictly increases; no signature is ever valid twice.
- Views never revert, in any state, paused or not.
- After a switch, the old address resolves to `bytes32(0)` via `identityOf`.

---

## 9. Test requirements

**Unit:** every revert path in §5; cooldown boundaries (exact second before/after); expired, replayed, wrong-signer, malformed signatures; self-switch; switch to an address bound elsewhere; EIP-1271 signer (deploy a mock AA).

**Fuzz:** random sequences of register/switch across many identities, asserting the §8 invariants hold throughout.

**Integration with `VipBoostDistributor`:** claim after a switch pays the new address; claim for an unregistered identity reverts cleanly with `IdentityNotRegistered`; claim while the registry is paused still succeeds.

**Gas:** `forge` snapshot for `register`, `registerBatch` at several sizes, `switchAddress` for both ECDSA and EIP-1271 signers.

---

## 10. Deployment and integration order

**Current (registry not deployed):**

1. Upgrade the proxy to `EarnVaultV2` with **one** `ProxyAdmin.upgradeAndCall(proxy, v2Impl, initializeV2(boostKeeper))` — use `script/upgrade/UpgradeEarnVaultToV2.s.sol` (pre-checks the admin slot; optional `IMPLEMENTATION` to upgrade to a pre-deployed, explorer-verified implementation), then **run `script/upgrade/VerifyEarnVaultV2Upgrade.s.sol` against the live chain** (the upgrade script's own post-flight only checks the simulation). `initializeV2` only accepts the ProxyAdmin as caller, so it cannot be run any other way; if an upgrade lands without it, boost credit is disabled (no boostKeeper) and `reinitializer(2)` stays unconsumed. Proper fix: repeat `upgradeAndCall` to the same implementation with it. Stopgap: the owner calls `setBoostKeeper`, which enables boost credit but leaves the initialized version at 1.
   - *Fresh deploy instead (no V1 history):* construct the proxy with the base `initialize()`, then `upgradeAndCall` to the same implementation with `initializeV2`. It cannot go in the proxy's constructor calldata: OZ v5 runs that before the ProxyAdmin exists, so it reverts `NotProxyAdmin`. Until the second transaction lands, `boostKeeper` is unset, so the deploy script must treat it as mandatory.
2. Hand the engine team the event ABI (`BoostCredited(user, amount, cycleId)`, `BoostCreditSkipped(user, amount, cycleId, reason)` and `BoostCycleCredited` for reconciliation). `cycleId` must start at 1 and be strictly increasing per address. A skipped entry (vault address, blacklisted, or zero amount) does not consume its `cycleId`, so it can be re-credited once eligible. Skipped funding stays as unreserved surplus (recoverable via `sweepSurplusToTreasury`, or reused by a later credit). The trust model and security budget are in `src/vaults/earn/base-tier-auto-compounding.md`.

**If reinstated (on-chain identity mapping, "scenario B"):** audit this contract first; deploy `IdentityRegistry(owner, backendSigners, pauser, switchCooldown)`; ship a V3 subclass of `EarnVaultV2` that stores the registry reference in its own ERC-7201 namespace and adds `onBoostCreditByIdentity(...)`, resolving `identityId → address` and feeding the existing address-keyed credit path; and run the full backfill (`registerBatch`) before the first identity-based credit. If EOAs become eligible but the mapping stays off-chain ("scenario A"), none of this is needed — the keeper just passes those addresses.

---

## 11. Explicitly out of scope

No tier data. No thresholds, rates, or bands. No principal or balance tracking. No boost computation. No relationship to `EarnVault` in either direction — the vault never calls this contract and this contract never calls the vault. Multi-identity (sybil) defense lives in the off-chain KYC layer, not here.
