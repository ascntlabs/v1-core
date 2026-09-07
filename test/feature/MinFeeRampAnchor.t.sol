// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";
import {HookMath} from "../../src/lib/HookMath.sol";

/// @dev Stable config with a REAL min-fee ramp spread (0.1% -> 0.2%). Every other pool in the
///      test tree collapses the ramp (minMinFee == maxMinFee), so this is the only live-pool
///      coverage where effectiveMinFee actually moves — required to observe the deferred
///      once-per-block floor relaxation (RAMP-1..4).
contract RampSpreadPoolConfig is StablePairPoolConfig {
    constructor() {
        minMinFee = 1_000; // 0.1%
        maxMinFee = 2_000; // 0.2% — fully-ramped floor after timeDecayLength idle
    }
}

/// @dev End-to-end anchors for the deferred once-per-block min-fee floor relaxation, through
///      REAL swaps (RAMP-1..4). The floor ramps off `now - rampAnchor`; the first swap of each
///      block moves the anchor halfway toward lastSwapTimestamp (never toward `now`), so:
///      the floor is constant within a block, the block containing a post-idle swap keeps the
///      FULL ramped floor (a dust swap buys nothing atomically), relaxation is geometric across
///      consecutive active blocks, and idle regrowth is never halved away. Timelines are strictly
///      linear (vm.warp only, no state snapshots — block-env cheats combined with snapshots are a
///      known optimized-profile hazard). Dust swaps (10 base units) simulate and realize to zero
///      pips, so their quote sits below the floor and the emitted dynamicFeePips reads the floor.
contract MinFeeRampAnchorTest is SimHookUtils {
    RampSpreadPoolConfig internal cfg;

    uint256 internal L; // timeDecayLength — shared by the ramp and the decay

    function setUp() public {
        cfg = new RampSpreadPoolConfig();
        (, uint160 initialSqrtPriceX96) = setupSimHookAndPool(cfg, false);
        addLiquidity(-2000, 2000, 1_000_000e6, initialSqrtPriceX96, false);
        L = cfg.timeDecayLength();
    }

    // ------ state readers ------

    function _anchor() internal view returns (uint256 a) {
        (,, uint40 ra,) = hook.poolData(poolId);
        a = uint256(ra);
    }

    function _lastTs() internal view returns (uint256 t) {
        (, uint48 ts,,) = hook.poolData(poolId);
        t = uint256(ts);
    }

    /// @dev The contract's settle rule, mirrored: anchor moves halfway toward lastTs.
    function _settle(uint256 anchor, uint256 lastTs) internal pure returns (uint256) {
        return lastTs - (lastTs - anchor) / 2;
    }

    /// @dev Expected floor for a given anchor at the CURRENT timestamp — the exact library call
    ///      the hook makes, so assertions are exact, not approximate.
    ///
    ///      `vm.getBlockTimestamp()` rather than `block.timestamp` on purpose: `TIMESTAMP` is
    ///      transaction-invariant as far as the optimizer is concerned, so on the via-IR
    ///      optimized profile it gets hoisted out of any loop that warps — and `vm.warp` mutates
    ///      it out-of-band where the optimizer cannot see. Reading it through the cheatcode is an
    ///      external staticcall, which cannot be folded. Same reason the loops below warp to an
    ///      explicit timeline instead of `block.timestamp + delta`.
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _floorFromAnchor(uint256 anchor) internal view returns (uint24) {
        return HookMath.calculateEffectiveMinFee(cfg.minMinFee(), cfg.maxMinFee(), _now() - anchor, L);
    }

    function _dust(bool zeroForOne) internal returns (BeforeSwapEventData memory b) {
        (, Vm.Log[] memory logs) = swap(zeroForOne, -10, false);
        b = getBeforeSwapEventData(logs);
    }

    // ------ RAMP-4: configurePool seeds the anchor; the first swap prices off it ------

    function test_configureSeedsRampAnchor_firstSwapPricesOffIt() public {
        // setUp configured the pool with no swaps yet: anchor seeded, swap clock never stamped.
        uint256 tCfg = _anchor();
        assertGt(tCfg, 0, "configurePool must seed rampAnchor");
        assertEq(_lastTs(), 0, "no swap has stamped the clock yet");

        // Idle a full horizon before the FIRST swap: its floor reads fully ramped off the seed,
        // and the settle is skipped (lastTs == 0 < anchor), so the seed survives untouched.
        vm.warp(block.timestamp + L);
        BeforeSwapEventData memory b = _dust(true);
        assertEq(uint256(b.effectiveMinFee), uint256(cfg.maxMinFee()), "first swap must pay ramp(idle since configure)");
        assertEq(_anchor(), tCfg, "pre-first-swap settle must be skipped");
        assertEq(_lastTs(), block.timestamp, "first swap must stamp lastSwapTimestamp");
    }

    // ------ RAMP-2: deferral — the reset block keeps the full ramped floor ------

    function test_deferral_dustAndSameBlockFollowerPayTheFullFloor() public {
        _dust(true); // warmup: stamps lastTs at the configure-time anchor (zero banked credit)
        vm.warp(block.timestamp + L); // idle a full horizon: floor fully ramped

        // The "reset" dust swap: first of its block, but its owed halving is measured as of
        // lastTs (banked credit was zero), so it pays the FULL ramped floor.
        BeforeSwapEventData memory b1 = _dust(true);
        assertEq(
            uint256(b1.effectiveMinFee), uint256(cfg.maxMinFee()), "post-idle swap must pay the fully ramped floor"
        );
        assertEq(uint256(b1.dynamicFeePips), uint256(cfg.maxMinFee()), "dust quote must clamp to the floor");

        // Same-block follow-up: no settle fires, floor unchanged — the dust swap bought nothing.
        BeforeSwapEventData memory b2 = _dust(true);
        assertEq(
            uint256(b2.effectiveMinFee), uint256(b1.effectiveMinFee), "same-block follower must see the same floor"
        );
        assertEq(uint256(b2.effectiveMinFee), uint256(cfg.maxMinFee()), "deferral: no same-block discount");
    }

    // ------ RAMP-1: geometric halving across consecutive active blocks + anchor recurrence ------

    function test_nextBlocks_floorHalvesGeometrically_anchorTracksRecurrence() public {
        _dust(true); // T0: seed
        uint256 shadowAnchor = _anchor(); // start from the configure-time seed, wherever it sits
        uint256 t = _now() + L; // explicit timeline — see `_now`
        vm.warp(t); // bank exactly one horizon of idle credit

        uint24 prevFloor = type(uint24).max;
        for (uint256 i = 0; i < 6; i++) {
            // shadow settle: this swap is the first of its block
            shadowAnchor = _settle(shadowAnchor, _lastTs());
            uint24 expectedFloor = _floorFromAnchor(shadowAnchor);

            BeforeSwapEventData memory b = _dust(true);
            assertEq(_anchor(), shadowAnchor, "on-chain anchor != shadow recurrence");
            assertEq(uint256(b.effectiveMinFee), uint256(expectedFloor), "floor != ramp(now - settledAnchor)");

            // monotone relaxation while blocks stay active (12s regrowth << halved credit)
            assertLt(uint256(b.effectiveMinFee), uint256(prevFloor), "floor must relax across active blocks");
            prevFloor = b.effectiveMinFee;

            // anchor bounds: monotone non-decreasing, never past lastSwapTimestamp
            assertLe(_anchor(), _lastTs(), "anchor must not pass lastSwapTimestamp");

            t += 12;
            vm.warp(t);
        }
        // after 6 active blocks the floor has bled most of the spread
        assertLt(uint256(prevFloor), uint256(cfg.minMinFee() + 100), "floor must approach minMinFee");

        // The headline sequence (0.2% -> ~0.15% -> ~0.125%) is pinned exactly inside the loop by
        // the recurrence; the floor can never undershoot the configured minimum.
        assertGe(uint256(prevFloor), uint256(cfg.minMinFee()), "floor never undershoots the minimum");
    }

    // ------ RAMP-1 (within-block leg): floor constant regardless of swap count ------

    function test_floorConstantWithinBlock() public {
        _dust(true);
        vm.warp(block.timestamp + L / 2); // partial ramp

        BeforeSwapEventData memory b1 = _dust(true); // settles the (zero-credit) halving
        BeforeSwapEventData memory b2 = _dust(false); // opposite-direction dust, same block
        (, Vm.Log[] memory logs) = swap(true, -10_000e6, false); // a REAL swap, same block
        BeforeSwapEventData memory b3 = getBeforeSwapEventData(logs);

        assertEq(uint256(b1.effectiveMinFee), uint256(b2.effectiveMinFee), "floor must not move within a block");
        assertEq(uint256(b2.effectiveMinFee), uint256(b3.effectiveMinFee), "floor must not move within a block");
    }

    // ------ RAMP-3: idle regrowth is never halved away ------

    function test_idleRegrowth_notHalvedAway() public {
        _dust(true);
        vm.warp(block.timestamp + L);
        _dust(true); // reset attempt at full floor
        vm.warp(block.timestamp + 12);
        BeforeSwapEventData memory bRelaxed = _dust(true); // one halving lands: floor ~half the spread
        assertLt(uint256(bRelaxed.effectiveMinFee), uint256(cfg.maxMinFee()), "precondition: floor partially relaxed");

        // Long idle again: the owed halving only touches credit banked BEFORE the idle gap, so
        // the regrown floor reads fully ramped — waiting cannot be cheapened retroactively.
        vm.warp(block.timestamp + 2 * L);
        BeforeSwapEventData memory bRegrown = _dust(true);
        assertEq(
            uint256(bRegrown.effectiveMinFee), uint256(cfg.maxMinFee()), "idle regrowth must restore the full floor"
        );
    }

    // ------ ACC-1 leg: decay keeps keying off the RAW inter-swap gap, not the anchor ------

    function test_decayRecurrence_unaffectedByAnchor() public {
        _dust(true); // warmup: stamps the swap clock
        (, Vm.Log[] memory logs) = swap(true, -10_000e6, false); // build a standing meter
        AfterSwapEventData memory a = getAfterSwapEventData(logs);
        assertTrue(a.cumPriceImpact != 0, "push must bank a standing cum");

        uint256 dt = 600;
        vm.warp(block.timestamp + dt);
        BeforeSwapEventData memory b = _dust(true);

        // Exact: the emitted decayed cum equals the library recurrence over the RAW gap. The
        // anchor sits further in the past than lastSwapTimestamp here, so any implementation
        // that fed anchor-time into the decay would over-decay and fail this equality.
        int256 expected = HookMath.decayCumByTime(a.cumPriceImpact, dt, L);
        assertEq(b.decayedCumPriceImpact, expected, "decay must key off the raw inter-swap interval");
    }

    // ------ RAMP-1 recurrence, fuzzed end-to-end over random block gaps ------

    function testFuzz_anchorRecurrence_overRandomGaps(uint16[6] memory gapsRaw) public {
        _dust(true);
        uint256 shadowAnchor = _anchor(); // start from the configure-time seed, wherever it sits

        uint256 t = _now(); // explicit timeline — see `_now`
        for (uint256 i = 0; i < 6; i++) {
            uint256 gap = bound(uint256(gapsRaw[i]), 0, 2 * L);
            t += gap;
            vm.warp(t);

            if (_lastTs() < t) {
                shadowAnchor = _settle(shadowAnchor, _lastTs());
            }
            uint24 expectedFloor = _floorFromAnchor(shadowAnchor);

            BeforeSwapEventData memory b = _dust(i % 2 == 0);
            assertEq(_anchor(), shadowAnchor, "anchor recurrence diverged");
            assertEq(uint256(b.effectiveMinFee), uint256(expectedFloor), "floor diverged from ramp(now - anchor)");
            assertLe(_anchor(), _lastTs(), "anchor passed lastSwapTimestamp");
        }
    }
}
