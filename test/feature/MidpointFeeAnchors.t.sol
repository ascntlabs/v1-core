// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @dev Integration anchors for the weighted-midpoint fee model, through REAL swaps on the stable
///      pool (same setUp as FeeAccuracy: USDC/USDT 6/6, price ~1, liquidity across +-2000 ticks).
///      The FORMULA-level split/seam invariance is EXACT and lives in
///      test/fuzz/Phase1MidpointFee.t.sol (MID-1..8); this suite proves the same economics survive
///      the full pipeline end-to-end — fee=0 simulator, AMM fee-retention feedback, accumulator
///      wiring, event plumbing. Every scenario is SAME-BLOCK (decay is identity at dt = 0), so
///      there is no vm.warp/vm.roll anywhere; state resets use vm.snapshotState/revertToState
///      only (block-env cheats combined with snapshots are a known optimized-profile hazard).
contract MidpointFeeAnchorsTest is SimHookUtils {
    StablePairPoolConfig internal cfg;

    uint256 internal constant PIPS = 1e6;
    // Canonical launch weights — must match the kPips/cPips this suite's pool config passes
    // to configurePool (per-pool one-time values; StablePairPoolConfig uses the defaults).
    uint256 internal constant K_PIPS = 2e6; // increasing-leg weight
    uint256 internal constant C_PIPS = 1e6; // decreasing-leg weight
    /// @dev ~0.4% simulated impact against the seeded liquidity: deep enough to dwarf the 10-pip
    ///      floor, small enough that no tranche of a 5-way split (last-leg rate ~2|cum| + estPI)
    ///      ever reaches the pool's 10_000-pip cap — the anchors stay clamp-free.
    uint256 internal constant PUSH_IN = 10_000e6;

    function setUp() public {
        cfg = new StablePairPoolConfig();
        (, uint160 initialSqrtPriceX96) = setupSimHookAndPool(cfg, false);
        // Moderate, wide liquidity around tick 0 so swaps produce measurable (sub-%) impact and the
        // size ratios below cleanly separate the branches (mirrors FeeAccuracy).
        addLiquidity(-2000, 2000, 1_000_000e6, initialSqrtPriceX96, false);
    }

    // ------ reference: faithful port of SimHook.calculateDynamicFee (midpoint model) ------
    // Mirrors FeeAccuracy._refFee. scenario in {1:increasing — k x leg midpoint, 2:decreasing
    // no-cross — c x leg midpoint, 3:crossing — c-weighted down-leg + k-weighted up-leg}. In
    // range (priceImpact <= PIPS, |cum| small) the contract's SafeCast/addSaturating(Uint) ops
    // reduce to plain checked arithmetic and the FullMath.mulDiv floors are reproduced verbatim,
    // so this recompute is exact.
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
            dynImpactFee = FullMath.mulDiv(absCum + absEstCum, K_PIPS, 2 * PIPS);
        } else if (!crossing) {
            scenario = 2;
            dynImpactFee = FullMath.mulDiv(absCum + absEstCum, C_PIPS, 2 * PIPS);
        } else {
            scenario = 3;
            uint256 twoP = 2 * estPI;
            dynImpactFee = FullMath.mulDiv(FullMath.mulDiv(absCum, absCum, twoP), C_PIPS, PIPS)
                + FullMath.mulDiv(FullMath.mulDiv(absEstCum, absEstCum, twoP), K_PIPS, PIPS);
        }

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

    // ------ anchor 1: same-block split blend ~= one-shot rate (split-invariance, end-to-end) ------
    // The formula makes midpoint amounts additive, so an atomic split of a push must blend to the
    // one-shot price. Through real swaps the equality picks up small drift: each executed leg
    // retains its fee in the pool (so the realized cum meter lags the fee=0 simulated endpoints),
    // the fee=0 simulator itself overshoots realized impact, and token-amount weights differ
    // slightly from impact-length weights as the price moves. Each effect is sub-1%, hence the 2%
    // relative band — the old model's staircase (3% blend vs 5% lump, a ~40% gap) sits far outside.

    /// @dev Sum of fee_i x amtIn_i over an n-way same-block split, with per-leg clamp-freedom
    ///      checks so the comparison exercises the midpoint formula and not the floor/cap.
    function _splitFeeAmount(
        uint256 n,
        uint256 amtIn
    ) internal returns (uint256 feeAmount, uint24 firstRate, uint24 lastRate) {
        uint256 legIn = amtIn / n;
        for (uint256 i = 0; i < n; i++) {
            (BeforeSwapEventData memory b,) = _swapDecode(true, -int256(legIn));
            if (i == 0) {
                assertLe(SignedMath.abs(b.decayedCumPriceImpact), 1, "dust warmup must leave the meter ~zero");
                firstRate = b.dynamicFeePips;
            }
            assertGt(b.dynamicFeePips, b.effectiveMinFee, "split leg must price above the floor");
            assertLt(b.dynamicFeePips, cfg.maxFee(), "split leg must price below the cap");
            feeAmount += uint256(b.dynamicFeePips) * legIn;
            lastRate = b.dynamicFeePips;
        }
    }

    function _assertSplitBlendMatchesOneShot(uint256 n) internal {
        // Dust warmup: leaves the cum meter at ~0 (a 10-base-unit swap simulates AND realizes
        // to zero pips), so both runs start from a flat meter.
        swap(true, -10, false);
        uint256 snap = vm.snapshotState();

        (uint256 splitAmount, uint24 firstRate, uint24 lastRate) = _splitFeeAmount(n, PUSH_IN);
        assertGt(lastRate, firstRate, "same-block tranches must climb the midpoint staircase");

        vm.revertToState(snap);
        (BeforeSwapEventData memory b,) = _swapDecode(true, -int256(PUSH_IN));
        assertLe(SignedMath.abs(b.decayedCumPriceImpact), 1, "one-shot must start from the same ~zero meter");
        assertGt(b.dynamicFeePips, b.effectiveMinFee, "one-shot must price above the floor");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "one-shot must price below the cap");
        uint256 oneAmount = uint256(b.dynamicFeePips) * PUSH_IN;

        assertApproxEqRel(splitAmount, oneAmount, 0.02e18, "split blend must price like the one-shot");
    }

    function test_splitBlend_2way_matchesOneShotRate() public {
        _assertSplitBlendMatchesOneShot(2);
    }

    function test_splitBlend_5way_matchesOneShotRate() public {
        _assertSplitBlendMatchesOneShot(5);
    }

    // ------ anchor 2: corrective dust pays ~the cum meter (dust-splitting hole closed) ------
    // A 10-base-unit corrective swap simulates to zero pips, so it traverses the zero-length leg
    // |cum| -> |cum|: c x its midpoint = |decayedCum| exactly — the local meter reading, not the
    // swap's own size, and nowhere near the floor.
    function test_correctiveDust_chargesTheMeter_notTheFloor() public {
        swap(true, -10, false); // dust warmup, meter ~0
        swap(true, -int256(PUSH_IN), false); // build |cum| ~0.4%, safely below the cap
        (BeforeSwapEventData memory b,) = _swapDecode(false, -10); // OPPOSITE-direction dust
        assertEq(b.priceImpact, 0, "dust swap must simulate to zero pips");

        uint256 absCum = SignedMath.abs(b.decayedCumPriceImpact);
        assertGt(absCum, 0, "standing cum required for the scenario");
        assertLt(absCum, cfg.maxFee(), "meter must sit below the cap for a non-degenerate read");

        // Exact recompute through the midpoint formula from the event's own values.
        (uint24 expected, uint8 scenario) = _refFee(0, b.decayedCumPriceImpact, false, b.effectiveMinFee);
        assertEq(scenario, 2, "corrective dust takes the decreasing branch");
        assertEq(b.dynamicFeePips, expected, "corrective dust != midpoint recompute");
        assertEq(uint256(b.dynamicFeePips), absCum, "corrective dust pays exactly |decayedCum|");
        assertGt(uint256(b.dynamicFeePips), 10 * uint256(b.effectiveMinFee), "meter reading dwarfs the floor");
    }

    // ------ anchor 3: a full one-shot rebalance charges ~half the standing cum ------
    // Retracing the whole standing leg in one swap prices at c x the midpoint of |cum| -> ~0,
    // i.e. ~|cum|/2 (the old model charged ~the full simulated impact, ~2x this). The realized
    // retrace never lands EXACTLY on zero — fee retention and simulator overshoot leave the
    // estimate a percent or so off the meter, landing just short (scenario 2) or just past
    // (scenario 3) — but the charged fee must equal the midpoint recompute from the event's own
    // (priceImpact, decayedCum) EXACTLY, and both seam branches read ~|cum|/2.
    function test_oneShotRebalance_chargesHalfTheMeter() public {
        swap(true, -10, false); // dust warmup, meter ~0
        swap(true, -int256(PUSH_IN), false); // build |cum| ~0.4%
        // Opposite one-shot of the same notional retraces the standing leg back to ~zero.
        (BeforeSwapEventData memory b,) = _swapDecode(false, -int256(PUSH_IN));

        uint256 absCum = SignedMath.abs(b.decayedCumPriceImpact);
        assertGt(absCum, 0, "standing cum required for the scenario");

        // Exact: charged fee == the midpoint-formula recompute from the emitted values.
        (uint24 expected, uint8 scenario) = _refFee(b.priceImpact, b.decayedCumPriceImpact, false, b.effectiveMinFee);
        assertTrue(scenario == 2 || scenario == 3, "full retrace must sit at the to-zero seam");
        assertEq(b.dynamicFeePips, expected, "rebalance fee != midpoint recompute");

        // ~half the meter: 5% relative headroom covers the estimate-vs-meter drift at the seam.
        assertGt(b.dynamicFeePips, b.effectiveMinFee, "rebalance must price above the floor");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "rebalance must price below the cap");
        assertApproxEqRel(uint256(b.dynamicFeePips), absCum / 2, 0.05e18, "one-shot rebalance != ~half the meter");
    }
}

/// @dev Stable config with NON-default weights (k=4e6, c=2e6). Every other pool in the test tree
///      launches at the canonical 2e6/1e6, so this is the only live-pool coverage of _beforeSwap
///      actually consuming config.kPips/cPips: a regression that hardcodes the defaults at the
///      calculateDynamicFee call site (exactly the pre-per-pool shape) passes the entire suite
///      except this contract.
contract DoubledWeightsPoolConfig is StablePairPoolConfig {
    constructor() {
        kPips = 4_000_000; // 4.0x midpoint weight: a fresh push prices at TWICE its impact
        cPips = 2_000_000; // 2.0x midpoint weight: a full one-shot rebalance prices at ~the meter
    }
}

contract MidpointFeeCustomWeightsTest is SimHookUtils {
    DoubledWeightsPoolConfig internal cfg;

    uint256 internal constant PIPS = 1e6;
    uint256 internal constant K_PIPS = 4e6; // must match DoubledWeightsPoolConfig.kPips
    uint256 internal constant C_PIPS = 2e6; // must match DoubledWeightsPoolConfig.cPips
    /// @dev Half the default suite's push: at k=4e6 the fresh-push rate is 2x impact, so this
    ///      keeps the quote (~2 x 2_000 pips) comfortably inside the 10_000-pip cap.
    uint256 internal constant PUSH_IN = 5_000e6;

    function setUp() public {
        cfg = new DoubledWeightsPoolConfig();
        (, uint160 initialSqrtPriceX96) = setupSimHookAndPool(cfg, false);
        addLiquidity(-2000, 2000, 1_000_000e6, initialSqrtPriceX96, false);
    }

    function _swapDecode(bool zeroForOne, int256 amt) internal returns (BeforeSwapEventData memory b) {
        (, Vm.Log[] memory logs) = swap(zeroForOne, amt, false);
        b = getBeforeSwapEventData(logs);
    }

    // Same port as MidpointFeeAnchorsTest._refFee, at THIS pool's weights.
    function _refFeeCustom(
        uint256 estPI,
        int256 cum,
        bool zeroForOne,
        uint24 effMin
    ) internal view returns (uint24 fee) {
        int256 dir = zeroForOne ? -int256(estPI) : int256(estPI);
        int256 estCum = dir + cum;
        uint256 absCum = SignedMath.abs(cum);
        uint256 absEstCum = SignedMath.abs(estCum);
        bool increasing = cum == 0 || (zeroForOne == (cum < 0));
        bool crossing = !increasing && estPI > absCum;

        uint256 dynImpactFee;
        if (increasing) {
            dynImpactFee = FullMath.mulDiv(absCum + absEstCum, K_PIPS, 2 * PIPS);
        } else if (!crossing) {
            dynImpactFee = FullMath.mulDiv(absCum + absEstCum, C_PIPS, 2 * PIPS);
        } else {
            uint256 twoP = 2 * estPI;
            dynImpactFee = FullMath.mulDiv(FullMath.mulDiv(absCum, absCum, twoP), C_PIPS, PIPS)
                + FullMath.mulDiv(FullMath.mulDiv(absEstCum, absEstCum, twoP), K_PIPS, PIPS);
        }

        if (dynImpactFee < effMin) fee = effMin;
        else if (dynImpactFee > cfg.maxFee()) fee = cfg.maxFee();
        else fee = uint24(dynImpactFee);
    }

    /// @notice A fresh push at k=4e6 prices at exactly TWICE its simulated impact (k x midpoint
    ///         of the 0 -> P leg = 2P) — double what the canonical k=2e6 pools charge, so the
    ///         weights provably flowed from this pool's config into the quote.
    function test_freshPush_pricesAtTwiceImpact() public {
        swap(true, -10, false); // dust warmup; realizes 0 pips, meter stays 0
        BeforeSwapEventData memory b = _swapDecode(true, -int256(PUSH_IN));
        assertEq(b.decayedCumPriceImpact, 0, "fresh push must start from a zero meter");
        assertGt(b.priceImpact, 1_000, "push must register substantial impact");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "quote must be unclamped to discriminate");
        assertEq(uint256(b.dynamicFeePips), 2 * b.priceImpact, "k=4e6 fresh push must price at twice its impact");
    }

    /// @notice A full one-shot rebalance at c=2e6 prices at ~the WHOLE meter (c x midpoint of the
    ///         |cum| -> ~0 leg = ~|cum|), double the canonical pools' ~half-meter price; pinned
    ///         exactly via the weight-parametric recompute from the event's own values.
    function test_oneShotRebalance_chargesTheMeter() public {
        swap(true, -10, false); // dust warmup
        swap(true, -int256(PUSH_IN), false); // build the standing meter
        (BeforeSwapEventData memory b) = _swapDecode(false, -int256(PUSH_IN));

        uint256 absCum = SignedMath.abs(b.decayedCumPriceImpact);
        assertGt(absCum, 0, "standing cum required for the scenario");

        uint24 expected = _refFeeCustom(b.priceImpact, b.decayedCumPriceImpact, false, b.effectiveMinFee);
        assertEq(b.dynamicFeePips, expected, "rebalance fee != custom-weight midpoint recompute");
        assertGt(b.dynamicFeePips, b.effectiveMinFee, "rebalance must price above the floor");
        assertLt(b.dynamicFeePips, cfg.maxFee(), "rebalance must price below the cap");
        assertApproxEqRel(uint256(b.dynamicFeePips), absCum, 0.05e18, "c=2e6 one-shot rebalance != ~the meter");
    }
}
