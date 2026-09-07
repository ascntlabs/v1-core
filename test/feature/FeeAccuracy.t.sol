// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @dev Fee-accuracy suite. Reconstructs the expected dynamic fee from the *contract's
///      own* emitted priceImpact + decayedCumPriceImpact via a faithful port of
///      `SimHook.calculateDynamicFee` (weighted-midpoint model: every swap pays weight × the
///      midpoint of the accumulator leg it traverses — k=2e6 on increasing legs, c=1e6 on
///      decreasing legs, and a c-down-leg + k-up-leg sum on a zero-cross), and asserts the
///      charged fee matches EXACTLY in each of the three path scenarios. Also bounds the fee=0
///      simulator over-estimate vs realized impact.
///      Uses a symmetric stable pool (USDC/USDT, 6/6, price≈1) so zeroForOne / oneForZero swaps of
///      equal notional cause comparable impact — size ratios then deterministically pick the branch.
contract FeeAccuracyTest is SimHookUtils {
    using StateLibrary for IPoolManager;

    StablePairPoolConfig internal cfg;

    uint256 internal constant PIPS = 1e6;
    // Canonical launch weights — must match the kPips/cPips this suite's pool config passes
    // to configurePool (per-pool one-time values; StablePairPoolConfig uses the defaults).
    uint256 internal constant K_PIPS = 2e6; // increasing-leg weight
    uint256 internal constant C_PIPS = 1e6; // decreasing-leg weight
    // zeroForOne exact-input, builds negative cum. Sized (~2_000 pips of impact per swap against
    // the seeded liquidity) so every scenario's RAW midpoint quote — up to 2|cum| ~ 8_000 pips on
    // the dust-into path — sits strictly INSIDE the [floor, maxFee = 10_000] clamp: a saturated
    // quote would let any formula >= maxFee pass the exact-recompute asserts (each scenario test
    // pins clamp-freedom explicitly below).
    int256 internal constant BUILD = -5_000e6;

    function setUp() public {
        cfg = new StablePairPoolConfig();
        (, uint160 initialSqrtPriceX96) = setupSimHookAndPool(cfg, false);
        // Moderate, wide liquidity around tick 0 so swaps produce measurable (few-%) impact and the
        // size ratios below cleanly separate the no-cross vs crossing branches.
        addLiquidity(-2000, 2000, 1_000_000e6, initialSqrtPriceX96, false);
    }

    // ------ reference: faithful port of SimHook.calculateDynamicFee ------
    // Weighted-midpoint model: each swap pays weight × the midpoint of the accumulator leg it
    // traverses. scenario ∈ {1:increasing (incl. dust into the imbalance) — k × midpoint =
    // 2|cum| + estPI exactly, 2:decreasing-no-cross (incl. corrective dust) — c × midpoint =
    // floor(|cum| − estPI/2), 3:crossing-zero — c-weighted down-leg + k-weighted up-leg, each
    // scaled by its share of the swap}. In range (priceImpact ≤ PIPS, |cum| small) the
    // contract's SafeCast/addSaturating(Uint) ops reduce to plain checked arithmetic, and the
    // FullMath.mulDiv floors are reproduced verbatim, so this is exact.
    function _refFee(
        uint256 estPI,
        int256 cum,
        bool zeroForOne,
        uint24 effMin
    ) internal view returns (uint24 fee, uint8 scenario) {
        int256 dir = zeroForOne ? -int256(estPI) : int256(estPI);
        int256 estCum = dir + cum;
        uint256 absCum = SignedMath.abs(cum);
        uint256 absEstCum = SignedMath.abs(estCum);
        // keyed off zeroForOne, not dir (dir == 0 for sub-pip dust) — mirrors the contract
        bool increasing = cum == 0 || (zeroForOne == (cum < 0));
        // strict >: swapping exactly to zero stays on the decreasing branch (mirrors the contract)
        bool crossing = !increasing && estPI > absCum;

        uint256 dynImpactFee;
        if (increasing) {
            scenario = 1;
            // k × midpoint of the leg |cum| -> |estCum|
            dynImpactFee = FullMath.mulDiv(absCum + absEstCum, K_PIPS, 2 * PIPS);
        } else if (!crossing) {
            scenario = 2;
            // c × midpoint of the leg |cum| -> |estCum|
            dynImpactFee = FullMath.mulDiv(absCum + absEstCum, C_PIPS, 2 * PIPS);
        } else {
            scenario = 3;
            // down-leg at c × its midpoint + up-leg at k × its midpoint, each weighted by its
            // share of the swap (leg lengths |cum| + |estCum| == estPI)
            uint256 twoP = 2 * estPI;
            dynImpactFee = FullMath.mulDiv(FullMath.mulDiv(absCum, absCum, twoP), C_PIPS, PIPS)
                + FullMath.mulDiv(FullMath.mulDiv(absEstCum, absEstCum, twoP), K_PIPS, PIPS);
        }

        // min-first clamp, mirroring the contract
        if (dynImpactFee < effMin) fee = effMin;
        else if (dynImpactFee > cfg.maxFee()) fee = cfg.maxFee();
        else fee = uint24(dynImpactFee);
    }

    function _swapDecode(
        bool zeroForOne,
        int256 amt
    ) internal returns (BeforeSwapEventData memory b, AfterSwapEventData memory a) {
        (, Vm.Log[] memory logs) = swap(zeroForOne, amt, false);
        b = getBeforeSwapEventData(logs);
        a = getAfterSwapEventData(logs);
    }

    function _assertFeeExact(BeforeSwapEventData memory b, bool zeroForOne) internal view returns (uint8 scenario) {
        uint24 expected;
        (expected, scenario) = _refFee(b.priceImpact, b.decayedCumPriceImpact, zeroForOne, b.effectiveMinFee);
        assertEq(b.dynamicFeePips, expected, "dynamic fee != reference recompute");
    }

    // ------ scenario 1: increasing imbalance (k × leg midpoint = 2|cum| + estPI) ------
    function test_feeExact_increasingImbalance() public {
        swap(true, BUILD, false); // warmup swap (zeroForOne)
        (BeforeSwapEventData memory b,) = _swapDecode(true, BUILD); // same direction → increasing
        assertEq(_assertFeeExact(b, true), 1, "expected increasing-imbalance scenario");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "quote must be unclamped for the recompute to discriminate");
        assertGt(b.dynamicFeePips, b.effectiveMinFee, "quote must sit above the floor");
    }

    // ------ scenario 2: decreasing imbalance, no zero-cross (c × leg midpoint = floor(|cum| − estPI/2)) ------
    function test_feeExact_decreasing_noCross() public {
        swap(true, BUILD, false); // warmup
        swap(true, BUILD, false); // build sizeable negative cum
        // A small opposite swap (1/20 of a build swap): positive dir, |dir| << |cum| → no cross.
        (BeforeSwapEventData memory b,) = _swapDecode(false, -250e6);
        assertEq(_assertFeeExact(b, false), 2, "expected decreasing (no-cross) scenario");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "quote must be unclamped for the recompute to discriminate");
        assertGt(b.dynamicFeePips, b.effectiveMinFee, "quote must sit above the floor");
    }

    // ------ scenario 3: crossing zero (c·|cum|²/2P + k·|estCum|²/2P, the two-leg sum) ------
    function test_feeExact_crossingZero() public {
        swap(true, BUILD, false); // warmup
        swap(true, BUILD, false); // moderate negative cum
        // A large opposite swap (5× a build swap): impact exceeds |cum| → estimatedCum flips → cross.
        (BeforeSwapEventData memory b,) = _swapDecode(false, -25_000e6);
        assertEq(_assertFeeExact(b, false), 3, "expected crossing-zero scenario");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "quote must be unclamped for the recompute to discriminate");
        assertGt(b.dynamicFeePips, b.effectiveMinFee, "quote must sit above the floor");
    }

    // ------ dust swaps (sub-pip simulated impact) read the standing meter ------
    // Both dust directions traverse the zero-length leg |cum| -> |cum|, whose midpoint is |cum|.
    // Dust INTO the imbalance is the size->0 limit of scenario 1: fee =
    // mulDiv(|cum|+|cum|, kPips, 2e6) = 2|cum|, clamped. Corrective dust is the size->0 limit of
    // scenario 2: c × |cum| = |cum| exactly, clamped — the corrective rate is the local meter
    // reading, not the swap's own size, so splitting a rebalance into unmeasurably small trades
    // no longer rides the floor (the dust-splitting hole is closed).
    function test_feeExact_dustIntoImbalance_chargesTwiceAbsCum() public {
        swap(true, BUILD, false); // warmup swap
        swap(true, BUILD, false); // build a standing negative cum
        (BeforeSwapEventData memory b,) = _swapDecode(true, -10); // same direction, 10 base units
        assertEq(b.priceImpact, 0, "dust swap must simulate to zero pips");
        assertGt(SignedMath.abs(b.decayedCumPriceImpact), 0, "standing cum required for the scenario");
        // Reference pins fee == 2|cum| exactly via the increasing branch — UNCLAMPED, so the
        // 2x-the-meter quantity itself is what the assert observes.
        assertEq(_assertFeeExact(b, true), 1, "dust into the imbalance takes the increasing branch");
        assertGt(b.dynamicFeePips, cfg.minMinFee(), "imbalance-direction dust pays 2x the cum meter, not the floor");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "2|cum| must sit inside the clamp for the assert to discriminate");
        assertEq(
            uint256(b.dynamicFeePips),
            2 * SignedMath.abs(b.decayedCumPriceImpact),
            "dust into the imbalance pays exactly twice the meter"
        );
    }

    function test_feeExact_correctiveDust_paysCumMeter() public {
        swap(true, BUILD, false); // warmup swap
        swap(true, BUILD, false); // build a standing negative cum
        (BeforeSwapEventData memory b,) = _swapDecode(false, -10); // OPPOSITE direction dust
        assertEq(b.priceImpact, 0, "dust swap must simulate to zero pips");
        uint256 absCum = SignedMath.abs(b.decayedCumPriceImpact);
        assertGt(absCum, 0, "standing cum required for the scenario");
        assertEq(_assertFeeExact(b, false), 2, "corrective dust takes the decreasing branch");
        // c × midpoint of the zero-length leg |cum| -> |cum| = |cum| exactly, then min-first clamp.
        uint24 expectedMeter =
            absCum < b.effectiveMinFee ? b.effectiveMinFee : (absCum > cfg.maxFee() ? cfg.maxFee() : uint24(absCum));
        assertEq(b.dynamicFeePips, expectedMeter, "corrective dust pays exactly clamp(|cum|)");
        // The standing cum dwarfs minMinFee=10 and sits inside the clamp, so the assert observes
        // the meter itself rather than a saturated bound.
        assertGt(b.dynamicFeePips, b.effectiveMinFee, "corrective dust pays the cum meter, not the floor");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "|cum| must sit inside the clamp for the assert to discriminate");
    }

    // ------ fee application: the charged fee must actually reach the pool's LPs ------
    // Every other fee assertion in this suite reads the BeforeSwap event; this one closes the loop
    // to v4-core state. If the OVERRIDE_FEE_FLAG return were broken (fee never applied), the
    // feeGrowthGlobal delta would be ~0 and this fails. protocolFeeBps is 0 here, so the full
    // dynamic fee is the LP fee. Exact-input zeroForOne accrues fees on currency0.
    function test_feeApplied_feeGrowthGlobalMatchesChargedFee() public {
        swap(true, BUILD, false); // warmup swap
        uint128 liq = manager.getLiquidity(poolId);
        (uint256 g0Before,) = manager.getFeeGrowthGlobals(poolId);

        uint256 amtIn = 40_000e6;
        (BeforeSwapEventData memory b,) = _swapDecode(true, -int256(amtIn));

        (uint256 g0After,) = manager.getFeeGrowthGlobals(poolId);
        uint256 lpFeeAmount = FullMath.mulDiv(g0After - g0Before, liq, FixedPoint128.Q128);
        uint256 expected = FullMath.mulDiv(amtIn, b.dynamicFeePips, PIPS);

        assertGt(lpFeeAmount, 0, "no fee reached the pool (override flag broken?)");
        // Per-step rounding + growth-granularity headroom; a missing/zeroed fee is orders off.
        assertApproxEqRel(lpFeeAmount, expected, 0.01e18, "feeGrowthGlobal delta != charged dynamic fee");
    }

    // ------ scenario math holds for exact-OUTPUT swaps too ------
    function test_feeExact_exactOutput_increasingImbalance() public {
        swap(true, BUILD, false); // warmup swap
        // positive amountSpecified = exact-output, same direction => increasing imbalance
        (BeforeSwapEventData memory b,) = _swapDecode(true, int256(10_000e6));
        assertEq(_assertFeeExact(b, true), 1, "exact-output must hit the same scenario math");
    }

    // ------ time decay: cum halves at half the decay window (linear, through the hook) ------
    function test_partialDecay_halvesCumMidInterval() public {
        swap(true, BUILD, false); // warmup swap
        (, AfterSwapEventData memory a1) = _swapDecode(true, BUILD); // establish cum
        skip(1800); // half of the 1h decay window
        (BeforeSwapEventData memory b,) = _swapDecode(true, -1_000e6);
        assertApproxEqAbs(
            b.decayedCumPriceImpact,
            a1.cumPriceImpact / 2,
            2,
            "mid-interval decay must be linear (cum/2 at t = decay/2)"
        );
    }

    // ------ estimate vs realized: the fee=0 simulator over-estimates exact-input impact ------
    function test_estimateVsRealized_exactInput_overchargeBounded() public {
        swap(true, BUILD, false); // warmup swap
        (BeforeSwapEventData memory b, AfterSwapEventData memory a) = _swapDecode(true, -40_000e6);

        uint256 estimated = b.priceImpact; // fee=0 simulation
        uint256 realized = a.priceImpact; // real post-swap slot0

        assertGe(estimated, realized, "fee=0 estimate must not under-state realized impact");

        // Overshoot bounded: at most ~2x the charged-fee fraction of realized impact (generous
        // headroom over the ~fee/1e6 theoretical bound), plus a small absolute pip floor.
        uint256 overshoot = estimated - realized;
        uint256 relBound = FullMath.mulDiv(realized, 2 * uint256(b.dynamicFeePips), PIPS) + 5;
        assertLe(overshoot, relBound, "estimate over-states realized impact beyond the fee-driven bound");
    }

    // ------ adversarial: the fee=0 estimate must NEVER under-state realized impact (never undercharge) ------
    // Fuzzes direction and size: the simulation runs fee=0 so it always moves at least as far as the
    // real fee-paying swap ⇒ estimated ≥ realized in every case. An under-estimate here would mean the
    // hook charges less than the swap's true impact warrants.
    function testFuzz_estimateNeverUnderchargesRealizedImpact(uint256 amtRaw, bool zeroForOne) public {
        uint256 amt = bound(amtRaw, 500e6, 200_000e6); // non-dust, within the seeded liquidity
        swap(true, -20_000e6, false); // warmup swap
        (BeforeSwapEventData memory b, AfterSwapEventData memory a) = _swapDecode(zeroForOne, -int256(amt));
        assertGe(b.priceImpact, a.priceImpact, "fee=0 estimate under-stated realized impact (would undercharge)");
    }
}

/// @dev Stable config with a NON-degenerate min-fee ramp (all shared PoolConfigs use
///      minMinFee == maxMinFee, leaving the ramp branch untested through a live swap).
contract RampStablePoolConfig is StablePairPoolConfig {
    constructor() {
        maxMinFee = 5_000; // floor ramps 10 -> 5_000 pips over timeDecayLength (1h)
    }
}

/// @dev Integration coverage for the dynamic min-fee ramp: the BeforeSwap event's
///      effectiveMinFee must track the linear ramp mid-interval, and the ramped floor
///      must actually clamp a low-impact fee.
contract FeeRampIntegrationTest is SimHookUtils {
    RampStablePoolConfig internal cfg;

    function setUp() public {
        cfg = new RampStablePoolConfig();
        (, uint160 initialSqrtPriceX96) = setupSimHookAndPool(cfg, false);
        addLiquidity(-2000, 2000, 1_000_000e6, initialSqrtPriceX96, false);
    }

    function _swapDecode(bool zeroForOne, int256 amt) internal returns (BeforeSwapEventData memory b) {
        (, Vm.Log[] memory logs) = swap(zeroForOne, amt, false);
        b = getBeforeSwapEventData(logs);
    }

    function test_effectiveMinFee_rampsMidInterval() public {
        swap(true, -20_000e6, false); // warmup; afterSwap stamps lastSwapTimestamp
        skip(1800); // half the 1h window
        BeforeSwapEventData memory b = _swapDecode(true, -1_000e6);
        // linear ramp: 10 + (5_000 - 10) * 1800 / 3600
        uint24 expected = uint24(10 + (uint256(5_000 - 10) * 1800) / 3600);
        assertApproxEqAbs(b.effectiveMinFee, expected, 1, "mid-interval floor != linear ramp");
        assertGt(b.effectiveMinFee, cfg.minMinFee(), "floor must have ramped up");
        assertLt(b.effectiveMinFee, cfg.maxMinFee(), "floor must not have saturated yet");
    }

    function test_rampedFloor_clampsLowImpactFee_afterFullWindow() public {
        swap(true, -20_000e6, false); // warmup
        skip(3601); // full window: cum fully decayed, floor saturated
        BeforeSwapEventData memory b = _swapDecode(true, -1_000e6);
        assertEq(b.effectiveMinFee, cfg.maxMinFee(), "floor saturates at maxMinFee");
        assertEq(b.decayedCumPriceImpact, 0, "cum fully decayed");
        assertLt(b.priceImpact, cfg.maxMinFee(), "probe swap impact must sit below the floor");
        assertEq(b.dynamicFeePips, cfg.maxMinFee(), "low-impact fee must clamp UP to the ramped floor");
    }
}
