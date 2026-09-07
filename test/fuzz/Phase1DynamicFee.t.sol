// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Phase1FuzzBase} from "./Phase1Helpers.sol";
import {HookMath} from "../../src/lib/HookMath.sol";
import {SafeCast} from "../../src/lib/SafeCast.sol";

/// @notice Phase-1 stateless fuzz over `SimHook.calculateDynamicFee` via the shared harness's
///         `exposedCalculateDynamicFee`. The fee is midpoint-priced: every swap pays
///         weight x the midpoint of the |cum| leg it traverses (kPips on increasing legs,
///         cPips on decreasing legs; a crossing pays both legs, each weighted by its share
///         of the swap). The weights are per-pool ONE-TIME config (set in configurePool,
///         immutable — not contract constants): exact-value tests below pin the canonical
///         launch defaults K_DEFAULT = 2e6 / C_DEFAULT = 1e6, which reproduce every spec
///         anchor; containment properties fuzz the full admissible weight lattice.
///
/// Covers: FEE-1 (clamp holds across the production impact domain [0, PIPS_SCALE], full-range
///         cum incl. int256 saturation extremes, and the FULL admissible (kPips, cPips)
///         weight lattice), FEE-2 (min-first clamp ordering — returns
///         effectiveMinFee even above maxFee; production safety is the configurePool bound chain),
///         FEE-9 (increasing/decreasing/crossing branch truth table against the midpoint
///         closed-form oracle), FEE-10 (increasing >= decreasing for matched inputs + the exact
///         per-branch identities), FEE-11 (fee AMOUNT monotone in estimatedPriceImpact — the RATE
///         dips past a crossing by design, pinned), FEE-12 (zero-cross accounting identity + the
///         two-leg charged form), FEE-13 (continuity at cum == 0).
///
/// Unlike the pre-midpoint model, rounding DOES happen inside calculateDynamicFee (mulDiv
/// floors): the increasing branch is exact (kPips/(2e6) = 1), the decreasing branch floors
/// <= 1 pip (the /2), and the crossing branch floors < 2 pips — one per leg, since each leg
/// applies its weight and divides in a single mulDiv rather than nesting two. Those
/// tolerances are asserted here; rounding-direction properties for the INPUT producers live in
/// Phase1HookMathLib.t.sol.
contract Phase1DynamicFeeFuzz is Phase1FuzzBase {
    uint24 internal constant WIDE_MAX = type(uint24).max; // disables the max clamp for branch oracles

    /// @dev Canonical launch weights — the values that reproduce every spec anchor and closed
    ///      form. kPips/cPips are per-pool one-time config now (configurePool, immutable), not
    ///      contract constants: anchor/oracle/identity tests pin these defaults because their
    ///      expected values are defaults-only statements.
    uint32 internal constant K_DEFAULT = 2e6;
    uint32 internal constant C_DEFAULT = 1e6;
    // Admissible weight bounds — mirror SimHook.MAX_K_PIPS / MAX_C_PIPS (configurePool rejects
    // zero and anything above these via ZeroK/KTooHigh/ZeroC/CTooHigh).
    uint32 internal constant MAX_K_PIPS = 20e6;
    uint32 internal constant MAX_C_PIPS = 20e6;

    // ------------------------------------------------------------------
    // FEE-1 — the clamp holds for every reachable input
    // ------------------------------------------------------------------

    /// @notice FEE-1: for any admissible clamp pair (effMin <= maxFee <= MAX_LP_FEE), any
    ///         admissible weight pair (kPips in [1, MAX_K_PIPS], cPips in [1, MAX_C_PIPS] —
    ///         the FULL configurePool-admissible lattice), any production-domain impact
    ///         (estimatedPriceImpact in [0, PIPS_SCALE] — see below), and cumPriceImpact over
    ///         full int256 including both saturation extremes, either direction, the result is
    ///         inside [effectiveMinFee, maxFee] — hence <= MAX_LP_FEE — and the call never
    ///         reverts.
    ///
    ///         estPI is bounded to [0, PIPS_SCALE] because that is the ENTIRE reachable domain:
    ///         `calculatePriceImpactCapped` — the only producer of this argument — caps at
    ///         PIPS_SCALE. The bound is now load-bearing, not cosmetic: the crossing branch
    ///         computes checked `2 * estimatedPriceImpact`, which overflows (reverts) for
    ///         estPI > 2^255 at the default kPips = 2e6 (larger kPips reverts earlier via the
    ///         weight mulDiv, ~2^256/10 at MAX_K_PIPS — both astronomically outside the
    ///         production domain) — a full-uint256 fuzz would fail on inputs that cannot exist in
    ///         production. cum keeps its full range AT ANY WEIGHT: the increasing/decreasing
    ///         branches saturate safely (addSaturatingUint, then the MAX_MIDPOINT_SUM = 4e12
    ///         cap before weight scaling — per the spec amendment, mulDiv(4e12, 1, 2e6) = 2e6
    ///         >= MAX_LP_FEE >= maxFee even at the minimum admissible weight, so the cap is
    ///         fee-neutral and only removes the mulDiv overflow revert that saturated |cum|
    ///         with kPips > 2e6 would otherwise hit), and the crossing branch needs
    ///         estPI > |cum|, so in-domain estPI keeps its squares tiny (|cum| < estPI <= 1e6).
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: dev.fuzz.runs = 1000
    function testFuzz_dynamicFee_alwaysWithinClamp(
        uint256 estPI,
        int256 cum,
        bool zeroForOne,
        uint24 effMin,
        uint24 maxFee,
        uint32 kPips,
        uint32 cPips
    ) public view {
        maxFee = uint24(bound(maxFee, 0, MAX_LP_FEE));
        effMin = uint24(bound(effMin, 0, maxFee));
        estPI = bound(estPI, 0, PIPS_SCALE); // production domain — see natspec
        kPips = uint32(bound(kPips, 1, MAX_K_PIPS)); // full admissible weight lattice
        cPips = uint32(bound(cPips, 1, MAX_C_PIPS));

        uint24 fee = harness.exposedCalculateDynamicFee(estPI, cum, zeroForOne, effMin, maxFee, kPips, cPips);

        assertGe(fee, effMin, "fee >= effectiveMinFee");
        assertLe(fee, maxFee, "fee <= maxFee");
        assertLe(fee, MAX_LP_FEE, "fee <= MAX_LP_FEE");
    }

    /// @notice FEE-1 saturation corners, pinned: cum at int256.max / int256.min+1 / int256.min
    ///         (the last unreachable in production — addSaturating floor — but the function must
    ///         still not revert or escape the clamp) crossed with in-domain impact corners AND
    ///         the weight-lattice corners k in {1, K_DEFAULT, MAX_K_PIPS} x c in
    ///         {1, C_DEFAULT, MAX_C_PIPS}. The impact corners narrowed from the old
    ///         {0, 1e6, uint256.max}: type(uint256).max now REVERTS when the crossing branch is
    ///         reached (checked `2 * estPI` overflow) and is unreachable in production
    ///         (calculatePriceImpactCapped caps at PIPS_SCALE), so the corners probe
    ///         {0, 1 pip, PIPS_SCALE} instead. Every saturated-cum case lands in the increasing
    ///         or decreasing branch (a crossing would need estPI > |cum|): addSaturatingUint
    ///         pins the leg sum at uint256.max, the MAX_MIDPOINT_SUM cap pulls it to 4e12 before
    ///         weight scaling — so the weight mulDiv cannot overflow at ANY admissible k (spec
    ///         amendment: without the cap, kPips > 2e6 would revert here) and its result
    ///         mulDiv(4e12, weight, 2e6) >= 2e6 >= maxFee for every weight >= 1 pip, so the
    ///         clamp catches it — no revert anywhere on the lattice.
    function test_dynamicFee_saturationCorners() public view {
        int256[3] memory cums = [type(int256).max, type(int256).min + 1, type(int256).min];
        // Narrowed impact domain: [0, PIPS_SCALE] is all calculatePriceImpactCapped can emit;
        // out-of-domain extremes belong to the (documented) revert region, not this corner pin.
        uint256[3] memory pis = [uint256(0), uint256(1), uint256(1e6)];
        uint32[3] memory ks = [uint32(1), K_DEFAULT, MAX_K_PIPS];
        uint32[3] memory cs = [uint32(1), C_DEFAULT, MAX_C_PIPS];
        for (uint256 i = 0; i < cums.length; i++) {
            for (uint256 j = 0; j < pis.length; j++) {
                for (uint256 m = 0; m < ks.length; m++) {
                    for (uint256 n = 0; n < cs.length; n++) {
                        uint24 feeZfo =
                            harness.exposedCalculateDynamicFee(pis[j], cums[i], true, 100, 10_000, ks[m], cs[n]);
                        uint24 feeOfz =
                            harness.exposedCalculateDynamicFee(pis[j], cums[i], false, 100, 10_000, ks[m], cs[n]);
                        // EQUALITY, not containment: every corner here has |cum| saturated far
                        // above MAX_MIDPOINT_SUM, so the capped quote mulDiv(4e12, weight, 2e6)
                        // >= 2e6 >= maxFee at EVERY lattice point (even weight = 1 pip) and the
                        // clamp must return exactly maxFee. This pins the cap's MAGNITUDE: a cap
                        // mis-set low (e.g. 4e6) quotes ~2 pips at k=1 and clamps to effMin —
                        // near-free swaps into a maximally imbalanced pool — which this catches.
                        assertEq(feeZfo, 10_000, "saturated-cum corner zfo must clamp to exactly maxFee");
                        assertEq(feeOfz, 10_000, "saturated-cum corner ofz must clamp to exactly maxFee");
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // FEE-2 — min-first clamp ordering (documented hazard, config-guard dependency)
    // ------------------------------------------------------------------

    /// @notice FEE-2 (confirmation of the hazardous ordering, NOT a reachable bug): when called
    ///         with effectiveMinFee > maxFee and a tiny impact, the min clamp fires FIRST and the
    ///         function returns effectiveMinFee — a value ABOVE maxFee. In production this state
    ///         is prevented ONLY by configurePool's minMinFee<=maxMinFee<=maxFee chain (and
    ///         calculateEffectiveMinFee staying within [minMinFee, maxMinFee], FEE-3): the clamp
    ///         itself has no ordering protection. A future reconfigure path or weakened bound
    ///         check re-exposes this instantly.
    function testFuzz_dynamicFee_invertedClamp_minWins(uint24 effMin, uint24 maxFee, uint256 estPI) public view {
        maxFee = uint24(bound(maxFee, 0, type(uint24).max - 1));
        effMin = uint24(bound(effMin, uint256(maxFee) + 1, type(uint24).max));
        // cum == 0 => increasing branch => at the default kPips = 2e6, dynamicImpactFee == estPI
        // exactly (k x the midpoint of a from-zero leg = the endpoint); keep it strictly below
        // effMin so the min branch is the one that fires.
        estPI = bound(estPI, 0, uint256(effMin) - 1);

        uint24 fee = harness.exposedCalculateDynamicFee(estPI, 0, true, effMin, maxFee, K_DEFAULT, C_DEFAULT);
        assertEq(fee, effMin, "min-first clamp returns effectiveMinFee");
        assertGt(fee, maxFee, "returned fee EXCEEDS maxFee when clamps are inverted");
    }

    /// @notice FEE-2 unreachability half: for every configurePool-admissible lattice point
    ///         (minMinFee <= maxMinFee <= maxFee <= MAX_LP_FEE, kPips in [1, MAX_K_PIPS],
    ///         cPips in [1, MAX_C_PIPS] — the production bound chain now includes the
    ///         ZeroK/KTooHigh/ZeroC/CTooHigh weight checks) and any ramp state, the effective
    ///         min fee produced by the REAL ramp (HookMath.calculateEffectiveMinFee) never exceeds
    ///         maxMinFee — so the inverted-clamp state above cannot arise in production, and the
    ///         dynamic fee stays <= maxFee for arbitrary production-domain impact inputs.
    function testFuzz_dynamicFee_admissibleLattice_neverExceedsMaxFee(
        uint24 minMin,
        uint24 maxMin,
        uint24 maxFee,
        uint256 t,
        uint48 decayLen,
        uint256 estPI,
        int256 cum,
        bool zeroForOne,
        uint32 kPips,
        uint32 cPips
    ) public view {
        maxFee = uint24(bound(maxFee, 0, MAX_LP_FEE));
        maxMin = uint24(bound(maxMin, 0, maxFee));
        minMin = uint24(bound(minMin, 0, maxMin));
        vm.assume(decayLen > 0); // configurePool enforces ZeroDecay
        estPI = bound(estPI, 0, PIPS_SCALE); // production domain — see the FEE-1 natspec
        kPips = uint32(bound(kPips, 1, MAX_K_PIPS)); // configurePool-admissible weights
        cPips = uint32(bound(cPips, 1, MAX_C_PIPS));

        uint24 effMin = HookMath.calculateEffectiveMinFee(minMin, maxMin, t, decayLen);
        assertLe(effMin, maxMin, "ramp output can never exceed maxMinFee");
        assertLe(effMin, maxFee, "hence effectiveMinFee <= maxFee (bound chain)");

        uint24 fee = harness.exposedCalculateDynamicFee(estPI, cum, zeroForOne, effMin, maxFee, kPips, cPips);
        assertLe(fee, maxFee, "production-shaped inputs never escape maxFee");
    }

    // ------------------------------------------------------------------
    // FEE-9 — branch-selection truth table
    // ------------------------------------------------------------------

    /// @notice FEE-9: over the full truth table {cum<0, cum==0, cum>0} x {zeroForOne, oneForZero},
    ///         the branch is increasing iff ((cum==0) OR (zeroForOne & cum<0) OR
    ///         (oneForZero & cum>0), per the invariant statement) and the charged quantity
    ///         follows the midpoint closed forms (C = |cum|, P = estPI, k=2, c=1):
    ///         increasing pays 2C + P (k x leg midpoint, exact), decreasing-no-cross (P <= C)
    ///         pays floor((C + (C-P)) / 2) (c x leg midpoint), and a crossing (P > C) pays the
    ///         two-leg sum floor(C^2/(2P)) + floor(2E^2/(2P)) with E = P - C — one floor per leg,
    ///         since each leg applies its weight inside a single mulDiv. Pinned at the
    ///         canonical defaults K_DEFAULT/C_DEFAULT — these closed forms are defaults-only
    ///         statements (the branch SELECTION is weight-independent). Inputs are
    ///         bounded away from saturation so the expected value is computable with plain
    ///         checked int math and explicit floors (an oracle independent of HookMath/FullMath),
    ///         and clamps are disabled (effMin = 0, maxFee = uint24.max) so branch output is
    ///         observed raw.
    function testFuzz_dynamicFee_branchTruthTable(uint256 estPI, int256 cum, bool zeroForOne) public view {
        estPI = bound(estPI, 0, 1e6);
        cum = bound(cum, -1e6, 1e6);

        // Oracle straight from the invariant statement.
        bool expectedIncreasing = (cum == 0) || (zeroForOne && cum < 0) || (!zeroForOne && cum > 0);

        uint256 absCum = cum >= 0 ? uint256(cum) : uint256(-cum);
        uint256 expectedFee;
        if (expectedIncreasing) {
            // k=2 x midpoint of the leg C -> C+P: exact, no floors (kPips/(2e6) == 1).
            expectedFee = 2 * absCum + estPI;
        } else if (estPI <= absCum) {
            // c=1 x midpoint of the leg C -> C-P: one floor from the /2.
            expectedFee = (absCum + (absCum - estPI)) / 2;
        } else {
            // Crossing: down-leg c x C/2 weighted C/P plus up-leg k x E/2 weighted E/P,
            // mirroring the implementation's nested mulDiv floors term by term.
            uint256 twoP = 2 * estPI; // estPI > absCum >= 0, so twoP >= 2: no div-by-zero
            uint256 e = estPI - absCum;
            expectedFee = (absCum * absCum) / twoP + (2 * e * e) / twoP;
        }

        uint24 fee = harness.exposedCalculateDynamicFee(estPI, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertEq(uint256(fee), expectedFee, "branch selection and charged quantity match the spec");
    }

    // ------------------------------------------------------------------
    // FEE-10 — increasing swaps pay at least as much as matched decreasing swaps
    // ------------------------------------------------------------------

    /// @notice FEE-10: for the same (|cum|, estimatedPriceImpact), the imbalance-INCREASING
    ///         direction pays k x its leg midpoint = 2|cum| + estPI, while the DECREASING
    ///         direction pays c x its leg midpoint — floor((2|cum| - estPI)/2) without a cross,
    ///         or the two-leg crossing form beyond it — so fee(increasing) >= fee(decreasing)
    ///         always: restoring the pool is never more expensive than unbalancing it. Clamps
    ///         disabled to compare the raw branch outputs; the exact identities are asserted too.
    ///
    ///         PRECONDITION: the ordering holds when cPips <= kPips. configurePool does NOT
    ///         enforce that — a deployer may configure c > k (the maxima are equal, 20e6/20e6;
    ///         the ordering is a deployer responsibility) — so this
    ///         stays pinned at K_DEFAULT/C_DEFAULT (where the exact identities also live); the
    ///         fuzz below generalizes the ordering over the c <= k sub-lattice.
    function testFuzz_dynamicFee_increasingChargesAtLeastDecreasing(uint256 estPI, int256 cum) public view {
        estPI = bound(estPI, 0, 1e6);
        cum = bound(cum, -1e6, 1e6);
        vm.assume(cum != 0);

        bool increasingDir = (cum < 0); // zeroForOne pushes negative => increases when cum < 0
        uint24 feeIncreasing =
            harness.exposedCalculateDynamicFee(estPI, cum, increasingDir, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint24 feeDecreasing =
            harness.exposedCalculateDynamicFee(estPI, cum, !increasingDir, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);

        assertGe(feeIncreasing, feeDecreasing, "increasing imbalance must cost >= decreasing");

        // Pre-clamp identities in this bounded domain (midpoint closed forms, k=2, c=1).
        uint256 absCum = cum >= 0 ? uint256(cum) : uint256(-cum);
        assertEq(uint256(feeIncreasing), 2 * absCum + estPI, "increasing fee == 2|cum| + estPI");
        if (estPI <= absCum) {
            assertEq(uint256(feeDecreasing), (2 * absCum - estPI) / 2, "decreasing fee == floor((2|cum| - estPI)/2)");
        } else {
            uint256 twoP = 2 * estPI;
            uint256 e = estPI - absCum;
            assertEq(
                uint256(feeDecreasing),
                (absCum * absCum) / twoP + (2 * e * e) / twoP,
                "crossing fee == floor(C^2/(2P)) + 2*floor(E^2/(2P))"
            );
        }
    }

    /// @notice FEE-10 generalized over the weight lattice: the ordering is not defaults-specific.
    ///         For ANY admissible (kPips, cPips) with cPips <= kPips (the precondition — see the
    ///         pinned test's natspec), the increasing charge k x midpoint(C -> C+P) dominates
    ///         both decreasing forms: without a cross because the decreasing leg's midpoint is
    ///         smaller and k >= c scales it no slower, and on a crossing because
    ///         (C^2 + E^2)/(2P) <= C + P/2 for C < P while every crossing floor only shrinks its
    ///         side. Only the >= property generalizes — the exact identities above are
    ///         defaults-only statements.
    function testFuzz_dynamicFee_increasingAtLeastDecreasing_anyWeights(
        uint256 estPI,
        int256 cum,
        uint32 kPips,
        uint32 cPips
    ) public view {
        estPI = bound(estPI, 0, 1e6);
        cum = bound(cum, -1e6, 1e6);
        vm.assume(cum != 0);
        kPips = uint32(bound(kPips, 1, MAX_K_PIPS));
        // Admissible AND c <= k: c > k is configurable in production but breaks the ordering.
        cPips = uint32(bound(cPips, 1, kPips < MAX_C_PIPS ? kPips : MAX_C_PIPS));

        bool increasingDir = (cum < 0); // zeroForOne pushes negative => increases when cum < 0
        uint24 feeIncreasing = harness.exposedCalculateDynamicFee(estPI, cum, increasingDir, 0, WIDE_MAX, kPips, cPips);
        uint24 feeDecreasing = harness.exposedCalculateDynamicFee(estPI, cum, !increasingDir, 0, WIDE_MAX, kPips, cPips);

        assertGe(feeIncreasing, feeDecreasing, "increasing >= decreasing for any admissible c <= k");
    }

    // ------------------------------------------------------------------
    // FEE-11 — fee AMOUNT monotone in estimatedPriceImpact
    // ------------------------------------------------------------------

    /// @notice FEE-11: the midpoint model's fee RATE is intentionally NOT monotone in
    ///         estimatedPriceImpact — it dips just past a zero-crossing (pinned below) — so the
    ///         anti-splitting guarantee is now amount-monotonicity + split-invariance, not
    ///         rate-monotonicity: with (cum, direction) fixed, clamps disabled (effMin = 0,
    ///         maxFee = WIDE_MAX), and e1 <= e2 in the production domain, the fee-amount proxy
    ///         fee(e)*e never decreases beyond floor slack — a larger swap can never pay LESS in
    ///         absolute terms, so splitting or oversizing buys nothing.
    ///
    ///         Slack derivation: the exact (real-valued) amount is monotone in e (increasing
    ///         branch: (2C+e)*e; decreasing: (C - e/2)*e up to the cross, then C^2/2 + (e-C)^2),
    ///         and each computed fee sits within (exact - 3, exact] pips: the increasing branch
    ///         is exact, the decreasing /2 floors <= 1 pip, and the crossing branch's two floors
    ///         lose < 1 + < 2 pips (the 2*floor(E^2/(2P)) term truncates up to just under 2).
    ///         Hence fee(e1)*e1 <= exactAmt(e1) <= exactAmt(e2) < (fee(e2) + 3)*e2. The asserted
    ///         slack 2*e2 is tighter than that proof bound; a brute-force sweep of the domain
    ///         shows the worst realized deficit is below 1*e2.
    ///
    ///         Pinned at the defaults: amount-monotonicity holds for any FIXED (k, c) — the
    ///         midpoint rule is linear in the weights, so scaling k/c scales each branch's exact
    ///         amount without disturbing its monotonicity in e — but the slack constant (and the
    ///         per-branch floor-loss accounting above) was derived at K_DEFAULT/C_DEFAULT.
    function testFuzz_dynamicFee_amountMonotoneInImpact(
        uint256 e1,
        uint256 e2,
        int256 cum,
        bool zeroForOne
    ) public view {
        e1 = bound(e1, 0, PIPS_SCALE);
        e2 = bound(e2, 0, PIPS_SCALE);
        cum = bound(cum, -1e6, 1e6);
        if (e1 > e2) (e1, e2) = (e2, e1);

        uint256 feeLo = harness.exposedCalculateDynamicFee(e1, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint256 feeHi = harness.exposedCalculateDynamicFee(e2, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);

        assertLe(feeLo * e1, feeHi * e2 + 2 * e2, "fee AMOUNT non-decreasing in impact (mod floor slack)");
    }

    /// @notice FEE-11 rate-dip pin (documentation — do NOT "fix" this): past a zero-crossing the
    ///         fee RATE dips below the exact-to-zero rebalance rate before climbing again. With
    ///         C = |cum| = 10_000 (1%): rate(P=10_000) = 5_000 (P == C lands in the decreasing
    ///         branch: c x midpoint C/2); rate(P=12_200) = 4_494 < 5_000 (near the rate minimum
    ///         at P = C*sqrt(3/2) ~ 1.22C); rate(P=30_000) = 14_998, back above. The dip is
    ///         inherent to midpoint pricing — the up-leg past zero starts from a ~0 rate — and is
    ///         not exploitable: the fee AMOUNT rate(P)*P = 3C^2/2 + P^2 - 2CP is strictly
    ///         increasing for P > C, asserted through the dip below.
    function test_dynamicFee_rateDipsPastCrossing_amountStillMonotone() public view {
        int256 cum = -10_000; // 1% imbalance; zeroForOne = false pulls it toward zero
        uint24 rateAtZeroTouch =
            harness.exposedCalculateDynamicFee(10_000, cum, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint24 rateJustPast = harness.exposedCalculateDynamicFee(12_200, cum, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint24 rateFarPast = harness.exposedCalculateDynamicFee(30_000, cum, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);

        assertEq(rateAtZeroTouch, 5_000, "P == C: c x midpoint C/2 = 5_000");
        assertEq(rateJustPast, 4_494, "crossing: floor(C^2/2P) + floor(2E^2/2P) = 4_098 + 396");
        assertEq(rateFarPast, 14_999, "deep crossing: 1_666 + 13_333");

        assertLt(rateJustPast, rateAtZeroTouch, "the rate DIP past the crossing exists by design");
        assertGt(rateFarPast, rateAtZeroTouch, "and the rate recovers above the rebalance rate");

        // The AMOUNT stays strictly increasing straight through the dip:
        assertLt(uint256(rateAtZeroTouch) * 10_000, uint256(rateJustPast) * 12_200, "amount grows into the dip");
        assertLt(uint256(rateJustPast) * 12_200, uint256(rateFarPast) * 30_000, "amount keeps growing past it");
    }

    /// @notice FEE-11 corollary (documentation): with an INVERTED clamp pair (effMin > maxFee —
    ///         impossible after configurePool's checks) even amount-monotonicity BREAKS: a tiny
    ///         impact returns effMin while a large one returns the smaller maxFee. Pins the exact
    ///         behavior that makes the FEE-2 config guard load-bearing for the economic ordering
    ///         too. (cum == 0, so the raw fee is exactly estPI — clamp-level, formula-agnostic.)
    function test_dynamicFee_invertedClamp_breaksMonotonicity() public view {
        uint24 effMin = 5_000;
        uint24 maxFee = 1_000; // inverted on purpose
        uint24 feeSmallImpact = harness.exposedCalculateDynamicFee(0, 0, true, effMin, maxFee, K_DEFAULT, C_DEFAULT);
        uint24 feeLargeImpact = harness.exposedCalculateDynamicFee(6_000, 0, true, effMin, maxFee, K_DEFAULT, C_DEFAULT);
        assertEq(feeSmallImpact, 5_000, "small impact hits min-first clamp");
        assertEq(feeLargeImpact, 1_000, "large impact hits max clamp");
        assertGt(feeSmallImpact, feeLargeImpact, "documented: fee DECREASES in impact when clamps invert");
    }

    // ------------------------------------------------------------------
    // FEE-12 — zero-cross identity
    // ------------------------------------------------------------------

    /// @notice FEE-12: when a decreasing-direction swap is large enough to cross zero, its
    ///         estimatedPriceImpact still decomposes exactly as |cum consumed| + |new imbalance
    ///         built| — where the new imbalance is computed by the REAL pipeline
    ///         (SafeCast.toInt256Capped -> HookMath.addSaturating). No imbalance is
    ///         double-counted or freely forgiven on the crossing swap. The CHARGED fee is no
    ///         longer estPI, though: the midpoint model prices the two legs separately (down-leg
    ///         c x C/2 weighted C/P, up-leg k x E/2 weighted E/P) — asserted against an
    ///         independent recompute using the implementation's exact nested floors,
    ///         floor(C^2/(2P)) + 2*floor(E^2/(2P)).
    function testFuzz_dynamicFee_zeroCrossIdentity(uint256 estPI, int256 cum, bool negSide) public view {
        cum = bound(cum, 1, 1e6);
        if (negSide) cum = -cum;
        uint256 absCum = cum >= 0 ? uint256(cum) : uint256(-cum);
        estPI = bound(estPI, absCum + 1, 2e6); // strictly larger than |cum| => true zero-cross

        bool zeroForOne = (cum > 0); // direction that pulls cum toward zero

        // Real pipeline for the post-swap estimated cumulative:
        int256 directional = zeroForOne ? -SafeCast.toInt256Capped(estPI) : SafeCast.toInt256Capped(estPI);
        int256 estCum = HookMath.addSaturating(directional, cum);

        // A true crossing: sign flipped.
        assertTrue((cum > 0 && estCum < 0) || (cum < 0 && estCum > 0), "sanity: crossing flips sign");

        uint256 absEstCum = estCum >= 0 ? uint256(estCum) : uint256(-estCum);
        assertEq(estPI, absCum + absEstCum, "estPI == |cum consumed| + |new imbalance|");

        // And the hook charges the two-leg midpoint sum on the crossing, clamps disabled —
        // the same nested floors as the implementation (mulDiv == plain / at these magnitudes).
        uint256 twoP = 2 * estPI;
        uint256 expectedFee = (absCum * absCum) / twoP + (2 * absEstCum * absEstCum) / twoP;
        uint24 fee = harness.exposedCalculateDynamicFee(estPI, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertEq(uint256(fee), expectedFee, "crossing swap is charged the two-leg midpoint sum");
    }

    // ------------------------------------------------------------------
    // FEE-13 — continuity at cum == 0
    // ------------------------------------------------------------------

    /// @notice FEE-13: at cum == 0 both directions land in the increasing branch with
    ///         |estimatedCum| == estimatedPriceImpact, and k x the midpoint of a from-zero leg
    ///         equals the endpoint (2 x P/2 = P) — so both charge exactly clamp(estPI), the same
    ///         fresh-push price as the pre-midpoint model, and the two branches agree at the
    ///         boundary.
    function testFuzz_dynamicFee_zeroCum_bothDirectionsEqualImpact(
        uint256 estPI,
        uint24 effMin,
        uint24 maxFee
    ) public view {
        maxFee = uint24(bound(maxFee, 0, MAX_LP_FEE));
        effMin = uint24(bound(effMin, 0, maxFee));

        uint24 feeZfo = harness.exposedCalculateDynamicFee(estPI, 0, true, effMin, maxFee, K_DEFAULT, C_DEFAULT);
        uint24 feeOfz = harness.exposedCalculateDynamicFee(estPI, 0, false, effMin, maxFee, K_DEFAULT, C_DEFAULT);

        assertEq(feeZfo, feeOfz, "directions agree at cum == 0");
        if (estPI >= effMin && estPI <= maxFee) {
            assertEq(uint256(feeZfo), estPI, "unclamped region charges exactly estPI");
        }
    }

    /// @notice FEE-13 cliff probe: nudging cum to +1 / -1 pip (e.g. decay rounding leaving a
    ///         1-pip residue) moves the fee by a bounded, non-straddleable amount:
    ///         - on the side where the 1-pip cum INCREASES imbalance the fee is 2C + P, so the
    ///           nudge moves it exactly 2 pips (k = 2 doubles it; was 1 pip pre-midpoint);
    ///         - on the opposing side any estPI > 1 pip crosses zero and pays the two-leg form
    ///           ~ P - 2 (P - 3 for odd P — the E^2/(2P) floors), within the spec's <= 3-pip
    ///           crossing-seam tolerance of the cum == 0 fee.
    ///         Either way there is no discontinuity an attacker could straddle.
    function testFuzz_dynamicFee_noCliffAroundZeroCum(uint256 estPI, bool zeroForOne) public view {
        estPI = bound(estPI, 0, 1e6);

        uint256 feeAtZero = harness.exposedCalculateDynamicFee(estPI, 0, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        // zeroForOne pushes cum negative, so cum = -1 is its imbalance-increasing side.
        int256 cumIncSide = zeroForOne ? int256(-1) : int256(1);
        uint256 feeIncSide =
            harness.exposedCalculateDynamicFee(estPI, cumIncSide, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint256 feeOppSide =
            harness.exposedCalculateDynamicFee(estPI, -cumIncSide, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);

        uint256 dInc = feeIncSide > feeAtZero ? feeIncSide - feeAtZero : feeAtZero - feeIncSide;
        uint256 dOpp = feeOppSide > feeAtZero ? feeOppSide - feeAtZero : feeAtZero - feeOppSide;
        assertLe(dInc, 2, "at most 2-pip jump on the increasing side (k = 2 x 1-pip nudge)");
        assertLe(dOpp, 3, "at most 3-pip jump across the zero seam (crossing-branch floors)");
    }
}
