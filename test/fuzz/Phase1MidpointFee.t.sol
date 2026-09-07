// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Phase1FuzzBase} from "./Phase1Helpers.sol";

/// @notice Phase-1 stateless fuzz over the weighted-midpoint fee model in
///         `SimHook.calculateDynamicFee`, via the shared harness's `exposedCalculateDynamicFee`.
///         Every swap pays weight x the MIDPOINT of the accumulator leg it traverses (kPips = 2e6
///         on increasing legs, cPips = 1e6 on decreasing legs; a zero-cross pays the c-weighted
///         down-leg + k-weighted up-leg, each scaled by its share of the swap).
///
/// Covers the MID-* family introduced with the midpoint fee-model change (FEE-9..13 cover the
/// branch-selection/clamp invariants and are maintained separately):
///         MID-1 split-invariance on increasing legs (EXACT — zero slack) + the pinned
///               1/3/5/7/9% staircase anchor blending to the 5.00% lump price;
///         MID-2 split-invariance on decreasing legs within the derived P/2 truncation envelope
///               + the pinned 9_500 / 5_000 rebalance anchors;
///         MID-3 crossing seam: one-shot == revert-to-zero + fresh-push within 3 pips x length
///               + the pinned 3_600 / 4_400 crossing anchors;
///         MID-4 boundary continuity at the P == C and C -> 0 seams (<= 3 pips);
///         MID-5 corrective dust reads the cum meter exactly (and the floor still wins below it);
///         MID-6 round-trip non-negativity — no free cum repositioning;
///         MID-7 the pinned U-curve of a fixed full-gap revert (NOT monotone in C, by design);
///         MID-8 a dominating floor prices every leg of a path flat at effectiveMinFee.
///
/// Modeling: an atomic split is a same-block sequence of legs over the signed cum line — leg i is
/// quoted at (len_i, cum_i, dir_i) and cum_{i+1} = cum_i -/+ len_i (zeroForOne pushes cum
/// NEGATIVE). Same-block => decay is identity and realized == simulated, mirroring the
/// _beforeSwap/_afterSwap wiring in the same-block idealization. Fee AMOUNTS are
/// rate x leg length (pips x pips, in uint256). Clamps are disabled (effMin = 0,
/// maxFee = type(uint24).max) except where the property IS the floor (MID-5/MID-8).
///
/// estimatedPriceImpact is bounded to the production domain [0, PIPS_SCALE]: the crossing branch
/// computes `2 * estimatedPriceImpact` with checked arithmetic, safe only because
/// calculatePriceImpactCapped (the sole producer) caps the input — full-range estPI fuzz is
/// FEE-1's job, not this suite's.
contract Phase1MidpointFeeFuzz is Phase1FuzzBase {
    uint24 internal constant WIDE_MAX = type(uint24).max; // disables the max clamp
    // Canonical launch weights (now per-pool config, set once in configurePool): every MID-*
    // exact form and pinned anchor below is a statement AT these defaults.
    uint32 internal constant K_DEFAULT = 2e6;
    uint32 internal constant C_DEFAULT = 1e6;
    uint256 internal constant MAX_LEGS = 8;

    // ------------------------------------------------------------------
    // shared leg plumbing
    // ------------------------------------------------------------------

    /// @dev zeroForOne pushes cum NEGATIVE (sign convention): on the positive side an
    ///      imbalance-INCREASING leg therefore swaps oneForZero, and mirrored on the negative side.
    function _dirFor(bool posSide, bool increase) internal pure returns (bool zeroForOne) {
        zeroForOne = posSide ? !increase : increase;
    }

    /// @dev Advance the signed cum line by one leg (same-block: realized == simulated).
    function _step(int256 cum, uint256 len, bool zeroForOne) internal pure returns (int256) {
        return zeroForOne ? cum - int256(len) : cum + int256(len);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // ------------------------------------------------------------------
    // MID-1 — impact-space additivity, increasing legs (EXACT)
    // ------------------------------------------------------------------

    /// @notice SCOPE. This family operates on ACCUMULATOR LEGS measured in impact pips: the
    ///         "amounts" below are traversal lengths, not token notional. What it proves is that
    ///         the midpoint RATE is additive over a partition of one traversal. It does NOT prove
    ///         that a split order pays the same fee TOTAL — the total is rate x notional, impact
    ///         is proportional to notional only on uniform in-range liquidity, and fee-bearing
    ///         execution makes the split take a different price path in any case. See
    ///         `docs/known-issues.md` KI-15, `docs/invariants.md` #3, and the amount-space
    ///         characterization in `test/feature/SplitAdditivity.t.sol`.
    ///
    /// @notice MID-1: an n-way atomic split of a monotone imbalance-increasing push traverses
    ///         EXACTLY the one-shot rate-weighted length. kPips/(2*PIPS_SCALE) = 1, so the increasing branch never
    ///         truncates: rate_i = c_i + c_{i+1} and the amounts telescope,
    ///         sum (c_i + c_{i+1})(c_{i+1} - c_i) = c_n^2 - c_0^2 = (c_0 + c_n)(c_n - c_0)
    ///         = one-shot rate x total length. The tight floor-slack bound is ZERO.
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: dev.fuzz.runs = 1000
    function testFuzz_midpointFee_impactSpaceAdditivity_increasing(
        uint256[8] memory lenSeeds,
        uint256 nSeed,
        uint256 c0Seed,
        bool posSide
    ) public view {
        uint256 n = bound(nSeed, 1, MAX_LEGS);
        uint256 c0 = bound(c0Seed, 0, PIPS_SCALE);
        int256 cumStart = posSide ? int256(c0) : -int256(c0);
        bool zeroForOne = _dirFor(posSide, true);

        int256 cum = cumStart;
        uint256 total;
        uint256 splitAmount;
        for (uint256 i = 0; i < n; i++) {
            // per-leg cap keeps the summed one-shot inside the production estPI domain [0, 1e6]
            uint256 len = bound(lenSeeds[i], 0, PIPS_SCALE / MAX_LEGS);
            uint24 rate = harness.exposedCalculateDynamicFee(len, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
            splitAmount += uint256(rate) * len;
            cum = _step(cum, len, zeroForOne);
            total += len;
        }

        uint24 oneRate =
            harness.exposedCalculateDynamicFee(total, cumStart, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertEq(splitAmount, uint256(oneRate) * total, "increasing split must equal the lump EXACTLY");
    }

    /// @notice MID-1 pinned anchor: 0 -> 5% pushed as five same-block 1% tranches prices the
    ///         1/3/5/7/9% staircase, whose amount-weighted blend is 50_000 pips — exactly the
    ///         5.00% one-shot price (the old model staircased 1/2/3/4/5% blending only 3%).
    function test_midpointFee_staircaseAnchor_reproducesExactly() public view {
        uint256[5] memory expectedRates = [uint256(10_000), 30_000, 50_000, 70_000, 90_000];
        int256 cum = 0;
        uint256 stairAmount;
        for (uint256 i = 0; i < 5; i++) {
            uint24 rate = harness.exposedCalculateDynamicFee(10_000, cum, true, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
            assertEq(uint256(rate), expectedRates[i], "tranche rate off the 1/3/5/7/9% staircase");
            stairAmount += uint256(rate) * 10_000;
            cum -= 10_000; // zeroForOne pushes cum negative
        }

        uint24 lumpRate = harness.exposedCalculateDynamicFee(50_000, 0, true, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertEq(uint256(lumpRate), 50_000, "lump 0 -> 5% prices at exactly 5.00%");
        assertEq(stairAmount, uint256(lumpRate) * 50_000, "staircase amount == lump amount, exactly");
        assertEq(stairAmount / 50_000, 50_000, "amount-weighted staircase blend = 50_000 pips");
    }

    // ------------------------------------------------------------------
    // MID-2 — split-invariance, decreasing legs (no cross)
    // ------------------------------------------------------------------

    /// @notice MID-2 (same impact-space scope as MID-1 above): an n-way atomic split of a
    ///         monotone imbalance-decreasing pull (never crossing zero) traverses the one-shot
    ///         rate-weighted length within the derived truncation envelope.
    ///         Each leg's rate floor((c_i + c_{i+1})/2) truncates at most 1/2 pip, so the split
    ///         under-shoots the real midpoint value (c_0^2 - c_n^2)/2 by at most
    ///         sum(len_i)/2 = P/2 — and the one-shot floor((c_0 + c_n)/2) x P under-shoots the
    ///         same value by at most P/2. Both integers therefore sit within floor(P/2) of each
    ///         other: the tight bound.
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: dev.fuzz.runs = 1000
    function testFuzz_midpointFee_impactSpaceAdditivity_decreasing(
        uint256[8] memory lenSeeds,
        uint256 nSeed,
        uint256 c0Seed,
        bool posSide
    ) public view {
        uint256 n = bound(nSeed, 1, MAX_LEGS);
        uint256 c0 = bound(c0Seed, 1, PIPS_SCALE);
        int256 cumStart = posSide ? int256(c0) : -int256(c0);
        bool zeroForOne = _dirFor(posSide, false);

        int256 cum = cumStart;
        uint256 remaining = c0; // total pull <= c0 => no leg ever crosses zero
        uint256 splitAmount;
        for (uint256 i = 0; i < n; i++) {
            uint256 len = bound(lenSeeds[i], 0, remaining);
            uint24 rate = harness.exposedCalculateDynamicFee(len, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
            splitAmount += uint256(rate) * len;
            cum = _step(cum, len, zeroForOne);
            remaining -= len;
        }
        uint256 pulled = c0 - remaining;

        uint24 oneRate =
            harness.exposedCalculateDynamicFee(pulled, cumStart, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint256 oneAmount = uint256(oneRate) * pulled;

        assertLe(
            _absDiff(splitAmount, oneAmount),
            pulled / 2,
            "decreasing split must match the one-shot within the P/2 truncation envelope"
        );
    }

    /// @notice MID-2 pinned anchors: rebalance cum=1% -> 0.9% pays 9_500 (0.95% = c x midpoint
    ///         of the 10_000 -> 9_000 leg; old model: 1_000); full one-shot rebalance
    ///         cum=1% -> 0 pays 5_000 (0.50% = c x midpoint of the 10_000 -> 0 leg; old: 10_000).
    function test_midpointFee_rebalanceAnchors() public view {
        assertEq(
            uint256(harness.exposedCalculateDynamicFee(1_000, -10_000, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT)),
            9_500,
            "cum=1% -> 0.9% rebalance must price at 9_500"
        );
        assertEq(
            uint256(harness.exposedCalculateDynamicFee(10_000, -10_000, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT)),
            5_000,
            "full one-shot rebalance of cum=1% must price at 5_000"
        );
    }

    // ------------------------------------------------------------------
    // MID-3 — crossing seam: one-shot == revert-to-zero + fresh-push
    // ------------------------------------------------------------------

    /// @notice MID-3: a one-shot crossing swap (P > C, remainder E = P - C) pays the same AMOUNT
    ///         as the same move executed as two swaps — revert exactly to zero (decreasing, P==C)
    ///         then a fresh push of E from cum == 0. Both sides under-approximate the same real
    ///         value C^2/2 + E^2: the one-shot's three mulDiv floors lose < 3 pips of rate
    ///         (x P of amount) and the two-swap side loses <= C/2 of amount, so the amounts agree
    ///         within 3 x P.
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: dev.fuzz.runs = 1000
    function testFuzz_midpointFee_crossingSeam_decomposes(uint256 cSeed, uint256 pSeed, bool posSide) public view {
        uint256 c = bound(cSeed, 1, PIPS_SCALE - 1);
        uint256 p = bound(pSeed, c + 1, PIPS_SCALE); // strictly larger than |cum| => true crossing
        uint256 e = p - c;
        int256 cum = posSide ? int256(c) : -int256(c);
        bool zeroForOne = _dirFor(posSide, false);

        uint24 oneRate = harness.exposedCalculateDynamicFee(p, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint256 oneAmount = uint256(oneRate) * p;

        // Two swaps along the identical path, same block, same direction throughout.
        uint24 downRate = harness.exposedCalculateDynamicFee(c, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint24 upRate = harness.exposedCalculateDynamicFee(e, 0, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint256 twoAmount = uint256(downRate) * c + uint256(upRate) * e;

        assertLe(
            _absDiff(oneAmount, twoAmount),
            3 * p,
            "crossing seam must decompose into revert-to-zero + fresh-push within 3 pips x length"
        );
    }

    /// @notice MID-3 pinned anchors: cum=0.8% reverted by 1% prices at 3_600
    ///         (8000^2/20000 + 2 x 2000^2/20000 = 3200 + 400) and cum=0.4% reverted by 1% at
    ///         4_400 (800 + 3600) — on both sides of the cum line.
    function test_midpointFee_crossingAnchors() public view {
        assertEq(
            uint256(harness.exposedCalculateDynamicFee(10_000, -8_000, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT)),
            3_600,
            "cum=-0.8% revert 1% must price at 3_600"
        );
        assertEq(
            uint256(harness.exposedCalculateDynamicFee(10_000, -4_000, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT)),
            4_400,
            "cum=-0.4% revert 1% must price at 4_400"
        );
        // positive-side mirror of both anchors
        assertEq(
            uint256(harness.exposedCalculateDynamicFee(10_000, 8_000, true, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT)),
            3_600,
            "cum=+0.8% revert 1% must price at 3_600"
        );
        assertEq(
            uint256(harness.exposedCalculateDynamicFee(10_000, 4_000, true, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT)),
            4_400,
            "cum=+0.4% revert 1% must price at 4_400"
        );
    }

    /// @notice The crossing branch divides once per leg, not twice. Nesting the divisions
    ///         (dividing by 2P first, then applying the weight) discarded a remainder the weight
    ///         then amplified by up to 20x. The worst case found by a full domain sweep was
    ///         absCum=50, absEstCum=51, P=101 at the 20x weight ceiling: 480 shipped against an
    ///         exact 505.05, a 25-pip undercharge, versus under 1 pip in the sibling branches.
    ///         That asymmetry let a splitter beat the one-shot fee (invariants #3).
    function test_midpointFee_crossingBranch_dividesOncePerLeg() public view {
        uint32 kMax = uint32(20 * PIPS_SCALE);
        uint32 cMax = uint32(20 * PIPS_SCALE);

        // cum = -50, P = 101 crossing to estCum = +51.
        uint24 fee = harness.exposedCalculateDynamicFee(101, -50, false, 0, WIDE_MAX, kMax, cMax);

        // Exact value is 20*(50^2 + 51^2)/(2*101) = 102020/202 = 505.049...
        // One floor per leg leaves at most 2 pips of truncation; the nested form gave 480.
        assertGe(uint256(fee), 503, "crossing branch must not truncate more than one pip per leg");
        assertLe(uint256(fee), 505, "crossing branch must never overcharge past the exact value");
    }

    /// @notice Splitting a crossing swap at the crossing point must not beat the one-shot fee by
    ///         more than the sibling branches' own truncation. This is the property the nested
    ///         division violated: the split legs truncate under a pip each, so a ~25-pip gap on
    ///         the one-shot side was pure advantage to the splitter.
    function testFuzz_midpointFee_crossingSplitHasNoAdvantage(uint256 cSeed, uint256 pSeed) public view {
        uint32 kMax = uint32(20 * PIPS_SCALE);
        uint32 cMax = uint32(20 * PIPS_SCALE);

        uint256 c = bound(cSeed, 1, 10_000);
        uint256 p = bound(pSeed, c + 1, 20_000); // strictly crossing
        uint256 e = p - c;

        // One shot: cross from -c all the way to +e.
        uint256 oneShot = uint256(harness.exposedCalculateDynamicFee(p, -int256(c), false, 0, WIDE_MAX, kMax, cMax)) * p;

        // Split at the crossing point: revert-to-zero, then fresh push.
        uint256 legA = uint256(harness.exposedCalculateDynamicFee(c, -int256(c), false, 0, WIDE_MAX, kMax, cMax)) * c;
        uint256 legB = uint256(harness.exposedCalculateDynamicFee(e, 0, false, 0, WIDE_MAX, kMax, cMax)) * e;

        // Splitting may save at most the per-leg truncation of both forms (a few pips x length),
        // never a ~20x-amplified remainder from a nested division.
        uint256 tolerance = 3 * p;
        if (legA + legB < oneShot) {
            assertLe(
                oneShot - (legA + legB),
                tolerance,
                "splitting a crossing swap must not beat the one-shot fee beyond truncation"
            );
        }
    }

    // ------------------------------------------------------------------
    // MID-4 — boundary continuity at the branch seams
    // ------------------------------------------------------------------

    /// @notice MID-4a: swapping EXACTLY to zero (P == C) stays on the decreasing branch (strict
    ///         `>` in crossingZero) and prices at floor(C/2) — the crossing formula's E -> 0
    ///         limit. The smallest true crossing (P = C + 1) sits within 3 pips of it: no seam
    ///         an attacker could straddle.
    function testFuzz_midpointFee_toZeroBoundary_continuous(uint256 cSeed, bool posSide) public view {
        uint256 c = bound(cSeed, 1, PIPS_SCALE - 1);
        int256 cum = posSide ? int256(c) : -int256(c);
        bool zeroForOne = _dirFor(posSide, false);

        uint24 feeToZero = harness.exposedCalculateDynamicFee(c, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertEq(uint256(feeToZero), c / 2, "exact-to-zero must price at floor(C/2)");

        uint24 feeJustPast =
            harness.exposedCalculateDynamicFee(c + 1, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertLe(_absDiff(feeToZero, feeJustPast), 3, "the P == C seam must be continuous within 3 pips");
    }

    /// @notice MID-4b: a crossing from a vanishing meter (C = 1 pip) prices within 3 pips of the
    ///         fresh push (C = 0) of the same size — the crossing formula approaches the
    ///         increasing branch as C -> 0 (fee ~ P - 2 vs P, mulDiv floors).
    function testFuzz_midpointFee_vanishingCum_continuous(uint256 pSeed, bool posSide) public view {
        uint256 p = bound(pSeed, 2, PIPS_SCALE); // p > C = 1 => true crossing
        int256 cum = posSide ? int256(1) : int256(-1);
        bool zeroForOne = _dirFor(posSide, false);

        uint24 feeCross = harness.exposedCalculateDynamicFee(p, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint24 feeFresh = harness.exposedCalculateDynamicFee(p, 0, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertLe(
            _absDiff(feeCross, feeFresh), 3, "crossing with C -> 0 must approach the fresh-push price within 3 pips"
        );
    }

    // ------------------------------------------------------------------
    // MID-5 — corrective dust reads the cum meter
    // ------------------------------------------------------------------

    /// @notice MID-5: a zero-impact (estPI = 0) swap AGAINST a standing imbalance traverses the
    ///         zero-length leg |cum| -> |cum| on the decreasing branch: c x its midpoint = |cum|
    ///         EXACTLY (clamps disabled). The corrective rate is the local meter reading, not the
    ///         swap's own size — this is the fix for the decreasing dust-splitting hole.
    function testFuzz_midpointFee_correctiveDust_readsMeterExactly(uint256 cSeed, bool posSide) public view {
        uint256 c = bound(cSeed, 1, PIPS_SCALE);
        int256 cum = posSide ? int256(c) : -int256(c);
        bool zeroForOne = _dirFor(posSide, false);

        uint24 fee = harness.exposedCalculateDynamicFee(0, cum, zeroForOne, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertEq(uint256(fee), c, "corrective dust must pay the standing cum meter exactly");
    }

    /// @notice MID-5 floor half: with the min clamp enabled the dust quote is
    ///         max(|cum|, effectiveMinFee) — the floor still wins below the meter, and the meter
    ///         wins above it (min-first clamp, maxFee wide open).
    function testFuzz_midpointFee_correctiveDust_floorStillWins(
        uint256 cSeed,
        uint256 effMinSeed,
        bool posSide
    ) public view {
        uint256 c = bound(cSeed, 1, PIPS_SCALE);
        uint24 effMin = uint24(bound(effMinSeed, 0, WIDE_MAX));
        int256 cum = posSide ? int256(c) : -int256(c);
        bool zeroForOne = _dirFor(posSide, false);

        uint24 fee = harness.exposedCalculateDynamicFee(0, cum, zeroForOne, effMin, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint256 expected = uint256(effMin) > c ? effMin : c;
        assertEq(uint256(fee), expected, "dust quote must be max(|cum|, effectiveMinFee)");
    }

    // ------------------------------------------------------------------
    // MID-6 — round-trip non-negativity (no free cum repositioning)
    // ------------------------------------------------------------------

    /// @notice MID-6: pushing P from a flat meter and fully reverting it in m same-block legs
    ///         always nets positive total fees. The push alone pays P x P; the revert legs can
    ///         only ADD (fees are unsigned), and their real midpoint value is P^2/2 with at most
    ///         P/2 of total truncation — so the revert path itself pays >= (P^2 - P)/2.
    function testFuzz_midpointFee_roundTripNeverFree(
        uint256 pSeed,
        uint256[8] memory legSeeds,
        uint256 mSeed,
        bool posSide
    ) public view {
        uint256 p = bound(pSeed, 1, PIPS_SCALE);
        uint256 m = bound(mSeed, 1, MAX_LEGS);

        bool pushDir = _dirFor(posSide, true);
        uint24 pushRate = harness.exposedCalculateDynamicFee(p, 0, pushDir, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        assertEq(uint256(pushRate), p, "fresh push must price at its own endpoint (k x P/2)");
        uint256 pushAmount = uint256(pushRate) * p;

        int256 cum = posSide ? int256(p) : -int256(p);
        bool revDir = _dirFor(posSide, false);
        uint256 remaining = p;
        uint256 revertAmount;
        for (uint256 i = 0; i < m; i++) {
            uint256 len = (i == m - 1) ? remaining : bound(legSeeds[i], 0, remaining);
            uint24 fee = harness.exposedCalculateDynamicFee(len, cum, revDir, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
            revertAmount += uint256(fee) * len;
            cum = _step(cum, len, revDir);
            remaining -= len;
        }
        assertEq(cum, 0, "sanity: the m legs fully revert the push");

        assertGe(revertAmount, (p * p - p) / 2, "revert path must pay >= its midpoint value minus truncation");
        uint256 total = pushAmount + revertAmount;
        assertGt(total, 0, "a same-block round trip always nets positive fees");
        assertGe(total, p * p, "revert legs only ADD to the one-shot push amount");
    }

    // ------------------------------------------------------------------
    // MID-7 — U-curve of the fixed full-gap revert (pinned)
    // ------------------------------------------------------------------

    /// @notice MID-7 pinned anchor: for a fixed 1% revert (P = 10_000) the fee
    ///         fee(C) = floor(C^2/2P) + 2 x floor((P-C)^2/2P) is NOT monotone in the standing
    ///         meter C — it reads 5_000 at C = P (the to-zero seam), dips to ~3_332 at the
    ///         C = 6_667 probe near C ~= 2P/3 (the exact integer minimum is 3_331, attained
    ///         nearby, e.g. at C = 6_666), and climbs back to the fresh-push price 10_000 at C = 0.
    function test_midpointFee_uCurveAnchor_fullGapRevert() public view {
        uint24 atFullGap = harness.exposedCalculateDynamicFee(10_000, -10_000, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint24 atThird = harness.exposedCalculateDynamicFee(10_000, -6_667, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);
        uint24 atZero = harness.exposedCalculateDynamicFee(10_000, 0, false, 0, WIDE_MAX, K_DEFAULT, C_DEFAULT);

        assertEq(uint256(atFullGap), 5_000, "C = P must price at half the meter");
        assertApproxEqAbs(
            uint256(atThird), 3_332, 2, "C ~= 2P/3 must sit at ~the U-curve minimum (exact integer min is 3_331 nearby)"
        );
        assertEq(uint256(atZero), 10_000, "C = 0 must price at the fresh-push rate");

        // down from C = P toward the minimum, then back up to the fresh-push price
        assertLt(atThird, atFullGap, "fee must fall moving C from P toward 2P/3");
        assertLt(atFullGap, atZero, "and rise again toward C = 0 - down-then-up, not monotone");
    }

    // ------------------------------------------------------------------
    // MID-8 — a dominating floor prices every leg flat
    // ------------------------------------------------------------------

    /// @notice MID-8: when effectiveMinFee sits at or above every raw midpoint quote a path can
    ///         produce, every leg pays exactly effectiveMinFee — the min-first clamp flattens the
    ///         whole walk. Quote bound for an n-leg walk with per-leg length <= maxLen and
    ///         |cum| <= sum(len): increasing <= 2 x sum(len) + maxLen, decreasing <= |cum|,
    ///         crossing < |cum|/2 + maxLen — all below 2 x sum(len) + maxLen.
    function testFuzz_midpointFee_floorDominates_flatPath(
        uint256[8] memory lenSeeds,
        uint256 dirMask,
        uint256 nSeed,
        uint256 effMinSeed
    ) public view {
        uint256 n = bound(nSeed, 1, MAX_LEGS);

        // Fix the leg lengths first so the dominating floor can be derived before any leg runs.
        uint256[] memory lens = new uint256[](n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            lens[i] = bound(lenSeeds[i], 0, 40_000);
            total += lens[i];
        }
        // 2 x total + maxLen + 1 <= 680_001 <= MAX_LP_FEE, so the bound below is always valid.
        uint24 effMin = uint24(bound(effMinSeed, 2 * total + 40_000 + 1, PIPS_SCALE));

        int256 cum = 0;
        for (uint256 i = 0; i < n; i++) {
            bool zeroForOne = ((dirMask >> i) & 1) == 1;
            uint24 fee =
                harness.exposedCalculateDynamicFee(lens[i], cum, zeroForOne, effMin, WIDE_MAX, K_DEFAULT, C_DEFAULT);
            assertEq(fee, effMin, "under a dominating floor every leg must price flat at effectiveMinFee");
            cum = _step(cum, lens[i], zeroForOne);
        }
    }
}
