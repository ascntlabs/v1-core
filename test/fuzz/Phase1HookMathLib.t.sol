// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {HookMath} from "../../src/lib/HookMath.sol";
import {SafeCast} from "../../src/lib/SafeCast.sol";

/// @notice External thin wrapper so `vm.expectRevert` can target the internal library functions
///         and so every fuzz call exercises them through a real CALL boundary.
contract Phase1LibCaller {
    function priceImpact(uint160 before_, uint160 after_) external pure returns (uint256) {
        return HookMath.calculatePriceImpactCapped(before_, after_);
    }

    function addSat(int256 a, int256 b) external pure returns (int256) {
        return HookMath.addSaturating(a, b);
    }

    function addSatUint(uint256 a, uint256 b) external pure returns (uint256) {
        return HookMath.addSaturatingUint(a, b);
    }

    function decay(int256 cum, uint256 t, uint256 len) external pure returns (int256) {
        return HookMath.decayCumByTime(cum, t, len);
    }

    function effMinFee(uint24 minMin, uint24 maxMin, uint256 t, uint256 len) external pure returns (uint24) {
        return HookMath.calculateEffectiveMinFee(minMin, maxMin, t, len);
    }

    function toInt256Capped(uint256 v) external pure returns (int256) {
        return SafeCast.toInt256Capped(v);
    }

    function toUint24Capped(uint256 v) external pure returns (uint24) {
        return SafeCast.toUint24Capped(v);
    }

    function toUint128Capped(uint256 v) external pure returns (uint128) {
        return SafeCast.toUint128Capped(v);
    }
}

/// @notice Phase-1 stateless fuzz over `src/lib/HookMath.sol` and `src/lib/SafeCast.sol`.
///
/// Covers: FEE-4 (calculatePriceImpactCapped in [0,1e6], cap semantics, no revert), FEE-7
///         (addSaturating never wraps, floor at int256.min+1; companion addSaturatingUint —
///         reintroduced for the midpoint fee legs — never wraps, cap at uint256.max), FEE-6
///         (decayCumByTime shrinks toward zero, sign-safe, exact-zero horizon, t=0 identity), FEE-3
///         (calculateEffectiveMinFee ramp range/endpoints/monotonicity + the minMin>maxMin
///         underflow-guard dependency), FEE-16 (SafeCast capped casts: saturating, monotone,
///         identity below cap), FEE-5 (decay + impact sites round DOWN, never amplify).
///
/// Rounding direction notes:
/// - calculatePriceImpactCapped floors (mulDiv): reported impact <= true impact — under-charges
///   by < 1 pip rather than over-charging.
/// - decayCumByTime floors the decayed MAGNITUDE: |result| <= true proportional remainder — decay
///   can only pull the accumulator toward zero faster, never leave extra imbalance behind.
/// - calculateEffectiveMinFee floors the ramp delta: effMin <= true linear value — the fee floor
///   rises no faster than the ideal ramp, so it can never overshoot maxMinFee.
contract Phase1HookMathLibFuzz is Test {
    uint256 internal constant PIPS = 1e6;
    int256 internal constant INT_MIN = type(int256).min;
    int256 internal constant INT_MAX = type(int256).max;
    uint256 internal constant UINT_MAX = type(uint256).max;
    uint160 internal constant SQRT_2POW48 = uint160(1) << 48; // below this, priceX96Before floors to 0

    Phase1LibCaller internal lib;

    function setUp() public {
        lib = new Phase1LibCaller();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        // Exact for the whole int256 domain incl. INT_MIN.
        return x >= 0 ? uint256(x) : uint256(~x) + 1;
    }

    // ==================================================================
    // FEE-4 — calculatePriceImpactCapped
    // ==================================================================

    /// @notice FEE-4: for EVERY pair of uint160 sqrt prices the result is in [0, 1e6] and the
    ///         call never reverts (no div-by-zero, no overflow — FullMath 512-bit intermediates).
    function testFuzz_priceImpact_alwaysBounded_neverReverts(uint160 sqrtBefore, uint160 sqrtAfter) public view {
        uint256 impact = lib.priceImpact(sqrtBefore, sqrtAfter);
        assertLe(impact, PIPS, "impact capped at 100%");
    }

    /// @notice FEE-4: sqrtBefore == 0 short-circuits to 0 for any after-price.
    function testFuzz_priceImpact_zeroBefore_returnsZero(uint160 sqrtAfter) public view {
        assertEq(lib.priceImpact(0, sqrtAfter), 0, "before == 0 => 0");
    }

    /// @notice FEE-4: sqrtAfter == 0 short-circuits to 0 for any before-price.
    function testFuzz_priceImpact_zeroAfter_returnsZero(uint160 sqrtBefore) public view {
        assertEq(lib.priceImpact(sqrtBefore, 0), 0, "after == 0 => 0");
    }

    /// @notice FEE-4: direction symmetry — the geometric-mean denominator makes a move and its
    ///         exact reverse read the SAME magnitude, bit-exact (both change and the geo mean are
    ///         symmetric in their arguments).
    function testFuzz_priceImpact_directionSymmetric(uint160 a, uint160 b) public view {
        assertEq(lib.priceImpact(a, b), lib.priceImpact(b, a), "impact must be direction-symmetric");
    }

    /// @notice FEE-4: for sqrtBefore in [1, 2^48) the squared before-price floors to 0, so the
    ///         change equals the whole after-price and the `priceChangeX96 >= priceX96Geo` guard
    ///         fires (a² >= ab whenever a >= b; both floor to 0 when a < b < 2^48) — the function
    ///         pins to exactly PIPS_SCALE, including sqrtAfter == sqrtBefore. This is the real
    ///         division-by-zero protection (NOT the sqrt==0 checks), and it holds even though a
    ///         100% reading for an unchanged price is economically conservative. Production keeps
    ///         pools above MIN_USABLE_SQRT_PRICE = 2^58 at init, but swaps can in principle
    ///         travel below it.
    function testFuzz_priceImpact_subUsablePrice_pinsToFullImpact(uint160 sqrtBefore, uint160 sqrtAfter) public view {
        sqrtBefore = uint160(bound(sqrtBefore, 1, uint256(SQRT_2POW48) - 1));
        sqrtAfter = uint160(bound(sqrtAfter, 1, type(uint160).max)); // 0 short-circuits to 0 instead
        assertEq(lib.priceImpact(sqrtBefore, sqrtAfter), PIPS, "before < 2^48 => pinned at 100%");
    }

    /// @notice FEE-4: identity — unchanged price in the usable range reports exactly 0 impact.
    function testFuzz_priceImpact_identityIsZero(uint160 sqrtP) public view {
        sqrtP = uint160(bound(sqrtP, SQRT_2POW48, type(uint160).max));
        assertEq(lib.priceImpact(sqrtP, sqrtP), 0, "no price change => 0 impact");
    }

    /// @notice FEE-4: the >= branch returns EXACTLY PIPS_SCALE — e.g. a doubled sqrt price
    ///         (price x4, change = 3x base vs a geo mean of 2x base) always lands on the cap,
    ///         never above it.
    function testFuzz_priceImpact_capBranchExact(uint160 sqrtBefore) public view {
        sqrtBefore = uint160(bound(sqrtBefore, SQRT_2POW48, (uint256(type(uint160).max)) / 2));
        uint160 sqrtAfter = sqrtBefore * 2;
        assertEq(lib.priceImpact(sqrtBefore, sqrtAfter), PIPS, "price 4x => capped at exactly 100%");
    }

    /// @notice FEE-5 (impact site): in a bounded domain where the oracle fits native uint256
    ///         math, the result equals the exact FLOOR of change*1e6/geoMean — the site never
    ///         rounds up, so a swap is never charged more than its true proportional impact.
    function testFuzz_priceImpact_isExactFloor(uint160 sqrtBefore, uint160 sqrtAfter) public view {
        // 2^48 <= sqrt <= 2^112 => priceX96 <= 2^128, change*1e6 fits uint256 comfortably.
        sqrtBefore = uint160(bound(sqrtBefore, SQRT_2POW48, uint256(1) << 112));
        sqrtAfter = uint160(bound(sqrtAfter, SQRT_2POW48, uint256(1) << 112));

        uint256 pb = (uint256(sqrtBefore) * uint256(sqrtBefore)) >> 96;
        uint256 pa = (uint256(sqrtAfter) * uint256(sqrtAfter)) >> 96;
        uint256 geo = (uint256(sqrtBefore) * uint256(sqrtAfter)) >> 96;
        uint256 change = pa >= pb ? pa - pb : pb - pa;

        uint256 expected = change >= geo ? PIPS : (change * PIPS) / geo; // independent floor oracle
        assertEq(lib.priceImpact(sqrtBefore, sqrtAfter), expected, "impact == floor(change*1e6/geo)");
    }

    // ==================================================================
    // FEE-7 — addSaturating
    // ==================================================================

    /// @notice FEE-7: for EVERY int256 pair the result is in [int256.min+1, int256.max] — the
    ///         function never returns int256.min and never reverts, so every downstream
    ///         SignedMath.abs / unary negation is exact.
    function testFuzz_addSat_neverReturnsIntMin(int256 a, int256 b) public view {
        int256 c = lib.addSat(a, b);
        assertGe(c, INT_MIN + 1, "result >= int256.min + 1 always");
    }

    /// @notice FEE-7: mixed-sign operands can never overflow — result equals the exact sum,
    ///         except the single point a+b == int256.min which is floored to min+1.
    function testFuzz_addSat_mixedSigns_exact(int256 a, int256 b) public view {
        if (b == INT_MIN) b = INT_MIN + 1; // keep the sign-flip below well-defined
        if ((a > 0 && b > 0) || (a < 0 && b < 0)) b = -b; // force mixed (or zero) signs
        int256 sum = a + b; // checked; cannot overflow for mixed signs
        int256 expected = sum == INT_MIN ? INT_MIN + 1 : sum;
        assertEq(lib.addSat(a, b), expected, "mixed signs: exact sum (min floored to min+1)");
    }

    /// @notice FEE-7: both-positive without overflow — exact; with overflow — pinned to max.
    function testFuzz_addSat_bothPositive(int256 a, int256 b) public view {
        a = bound(a, 1, INT_MAX);
        // exact region
        int256 bExact = bound(b, 0, INT_MAX - a);
        assertEq(lib.addSat(a, bExact), a + bExact, "no-overflow region is exact");
        // overflow region (non-empty for every a >= 1)
        int256 bOver = bound(b, INT_MAX - a + 1, INT_MAX);
        assertEq(lib.addSat(a, bOver), INT_MAX, "positive overflow pins to int256.max");
    }

    /// @notice FEE-7: both-negative without overflow — exact; with overflow — pinned to min+1
    ///         (NOT min: the abs-safe floor).
    function testFuzz_addSat_bothNegative(int256 a, int256 b) public view {
        a = bound(a, INT_MIN + 1, -1);
        // exact region: a+b >= min+1
        int256 bExact = bound(b, INT_MIN + 1 - a, 0);
        assertEq(lib.addSat(a, bExact), a + bExact, "no-overflow region is exact");
        // overflow region: a+b <= min
        int256 bOver = bound(b, INT_MIN, INT_MIN - a);
        assertEq(lib.addSat(a, bOver), INT_MIN + 1, "negative overflow pins to int256.min + 1");
    }

    /// @notice FEE-7 exact endpoints from the invariant harness note, plus the int256.min INPUT
    ///         edge (production cum never equals min thanks to this very floor, but the function
    ///         must still normalize it).
    function test_addSat_endpoints() public view {
        assertEq(lib.addSat(INT_MAX, 1), INT_MAX, "(max, 1) saturates high");
        assertEq(lib.addSat(1, INT_MAX), INT_MAX, "(1, max) saturates high");
        assertEq(lib.addSat(INT_MIN + 1, -1), INT_MIN + 1, "(min+1, -1) saturates low at min+1");
        assertEq(lib.addSat(INT_MIN, INT_MIN), INT_MIN + 1, "(min, min) wraps in unchecked, caught, floored");
        assertEq(lib.addSat(INT_MIN, 0), INT_MIN + 1, "(min, 0): even the exact sum min is normalized to min+1");
        assertEq(lib.addSat(INT_MIN, INT_MAX), -1, "(min, max) exact");
        assertEq(lib.addSat(INT_MAX, INT_MAX), INT_MAX, "(max, max) saturates high");
        assertEq(lib.addSat(0, 0), 0, "(0, 0) exact");
    }

    // ==================================================================
    // FEE-7 companion — addSaturatingUint
    // (uint256 sibling, reintroduced as the midpoint-fee leg adder: it keeps the
    //  |cum| -> |estCum| leg sums from reverting when the accumulator is saturated)
    // ==================================================================

    /// @notice FEE-7 companion: whenever the true sum fits uint256, addSaturatingUint is the
    ///         exact sum — no wrap, no early saturation.
    function testFuzz_addSatUint_noOverflow_exact(uint256 a, uint256 b) public view {
        b = bound(b, 0, UINT_MAX - a);
        assertEq(lib.addSatUint(a, b), a + b, "no-overflow region is exact");
    }

    /// @notice FEE-7 companion: when the true sum exceeds uint256, the result pins to
    ///         uint256.max — never wraps, never reverts (the checked `a + b` would revert;
    ///         the guard fires first).
    function testFuzz_addSatUint_overflow_pinsToMax(uint256 a, uint256 b) public view {
        a = bound(a, 1, UINT_MAX); // a == 0 has an empty overflow region
        b = bound(b, UINT_MAX - a + 1, UINT_MAX);
        assertEq(lib.addSatUint(a, b), UINT_MAX, "overflow pins to uint256.max");
    }

    /// @notice FEE-7 companion: commutative across the full domain — argument order cannot
    ///         change where saturation lands.
    function testFuzz_addSatUint_commutative(uint256 a, uint256 b) public view {
        assertEq(lib.addSatUint(a, b), lib.addSatUint(b, a), "addSaturatingUint commutes");
    }

    /// @notice FEE-7 companion exact endpoints,
    ///         incl. the (max, 0) boundary where the guard `a > max - b` is a strict compare —
    ///         an exact landing ON uint256.max is a sum, not a saturation.
    function test_addSatUint_endpoints() public view {
        assertEq(lib.addSatUint(UINT_MAX, 1), UINT_MAX, "(max, 1) saturates at uint256.max");
        assertEq(lib.addSatUint(1, UINT_MAX), UINT_MAX, "(1, max) saturates at uint256.max");
        assertEq(lib.addSatUint(UINT_MAX, UINT_MAX), UINT_MAX, "(max, max) saturates at uint256.max");
        assertEq(lib.addSatUint(UINT_MAX, 0), UINT_MAX, "(max, 0) exact - boundary, not saturation");
        assertEq(lib.addSatUint(UINT_MAX - 1, 1), UINT_MAX, "(max-1, 1) exact landing on max");
        assertEq(lib.addSatUint(100, 200), 300, "small operands exact");
        assertEq(lib.addSatUint(0, 0), 0, "(0, 0) exact");
    }

    // ==================================================================
    // FEE-6 — decayCumByTime
    // ==================================================================

    /// @notice FEE-6: over the production-reachable domain cum in [int256.min+1, int256.max]
    ///         (the addSaturating floor, FEE-7) and ANY (t, L): |result| <= |cum|, the sign is
    ///         preserved or the result is 0, and the zero-cases (cum==0, L==0, t>=L) return
    ///         exactly 0. Decay can only shrink toward zero — never amplify, never flip sign.
    function testFuzz_decay_shrinksTowardZero(int256 cum, uint256 t, uint256 len) public view {
        cum = bound(cum, INT_MIN + 1, INT_MAX);
        int256 r = lib.decay(cum, t, len);

        assertLe(_abs(r), _abs(cum), "|result| <= |cum| - never amplifies");
        assertTrue(r == 0 || (r < 0) == (cum < 0), "sign preserved or zero");
        if (cum == 0 || len == 0 || t >= len) {
            assertEq(r, 0, "zero-cases return exactly 0");
        }
    }

    /// @notice FEE-6: t == 0 identity on the reachable domain — no decay means the accumulator
    ///         passes through bit-exact.
    function testFuzz_decay_identityAtTZero(int256 cum, uint256 len) public view {
        cum = bound(cum, INT_MIN + 1, INT_MAX);
        vm.assume(len > 0);
        assertEq(lib.decay(cum, 0, len), cum, "t == 0 => identity");
    }

    /// @notice FEE-6: |result| is monotonically non-increasing in t — more elapsed time never
    ///         leaves MORE imbalance behind.
    function testFuzz_decay_monotoneInTime(int256 cum, uint256 t1, uint256 t2, uint256 len) public view {
        cum = bound(cum, INT_MIN + 1, INT_MAX);
        if (t1 > t2) (t1, t2) = (t2, t1);
        uint256 rEarly = _abs(lib.decay(cum, t1, len));
        uint256 rLate = _abs(lib.decay(cum, t2, len));
        assertGe(rEarly, rLate, "|decayed| non-increasing in elapsed time");
    }

    /// @notice FEE-6 horizon boundary: at t == L the result is EXACTLY 0 (the mechanism that
    ///         recovers a saturated accumulator); at t == L-1 it is still sign-consistent and
    ///         bounded by |cum|.
    function testFuzz_decay_horizonBoundary(int256 cum, uint256 len) public view {
        cum = bound(cum, INT_MIN + 1, INT_MAX);
        len = bound(len, 1, type(uint48).max); // PoolConfig stores timeDecayLength as uint48
        assertEq(lib.decay(cum, len, len), 0, "t == L => exactly 0");
        int256 rJustBefore = lib.decay(cum, len - 1, len);
        assertLe(_abs(rJustBefore), _abs(cum), "t == L-1 still bounded");
        assertTrue(rJustBefore == 0 || (rJustBefore < 0) == (cum < 0), "t == L-1 sign-safe");
    }

    /// @notice FEE-6 out-of-domain edge (documentation): cum == int256.min (unreachable — FEE-7's
    ///         floor) does NOT round-trip at t == 0: abs(min) = 2^255 exceeds int256.max, the
    ///         toInt256Capped cap fires, and the result is min+1. Harmless (1-ulp shrink toward
    ///         zero, sign kept) but pins why the addSaturating floor at min+1 matters.
    function test_decay_intMinInput_normalizedNotIdentity() public view {
        assertEq(lib.decay(INT_MIN, 0, 100), INT_MIN + 1, "min input decays to min+1 at t=0 (cap)");
    }

    /// @notice FEE-5 (decay site): bounded-domain exactness — the decayed magnitude equals the
    ///         two-step floor floor(|cum| * floor(timeLeft*1e6/L) / 1e6), which never exceeds the
    ///         true proportional remainder floor(|cum|*timeLeft/L). Round-down only: decay never
    ///         leaves MORE imbalance than the ideal linear decay would.
    function testFuzz_decay_isExactFloor(int256 cum, uint256 t, uint256 len) public view {
        cum = bound(cum, -int256(uint256(1) << 128), int256(uint256(1) << 128));
        vm.assume(cum != 0);
        len = bound(len, 1, uint256(1) << 100);
        t = bound(t, 0, len - 1);

        uint256 absCum = _abs(cum);
        uint256 timeLeft = len - t;
        uint256 expectedAbs = (absCum * ((timeLeft * PIPS) / len)) / PIPS; // independent oracle

        int256 r = lib.decay(cum, t, len);
        assertEq(_abs(r), expectedAbs, "decayed magnitude == two-step floor");
        assertLe(expectedAbs, (absCum * timeLeft) / len, "two-step floor <= true proportional floor");
    }

    // ==================================================================
    // FEE-3 — calculateEffectiveMinFee
    // ==================================================================

    /// @notice FEE-3: for every admissible pair (minMin <= maxMin) and any (t, L): the ramp stays
    ///         inside [minMinFee, maxMinFee], equals minMinFee at t == 0, and equals maxMinFee
    ///         for t >= L. Consequently (with configurePool's maxMinFee <= maxFee) the fee floor
    ///         can never exceed the fee cap.
    function testFuzz_effMinFee_rangeAndEndpoints(uint24 minMin, uint24 maxMin, uint256 t, uint256 len) public view {
        maxMin = uint24(bound(maxMin, 0, type(uint24).max));
        minMin = uint24(bound(minMin, 0, maxMin));

        uint24 fee = lib.effMinFee(minMin, maxMin, t, len);
        assertGe(fee, minMin, "ramp >= minMinFee");
        assertLe(fee, maxMin, "ramp <= maxMinFee");

        assertEq(lib.effMinFee(minMin, maxMin, 0, len), minMin, "t == 0 => minMinFee");
        // Note the t==0 carve-out: the impl checks t==0 BEFORE t>=L, so at (t=0, L=0) it
        // returns minMinFee, not maxMinFee — still inside [minMin, maxMin], no violation.
        if (t > 0 && t >= len) {
            assertEq(fee, maxMin, "t >= L (t > 0) => maxMinFee");
        }
    }

    /// @notice FEE-3: monotone non-decreasing in timeSinceLastSwap — the floor only ratchets up
    ///         as the pool sits idle, never down.
    function testFuzz_effMinFee_monotoneInTime(
        uint24 minMin,
        uint24 maxMin,
        uint256 t1,
        uint256 t2,
        uint256 len
    ) public view {
        maxMin = uint24(bound(maxMin, 0, type(uint24).max));
        minMin = uint24(bound(minMin, 0, maxMin));
        if (t1 > t2) (t1, t2) = (t2, t1);
        assertLe(lib.effMinFee(minMin, maxMin, t1, len), lib.effMinFee(minMin, maxMin, t2, len), "ramp monotone in t");
    }

    /// @notice FEE-5 (ramp site): the ramp delta is the exact floor of spread*t/L — the floor
    ///         rises no faster than the ideal linear ramp (round-down), which is what guarantees
    ///         it cannot overshoot maxMinFee mid-ramp.
    function testFuzz_effMinFee_isExactFloor(uint24 minMin, uint24 maxMin, uint256 t, uint256 len) public view {
        maxMin = uint24(bound(maxMin, 1, type(uint24).max));
        minMin = uint24(bound(minMin, 0, maxMin - 1)); // strict spread so the ramp is live
        len = bound(len, 2, uint256(1) << 100);
        t = bound(t, 1, len - 1);

        uint256 spread = uint256(maxMin) - uint256(minMin);
        uint256 expected = uint256(minMin) + (spread * t) / len; // fits: spread < 2^24, t/len < 1
        assertEq(uint256(lib.effMinFee(minMin, maxMin, t, len)), expected, "ramp == minMin + floor(spread*t/L)");
    }

    /// @notice FEE-3 guard-dependency documentation: called with minMinFee > maxMinFee (blocked
    ///         in production ONLY by configurePool's MinFeeBounds check) the library does NOT
    ///         wrap to a huge value — the checked uint24 subtraction at the spread line PANICS
    ///         for 0 < t < L. (The invariants catalog says "underflows to a huge value"; actual
    ///         solc-0.8 behavior is an arithmetic panic — same conclusion, the config guard is
    ///         load-bearing, but the failure mode is a revert-DoS, not a silent huge floor.)
    function testFuzz_effMinFee_invertedBounds_panics(uint24 minMin, uint24 maxMin, uint256 t, uint256 len) public {
        minMin = uint24(bound(minMin, 1, type(uint24).max));
        maxMin = uint24(bound(maxMin, 0, minMin - 1)); // inverted: minMin > maxMin
        len = bound(len, 2, type(uint256).max);
        t = bound(t, 1, len - 1); // the only region reaching the subtraction

        vm.expectRevert(stdError.arithmeticError);
        lib.effMinFee(minMin, maxMin, t, len);
    }

    /// @notice FEE-3 guard-dependency, silent half: with inverted bounds and t >= L the function
    ///         returns maxMinFee — SILENTLY below minMinFee (an inverted floor, no revert).
    ///         Both halves show correctness rests entirely on configurePool's MinFeeBounds.
    function test_effMinFee_invertedBounds_silentInversionAtHorizon() public view {
        uint24 fee = lib.effMinFee(5_000, 100, 10, 10); // minMin > maxMin, t == L
        assertEq(fee, 100, "t >= L returns maxMinFee even when < minMinFee");
    }

    // ==================================================================
    // FEE-16 — SafeCast capped casts
    // ==================================================================

    /// @notice FEE-16: toInt256Capped == min(value, int256.max); identity below the cap,
    ///         saturating at it, never reverting.
    function testFuzz_toInt256Capped(uint256 v) public view {
        int256 r = lib.toInt256Capped(v);
        if (v <= uint256(INT_MAX)) {
            assertEq(r, int256(v), "identity below cap");
        } else {
            assertEq(r, INT_MAX, "saturates at int256.max");
        }
    }

    /// @notice FEE-16: toUint24Capped == min(value, uint24.max).
    function testFuzz_toUint24Capped(uint256 v) public view {
        uint24 r = lib.toUint24Capped(v);
        if (v <= type(uint24).max) {
            assertEq(uint256(r), v, "identity below cap");
        } else {
            assertEq(r, type(uint24).max, "saturates at uint24.max");
        }
    }

    /// @notice FEE-16: toUint128Capped == min(value, uint128.max).
    function testFuzz_toUint128Capped(uint256 v) public view {
        uint128 r = lib.toUint128Capped(v);
        if (v <= type(uint128).max) {
            assertEq(uint256(r), v, "identity below cap");
        } else {
            assertEq(r, type(uint128).max, "saturates at uint128.max");
        }
    }

    /// @notice FEE-16: all three casts are monotone non-decreasing — saturation can flatten but
    ///         never invert an ordering (no adversary-favoring truncation).
    function testFuzz_cappedCasts_monotone(uint256 v1, uint256 v2) public view {
        if (v1 > v2) (v1, v2) = (v2, v1);
        assertLe(lib.toInt256Capped(v1), lib.toInt256Capped(v2), "toInt256Capped monotone");
        assertLe(lib.toUint24Capped(v1), lib.toUint24Capped(v2), "toUint24Capped monotone");
        assertLe(lib.toUint128Capped(v1), lib.toUint128Capped(v2), "toUint128Capped monotone");
    }

    /// @notice FEE-16: exact boundary pins one unit below / at / above each cap.
    function test_cappedCasts_boundaries() public view {
        assertEq(lib.toInt256Capped(uint256(INT_MAX) - 1), INT_MAX - 1);
        assertEq(lib.toInt256Capped(uint256(INT_MAX)), INT_MAX);
        assertEq(lib.toInt256Capped(uint256(INT_MAX) + 1), INT_MAX);
        assertEq(lib.toInt256Capped(type(uint256).max), INT_MAX);

        assertEq(lib.toUint24Capped(uint256(type(uint24).max) - 1), type(uint24).max - 1);
        assertEq(lib.toUint24Capped(uint256(type(uint24).max)), type(uint24).max);
        assertEq(lib.toUint24Capped(uint256(type(uint24).max) + 1), type(uint24).max);

        assertEq(lib.toUint128Capped(uint256(type(uint128).max) - 1), type(uint128).max - 1);
        assertEq(lib.toUint128Capped(uint256(type(uint128).max)), type(uint128).max);
        assertEq(lib.toUint128Capped(uint256(type(uint128).max) + 1), type(uint128).max);
    }
}
