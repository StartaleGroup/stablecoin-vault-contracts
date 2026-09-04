# Base-tier auto-compounding — resolved design (2026-08-24)

Answers the question: how does auto-compounding actually work for money already inside `EarnVault`, without needing claim-on-behalf, deposit-on-behalf, or atomicity guarantees between two calls — and does it have to run as a separate transaction per user?

---

## The key realization: base yield never leaves the vault

`onYield`'s own docstring states it "MUST be called AFTER transferring `amount` USDSC to this contract." By the time `onYield` runs, the yield tokens are **already sitting inside `EarnVault`'s own balance** — reserved via `claimReserve`. Nothing needs to be claimed out and deposited back in, because it never left.

The claim-then-reinvest pattern with atomicity concerns (`claimAndReinvest`, `depositFor`) is the right tool specifically for VIP boost, where tokens genuinely live in a *different* contract (`VipBoostDistributor`) and have to physically cross over. For base yield, that problem doesn't exist — applying the same pattern here would incur two unnecessary token transfers (pay out, then immediately pull back in) to solve something that's actually just an internal relabeling.

## Why there's no compounding today

```solidity
function _settle(address user) internal virtual {
  ...
  if (gi > ui) {
    uint256 owed = Math.mulDiv(p, gi - ui, $.RAY);
    $.accrued[user] += owed;   // ← this is the only line that matters
  }
  $.userIndex[user] = gi;
}
```

`owed` goes into `accrued[user]` — a side-pot that never participates in `totalPrincipal`, so it never earns further yield. This is simple interest, not compound interest, by design.

## The fix — fold `owed` into `principal` instead of `accrued`

```solidity
function _settle(address user) internal virtual {
  EarnVaultStorage storage $ = _getStorage();
  uint256 p = $.principal[user];
  if (p == 0) {
    $.userIndex[user] = $.globalIndex;
    return;
  }
  uint256 ui = $.userIndex[user];
  uint256 gi = $.globalIndex;
  if (gi > ui) {
    uint256 owed = Math.mulDiv(p, gi - ui, $.RAY);
    $.principal[user] += owed;      // was: $.accrued[user] += owed
    $.totalPrincipal += owed;       // new — keeps the invariant in lockstep
  }
  $.userIndex[user] = gi;
}
```

No token transfer, no custody question, no atomicity to guarantee — there's only one state-mutating step, not two. `totalPrincipal == sum(principal[user])` stays an exact invariant, since both sides update together in the same call every time; nothing goes stale in a way that shortchanges anyone. This is tier-blind by construction — Base, Silver, and Gold principal all compound identically, since `EarnVault` never distinguishes them.

**For users who already interact with the vault** — any `deposit`/`withdraw`/`claim` already calls `_settle` — this compounds for free, zero new infrastructure needed.

**For passive depositors who never call anything again:**

```solidity
function compound(address user) external whenNotPaused nonReentrant {
  _checkNotBlacklisted(user);
  _settle(user);
}
```

Deliberately **permissionless** — same reasoning as `VipBoostDistributor.claim()` being permissionless: this can only ever increase a user's own recorded principal, never send anything anywhere, so there's nothing to protect against. A keeper calls it on a schedule (e.g. daily) for every participating address.

## Does it have to be one transaction per user?

Yes, for this approach — `principal[user]` is a per-address storage slot, so there's no single aggregate write across many users. A `compoundMany(address[] users)` looping over `_settle` reduces transaction *count* but not total gas, and still hits a block gas ceiling for a large population eventually — the same scaling wall that motivated the Merkle-distributor over a reward-index approach for VIP boost. Worth load-testing against actual Base-tier population size before treating batching as sufficient long-term.

**The more ambitious, zero-per-user-transaction alternative** (not recommended now, but worth knowing exists): convert to a true share-price model — store `shares[user]`, derive `principal[user] = shares[user] × exchangeRate` at read time, the way Aave's aTokens or Compound's cTokens work. Nobody's balance is ever written when yield arrives; it's recomputed live against one shared rate. This is a genuine storage-model rewrite plus a one-time migration of existing `principal[user]` values into share terms — real engineering, not a fit for "basic form," but the correct next step if/when zero-per-user-transaction compounding becomes a hard requirement.

| | Today (V1) | Minimal fix (`compound`) | Full share-price rewrite |
|---|---|---|---|
| Compounds at all? | No | Yes, for anyone settled | Yes, continuously, for everyone |
| Needs a keeper? | N/A | Only for passive users | Never |
| Per-user transaction? | N/A | Yes, one per user per interval | None, ever |
| Token movement? | N/A | None | None |
| Engineering size | — | ~2 lines + 1 new function | Storage model rewrite + migration |

## Two loose ends to resolve before shipping this

- **Existing `accrued[user]` balances predate the change.** Leave `claim()`/`_claimUSDSC` working exactly as-is for anyone with a pre-change `accrued` balance — let it drain naturally as they eventually claim it. Don't attempt to retroactively migrate historical accrued into principal; that reopens the same per-user batching problem for no real benefit.
- **`claim()` quietly becomes boost-token-only going forward.** Once new USDSC yield always folds into principal, there's nothing new for `claim()` to pay out for USDSC (`hasUSDSCClaim` will only ever be true from lingering pre-change balances). This is a real, if likely welcome, behavior change — worth a one-line callout to product rather than a silent side effect.

## Direct answers to the original questions

- **Does this need claim-on-behalf or deposit-on-behalf?** No. Nothing is claimed and nothing is deposited — it's a pure internal relabeling of already-resident funds.
- **Should you be allowed to claim on behalf of someone?** Moot here — there's no payout event in this operation at all. That question only matters for VIP boost reinvestment, a separate problem.
- **Could there be a `claimAndDepositFor` guaranteeing atomicity?** Wrong tool for this case — atomicity between two calls is only a concern when two calls (a payout and a re-deposit) actually need to happen. Here there's only one call.
- **Keeper-initiated, no user action, works for both AA and EOA?** Yes — `compound(user)` doesn't care what kind of wallet the address is; it's pure vault-internal accounting, untied to wallet capabilities.
- **A way to readjust the index without moving money?** Yes — this is exactly that: `_settle`'s existing index math, just redirected to write into `principal` instead of `accrued`.

---

## Implementation note (2026-08-31): boost-settlement ordering had to change too

Building this surfaced one correctness issue this doc's `_settle` snippet doesn't account for. Boost rewards are settled using `principal` as its weighting basis (see `BoostRewardsLib.settleBoost`), and the existing code (`_deposit`) always settles boost *before* changing principal. Once `_settle` itself starts folding USDSC yield into principal, any caller that reads `principal` for boost purposes *after* calling `_settle` (as `withdraw()`/`claim()`/`_claimBoostRewards()` all do) would be settling boost against an already-inflated principal — over-crediting boost rewards for a period the user only held the smaller, pre-compound amount.

Fix: `_settle()` now settles boost for all active tokens *first*, using principal as held up to that point, before folding any USDSC yield into principal. This is centralized inside `_settle` itself (not scattered across each caller), so every call site is correct by construction rather than by convention.

One knock-on effect: `claimable()`, `totalValue()`, and `getUserInfo()` all used to compute `owed` inline and treat it as claimable USDSC. Since `owed` no longer becomes claimable (it becomes principal), these were updated: `claimable()` now returns only legacy `accrued` (what `claim()` will actually pay), and a new `pendingYield(user)` view exposes the not-yet-settled amount so `totalValue()`/`getUserInfo()` stay accurate for passive users who haven't been settled recently.

## Implementation structure (2026-08-31): a real `EarnVaultV2`, not an edit to V1

The first pass at this implementation edited `EarnVaultUpgradeable.sol` (V1) directly in place. That was reverted in favor of the proper subclass pattern already used elsewhere in this codebase (the VIP boost branch's own `EarnVaultV2`, and the upgrade-safety test mocks): a new `src/vaults/earn/EarnVaultV2.sol`, `contract EarnVaultV2 is EarnVaultUpgradeable`, overriding `_settle()`/`claimable()`/`totalValue()`/`getUserInfo()` and adding `compound()`/`compoundMany()`/`pendingYield()`. Reasons this is the better structure:

- **Audit baseline.** V1 stays frozen and byte-for-byte the currently-live contract (aside from adding the `virtual` keyword to 3 view functions - a zero-behavior-change touch required so V2 can override them). An auditor gets two clean, independently reviewable contracts instead of a diff against a moving target.
- **Real upgrade testing.** `test/unit/EarnVaultAutoCompound.t.sol`'s `setUp()` now deploys the actual V1 implementation behind a `TransparentUpgradeableProxy`, builds genuine pre-upgrade state (including a real legacy `accrued` balance and a never-settled backlog carried across the boundary), then upgrades that same proxy to `EarnVaultV2` - exactly the production upgrade path - before any test runs. This wasn't possible when V2's logic just replaced V1's source in place, since there was no old implementation left in the repo to upgrade *from*.
- **No new storage, so no reinitializer needed.** `EarnVaultV2`'s constructor just calls `_disableInitializers()`; upgrading a live V1 proxy to it needs an empty-calldata `upgradeAndCall`, nothing more.
- **Naming/versioning:** the VIP boost branch (`feat/earn-v2-loyalty-identity-boost`) already committed its own real `EarnVaultV2` (`depositFor`/`autoReinvestKeeper`). Rather than merge that branch and renumber one of the two V2s, the plan is to treat that branch as a frozen reference and port its features onto *this* branch later as `EarnVaultV3 is EarnVaultV2`, never merging it directly.

## Cadence and gas sizing (2026-08-31)

**Cadence: `compound()`/`compoundMany()` should run far less often than `onYield()`, not in lockstep with it.**

Between two `onYield()` calls, `globalIndex` doesn't move, so `owed` is zero and compounding in that window is a wasted transaction that still costs gas — the ceiling on usefulness is once per `onYield()` cycle (currently 3 hours), not a floor. But going anywhere near that ceiling buys almost nothing: compounding frequency has strongly diminishing returns relative to the underlying yield rate. At a representative 6% APR:

| Compounding interval | Effective annual yield |
|---|---|
| Continuous (theoretical limit) | 6.1837% |
| Every 3 hours (matching `onYield`) | 6.1826% |
| Daily | 6.1831% |
| Weekly | 6.1755% |
| Monthly | 6.1520% |

Daily vs. every-3-hours differs in the fifth decimal place. **Recommendation: run the keeper daily, not every 3 hours** — it captures essentially all of the compounding benefit while cutting keeper transaction volume 8x. Weekly is defensible too if gas cost matters more than the extra ~1bps/year. This has nothing to do with correctly capturing yield — that stays `onYield()`'s job at whatever cadence the redistributor already uses. Active users (anyone who deposits/withdraws/claims) already compound for free via their own transactions calling `_settle()`; the keeper's cadence only matters for the passive segment.

One operational refinement, not a blocker: very small (dust) accounts may cost more in keeper gas to compound than the yield they've accrued is worth. A floor threshold (skip, or batch less frequently, below some principal size) is worth adding later if this turns out to matter in practice.

**Gas sizing, measured (not hand-estimated) against real state.** As of this writing: ~$1.17M principal across 31,799 wallets. Soneium (OP Stack L2) block gas limit: 40,000,000. `test/unit/EarnVaultAutoCompound.t.sol`'s `test_Gas_CompoundMany_BatchSizingProjection*` tests measure `compoundMany()`'s actual execution gas via `forge test` (not a hand estimate) at two batch sizes and take the marginal (slope) per-user cost, then add an analytically-computed worst-case calldata gas cost (every address byte treated as non-zero, standard EIP-2028 pricing) to project batch sizes at 60% of the block gas limit:

| Scenario | Measured marginal gas/user | Safe batch size | Batches for 31,799 wallets |
|---|---|---|---|
| No active boost tokens | 4,551 | ~4,878 | 7 |
| 2 active boost tokens, steady state (warm) | 10,415 | ~2,225 | 15 |
| 2 active boost tokens, first-ever touch (cold, one-time only) | 98,043 | ~243 | 131 (once) |

The "cold" row is not a recurring cost — it only applies the *first* time a given (user, token) pair is ever settled after a boost token becomes active (Ethereum's zero→non-zero `SSTORE` penalty on `userBoostIndex`/`userBoostAccrued`, paid once, ever, per pair). Every subsequent daily run for that population hits the "warm" row instead. So the realistic ongoing operational cost is **~15 batched transactions/day** at current population size (or as few as 7 if no boost tokens are active that cycle), with L2 execution cost in the low single-digit dollars per day at Soneium's observed gas prices — not an operational concern at this scale. Filtering the batch to only addresses with `pendingYield(user) > 0` before submitting (skip no-ops) shrinks this further in practice, since not all 31,799 wallets are passive.

Not estimated here, and explicitly out of scope for this note: L1 data-posting cost. OP Stack chains post batch calldata to Ethereum L1 separately from the L2 execution gas counted above, priced independently. Get a live quote from Soneium's fee estimation before finalizing production batch sizes, and consider packing addresses tightly (20 bytes, manually decoded, instead of ABI's 32-byte-padded encoding) to reduce both L2 calldata gas and L1 data-posting cost for a given batch.
