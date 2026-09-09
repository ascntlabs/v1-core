# Known issues and accepted risks

Behaviors that are known, deliberate, and **not** going to be changed — recorded so auditors can
distinguish "not yet found" from "found, analysed, and accepted", and so integrators can work
around them. Each entry states the mechanism, why it is accepted, and what an integrator should do.

Properties the code *does* guarantee are in [`invariants.md`](invariants.md).

| | Entry | Area |
|---|---|---|
| KI-1 | Exact-input swaps past the book's capacity quote `maxFee` | fee model |
| KI-11 | The `maxFee` clamp is direction-agnostic | fee model |
| KI-6 | A dust swap across a zero-liquidity gap saturates the accumulator | fee model |
| KI-7 | Decay is credited for idle time, not wall-clock time | fee model |
| KI-8 | The min-fee floor can be relaxed by ~13 blocks of dust swaps | fee model |
| KI-14 | Impact readings degrade below `MIN_USABLE_SQRT_PRICE`, both directions | fee model |
| KI-15 | The midpoint fee is an approximation; no fee-total split-neutrality | fee model |
| KI-3 | Protocol-fee dust is forfeited by the treasury | settlement |
| KI-16 | `swapDelta − hookDelta` recomposition headroom at the int128 boundary | settlement |
| KI-13 | LP and protocol fees are charged on opposite sides of the swap | settlement |
| KI-4 | A gas-burning token can halt swaps despite the claims fallback | settlement |
| KI-9 | Fee-on-transfer, rebasing and fee-on-top tokens are unsupported | tokens |
| KI-10 | `configurePool` takes a bare `PoolId`, unbound to the pool's key | lifecycle |
| KI-12 | `setHookFactory` is one-shot with no rotation path | governance |
| KI-17 | `deployHook` is owner-only with no timelock | governance |
| KI-18 | The JIT lock does not gate fee-only pokes | lifecycle |
| KI-5 | There is no kill switch for a live pool | governance |
| KI-2 | Book-exhausting swaps walk the tick bitmap expensively | gas |

---

## KI-1 — Exact-input swaps that exceed the pool's directional liquidity are quoted at `maxFee`

**Status: accepted, will not be fixed.** Affects exact-input swaps only.

### Mechanism

`SwapSimulator` replays the incoming swap at `feePips = 0` to measure price impact, while the real
swap executes at the quoted dynamic fee. For **exact-input** swaps the price path is fee-dependent:
v4 deducts the fee from the input per step (`SwapMath.computeSwapStep` feeds
`amountRemainingLessFee` into `getNextSqrtPriceFromInput`), so the real swap pushes only
`(1 − fee)` of the notional the simulation pushes. **Exact-output swaps are immune** — their price
path is derived from the output target with the fee added on top of the input, so it does not
depend on the fee, and the simulation is exact.

Within the pool's in-range depth this is the small conservative bias the simulator has always
documented (≈ `fee/1e6`, always an over-estimate). It stops being small at one boundary. Define
`capacity` as the input that consumes the entire directional book. For order sizes in

```
(capacity,  capacity / (1 − maxFee))
```

the fee-free replay exhausts the book and walks into empty tick space, where the price ratio
quickly passes the impact formula's saturation point (`|r−1|/√r ≥ 1`, i.e. `r ≥ (3+√5)/2 ≈ 2.618`),
so it reads the 100 % cap and `calculateDynamicFee` clamps to `maxFee` — while the real,
fee-reduced swap would have stayed inside liquidity with small genuine impact. Independent
review measured an overquote of roughly **136×** at the cliff.

The window's width scales with `maxFee`. `configurePool` caps `maxFee` at 50 %, so the band is
bounded — see the Scale section below.

### Why it is accepted

1. **No correct fix exists at reasonable cost.** The honest fix is a self-consistent fee `f*` with
   `f* = F(impact(f*))`. Inside this window there is no fixed point: the fee↔impact map is
   discontinuous at the capacity boundary and iteration falls into a clean 2-cycle (pass 1 quotes
   `maxFee`, pass 2 quotes low, pass 3 reinstates pass 1). Outside the window at high `maxFee` the
   iteration oscillates undamped (80→18→67→29→59…) and needs ~6–7 bisection simulations to
   converge. The cheap scheme — simulate twice, charge pass 2 — is accuracy-bounded at ≈ `(1−fee)`
   of perfect and *degrades* as `maxFee` rises: at the 50 % ceiling pass 2 pushes only half the
   notional, under-reads the impact, and quotes low, turning an overquote into an underquote. So the fix doubles
   simulation gas, adds exhaustion-detection and saturation edge cases, and still does not close
   the issue.
2. **Nothing is extracted involuntarily.** The fee is quoted on the swapper's own order and
   nothing persists to pool state. An overquoted swap fails the swapper's slippage check and they
   reroute or split. **This makes the swapper's own slippage bound the mitigation** — see the
   integrator note below.
3. **The cliff has no defensive value.** Splitting into sub-capacity orders bypasses it trivially,
   so removing it would forfeit nothing. The real anti-splitting defense is the cumulative-impact
   accumulator, not this artifact.
4. **It signals a sick pool, not a sick hook.** Triggering requires an exact-input order that
   consumes the entire directional book — a liquidity-provisioning failure state. Charging
   `maxFee` to an order that large is defensible.
5. **It is economically defensible pricing.** Price movement through empty tick space has no LP
   counterparty; impact-through-liquidity is the correct fee basis. The overquote applies only to
   the portion of "impact" that the fee discount would have kept out of empty space.

### Integrator note

The protection against paying an overquote is **your own slippage bound**. A swap submitted with a
meaningful `amountOutMinimum` (or equivalent) reverts rather than paying `maxFee`; a swap submitted
with loose or absent slippage bounds will pay it in full, and the proceeds go to the LPs and the
protocol slice. Do not submit unbounded exact-input swaps sized near or above a pool's in-range
depth. Splitting into sub-capacity orders avoids the window entirely; the split total is not
guaranteed to equal the one-shot fee (KI-15), but it is bounded by the same clamps.

### Detection signature (for monitoring)

At the end of `SwapSimulator._simulate`, `remaining != 0` means the walk hit `sqrtPriceLimitX96`
before consuming the order. Two causes: a tight user price limit (benign partial-fill territory),
or the limit acting as a backstop after the book was exhausted (the KI-1 signature). **The hook
does not branch on this**, and `Result` does not surface `remaining` directly — a caller can infer
it by comparing the specified-side delta against `amountSpecified`.

### Scale

The band spans `(capacity, capacity / (1 − maxFee))`, so its width scales with `maxFee`.
`configurePool` caps `maxFee` at 500,000 pips (50 %) hook-wide, so the band is **bounded** at
`2 × capacity`. At a 100 % ceiling it would have been unbounded.

That bound does not change the mitigation above. A quoted fee of 500,000 pips still surrenders
half of an exact-input order; what the cap also removes is the exact-**output** revert v4-core
raises at a 100 % override (`Pool.InvalidFeeForExactOut`), which is unreachable. The quote is
disclosed pre-signature, and a meaningful slippage bound turns the exact-input case into a revert
rather than a payment.

---

## KI-2 — Book-exhausting swaps walk the tick bitmap expensively

**Status: no action — inherent v4 behavior, not hook-specific.**

Every swap on a `SimHook` pool pays for the tick walk twice — once in the simulator's read-only
replay and once in the real `Pool.swap` — and a swap that blows through the book walks the tick
bitmap word-by-word via `extsload` (~2,100 gas per cold slot; worst case on the order of 14 M gas
at `tickSpacing = 1`). The practical consequence is a capacity ceiling: a very large,
many-crossing swap that would fit in a block against a vanilla v4 pool can exceed the block gas
limit here, forcing the swapper to split. Splitting does not preserve the fee total exactly
(KI-15), though every leg stays inside `[effectiveMinFee, maxFee]`.

A related case: inside KI-1's over-quote window the fee-free replay exhausts the book and
continues scanning bitmap words the real, fee-bearing swap never visits, so the swapper
pays for tick-walking that buys them nothing. The gas is self-inflicted by an order sized past the
directional book with a loose price limit, and it is bounded by the limit the swapper chose; a
tighter `sqrtPriceLimitX96` avoids it. On a pool carrying the full-range seed (KI-6) liquidity is
never zero, so every step of the walk consumes input rather than free-running.

Accepted because vanilla v4 walks the same ticks for the same order, and the simulator's *marginal*
overhead per crossing is well under the headline ratio: `Pool.swap` re-reads the same slots warm
(~100 gas vs ~2,100 cold). Steady-state overhead is ~1.5–1.8× vanilla per the repo's own snapshots
(`snapshots/SwapGasComparison.json`: 83,622 vs 54,441 on the full path; per-crossing scaling in
`snapshots/SimHookOverheadByCrossings.json`). The cost is transient per transaction — no pool state
is bricked — and is paid by the swapper who submitted the order. A saturation clamp on the walk was
considered and rejected: added complexity with no beneficiary.

---

## KI-6 — A dust swap across a zero-liquidity gap saturates the accumulator

**Status: accepted.** The `_afterSwap` zero-impact guard fires only when a swap exchanged exactly
zero tokens. A tiny swap on a pool whose spot sits in a zero-liquidity region free-walks the empty
range (v4 consumes no input while `liquidity == 0`) and settles its dust at the far edge, so the
guard does not fire and the entire traversal is booked as impact — saturating `cumPriceImpact` and
pricing subsequent swaps at `maxFee` until it decays.

Accepted because the precondition is a pool with no liquidity at spot, which is already a broken
state: in *any* concentrated-liquidity AMM, a price region with no liquidity can be crossed for
almost nothing, and this is a v4 property the hook inherits rather than creates. The impact booked
is a real price move, not a fabricated one. Nothing is drained — the elevated fee accrues to
in-range LPs, so the griefer pays gas and gains nothing directly. An attacker who is *also* the
dominant in-range LP recaptures part of that fee from whatever flow keeps trading through the
elevated quote. Accepted as bounded: it needs organic flow willing to pay the clamped fee, every
quote is disclosed before signature, and the full-range seed below removes the zero-cost
traversal. KI-11 sets out where the recapture is largest.

### Deployment premise: the full-range seed

The protocol seeds every pool full-range at launch. The seed is not locked, so keeping one
full-range position in the pool at all times is the operating recommendation, for this reason:
it keeps `L > 0` at every tick. Two consequences:

- **The zero-liquidity precondition above does not arise on a launched pool.** A price move always
  exchanges tokens, so a gap-walk must consume input proportional to the seed rather than
  free-running across empty space.
- **The `_afterSwap` exact-zero guard becomes correct by construction.** Without the seed the
  guard is a path-to-state inconsistency: because it books zero for a swap that settles with both
  deltas at zero, a closed price loop across empty space could leave the accumulator holding
  impact the book's end state no longer supports, and the mirror path could scrub a standing
  surcharge without paying for the unwind. With `L > 0` everywhere the exact-zero case cannot
  coincide with a real price move, so neither variant is reachable.

The premise is operational — enforced by the pool-launch process, not by the contract — and is
pinned by a seeded-pool regression alongside the unseeded case above. Pools initialized against
the hook by third parties and never configured are unsupported. Time decay bounds how long any
residual meter reading persists, but note same-block decay is the identity, so it provides no
intra-block relief.

**This premise does not close the saturation case above.** A dust swap through a *thin* region
still books a large impact per unit of notional — that is normal market structure, priced as
such. What the seed removes is the zero-cost traversal and the path/state inconsistency, not the
sensitivity of the meter to genuinely thin books.

**Recovery is by time decay, not by cheap corrective trading — see KI-11.** While the accumulator
is saturated, a corrective swap is *also* clamped to `maxFee`, so rebalancing remains possible but
is not cheap. Decay is what restores cheap pricing.

---

## KI-7 — Decay is credited for idle time, so an actively-traded pool retains more impact

**Status: accepted, working as intended.** `decayCumByTime` applies its linear retention factor
once per swap, against the time since the *last swap*. Because a linear factor applied N times is
not the same as one factor applied over the total elapsed time
(`Π(1 − Δtᵢ/L) > 1 − Σ(Δtᵢ/L)`), a continuously-traded pool retains more impact than the
"decays linearly to zero over `timeDecayLength`" description suggests — under sustained
one-swap-per-block activity retention approaches `e⁻¹ ≈ 37 %` per window rather than reaching zero.

This is the intended semantic, and matches the min-fee ramp's clock: **decay is credit for the pool
being quiet, not for wall-clock time passing.** A pool being traded every block has not been quiet,
and its divergence pressure is being continuously refreshed, so it should not receive full decay
credit. The side effect is that dust swaps can hold the accumulator elevated and inflate fees for
later swappers; that is accepted because the inflated fee accrues to LPs rather than to the party
paying for the dust swaps, the cost is sustained (one swap per block, for the whole window) and
highly visible, and the accumulator still decays substantially each window — it is slowed, not
frozen.

---

## KI-8 — The min-fee floor's clock can be relaxed by ~13 blocks of dust swaps

**Status: accepted.** The floor's `rampAnchor` halves its idle-time credit on the first
swap of each block, independent of swap size, so the recurrence
`credit → blockTime + credit/2` converges toward a ~2-block floor: roughly 13 consecutive blocks of
dust swaps can walk an idle pool's `effectiveMinFee` from `maxMinFee` down toward `minMinFee`.

This is already the hardened form of the mechanism — it replaced a floor that any single swap reset
instantly — and the remaining exposure is thin in both directions. Grinding costs ~13 blocks during
which the stale-price opportunity being set up is exposed to any other swapper taking it first, and
the payoff only exists when the intended swap's own impact fee is *below* the floor: the quote is
`max(impactFee, effectiveMinFee)`, so collapsing the floor saves nothing on a swap whose impact
already prices above it. That confines the benefit to low-impact swaps, where the absolute saving
is correspondingly small. Every candidate fix (gating the settle on realized impact, or making
relaxation strictly proportional to wall-clock time) adds more complexity than the residual risk
justifies.

---

## KI-10 — `configurePool` takes a bare `PoolId`, unbound to the pool's key

**Status: accepted.** `configurePool` checks that *some* initialized pool exists behind the id, not
that the pool's `PoolKey.hooks` is this hook. Because configuration is one-shot with no
reconfigure path, passing the wrong id permanently consumes that id's configuration. `PoolId` is
`keccak256(abi.encode(PoolKey))` and PoolManager stores no key alongside the pool, so the hook
cannot recover `key.hooks` from the id it is given — checking it would require taking a `PoolKey`.

There is no unprivileged exposure: the entry is owner/poolDeployer-gated, ids cannot be forged or
front-run, and an unconfigured pool fails closed (swaps and deposits revert). What remains is
operator error, and only one of its three shapes matters:

| Mistake | Result |
|---|---|
| Id matches no pool | Reverts `PoolNotInitialized` — you would have to hit a valid keccak preimage by accident |
| Id of a pool on a **different hook** | Accepted, but harmless: it burns the one-shot for an id that could never be one of this hook's pools, the named pool is untouched, and the intended pool is simply configured on retry |
| Id of **another of this hook's pools** | The damaging case — that pool permanently inherits the wrong parameters and must be relaunched on a fresh id |

Only the third case causes loss, and no signature change prevents it: passing a `PoolKey` would
turn "paste the wrong id" into "load the wrong key", which is less likely but not excluded. The
effective control is procedural, below. Binding the id at initialization instead (recording the
pool in `_afterInitialize`, which v4 routes only to this hook's pools) would close the second case
and leave the third open — worth considering on its own merits as a stronger invariant and one
fewer external call, but not a fix for the failure that matters.

**Operator note:** drive `configurePool` from the same deployment artifact that initialized the
pool, never from a hand-copied id. That addresses the damaging case directly, which no on-chain
check does.

---

## KI-3 — Protocol-fee dust is forfeited by the treasury

**Status: accepted — deliberate rounding policy.** The `afterSwap` take rounds down,
`take = floor(mag × hookFee / 1e6)` over the unspecified-side magnitude, so a swap below
`1e6 / hookFee` raw units of the unspecified token collects no protocol fee and every larger swap
forfeits the sub-unit remainder. The treasury is the party that eats integer dust: the take only
ever under-collects, by strictly less than one raw unit per swap regardless of size, and never
rounds up into the swapper's realized credit. The remainder is not destroyed — it stays in the
pool and accrues to LPs. LPs are unaffected in both directions: the LP slice is charged by
v4-core, which rounds in the pool's favour, and `_computeProtocolFeeSplit` reduces the LP fee only
when a live treasury is set, so a carved slice always reaches either the treasury or the LPs,
never neither.

Materially, the zero-collection window is economically unreachable on 18-decimal tokens, sub-cent
on 6-decimal majors at normal fee levels, and reaches meaningful swap sizes only on low-decimal
tokens in the lowest-fee regimes; grinding it is unprofitable by orders of magnitude, since each
grind costs full gas plus the full LP fee to dodge under one unit of protocol fee. Asserted by
`test/fuzz/Phase1SettleTake.t.sol` (FEE-5 / SETTLE-4).

---

## KI-4 — A gas-burning token can halt swaps despite the claims fallback (SETTLE-17)

**Status: accepted, out of scope of the fallback.** A treasury transfer that reverts falls back to
minting ERC-6909 claims, so an ordinary reverting or blacklisting token cannot halt swaps. A token
that *consumes all forwarded gas* before failing defeats that fallback — the uncaught fallback
mint runs out of the ~1/64 remaining gas and reverts the swap. This is griefing recoverable by
resubmitting with more gas, not a permanent brick. Token selection is permissioned at pool launch;
degenerate tokens are a launch-time responsibility. Pinned by
`test/reentrancy/RevertOnTransferDoS.t.sol`.

---

## KI-11 — The `maxFee` clamp is direction-agnostic, so the corrective discount is not observable at extreme imbalance

**Status: accepted — intended ordering.** The weight is applied first and the ceiling second
(both in `SimHook.calculateDynamicFee`). `maxFee` is a hard ceiling on what *any* swap pays,
not a target the directional weighting is scaled into: the `k`/`c` discount operates below the
ceiling, and above it every swap pays the maximum regardless of direction. Reversing the order —
clamping the direction-independent midpoint first and applying the weight afterwards, so healing
would cap at `maxFee × cPips/kPips` — was considered and **rejected**; it would mean a pool that
has committed to a `maxFee` ceiling silently charges half of it for an entire class of swaps.

The consequence is recorded here because it surfaces in review as an apparent defect: above a
certain standing imbalance both branches compute raw fees above `maxFee` and both clamp to it, so
the discount stops being *observable* even though it is still being computed.

### The fee surface

Writing `C = |cum|` and `p` for the swap's own impact, with the shipped weights
(`kPips = 2e6`, `cPips = 1e6`) the two non-crossing branches reduce to:

| Direction | `midpointSum` | Raw fee (pips) |
|---|---|---|
| Imbalancing | `2C + p` | `2C + p` |
| Healing | `2C − p` | `C − p/2` |

Note the healing fee depends on `C` and only weakly on `p`: it runs from `C` for a dust heal down
to `C/2` for a full heal to zero. That is the intended state-based (not size-based) design — but it
means a healing swap's rate is set by the imbalance it is trying to remove.

Worked example, since this is the first thing a reader asks: a full heal from `C = 1,000,000` back
to zero is charged 50 %. That is the model working as specified, not an artifact — the leg from
100 % to 0 % has midpoint 50 %, and `cPips = 1.0×` charges exactly that. It stays economically
sound because a 100 % impact reading implies the price ratio moved at least 2.618× (where
`|r−1|/√r ≥ 1`), so the correction is still profitable at a 50 % fee; the reading is capped,
though, so a 2.618× and a 100× dislocation are charged identically, and the arbitrageur's margin
is thinnest right at that boundary.

Clamping therefore has **two** thresholds, not one:

- **`C > maxFee/2`** — imbalancing swaps clamp. (Between here and the next threshold the discount
  still works: imbalancing pays `maxFee`, healing pays `C < maxFee`.)
- **`C > 2 × maxFee`** — *no* healing swap of any size prices below `maxFee`, because even the
  best case `C/2` exceeds the cap. Between `maxFee` and `2 × maxFee`, only sufficiently large
  heals (`p ≥ 2(C − maxFee)`) still escape.

**Severity scales inversely with `maxFee`**, so the intended production setting matters more than
any other input here. At the worst-case admissible setting — the hook-wide ceiling of 500,000 pips
(50 %):

| Threshold | Level of `C` | As cumulative impact |
|---|---:|---:|
| Imbalancing swaps start clamping | 250,000 | 25 % |
| Dust heals start clamping | 500,000 | 50 % |
| **All heals clamp — discount fully erased** | **1,000,000** | **100 %** |

`calculatePriceImpactCapped` caps each *swap* at 100 %, so a single full-impact swap reaches the
1,000,000 threshold; `_afterSwap` accumulates, so a run of smaller same-direction swaps faster than
decay removes them does too. That is still a materially higher bar than at a low `maxFee`.

### Why it matters, and the two things that limit it

In this regime the hook stops pricing divergence and becomes a flat `maxFee` hook until decay
relaxes `C`. Rebalancing stays *possible* — an arbitrageur pays `maxFee` to do it — but the
incentive designed to attract them is gone, leaving time decay (KI-7, itself slowed by activity)
as the only route back to informative pricing.

Two things bound it. First, a stabilising feedback: a pool stuck at `maxFee` deters trading, and
less trading means more idle time, which under KI-7's per-swap decay means *faster* relaxation —
the state partly cures itself by suppressing the activity that sustains it. Second, at a high
`maxFee` the raw fee is already prohibitive well before the clamp binds. At `C = 250,000` with
`maxFee` at its ceiling, imbalancing flow pays 50 % and a dust heal 25 %: the directional ordering
is still intact, but ordinary flow is not trading at either price. The discount vanishing at
`C = 1,000,000` is therefore a refinement of an already-unusable state, not the thing that breaks it.

The same bound applies to dominant-LP recapture (KI-6). Extraction needs organic flow willing to
keep paying the clamped fee; at the 50 % cap very little is, so there is little to
recapture. Recapture is largest at *low* `maxFee` settings, where the threshold is proportionally
lower and the cap is small enough that ordinary traders keep transacting through it.

### Choosing `maxFee` — the side effects, in both directions

`maxFee` is a per-pool choice, admissible anywhere up to the hook-wide ceiling of 500,000 pips
(50 %) — `configurePool` rejects anything above it. That optionality is
deliberate, but the parameter scales several accepted behaviours at once, and it does so in
*opposite* directions — there is no setting that minimises everything. Deployers should pick with
the whole table in view rather than optimising one row.

| Raising `maxFee` | Lowering `maxFee` |
|---|---|
| **Widens** the KI-1 over-quoted exact-input band `(capacity, capacity/(1 − maxFee))`, widest at the 500,000 ceiling where it reaches `2 × capacity` | **Narrows** that band; it vanishes as `maxFee` → 0 |
| **Raises** the KI-11 thresholds, so the direction-agnostic clamp regime needs a larger standing imbalance to reach | **Lowers** them proportionally — the `k`/`c` discount stops being observable at smaller imbalances |
| **Raises** the ceiling a KI-6 gap-saturated pool is pinned at, making that window more punitive while it lasts | **Caps** the damage of a saturated accumulator |
| Makes the clamped regime largely academic: little organic flow transacts at a very high fee, so there is little to extract | Makes the clamped regime economically live: ordinary flow keeps paying, which is what dominant-LP recapture (KI-6) needs |

Two consequences worth stating plainly. At the ceiling the KI-1 band is at its widest
(`2 × capacity`), but the KI-11 clamp regime requires 100 % cumulative impact to reach and the pool
is priced out of use before that — so the practical exposure is KI-1. At a tight `maxFee` the
reverse holds: KI-1 is narrow, but KI-11's thresholds fall with it and the cap is low enough that
real flow keeps transacting through the clamped regime.

Note also that `maxFee` is the ceiling on the **total** dynamic fee, before the protocol split.
The protocol slice is a further `protocolFeeBps` (capped at 20 %) of whatever is charged, so LPs
receive at least 80 % of any fee at any `maxFee`.

### Alternatives considered and rejected

- **Clamp before weighting** (clamp the direction-independent midpoint against a shared ceiling,
  then apply the weight, so healing caps at `maxFee × cPips/kPips`). Preserves the ratio to
  saturation and leaves imbalancing output bit-identical, but **rejected on the design point**: it
  makes the pool charge a fraction of its declared ceiling for a whole class of swaps. `maxFee`
  means the most a swap can pay, and a corrective swap that computes above it should pay it.
- **Exempting the healing branch from the clamp is backwards and must not be done.** The raw
  healing fee at extreme imbalance is *above* `maxFee`, not below — at `C = 1,000,000` a dust heal
  computes 100 %. Removing the clamp would charge that instead of `maxFee`, making corrective flow
  dramatically more expensive.
- **Repricing the healing branch against the reduction achieved** rather than the leg midpoint
  would break the path-additivity property in invariant #3 and abandon the state-based design.

The behaviour stands as written. Auditors re-deriving this should note the ordering is deliberate.

---

## KI-14 — Impact readings degrade below `MIN_USABLE_SQRT_PRICE`, in both directions

**Status: accepted.** `MIN_USABLE_SQRT_PRICE` (2^58) is enforced in `_beforeInitialize` and never
re-checked, so a pool whose price collapses far enough after launch keeps trading on a degraded
reading. The degradation is **not** uniformly conservative — which direction it goes depends on how
far the price has fallen.

`calculatePriceImpactCapped` works on `priceX96 = floor(sqrtP² / 2^96)`, so for `sqrtP = 2^k` the
stored price is `2^(2k−96)` and the smallest move that registers is `1 / priceX96`:

| `sqrtPriceX96` | `priceX96` | Smallest detectable move | Reading |
|---|---:|---:|---|
| ≥ 2^58 | ≥ 1,048,576 | ~0.95 pip | correct |
| 2^56 | 65,536 | ~15 pips | under-reads |
| 2^53 | 1,024 | ~977 pips (0.1 %) | under-reads |
| 2^50 | 16 | 62,500 pips (6.25 %) | under-reads |
| 2^48 | 1 | 1,000,000 pips (100 %) | under-reads |
| < 2^48 | 0 | — | **always 100 %** |

Both thresholds are exact. 2^58 is the floor precisely because `priceX96` there is ~`PIPS_SCALE`,
i.e. one-pip resolution. Below 2^48, `sqrtP² < 2^96` makes the geometric mean floor to zero, the
`priceChangeX96 >= priceX96Geo` guard becomes `0 >= 0`, and every swap returns the cap.

So: **2^48 ≤ sqrtP < 2^58 under-reads** — real moves floor to 0 pips and quotes collapse to
`effectiveMinFee` (under-charging, the unsafe direction). **sqrtP < 2^48 over-reads** — every swap
reads 100 % and quotes `maxFee` (over-charging, safe, but the pool is economically unusable). Near
2^48 the transition is not clean: a move straddling it can give `priceChange = 1` against
`geo = 1`, tripping the cap.

Accepted on reachability. 2^58 corresponds to a raw price around 1.3e-23; even under the worst
common decimal skew (18-decimal against 6-decimal) that is a human price near 1e-11, and the
under-reading band only becomes materially wrong (whole-percent moves reading zero) another
~10,000× below that. Reaching it requires a token to have lost essentially all value first, and
pool creation is permissioned. No profitable unprivileged path into the state was constructed in
review. Re-checking the floor on the swap path was considered and not adopted: it adds a
per-swap check to defend a state no live token reaches.

### Resolution is one pip everywhere, not only below the floor

Separately from the low-price degradation above, and reachable at ordinary price levels: impact is
measured in whole pips. `calculatePriceImpactCapped`'s final `mulDiv` floors, and `_afterSwap`
writes that integer straight into `cumPriceImpact` with **no fractional remainder retained between
swaps**. Any swap whose realized price move is below one pip therefore books exactly zero, and a
sequence of such swaps can walk the price in one direction while the accumulator reads flat. In a
deep enough pool this needs no unusual price level — only legs small enough to stay individually
under the threshold.

The state-based meter does not close the dust-splitting hole *completely*: it closes it above
one-pip resolution.

Accepted as bounded rather than fixed. Each dust leg still pays `effectiveMinFee` on its own
notional plus per-swap gas, so walking the price in sub-pip increments costs the floor fee times
the number of legs — the same economic bound that limits KI-8's ramp-walking, and it scales with
the number of legs rather than with the distance moved. A higher-precision accumulator or an
explicit fractional-carry field would close it and was considered; it was not adopted, because the
carry adds per-swap storage to defend against an attack that pays the floor fee on every leg.

---

## KI-12 — `setHookFactory` is one-shot with no rotation path

**Status: accepted.** `hookFactory` is written at most once (`HookFactoryAlreadySet` on any second
call) and no function anywhere rotates it. It is simultaneously the only authorised caller of
`registerSubscriber` and the root every provenance answer resolves through, so if the canonical
factory were ever found defective there is no repointing it — recovery is a full protocol
redeploy, with pools relaunched against fresh hooks.

Accepted because the write is validated hard before it becomes permanent: the candidate must be a
contract, and must point back at this governance (`f.governance() == address(this)`), so the
mutual handshake makes a mis-wired factory fail closed rather than stick. The factory's own surface
is also small and owner-gated throughout — it deploys, records provenance, and flags deprecation;
it holds no funds and has no upgrade path of its own to go wrong. Making it rotatable would trade a
permanent-but-validated pointer for a mutable root of trust, which is the wrong direction for the
one value every provenance check anchors on.

**Operator note:** wiring `setHookFactory` is the single most consequential call in a deployment.
Verify the factory's deployed bytecode and its `governance()` return value before making it.

---

## KI-13 — LP and protocol fees are charged on opposite sides of the swap

**Status: accepted, bounded.** v4 permits an `afterSwap` hook delta only in the *unspecified*
currency, so the protocol slice is always taken there, while the LP fee is charged by v4-core on
the *specified* side. The consequence is that `lpFee + hookFee == dynamicFee` holds exactly in
pips but not in economic value, and on exact-output swaps the protocol slice is levied on a base
that the LP fee has already grossed up.

The divergence is bounded and self-neutralising in normal operation — on the order of 0.16 % of
the fee at a 1 % realized `dynamicFee`. It scales with the realized fee rather than sitting only at
the configuration boundary — roughly 1.6–3.2 % of the fee at a 10–20 % realized `dynamicFee`, and
largest at the 500,000-pip `maxFee` ceiling. It is a structural consequence of v4's hook-delta rules rather than a
choice this hook makes: taking the slice on the specified side is not available. Recorded because
it is the most frequently re-derived observation across independent reviews, not because it poses
a risk.

---

## KI-9 — Fee-on-transfer, rebasing and fee-on-top tokens are unsupported

**Status: accepted — inherited from v4-core, mitigated by permissioned launch.**

v4's accounting does not support tokens whose transferred amount differs from the amount requested;
this hook inherits that rather than introducing it. The hook-specific effect is treasury-only:
`poolManager.take` debits the ledger and transfers the same nominal `take128`, so PoolManager
reserves stay consistent with its ledger and both LP and swapper accounting stay exact — a
fee-on-transfer currency simply delivers less than `take128` to the treasury, and
`ProtocolFeeTaken` logs the nominal figure. No reconciliation is attempted.

**Token restrictions for pool launch.** Pool creation and `configurePool` are permissioned, which
makes these enforceable off-chain. Do not launch pools whose currencies are:

- fee-on-transfer or deflationary (treasury under-collects; see above),
- rebasing (balances drift out of step with v4's internal accounting),
- fee-on-top (breaks v4 `take` for all participants),
- gas-burning on failure (defeats the claims fallback — KI-4).

---

## KI-5 — There is no kill switch for a live pool

**Status: deliberate, pinned by tests.** No owner, timelock, or pauser action halts swaps or
removals on a configured pool; factory deprecation is advisory only; pool configuration is
one-shot. Recovery from a bad pool is relaunch on a fresh pool id. `Phase2_XSub2_NoKillSwitch.t.sol`
fails the moment a halt path is added, so this cannot change silently. See the README's governance
model.

Deprecation is a signal for off-chain consumers only; the levers that actually bite are
`setHookAddLiquidityPaused` and `removeSubscriber`.

---

## KI-15 — The midpoint fee is an approximation; there is no fee-total split-neutrality

**Status: accepted by design.** The fee is derived in *price-impact* space and charged on *token
notional*. `_beforeSwap` replays the swap fee-free, reads the pool price before and after, and
turns that endpoint impact plus the standing accumulator into a fee **percentage**; v4 then
applies that percentage to the swap's token amount. The two measuring sticks are proportional only
when in-range liquidity is uniform along the path, and diverge when it is not.

### Mechanism

Each swap is quoted at `weight × midpoint(|cum|, |estCum|)`. That midpoint is a trapezoidal
approximation of the path integral of the rate over notional, and the approximation is exact only
where impact is linear in notional. On a lumpy book, a one-shot swap gets **one** rate — derived
from the whole path's endpoint impact, which the thin regions dominate — applied to **all** of its
tokens, most of which crossed deep liquidity. Splitting prices each leg on its own state and
converges to the integral.

The error therefore runs in **both** directions, set by the curvature of the impact profile.
Worked, at `k = 2×` and an accumulator starting at zero:

| Profile | Legs | One-shot | Split |
|---|---|---:|---:|
| **Convex** (dense→thin) | 900 tokens over 0 → 0.1 %, then 100 tokens over 0.1 → 1.0 % | rate 1.0 % on 1000 = **10.0** | 0.1 % × 900 + 1.1 % × 100 = **2.0** |
| **Concave** (thin→dense) | 100 tokens over 0 → 0.9 %, then 900 tokens over 0.9 → 1.0 % | rate 1.0 % on 1000 = **10.0** | 0.9 % × 100 + 1.9 % × 900 = **18.0** |

In the convex case the split total sits below the one-shot; in the concave case above it. A router
optimising fees takes whichever is cheaper, so in practice the pool sees `min(one-shot, best
split)` — which is why this is recorded as an accepted imprecision rather than a symmetric one.

### Two further sources of the same divergence

1. **Fee-free quote vs fee-bearing execution.** `SwapSimulator` runs at `fee = 0`, so for
   exact-input the real swap pushes only `(1 − fee)` of the simulated notional, while `_afterSwap`
   books the *realized* move. Nothing reconciles the two, and same-block decay is the identity, so
   inside a block the difference carries from leg to leg instead of washing out. Same-block
   tranches can therefore beat the one-shot quote **even on uniform liquidity** — this mechanism
   does not need a lumpy book.
2. **Impact-conservatism is not fee-conservatism.** The simulator's exact-input over-estimate
   raises the fee on the imbalance-increasing branch (`midpointSum = 2C + p`) but *lowers* it on
   the non-crossing corrective branch, where `midpointSum = 2C − p` and the quote is
   `c·(C − p/2)`, decreasing in `p`. An over-estimated `p` there produces a quote slightly below
   the realized-path fee, of order `c·(p_sim − p_real)/2`.

A third, second-order note for anyone re-deriving the algebra:
`calculatePriceImpactCapped` is an **endpoint** reading measured against the geometric mean, not
an additive route coordinate. Leg readings do not sum exactly to the whole-path reading, so
formula-level midpoint tests do not by themselves establish split neutrality across a composed
price path.

### Why it is accepted

- **It is not a fund-loss path.** Nothing is drained; no LP position is mis-accounted, and every
  leg is floored at `effectiveMinFee` and capped at `maxFee`.

  Note the routes do **not** land on identical end states. Midpoint additivity holds over a
  *given* price path; two fee-bearing routes do not take the same path, because the cheaper one
  surrenders less notional to fees and therefore pushes the price further. On the convex fixture in
  `test/feature/SplitAdditivity.t.sol` the split pays 41 % less fee and ends with an accumulator
  5.4 % *higher* than the one-shot. The divergence is bounded by the fee itself and moves opposite
  to it — a cheaper route always ends further along, never short.
- **The split total is the economically defensible price.** It is the local-rate integral over the
  path — each region priced at the rate its own impact implies. The one-shot quote is the
  imprecise one, and on the common concentrated shape (depth near spot, thinning outward) it is
  imprecise in the LPs' favour: flow that does not do the repricing work overpays, and the
  difference stays with the pool.
- **Every quote is disclosed before signature.** The v4 Quoter runs `beforeSwap`, so no one pays a
  rate they did not see; a quote that exceeds a swapper's tolerance fails their slippage check and
  they split or reroute — the same mitigation as KI-1's.

### The alternative that was declined

Pricing the fee off the simulator's per-step token deltas (or a leg-weighted equivalent) so the
rate aligns with the notional v4 actually charges. The simulator already computes those deltas
and currently discards them, so the information is on hand. It was **not** adopted: it replaces a
state-based rate with a size-based one, which is the property the whole design rests on — a swap's
price is meant to be a function of the pool's standing imbalance, not of how the order was
chopped up. Accepting a bounded, disclosed, two-sided approximation was judged the better trade.

### What this means for the invariants

Invariant #3 is additivity of the **rate in impact units**, not of the fee total, and is worded
accordingly. Any reading of the form "splitting or batching never beats the one-shot fee" is
false on a non-uniform book. KI-1 and KI-2 defer to this entry for what splitting does to the fee
total.

---

## KI-16 — `swapDelta − hookDelta` recomposition headroom is argued, not proven at the boundary

**Status: accepted; unreachable at real token supplies.** `_takeProtocolFeeOnAfterSwap` proves the
returned treasury take fits in `int128` on its own, but that argument does not by itself cover
v4's later recomposition step, which subtracts the hook delta from the swap delta.

The bound: the take is always levied on the **unspecified** currency
(`AscntBaseHook._takeProtocolFeeOnAfterSwap`), and `MAX_PROTOCOL_FEE_BPS` is 2,000 (20 %), so
`take ≤ 0.2 × mag`. The worst case is an exact-output swap, where the unspecified side is the
input and the recomposition carries `−in − take`, bounded by `1.2 × in`. Overflow therefore
requires `in > 2^127 / 1.2 ≈ 1.4e38` raw units — beyond any plausible token supply. Should it ever
be reached, v4's `toBalanceDelta` uses checked casts, so the failure mode is a clean revert of the
swap, not silent corruption of the delta.

Recorded rather than fixed because there is nothing to fix at present parameters, and flagged
because it is a *hardening* item: if the settlement path is ever revised, the regression should
exercise the full recomposition near the signed-128-bit boundary rather than the hook helper in
isolation.

---

## KI-17 — `deployHook` is owner-only with no timelock

**Status: deliberate.** Governance is deliberately asymmetric. Slow-lane parameters
(`setProtocolFeeBps`, `setTreasury`, `setPoolDeployer`, timelock rotation) sit behind the
timelock; hook deployment does not, so a new pool can be launched without a notice period.

The residual on owner compromise is **provenance laundering**, not theft of existing TVL: a
stolen owner key can deploy arbitrary code through the canonical factory, and that hook then
passes `isCanonicalHook`, endangering *future* deposits by integrators who trust the registry.
Existing positions are not reachable this way — the subscriber callback is gas-capped and wrapped
in `try/catch`, configuration is one-shot, and no governance action reaches LP principal (KI-5).

Timelocking `deployHook` alone would not close it: `setHookFactory` is plain `onlyOwner`
(see KI-12), so a compromised owner can install a rogue factory regardless. Closing the path
properly means timelocking both, which trades away the fast-launch property the asymmetry exists
to provide.

Mitigations relied on instead: the owner is the genesis Safe that also holds the timelock, so both
lanes share one signing policy; integrators are directed to filter on the canonical factory as the
event emitter rather than trusting `isCanonicalHook` blindly; and `removeSubscriber` quarantines a
rogue hook from the fee path once identified.

---

## KI-18 — The JIT lock does not gate fee-only pokes

**Status: deliberate, pinned by tests.** `_beforeRemoveLiquidity` gates on `liquidityDelta < 0`,
so a zero-delta "poke" that realizes accrued fees succeeds while a position is inside its JIT
lock. It looks like a bypass and is not one, because of what the lock is for.

The lock's deterrent is **inventory risk on principal**: a JIT depositor must leave capital exposed
to price movement for `jitLockBlocks` before it can exit. A poke collects fees that have already
accrued and leaves principal fully exposed for the remainder of the window, so it removes nothing
from the deterrent. This differs from fee-withholding designs (e.g. penalty hooks that confiscate
accrued fees on early exit), where a poke genuinely escapes the penalty and gating it is required.

Gating pokes would also block honest LPs from compounding or collecting during a lock, for no gain.

The residual is calibration, not mechanism: `jitLockBlocks` must be long enough that the cost of
holding exposed inventory exceeds the fee capture a JIT deposit can achieve. That is a per-pool
launch-time parameter choice, disclosed on-chain via `poolConfig` before anyone deposits.

---

## Deployment premises and portability

Not findings, but conditions this repository's reasoning assumes. They are verified per deployment
rather than enforced by the contracts.

- **Full-range seed.** The protocol seeds every pool full-range at launch; the seed is not locked,
  and keeping one full-range position in place at all times is the operating recommendation, so
  `L > 0` at every tick. KI-6 and invariant #6 both rest on this.
- **Primary target is Ethereum mainnet; other EVM L2s may follow.** Nothing in the hook is
  mainnet-specific, but three properties are checked before deploying to a new chain.
- **Block-denominated constants are wall-clock only relative to a chain's block cadence.**
  `MAX_JIT_LOCK_BLOCKS` (50,400 ≈ 7 days at ~12 s), each pool's `jitLockBlocks`, and KI-8's
  reaction window are all counted in `block.number`. On a chain with faster block production the
  same count is a proportionally shorter lock, and on chains whose `block.number` tracks L1 it is
  unchanged. `jitLockBlocks` is calibrated per deployment, not carried over.
- **Cancun or later is required** — the reentrancy and settlement paths use transient storage
  (`tstore`/`tload`).
- **Standard EVM `CREATE2` derivation is required.** `HookFactory.computeAddress` assumes it;
  chains that derive contract addresses differently (the zkSync family) are unsupported unless the
  factory is adapted, because hook-address mining underpins the v4 permission encoding.
- **Sufficient block gas limit** for a worst-case full-subscriber `setProtocolFeeBps` broadcast;
  the push is gas-capped per subscriber and self-heals through `syncProtocolFee`, but the headline
  figure should be checked against the target chain's limit before launch.

---

## Minor accepted findings

Small enough not to warrant their own entry, recorded so they are not re-reported as new. All
reviewed, all accepted, none scheduled for change.

**Constructor seeds the fee cache before subscription.** `AscntBaseHook`'s constructor copies the
live `protocolFeeBps`. On the factory path this is invisible — registration and the first push run
in the same transaction. A hook deployed outside the factory but pointed at the canonical
governance holds the live rate while unsubscribed until anyone calls the permissionless
`syncProtocolFee`. Invariant #16 is worded as *convergence* and speaks only to subscribed and
removed hooks, so nothing false is claimed; the practical effect is a non-canonical hook
voluntarily forwarding fees to the canonical treasury.

**`PoolConfigured.configured` is always `true`.** The storage flag of that name is load-bearing —
`_beforeSwap` and `_afterAddLiquidity` both revert `PoolNotConfigured` on it — but the event
*parameter* carries no information, since the event only fires at the end of `configurePool`.
Left as-is rather than churn an event signature.

**`BeforeSwap` emits the total fee, not the split.** `dynamicFeePips` is the fee before the
protocol carve. That is deliberate: it is the fee model's output and appears nowhere else. The
split is not emitted because it is already available — realized protocol revenue comes from
`ProtocolFeeTaken` in token amounts, and the LP fee is v4-core's own `Swap.fee`. A dedicated
event would cost ~2% of a steady-state swap to restate both.

**`removeSubscriber` skips its zeroing push silently for code-less addresses,** emitting no
`SubscriberPushFailed` (that fires only on a caught revert). Nothing is lost, because **a
subscribed hook always has code**: `registerSubscriber` ends with an unguarded call to
`onProtocolFeeBpsUpdated` — no stipend, no try/catch — which reverts on Solidity's extcodesize
check against a code-less address, so registration cannot complete; and post-Cancun (EIP-6780) a
deployed hook cannot become code-less afterwards. The branch therefore only fires for an address
that was never subscribed and has no cache to zero, so `SubscriberPushFailed` would be actively
misleading — nothing failed. The call is not traceless either: it runs on to emit
`HookAddLiquidityPauseSet`. The code-length check itself is required, not defensive — without it
the call reverts uncatchably and takes down the timelock execution.

**`HookMath.calculateEffectiveMinFee` with `timeDecayLength == 0`** returns `maxMinFee` for any
nonzero idle time. Unreachable: `configurePool` rejects zero decay, and `HookMath`'s functions are
`internal`, so they are inlined rather than externally callable. Backstop territory, like the
`SafeCast` clamps.

**`int128(take128)` is a raw cast** where the rest of `AscntBaseHook` uses `SafeCast`. Safe by an
exact 5x margin: `hookFee < PIPS_SCALE` makes `take < mag` strict, and `MAX_PROTOCOL_FEE_BPS`
(2,000 bps = 20%) is a `constant`. If it is ever revisited it needs a *clamping* `toInt128Capped`
— a reverting cast would contradict the library's stated convention that a revert bricks the pool.

**`HookFactory`'s constructor checks `_governance != address(0)` but not `code.length > 0`,**
unlike `AscntGovernance.setHookFactory`'s three-part validation of the same pointer. No reachable
consequence: every mutator is `onlyOwner` and the `governance.owner()` lookup reverts against a
code-less address, so such a factory is inert and can never become canonical.

**`MAX_JIT_LOCK_BLOCKS` (~7 days) exceeds `MIN_TIMELOCK_DELAY` (24 h).** A max-locked position can
be unable to exit across a full governance notice period. Accepted because no timelock-gated
action reaches LP principal — configuration is immutable, there is no kill switch, and the hook
carries no `afterRemoveLiquidityReturnDelta` bit so it cannot tax an exit. The only LP-visible
slow-lane change is `setProtocolFeeBps`, capped at 20% of fee revenue. `MIN_TIMELOCK_DELAY` is
deliberately left at 24 h: it is read only by `_requireValidTimelock` at acceptance time, enforces
nothing at runtime, and is never re-checked, so raising it to satisfy the inequality would buy
nothing.

**`MAX_TIME_DECAY_LENGTH` stays at 1 day.** Raising it was considered and declined: it would
extend the KI-6 saturation window from a day to a week, and because the same value also drives the
min-fee ramp clock it would weaken stale-price protection at the same time.

---

## Resolved — recorded to prevent re-litigation

- **Out-of-bounds `sqrtPriceLimitX96` caused a non-terminating simulation walk.** Fixed in
  `src/lib/SwapSimulator.sol`: limits at or beyond `TickMath.MIN_SQRT_PRICE`/`MAX_SQRT_PRICE`
  (the boundary values are themselves invalid) now short-circuit to a zero-impact result. The
  guard deliberately **returns rather than reverts** — `Pool.swap` runs this exact check
  immediately after the hook returns and reverts the whole swap with the canonical
  `PriceLimitOutOfBounds`, so the quoted fee is never consequential and the transaction dies
  exactly as it would on a hookless pool (error-parity for integrators). Check semantics and
  ordering mirror `Pool.swap`'s `PriceLimitAlreadyExceeded`-then-`PriceLimitOutOfBounds` sequence.
  Note for integrators: the v3-periphery convention of `sqrtPriceLimitX96 = 0` meaning "no limit"
  does **not** apply — v4 treats it as out of bounds and reverts.
- **JIT-lock griefing via `PositionManager.increaseLiquidity`** — refuted against the pinned
  v4-periphery commit: `_increase` carries `onlyIfApproved`, identical to `_decrease`/`_burn`. A
  residual caveat remains only for non-canonical routers that collapse multiple LPs onto one
  `(sender, salt)` key; see `test/access/Phase2_JitClockGriefing.t.sol`.
