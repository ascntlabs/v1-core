# Audit response — September 2026

Covers three independent reviews of Ascnt v1 Core and states, for each finding, what was done.

| Review | Date |
|---|---|
| Olympix BugPoCer scan | 2026-08-24 |
| Vulsight one-day complimentary review | 2026-08-27 |
| LeftClaw job #680 | 2026-09-04 |

All three reviews covered the same source tree, frozen on 2026-08-18.

**Behavioural difference from the reviewed tree.** One, and it is a fix: `configurePool` now rejects
`maxFee == LPFeeLibrary.MAX_LP_FEE`, so the largest admissible cap is 999,999 pips. Everything else
in this response is documentation, tests, or code comments — no other behaviour changed.

Reports, as received, are in [`docs/audits/`](audits/):
`2026-08-24-olympix-bugpocer-scan.pdf`, `2026-08-27-vulsight-one-day-review.pdf`,
`2026-09-04-leftclaw-680.html`.

Statuses: **Fixed** (code changed) · **Accepted — documented** (behaviour stands, written up) ·
**Operational** (handled by the deployment process, documented as a premise) ·
**Partially accepted** (addressed, but not in the form recommended).

---

## Olympix BugPoCer (2026-08-24)

| ID | Finding | Status | Where |
|---|---|---|---|
| 5.1.1 | Split-additivity holds in impact space but not in amount space | Accepted — documented | KI-15; invariant #3 rewritten; `test/feature/SplitAdditivity.t.sol` |
| 5.2.1 | Exact-output swaps revert once saturated at `maxFee == MAX_LP_FEE` | **Fixed** | `SimHook.configurePool`; `Phase4aProbe.t.sol`, `ConfigurePoolBounds.t.sol` |

**5.2.1 detail.** `configurePool` now rejects the 1e6 endpoint, so `lpFee ≤ maxFee ≤ 999,999 < 1e6`
and v4-core's `Pool.InvalidFeeForExactOut` is unreachable from hook fee math. The FEE-14 boundary
test was inverted accordingly: it now asserts the exact-output swap *executes* at the cap. A useful
side effect is that KI-1's over-quote band `(capacity, capacity/(1 − maxFee))`, previously unbounded
at a 100 % ceiling, is now bounded at `1e6 × capacity`. The exact-**input** case is not removed by
this — at 999,999 pips a swapper still surrenders all but ~one millionth of an unbounded order — so
KI-1's integrator note (disclosed quote, meaningful slippage bound) stands unchanged.

---

## Vulsight one-day review (2026-08-27)

| ID | Finding | Status | Where |
|---|---|---|---|
| ASCNT-H-01 | Fee derived in impact space, charged on token notional | Accepted — documented | KI-15; invariant #3; `SimHook.calculateDynamicFee` comment; `test/feature/SplitAdditivity.t.sol` |
| ASCNT-M-01 | Exact-zero settlement guard breaks accumulator path-to-state consistency | Operational | KI-6 "Deployment premise"; invariant #6; `test/feature/SeededPoolAccumulator.t.sol` |
| ASCNT-L-01 | Fee-free quoting and fee-bearing execution diverge from the split-neutrality claims | Accepted — documented | KI-15 §"Two further sources"; invariant #9; `SwapSimulator` docstring; `test/feature/QuoteVsExecution.t.sol` |
| ASCNT-L-02 | Sub-pip moves discarded with no fractional carry | Accepted — documented | KI-14 §"Resolution is one pip everywhere"; `test/feature/SubPipResolution.t.sol` |
| Appendix | `swapDelta − hookDelta` recomposition headroom unproven at the int128 boundary | Accepted — documented + test | KI-16; `test/feature/SettlementBoundary.t.sol` |
| Appendix | Written invariants stronger than the implementation supports | **Fixed (docs)** | invariants #3, #6, #9; README |

**H-01.** The mechanics as described are correct; the conclusion is framed differently here. The
midpoint fee is a trapezoidal approximation of the path integral of the rate over notional, and a
split route recovers that integral — so the split total is the economically defensible price, not a
discount. The error is two-sided: on a convex profile (dense→thin) the one-shot overcharges relative
to the integral, on a concave profile it undercharges. Since a fee-optimising router takes whichever
is cheaper, the pool sees `min(one-shot, best split)`; that asymmetry is recorded in KI-15 rather
than argued away. Not a fund-loss path — nothing is drained, no position is mis-accounted, every
leg is floored at `effectiveMinFee`, and every quote is disclosed pre-signature through the v4
Quoter. The routes do not, however, land on the same end state: writing the characterization test
showed that the cheaper route surrenders less notional to fees and therefore travels further, so on
the convex fixture a split paying 41 % less fee ends with an accumulator 5.4 % higher. KI-15 and
invariant #3 state that rather than claiming end-state equality. The recommended notional-weighted fee was considered and declined, with the
reason recorded in KI-15: it converts a state-based rate into a size-based one, which is the
property the design rests on.

**M-01.** Accepted as reachable in principle and closed by a deployment premise rather than a code
change. The protocol seeds every pool full-range at launch and, as the seed is not locked,
keeping one full-range position in place is the operating recommendation, so `L > 0`
at every tick and any price move necessarily exchanges tokens — the exact-zero case cannot coincide
with a real price move, and neither the injection nor the scrubbing variant is reachable. The
premise is now stated in KI-6 and invariant #6 and pinned by a seeded-pool regression that asserts
both variants alongside the existing unseeded contrast case. Note the premise does **not** close
KI-6's own saturation case: a dust swap through a genuinely *thin* region still books a large impact
per unit of notional, which is normal market structure and priced as such.

**L-01.** Both effects accepted and pinned in `test/feature/QuoteVsExecution.t.sol`. Measured on
a single-range (uniform-liquidity) pool, so Effect 1 is isolated from H-01's curvature argument:
the same gross notional sent as two same-block tranches is quoted below the one-shot. On the
corrective branch the simulator reads 3,203 pips of impact where the realized move is 3,196, and
the quote lands at 2,378 pips where the realized move would have priced 2,382 — the over-estimate
making the fee *cheaper*, which is Effect 2 exactly. Effect 2 — that the simulator's exact-input over-estimate is
conservative in impact units but *anti*-conservative in fee terms on the non-crossing corrective
branch, where the quote is `c·(C − p/2)` and decreasing in `p` — was not previously recorded
anywhere, and the "always conservative" language in `SwapSimulator`'s docstring has been qualified
accordingly. Invariant #9 now distinguishes impact conservatism from fee conservatism explicitly.

**Appendix, int128.** Pinned in `test/feature/SettlementBoundary.t.sol` as the arithmetic bound
rather than a live settlement at 2^127 — minting a token to that supply to exercise a path the
bound already excludes buys nothing. If the settlement path is revised, that test should be
replaced with the end-to-end version the recommendation describes. The bound holds: the take is levied on the unspecified currency and
`MAX_PROTOCOL_FEE_BPS` is 20 %, so the exact-output worst case is `1.2 × in` and overflow needs
`in > 2^127/1.2 ≈ 1.4e38` raw units. v4's checked casts make the failure mode a clean revert rather
than corruption. Recorded as KI-16 and treated as a hardening item for any future revision of the
settlement path, per the recommendation.

---

## LeftClaw #680 (2026-09-04)

| # | Finding | Status | Where |
|---|---|---|---|
| 1 | `deployHook` owner-only, no timelock | Accepted — documented | KI-17 |
| 2 | JIT lock does not gate fee-only pokes (`liquidityDelta == 0`) | Accepted — documented | KI-18; `SimHook.sol` comment; `Phase4bJitBoundary.t.sol::test_jit2_pokeSettlesFeesWhilePrincipalStaysLocked` |
| 3 | Zero-liquidity gap-walk saturates the accumulator | Operational | KI-6 (same premise as Vulsight M-01); `test/feature/SeededPoolAccumulator.t.sol` |
| 4 | Simulator walks empty tick-bitmap words inside KI-1's window | Accepted — documented | KI-2; `SeededPoolAccumulator.t.sol::test_ki2_seedBoundsTheWalkByInputRatherThanByPriceLimit` |
| 5 | JIT lock is `block.number`-denominated, shorter in wall-clock on fast chains | Accepted — documented | KI "Deployment premises"; README; invariant #21 |
| 6 | Full-subscriber broadcast gas vs block limit | Accepted — documented | KI "Deployment premises" |
| 7 | KI-8 reaction window shortens on faster block times | Accepted — documented | KI "Deployment premises" |
| 8 | `PUSH_GAS_STIPEND` margin under repricing | Accepted — documented | KI "Deployment premises" |
| 9 | Decay double-rounding | Accepted — no change | already bounded and pinned by existing tests |
| 10 | Sub-pip protocol-fee dust accrues to LPs, not as documented | **Fixed (docs)** | KI-3 retitled and corrected |
| 11 | zkSync-family `CREATE2` derivation breaks hook-address mining | Accepted — documented | KI "Deployment premises" (unsupported) |
| 12 | Cancun `tstore`/`tload` required | Accepted — documented | KI "Deployment premises" |
| 13 | No chain-specific known-issue entries | **Partially accepted** | KI "Deployment premises and portability" |

**#1.** Documented rather than changed. The asymmetry is deliberate — slow-lane parameters sit
behind the timelock, hook deployment does not. The residual on owner compromise is provenance
laundering endangering *future* deposits, not existing TVL: the subscriber callback is gas-capped
and `try/catch`-wrapped, configuration is one-shot, and no governance action reaches LP principal.
Worth noting the proposed fix is incomplete on its own — `setHookFactory` is plain `onlyOwner`
(KI-12), so a compromised owner installs a rogue factory regardless; closing the path means
timelocking both lanes, which removes the fast-launch property the asymmetry exists for.

**#2.** Contested on threat model, and documented. The lock deters through inventory risk on
*principal*; a poke realizes already-accrued fees and leaves principal exposed for the remainder of
the window, so it takes nothing from the deterrent. This differs from fee-withholding designs, where
a poke genuinely escapes the penalty. Gating pokes would block honest LPs from compounding for no
gain. The residual is calibration of `jitLockBlocks`, a per-pool launch-time choice readable
on-chain before deposit.

**#5 and #7.** No code change; `MAX_JIT_LOCK_BLOCKS` stays at 50,400. The lock is block-denominated
by design, and the consequence — that the same block count is a shorter wall-clock lock where blocks
are faster — is now stated in invariant #21 and the register's deployment-premises section, with
`jitLockBlocks` calibrated per deployment rather than carried across chains. Raising the ceiling to
absorb faster chains was considered and not adopted: it would widen the worst-case lock on mainnet
to fix a parameter-selection problem.

**#13, partially accepted.** A per-chain risk register was not adopted. Instead the portability
conditions are stated generically in "Deployment premises and portability" — block-denominated
constants, Cancun, standard `CREATE2` derivation, block gas limit — and verified per deployment.
The primary target is Ethereum mainnet; other EVM L2s may follow, and each is checked against that
list at launch rather than pre-enumerated here.
