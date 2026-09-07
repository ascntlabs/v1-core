// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {HookMath} from "../../src/lib/HookMath.sol";

/// @title HookMathTest
/// @notice Direct unit tests for `HookMath.calculateEffectiveMinFee` — the linear ramp
/// from minMinFee (active pool) to maxMinFee (dormant pool), keyed off the elapsed
/// inter-swap time over `timeDecayLength`.
contract HookMathEffectiveMinFeeTest is Test {
    /// @dev External dispatch wrapper — library pure functions inline, so reverts (none here)
    /// or fuzz failures need a real CALL frame for cleaner debug output.
    function exposedCalculate(
        uint24 minMinFee,
        uint24 maxMinFee,
        uint256 timeSinceLastSwap,
        uint256 timeDecayLength
    ) external pure returns (uint24) {
        return HookMath.calculateEffectiveMinFee(minMinFee, maxMinFee, timeSinceLastSwap, timeDecayLength);
    }

    // ------ boundary conditions ------

    function test_returnsMin_atTimeZero() public pure {
        assertEq(HookMath.calculateEffectiveMinFee(100, 5_000, 0, 3600), 100);
    }

    function test_returnsMax_atTimeDecayLength() public pure {
        // t == timeDecayLength: the `>=` branch fires.
        assertEq(HookMath.calculateEffectiveMinFee(100, 5_000, 3600, 3600), 5_000);
    }

    function test_returnsMax_beyondTimeDecayLength() public pure {
        // t >> timeDecayLength: saturates at maxMinFee.
        assertEq(HookMath.calculateEffectiveMinFee(100, 5_000, 36_000, 3600), 5_000);
    }

    // ------ ramp at canonical points ------

    function test_linearAtMidpoint() public pure {
        // t = decay / 2 → effective = (min + max) / 2 within rounding tolerance.
        uint24 result = HookMath.calculateEffectiveMinFee(100, 5_000, 1800, 3600);
        assertApproxEqAbs(uint256(result), 2_550, 1);
    }

    function test_linearAtQuartilePoints() public pure {
        // t = decay / 4 → effective = min + (max - min) / 4
        uint24 q1 = HookMath.calculateEffectiveMinFee(100, 5_000, 900, 3600);
        assertApproxEqAbs(uint256(q1), 100 + (4_900 / 4), 1);

        // t = 3 * decay / 4 → effective = min + 3 * (max - min) / 4
        uint24 q3 = HookMath.calculateEffectiveMinFee(100, 5_000, 2700, 3600);
        assertApproxEqAbs(uint256(q3), 100 + (3 * 4_900 / 4), 1);
    }

    // ------ degenerate cases ------

    function test_returnsFlat_whenMinEqMax() public pure {
        // minMinFee == maxMinFee → returns that value regardless of t.
        // Includes the (0, 0) degenerate case (folded in from the old _whenBothZero test).
        assertEq(HookMath.calculateEffectiveMinFee(500, 500, 0, 3600), 500);
        assertEq(HookMath.calculateEffectiveMinFee(500, 500, 1000, 3600), 500);
        assertEq(HookMath.calculateEffectiveMinFee(500, 500, 3600, 3600), 500);
        assertEq(HookMath.calculateEffectiveMinFee(500, 500, 100_000, 3600), 500);
        assertEq(HookMath.calculateEffectiveMinFee(0, 0, 0, 3600), 0);
        assertEq(HookMath.calculateEffectiveMinFee(0, 0, 1000, 3600), 0);
        assertEq(HookMath.calculateEffectiveMinFee(0, 0, type(uint256).max, 3600), 0);
    }

    function test_returnsMin_whenSpreadIsOne_smallT() public pure {
        // Smallest non-degenerate spread (max - min == 1). At low t the ramp rounds down to min.
        assertEq(HookMath.calculateEffectiveMinFee(100, 101, 100, 3600), 100);
    }

    function test_returnsMax_whenSpreadIsOne_atBoundary() public pure {
        assertEq(HookMath.calculateEffectiveMinFee(100, 101, 3600, 3600), 101);
    }

    // ------ extreme parameter ranges ------

    function test_handlesMaxSpread() public pure {
        // min = 0, max = type(uint24).max — exercise the largest possible ramp range.
        uint24 result = HookMath.calculateEffectiveMinFee(0, type(uint24).max, 1800, 3600);
        // Midpoint of (0, 16_777_215) ≈ 8_388_607
        assertApproxEqAbs(uint256(result), 8_388_607, 1);
    }

    function test_handlesLargeTimeDecayLength() public pure {
        // Stress FullMath.mulDiv path with a large decayLength.
        uint256 decay = 30 days; // 2_592_000 seconds
        uint24 result = HookMath.calculateEffectiveMinFee(100, 5_000, decay / 2, decay);
        assertApproxEqAbs(uint256(result), 2_550, 1);
    }

    // ------ property fuzz ------

    /// @dev Monotonicity + bounds: result is always in [minMinFee, maxMinFee], and increases
    /// (non-strictly) with t. Note: we only exercise the non-degenerate case where minMinFee
    /// <= maxMinFee — the helper's contract assumes this invariant holds (validated in
    /// `_writePoolConfig`). The flat-floor degenerate path (min == max) is covered above.
    function testFuzz_resultInBounds(
        uint24 minMinFee,
        uint24 maxMinFee,
        uint256 timeSinceLastSwap,
        uint256 timeDecayLength
    ) public pure {
        vm.assume(minMinFee <= maxMinFee);
        vm.assume(timeDecayLength > 0);

        uint24 result = HookMath.calculateEffectiveMinFee(minMinFee, maxMinFee, timeSinceLastSwap, timeDecayLength);
        assertGe(result, minMinFee, "result below minMinFee");
        assertLe(result, maxMinFee, "result above maxMinFee");
    }

    function testFuzz_monotonicInTime(
        uint24 minMinFee,
        uint24 maxMinFee,
        uint256 t1,
        uint256 t2,
        uint256 timeDecayLength
    ) public pure {
        vm.assume(minMinFee <= maxMinFee);
        vm.assume(timeDecayLength > 0);
        vm.assume(t1 <= t2);
        // FullMath.mulDiv is 512-bit internally, so spread * t is safe for any uint256.
        // No bound on t2 needed.

        uint24 r1 = HookMath.calculateEffectiveMinFee(minMinFee, maxMinFee, t1, timeDecayLength);
        uint24 r2 = HookMath.calculateEffectiveMinFee(minMinFee, maxMinFee, t2, timeDecayLength);
        assertGe(r2, r1, "result not monotonic in time");
    }

    // ------ invariant-violation behaviour ------

    /// @dev The helper documents `minMinFee <= maxMinFee` as an upstream-validated invariant.
    /// If a future change accidentally calls the helper with min > max, the `spread = max - min`
    /// subtraction underflows and reverts (Solidity ^0.8 safe math). This test pins that
    /// behaviour so any refactor that hides the violation gets flagged.
    function test_revertsOnInvariantViolation_minGreaterThanMax() public {
        // External-call wrapper so vm.expectRevert sees the revert frame.
        vm.expectRevert();
        this.exposedCalculate(1000, 100, 500, 3600);
    }
}

/// @notice Direct unit tests for `HookMath.calculatePriceImpactCapped` — the pips conversion
/// every fee in the system flows through. Impact is measured on price (sqrtPrice squared),
/// relative to the GEOMETRIC MEAN of the two prices, capped at 100% (PIPS_SCALE).
contract HookMathPriceImpactTest is Test {
    uint256 constant PIPS = 1e6;
    uint160 constant Q96 = uint160(FixedPoint96.Q96); // sqrtPrice for price == 1

    function test_zeroBefore_returnsZero() public pure {
        assertEq(HookMath.calculatePriceImpactCapped(0, Q96), 0);
    }

    function test_zeroAfter_returnsZero() public pure {
        assertEq(HookMath.calculatePriceImpactCapped(Q96, 0), 0);
    }

    function test_noMove_returnsZero() public pure {
        assertEq(HookMath.calculatePriceImpactCapped(Q96, Q96), 0);
    }

    /// @dev STATUS QUO PIN: below sqrtPrice 2^48 (tick < ~-665k) the Q96 squaring truncates the
    /// price to 0 and the cap check (0 >= 0) reports 100% impact even for a ZERO move — such a
    /// pool would charge maxFee on every swap. Curated launches never sit there; pinned so any
    /// change to this behavior is a conscious decision (and must sync both Python ports).
    function test_lowPriceDomain_degeneratesToFullImpact() public pure {
        assertEq(HookMath.calculatePriceImpactCapped(TickMath.MIN_SQRT_PRICE, TickMath.MIN_SQRT_PRICE), PIPS);
    }

    function test_knownValue_upMove() public pure {
        // sqrtPrice x1.005 => price x1.010025; |r-1|/sqrt(r) = 0.010025/1.005 => 9_975 pips.
        uint160 after_ = uint160(uint256(Q96) * 1005 / 1000);
        assertApproxEqAbs(HookMath.calculatePriceImpactCapped(Q96, after_), 9_975, 2);
    }

    function test_knownValue_downMove() public pure {
        // sqrtPrice x0.995 => price x0.990025; |r-1|/sqrt(r) = 0.009975/0.995 => 10_025 pips.
        uint160 after_ = uint160(uint256(Q96) * 995 / 1000);
        assertApproxEqAbs(HookMath.calculatePriceImpactCapped(Q96, after_), 10_025, 2);
    }

    /// @dev A move and its exact reverse read the same magnitude — the geometric-mean
    /// denominator makes the reading direction-symmetric, bit-exact.
    function test_directionSymmetric_exactReverse() public pure {
        uint160 after_ = uint160(uint256(Q96) * 1005 / 1000);
        assertEq(HookMath.calculatePriceImpactCapped(Q96, after_), HookMath.calculatePriceImpactCapped(after_, Q96));
    }

    function test_capsAt100Percent_upMove() public pure {
        // sqrtPrice x2 => price x4 => 300% raw change vs a 200% geo mean, capped at PIPS_SCALE.
        assertEq(HookMath.calculatePriceImpactCapped(Q96, 2 * Q96), PIPS);
    }

    function test_capsAt100Percent_downMove() public pure {
        // sqrtPrice x0.5 => price x0.25 => 75% raw change vs a 50% geo mean, capped — the cap
        // now engages on down moves too (symmetric in log terms, r <= ~0.382).
        assertEq(HookMath.calculatePriceImpactCapped(Q96, Q96 / 2), PIPS);
    }

    function test_justBelowCap_notCapped() public pure {
        // Cap boundary: change >= geo mean iff sqrt(r) >= (1+sqrt(5))/2 ~ 1.618. At sqrtPrice
        // x1.617: r = 2.614689, |r-1|/sqrt(r) = 1.614689/1.617 => 998_570 pips, below the cap.
        uint160 after_ = uint160(uint256(Q96) * 1617 / 1000);
        uint256 impact = HookMath.calculatePriceImpactCapped(Q96, after_);
        assertLt(impact, PIPS);
        assertApproxEqAbs(impact, 998_570, 2);
    }

    function test_justAboveCapBoundary_capped() public pure {
        // sqrtPrice x1.619 clears the golden-ratio boundary: r = 2.621161, change 1.621161 >=
        // geo mean 1.619 => capped exactly at PIPS_SCALE.
        uint160 after_ = uint160(uint256(Q96) * 1619 / 1000);
        assertEq(HookMath.calculatePriceImpactCapped(Q96, after_), PIPS);
    }

    /// @dev Never reverts and never exceeds PIPS_SCALE anywhere in the valid sqrtPrice domain
    /// (the Q96-divided squaring must not overflow at MAX_SQRT_PRICE).
    function testFuzz_neverRevertsAndBounded(uint160 before_, uint160 after_) public pure {
        before_ = uint160(bound(before_, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        after_ = uint160(bound(after_, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint256 impact = HookMath.calculatePriceImpactCapped(before_, after_);
        assertLe(impact, PIPS, "impact must never exceed 100%");
    }

    /// @dev Larger moves in the same direction never report smaller impact, up to 1 pip of
    /// slack: change and geo mean are floored independently, so two adjacent readings can
    /// disagree by one unit. Domain starts at MIN_USABLE_SQRT_PRICE (2^58) — below it the
    /// X96 price granularity is coarser than a pip and the geo-mean denominator makes the
    /// reading legitimately non-monotone.
    function testFuzz_monotonicInMoveSize(uint160 before_, uint160 a1, uint160 a2) public pure {
        before_ = uint160(bound(before_, uint160(1) << 58, TickMath.MAX_SQRT_PRICE));
        a1 = uint160(bound(a1, before_, TickMath.MAX_SQRT_PRICE));
        a2 = uint160(bound(a2, a1, TickMath.MAX_SQRT_PRICE));
        assertGe(
            HookMath.calculatePriceImpactCapped(before_, a2) + 1,
            HookMath.calculatePriceImpactCapped(before_, a1),
            "impact not monotonic in move size"
        );
    }
}
