# Security invariants

The properties the code is intended to guarantee, consolidated for auditors: each entry states
what should be impossible to break, where the code enforces it, and which tests pin it. The full
invariant catalog (the registry behind the `FEE-*`/`MID-*`/`XSUB-*`/… IDs in test names) is shared
with auditors during review; this file is the prose synthesis, not a replacement for it.

Behaviors deliberately **not** guaranteed — known, analysed, and accepted — are in
[`known-issues.md`](known-issues.md). Read both: an invariant here is scoped by any accepted
exception recorded there.

## Fee quoting

1. **Every quoted fee lies in `[effectiveMinFee, maxFee]`**, and `maxFee < MAX_LP_FEE` by
   `configurePool`'s bounds — the hook can never return a fee v4-core would reject.
   Enforced: final clamp in `SimHook.calculateDynamicFee`; bounds in `configurePool`.
   Tests: `test/fuzz/Phase1DynamicFee.t.sol`, `test/feature/ConfigurePoolBounds.t.sol`.

2. **The min-fee floor ramps monotonically** from `minMinFee` to `maxMinFee` with idle time,
   and its clock's credit halves at most once per block — measured against the last swap's
   timestamp, never `now`, so no single swap (and no same-block burst) can reset the floor, and
   idle time is never double-counted. Enforced: the `rampAnchor` settle in `SimHook._beforeSwap`;
   `HookMath.calculateEffectiveMinFee`.
   Tests: `test/feature/MinFeeRampAnchor.t.sol`, `test/fuzz/Phase1MinFeeRamp.t.sol`.

   Bounded relaxation, not immunity: the halving is size-independent, so ~13 consecutive blocks of
   dust swaps walk the floor back toward `minMinFee`. Accepted —
   [`known-issues.md`](known-issues.md) KI-8.

3. **Fees are state-based, and additive in impact units — not in fee totals.** Each swap is
   quoted at weight × the midpoint of the accumulator leg it traverses. Midpoints are exact and
   additive in *impact* units, so split legs' accumulator traversals sum to the one-shot
   traversal up to rounding and clamp slack — **for a given price path**. Note "clamp slack" is
   doing real work at saturation, where every path clamps to
   `maxFee` and additivity is trivially satisfied but uninformative (KI-11). Enforced:
   `SimHook.calculateDynamicFee`.
   Tests: `test/fuzz/Phase1MidpointFee.t.sol`, `test/feature/MidpointFeeAnchors.t.sol`,
   `test/feature/FeeAccuracy.t.sol`.

   **This is not fee-total split-neutrality, and must not be read as one.** The quoted value is a
   *rate*; v4 charges it on token notional. The midpoint is a trapezoidal approximation of the
   path integral of the rate over notional, and it is exact only where impact is linear in
   notional — that is, on uniform in-range liquidity, which is what the tests above exercise. On
   a non-uniform book, splitting prices each leg on its own state and converges to that integral,
   which may sit **below** the one-shot quote (convex impact profile, dense→thin) or **above** it
   (concave profile). Two further reasons the tests do not close the claim: the quote is taken
   from a fee-free replay while state advances by the smaller fee-bearing move (see #9), and
   `calculatePriceImpactCapped` is an *endpoint* reading rather than an additive route
   coordinate, so leg readings do not sum exactly to the whole-path reading.

   **Nor does splitting leave the terminal accumulator unchanged.** Additivity holds over a given
   price path, and two fee-bearing routes do not take the same path: the cheaper route surrenders
   less notional to fees, so more of it reaches the curve and the price travels further, booking
   *more* impact. Measured on the convex fixture in
   `test/feature/SplitAdditivity.t.sol`, a split paying 41 % less fee ends with an accumulator
   5.4 % higher than the one-shot. Every quote still lies in `[effectiveMinFee, maxFee]`.
   Accepted by design — [`known-issues.md`](known-issues.md) KI-15.

4. **Quoting cannot revert from extreme state.** Saturating adds bound the accumulator,
   `MAX_MIDPOINT_SUM` caps the midpoint sum fee-neutrally (a capped sum still clamps to
   `maxFee` exactly as the uncapped one would), casts clamp instead of reverting, and the
   zero-crossing branch's inputs are bounded by the 100 % impact cap — a saturated pool still
   quotes, at `maxFee`. Enforced: `HookMath.addSaturating*`, `SafeCast`, `MAX_MIDPOINT_SUM` and
   the inline bound notes in `calculateDynamicFee`.
   Tests: `test/base/Saturation.t.sol`, `test/fuzz/Phase1HookMathLib.t.sol`.

5. **Only dynamic-fee pools are served**, and the returned fee always carries
   `OVERRIDE_FEE_FLAG` with only the LP slice. Enforced: `SimHook._beforeInitialize`,
   `_beforeSwap` return.
   Tests: `test/feature/BeforeInitializeFeeFlag.t.sol`,
   `test/differential/Phase3_Settle3_14_FeeOverride.t.sol`.

## Impact accumulator

6. **Only realized price movement is booked.** `_afterSwap` measures against the pre-swap
   snapshot, capped at 100 % (1e6 pips), signed by direction; a swap that exchanged zero tokens
   books zero even if the price moved (a no-liquidity walk to the price limit is economically a
   no-op). Enforced: `SimHook._afterSwap`.

   That guard's correctness rests on a deployment premise: the protocol seeds every pool
   full-range at launch and, as the seed is not locked, keeping one full-range position in place
   at all times is the operating recommendation, so `L > 0` at every tick and any price move
   necessarily exchanges tokens. Where the premise holds, the exact-zero case cannot coincide with
   a real price move; where it does not — an unseeded third-party pool — a closed price loop
   across empty space can leave the accumulator inconsistent with the book's end state. See
   [`known-issues.md`](known-issues.md) KI-6.
   Tests: `test/invariant/Phase4aAccLifecycle.t.sol`,
   `test/differential/Phase3_Acc_AccumulatorOracle.t.sol`.

   The zero guard is an exact-zero test, so it does not generalize to *near*-zero: a dust swap
   that crosses a zero-liquidity region books the whole traversal and can saturate the
   accumulator. Accepted as a concentrated-liquidity property —
   [`known-issues.md`](known-issues.md) KI-6. Read this invariant as "impact booked is a real
   price move", not "impact booked is proportional to notional".

7. **Decay never expands `|cum|`**, and a full idle `timeDecayLength` since the last swap decays
   it to exactly zero. Enforced: `HookMath.decayCumByTime`.
   Tests: `test/fuzz/Phase1HookMathLib.t.sol`, `test/differential/Phase3_Acc_AccumulatorOracle.t.sol`.

   The retention factor is applied once per swap against the inter-swap gap, so decay over a span
   containing swaps is **not** equal to one linear decay over that span — an actively-traded pool
   retains more. Intended (decay is credit for idle time); see [`known-issues.md`](known-issues.md)
   KI-7. Do not read this invariant as "|cum| reaches zero `timeDecayLength` after the last
   *impact*".

8. **Impact is direction-symmetric**: measured against the geometric mean of pre/post prices, a
   round trip reads the same magnitude both ways. Enforced:
   `HookMath.calculatePriceImpactCapped`, `SimHook._beforeInitialize`.
   Tests: `test/base/HookMath.t.sol`.

   Scoped to prices at or above `MIN_USABLE_SQRT_PRICE` (2^58), which `_beforeInitialize`
   enforces at pool launch and nothing re-checks at runtime. Below that floor the reading degrades
   in both directions — under-reading between 2^48 and 2^58, over-reading below 2^48. Accepted;
   exact thresholds in [`known-issues.md`](known-issues.md) KI-14.

## Simulation

9. **`SwapSimulator` is view-only and tracks the live engine**, mirroring `Pool.swap`'s tick
   traversal. Drift against the real engine is pinned by a swap-and-revert oracle. Enforced:
   `src/lib/SwapSimulator.sol`.
   Tests: `test/base/SwapSimulator.t.sol`, `test/base/SwapSimulator_QuoterOracle.t.sol`.

   The simulation runs at fee = 0, so its *impact reading* is exact for exact-output swaps and
   conservative (over-estimating, never under-estimating) for exact-input ones. The over-estimate
   is ≈ fee/1e6 within the pool's in-range depth, but is **not** bounded there: exact-input orders
   sized in `(capacity, capacity/(1 − maxFee))` are quoted at `maxFee`. Accepted, not fixed —
   [`known-issues.md`](known-issues.md) KI-1. Auditors should treat "the quote is always close to
   the fee-adjusted impact" as **false** at that boundary, and the conservative *direction* as the
   property that actually holds.

   **Conservative in impact units does not mean conservative in fee terms.** The over-estimate is
   safe on the imbalance-increasing branch, where the midpoint sum is `2C + p` and a larger `p`
   raises the fee. It inverts on the non-crossing corrective branch, where the sum is `2C − p`:
   the quoted fee is `c·(C − p/2)`, *decreasing* in `p`, so an over-estimated `p` yields a quote
   slightly **below** the realized-path fee, of order `c·(p_sim − p_real)/2`. Separately, the
   quote is taken from the fee-free replay while `_afterSwap` advances state by the smaller
   fee-bearing move, and same-block decay is the identity, so the difference persists across
   legs within a block rather than washing out. Accepted —
   [`known-issues.md`](known-issues.md) KI-15.

10. **Hostile swap parameters cannot make the quote path spin or revert.** Zero amounts,
    already-exceeded limits, and out-of-bounds limits short-circuit to a zero-impact result —
    in each case v4-core reverts the swap itself immediately after (its guards run in the same
    order), so the quoted fee is never consequential. Enforced: the three early returns in
    `SwapSimulator._simulate`.
    Tests: `test/feature/PriceLimitBounds.t.sol`.

## Protocol fee and settlement

11. **The protocol slice is bounded at 20 %** of each dynamic fee (`MAX_PROTOCOL_FEE_BPS`), so
    LPs keep at least 80 % of any fee charged. Enforced: `AscntGovernance.setProtocolFeeBps`,
    recomputed per swap in `_computeProtocolFeeSplit`.
    Tests: `test/fuzz/Phase1SettleSplit.t.sol`, `test/feature/ProtocolFeeAccounting.t.sol`.

12. **A carved slice always has a destination.** The split reads the live treasury and carves
    only when one is set; governance couples `setTreasury`/`setProtocolFeeBps` so a nonzero fee
    can never coexist with a zero treasury. The slice reaches the treasury or stays with LPs —
    never neither. Enforced: `_computeProtocolFeeSplit`, `AscntGovernance` setter coupling.
    Tests: `test/differential/Phase3_Xsub4_BpsCoupling.t.sol`, `test/fuzz/Phase1SettleSplit.t.sol`.

13. **The take rounds down and equals the swapper's charge.** One value feeds both the treasury
    take and the returned hook delta, so they cannot diverge; rounding dust (< 1 raw unit per
    swap) is eaten by the treasury, never charged to the swapper. See
    [`known-issues.md`](known-issues.md) KI-3 for the accepted-dust analysis. Enforced:
    `_takeProtocolFeeOnAfterSwap`.
    Tests: `test/fuzz/Phase1SettleTake.t.sol`, `test/differential/Phase3_Settle6_Settlement.t.sol`.

14. **A hostile token cannot halt swaps via the take.** A reverting treasury transfer falls
    back to minting ERC-6909 claims on the PoolManager (`ProtocolFeeTakenAsClaims`); a token
    that burns all forwarded gas before failing is the accepted out-of-scope case (SETTLE-17).
    Enforced: try/catch in `_takeProtocolFeeOnAfterSwap`.
    Tests: `test/reentrancy/RevertOnTransferDoS.t.sol`.

15. **Re-entrant swaps cannot cross-contaminate fee state.** The per-swap protocol rate lives
    in a poolId-keyed transient slot, written in `beforeSwap` and read in `afterSwap` before
    any external call — a nested swap brackets its own stash and its own price snapshot. All
    `afterSwap` state writes complete before the untrusted token call. Enforced: the transient
    stash in `AscntBaseHook`, the ordering in `SimHook._afterSwap`.
    Tests: `test/reentrancy/ReentrancyInvariant.t.sol`, `test/reentrancy/NestedSwapDuringTake.t.sol`,
    `test/reentrancy/PostTransferReentrancy.t.sol`.

16. **Each hook's fee cache converges on the authoritative value for its lifecycle state**: the
    global rate while subscribed, zero once removed. Push failures are fault-isolated and
    permissionlessly repairable via `syncProtocolFee`, in both directions; a removed hook can
    never be re-armed (re-subscription requires a fresh CREATE2 deploy). Enforced:
    `AscntBaseHook.syncProtocolFee`, `AscntGovernance.removeSubscriber`.
    Tests: `test/governance/SubscriberHardening.t.sol`, `test/governance/Propagation.t.sol`,
    `test/governance/HookLifecycleHardening.t.sol`.

## Governance and lifecycle

17. **Two-lane authority holds everywhere**: parameter and role changes go through the timelock
    (≥ 24 h `getMinDelay`, validated on every rotation); only deploys, deprecation flags, pause
    levers, pauser rotation, and pool launch are direct-call. The full matrix is in the README.
    Tests: `test/access/Phase2_GovAuthorityMatrix.t.sol`, `test/timelock/Timelock.t.sol`,
    `test/access/Phase2_LifecycleAccess.t.sol`, `test/access/Phase2_GovInvariant.t.sol`.

18. **The protocol cannot be left ownerless**: `renounceOwnership` always reverts, and
    `transferOwnership` is timelock-gated — so a mistaken transfer is recoverable by the
    timelock regardless of where ownership sits. Enforced: `AscntGovernance` overrides.
    Tests: `test/governance/AscntGovernance.t.sol`.

    The owner slot being non-zero is unconditional — `renounceOwnership` always reverts and
    `transferOwnership` rejects `address(0)`. Recoverability from a bad transfer depends on the
    timelock slot pointing at a contract that can originate calls, which rotation now guarantees:
    `proposeTimelock` only nominates, and the role moves only when the nominee itself calls
    `acceptTimelock`. A candidate nobody can drive can never complete that step, so it cannot take
    the slot and strand the slow lane. Note this secures rotation, not honesty —
    `_requireValidTimelock` still checks shape (`getMinDelay() >= 24h`) rather than control, and a
    nominee can lower its own delay after accepting.

19. **Pool configuration is one-shot and immutable** — no reconfigure path exists; a
    misconfigured pool must be relaunched on a fresh pool id. Enforced:
    `SimHook.configurePool`.
    Tests: `test/invariant/SimHookInvariant.t.sol` (config-immutability campaign),
    `test/feature/ConfigurePoolBounds.t.sol`.

20. **There is no kill switch** for a live, configured pool: no owner, timelock, or pauser
    action halts swaps or removals; factory deprecation is advisory only. This is pinned
    deliberately — the tests fail the moment a halt path is added. Enforced: absence, pinned by
    `test/access/Phase2_XSub2_NoKillSwitch.t.sol`.

21. **LP exit is always open.** The pause (global or per-hook) blocks deposits only; removals
    are never gated by pause or configuration state. The only removal gate is the JIT lock,
    itself bounded by `MAX_JIT_LOCK_BLOCKS` (≈ 7 days at mainnet cadence; the lock is denominated
    in `block.number`, so its wall-clock length depends on the deployment chain's block time).
    Enforced: `AscntBaseHook._beforeAddLiquidity`
    vs `SimHook._beforeRemoveLiquidity`.
    Tests: `test/feature/EmergencyPause.t.sol`, `test/jit/Phase4bJitPause.t.sol`.

22. **Global and per-hook pause compose as OR** and are independent: lifting the global breaker
    restores each hook to exactly its own quarantine state. Enforced:
    `AscntGovernance.isAddLiquidityBlocked`.
    Tests: `test/feature/EmergencyPause.t.sol`.

23. **Subscriber removal is fail-safe and grief-proof**: the zeroing push is gas-stipended and
    fault-isolated (a hostile hook cannot block its own removal), re-asserted on every repeat
    call, and the removed hook lands with add-liquidity paused until someone consciously
    re-opens it. The broadcast loop is bounded (≤ 256 subscribers × 50k gas stipend).
    Enforced: `AscntGovernance.removeSubscriber`, `MAX_SUBSCRIBERS`, `PUSH_GAS_STIPEND`.
    Tests: `test/governance/SubscriberHardening.t.sol`, `test/governance/HookLifecycleHardening.t.sol`.

## Provenance

24. **Canonical provenance cannot be forged.** `AscntGovernance.isCanonicalHook` resolves from
    the governance root through its one-shot, validated `hookFactory` pointer — no hook-supplied
    pointer is trusted anywhere in the chain, and `isVerifiedHook` is only ever written inside
    the owner-gated `deployHook`, which CREATE2-deploys the hook itself. An impostor hook, fake
    factory, or internally-consistent fake governance is simply absent from the registry.
    Verification is permanent; deprecation is advisory and does not revoke it. Enforced:
    `AscntGovernance` provenance views + `setHookFactory` handshake, `HookFactory.deployHook`.
    Tests: `test/governance/CanonicalHookProvenance.t.sol`.

25. **Hook self-attestation fails closed.** `hook.isVerified()`/`isDeprecated()` return false
    unless the hook's recorded deployer *is* the canonical factory (and it has code) — but they
    remain self-attestations, meaningful only after the caller has authenticated `governance`.
    Integrators must resolve from the root instead (README: integrator notes).
    Enforced: `AscntBaseHook.isVerified`/`isDeprecated`.
    Tests: `test/governance/CanonicalHookProvenance.t.sol`.

## JIT liquidity lock

26. **A position must age `jitLockBlocks` after its last add before withdrawing.** The clock is
    keyed on v4-core's exact position key (sender, ticks, salt): fee-only pokes neither trip
    nor reset it; single-unlock batching cannot reset it; one PoolManager caller can never bump
    another's clock (users sharing one naive router with identical ticks+salt share a position
    — and therefore a clock — which is inherent to v4's sender-keyed positions). A top-up
    re-locks the entire position by design. Enforced: `SimHook._afterAddLiquidity` /
    `_beforeRemoveLiquidity`.
    Tests: `test/feature/JitLock.t.sol`, `test/feature/SandwichJit.t.sol`,
    `test/jit/Phase4bJitBoundary.t.sol`, `test/jit/Phase4bJitIsolation.t.sol`,
    `test/access/Phase2_JitClockGriefing.t.sol`.

## Isolation

27. **Pools are isolated**: all per-pool state (`poolData`, `poolConfig`, JIT clocks, the
    transient fee stash) is poolId-keyed; no swap on one pool can move another pool's
    accumulator, floor clock, or fee.
    Tests: `test/feature/MultiPoolIsolation.t.sol`, `test/jit/Phase4bJitIsolation.t.sol`.

28. **Hooks are isolated from each other**: governance's broadcast loop is fault-isolated per
    subscriber, so one hook's failure cannot block another's update or a global fee change.
    Tests: `test/governance/Propagation.t.sol`, `test/governance/SubscriberHardening.t.sol`.
