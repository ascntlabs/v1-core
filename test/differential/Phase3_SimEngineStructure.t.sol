// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SwapSimulator} from "../../src/lib/SwapSimulator.sol";
import {SwapQuoter} from "../utils/SwapQuoter.sol";
import {TestSwapQuoter} from "../utils/TestSwapQuoter.sol";

/// @notice phase3-differential — structural SwapSimulator vs live-engine differentials:
///         SIM-8 (bitmap word boundaries), SIM-10 (mixed-sign liquidityNet crossings),
///         SIM-5 (termination/correctness across zero-liquidity gaps), SIM-9 (MIN/MAX-tick
///         edge with an initialized boundary position), SIM-13 (per-pool read isolation),
///         SIM-14 (sequential mid-range start states), SIM-15 (stateless range/monotone
///         bounds), SIM-12 (simulate performs zero state mutation).
///
/// All pools are fee=0 and hookless so sim == engine must hold EXACTLY (the simulator's
/// hard-coded fee=0 matches), making every comparison a bit-equality, and the quoter
/// (runs the LIVE engine then reverts) can also pin the signed deltas.
///
/// Pools share one manager and one currency pair; keys differ by tickSpacing only:
///   main (ts=10): deep base + word-boundary ticks (2550=bitPos255/word0,
///                 2560=bitPos0/word1, -2560=bitPos0/word-1, -2550, -10=bitPos255/word-1)
///                 + interleaved positions for mixed-sign crossings.
///   gap  (ts=20): liquidity ONLY in [-5000,-3000] and [3000,5000]; price starts at tick 0
///                 with ZERO active liquidity.
///   edge (ts=5) : small base + positions hugging the last usable ticks +-88726x.
///   iso  (ts=60): the mutation victim for the isolation test.
contract Phase3_SimStructureDiffTest is Test, ArtifactDeployers {
    using StateLibrary for *;

    PoolKey internal mainKey;
    PoolId internal mainId;
    PoolKey internal gapKey;
    PoolId internal gapId;
    PoolKey internal edgeKey;
    PoolId internal edgeId;
    PoolKey internal isoKey;
    PoolId internal isoId;

    TestSwapQuoter internal quoter;

    int24 internal constant TS_MAIN = 10;
    int24 internal constant TS_GAP = 20;
    int24 internal constant TS_EDGE = 5;
    int24 internal constant TS_ISO = 60;

    // last usable tick multiples of TS_EDGE inside [MIN_TICK, MAX_TICK] = [-887272, 887272]
    int24 internal constant EDGE_LOW_LOWER = -887270;
    int24 internal constant EDGE_LOW_UPPER = -887260;
    int24 internal constant EDGE_HIGH_LOWER = 887260;
    int24 internal constant EDGE_HIGH_UPPER = 887270;

    function setUp() public {
        deployArtifactManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 init = TickMath.getSqrtPriceAtTick(0);
        (mainKey, mainId) = initPool(currency0, currency1, IHooks(address(0)), 0, TS_MAIN, init);
        (gapKey, gapId) = initPool(currency0, currency1, IHooks(address(0)), 0, TS_GAP, init);
        (edgeKey, edgeId) = initPool(currency0, currency1, IHooks(address(0)), 0, TS_EDGE, init);
        (isoKey, isoId) = initPool(currency0, currency1, IHooks(address(0)), 0, TS_ISO, init);

        // ---- main: deep base + word-boundary ticks + interleaved ranges ----
        _addByAmount0(mainKey, -5000, 5000, 1_000 ether);
        _addByAmount0(mainKey, 2550, 2560, 5 ether); // bitPos 255 (word 0) / bitPos 0 (word 1)
        _addByAmount0(mainKey, -2560, -2550, 5 ether); // bitPos 0 / bitPos 1 (word -1)
        _addByAmount0(mainKey, -10, 10, 5 ether); // -10 = bitPos 255 of word -1
        _addByAmount0(mainKey, -100, 50, 5 ether); // interleaved uppers/lowers around 0
        _addByAmount0(mainKey, -50, 100, 5 ether);
        _addByAmount0(mainKey, 30, 200, 5 ether); // +30 lower crossed upward = +liq among -liq uppers
        _addByAmount0(mainKey, -200, -30, 5 ether); // mirror for the downward path

        // ---- gap: two islands, nothing at the current price ----
        _addByAmount0(gapKey, -5000, -3000, 100 ether);
        _addByAmount0(gapKey, 3000, 5000, 100 ether);

        // ---- edge: small base + raw-liquidity positions at the usable-tick extremes ----
        // (amount0-derived liquidity truncates to 0 at these sqrt prices; raw values keep
        // the token cost negligible while making the boundary ticks initialized)
        _addByAmount0(edgeKey, -600, 600, 1 ether);
        _addRawLiquidity(edgeKey, EDGE_LOW_LOWER, EDGE_LOW_UPPER, 1e12);
        _addRawLiquidity(edgeKey, EDGE_HIGH_LOWER, EDGE_HIGH_UPPER, 1e12);

        // ---- iso: plain small pool ----
        _addByAmount0(isoKey, -120, 120, 10 ether);

        quoter = new TestSwapQuoter(manager);
    }

    // ------ helpers ------

    function _addByAmount0(PoolKey memory k, int24 lower, int24 upper, uint256 amount0) internal {
        uint160 sl = TickMath.getSqrtPriceAtTick(lower);
        uint160 su = TickMath.getSqrtPriceAtTick(upper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sl, su, amount0);
        _addRawLiquidity(k, lower, upper, int256(uint256(liq)));
    }

    function _addRawLiquidity(PoolKey memory k, int24 lower, int24 upper, int256 liq) internal {
        modifyLiquidityRouter.modifyLiquidity{value: 1}(
            k,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function _params(bool zeroForOne, int256 amt) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amt,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @dev Differential core: sim vs the LIVE engine (via the swap+revert quoter), price
    ///      AND both signed deltas, with no state advance. Returns the sim result.
    function _diffExact(
        PoolKey memory k,
        PoolId id,
        int24 ts,
        SwapParams memory p
    ) internal returns (SwapSimulator.Result memory r) {
        r = SwapSimulator.simulate(manager, id, ts, p);
        SwapQuoter.SwapQuote memory q = quoter.quote(k, p, "");
        assertEq(r.sqrtPriceAfterX96, q.finalSqrtPriceX96, "sim price != engine price");
        assertEq(r.amount0Delta, q.amount0, "sim amount0 != engine");
        assertEq(r.amount1Delta, q.amount1, "sim amount1 != engine");
    }

    /// @dev Differential with a real state-advancing swap (for sequential-state tests).
    function _diffAndAdvance(PoolKey memory k, PoolId id, int24 ts, SwapParams memory p) internal {
        (uint160 before_,,,) = StateLibrary.getSlot0(manager, id);
        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, id, ts, p);
        assertEq(r.sqrtPriceBeforeX96, before_, "sim before != slot0");
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(k, p, settings, ZERO_BYTES);
        (uint160 realAfter,,,) = StateLibrary.getSlot0(manager, id);
        assertEq(r.sqrtPriceAfterX96, realAfter, "sim after != engine after");
    }

    // ------ SIM-8: bitmap word boundaries (bitPos 0 and 255, both directions) ------

    function test_sim8_wordBoundary_upCrossing() public {
        // push far past ticks 2550 (bitPos 255, word 0) and 2560 (bitPos 0, word 1)
        SwapSimulator.Result memory r = _diffExact(mainKey, mainId, TS_MAIN, _params(false, -800 ether));
        assertGt(
            TickMath.getTickAtSqrtPrice(r.sqrtPriceAfterX96),
            2560,
            "precondition: swap must actually cross the word-boundary ticks"
        );
    }

    function test_sim8_wordBoundary_downCrossing() public {
        // push down past -2550 (bitPos 1) and -2560 (bitPos 0, word -1); the lte=true scan
        // also walks -10 = bitPos 255 of word -1 on the way
        SwapSimulator.Result memory r = _diffExact(mainKey, mainId, TS_MAIN, _params(true, -800 ether));
        assertLt(
            TickMath.getTickAtSqrtPrice(r.sqrtPriceAfterX96),
            -2560,
            "precondition: swap must actually cross the word-boundary ticks"
        );
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sim8_wordBoundaryRegion(uint256 amount, bool zeroForOne) public {
        // varied landings before/on/after the boundary ticks in both scan directions
        int256 amt = -int256(bound(amount, 1 ether, 800 ether));
        _diffExact(mainKey, mainId, TS_MAIN, _params(zeroForOne, amt));
    }

    // ------ SIM-10: mixed-sign liquidityNet crossings ------

    function test_sim10_mixedSignCrossings_up() public {
        // upward path from tick 0 crosses +10/+50/+100 (uppers, -liq) AND +30 (a lower,
        // +liq): the sign-flip and addDelta handling must match the engine at each one.
        // Final price + deltas equality after the whole mixed path is the observable.
        SwapSimulator.Result memory r = _diffExact(mainKey, mainId, TS_MAIN, _params(false, -40 ether));
        assertGt(
            TickMath.getTickAtSqrtPrice(r.sqrtPriceAfterX96), 150, "precondition: must cross the mixed-sign tick set"
        );
    }

    function test_sim10_mixedSignCrossings_down() public {
        // downward mirror: -10/-50/-100 (removals) and -30 (an upper entered downward, +liq)
        SwapSimulator.Result memory r = _diffExact(mainKey, mainId, TS_MAIN, _params(true, -40 ether));
        assertLt(
            TickMath.getTickAtSqrtPrice(r.sqrtPriceAfterX96), -150, "precondition: must cross the mixed-sign tick set"
        );
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sim10_mixedSignRegion(uint256 amount, bool zeroForOne, bool exactIn) public {
        int256 amt = exactIn ? -int256(bound(amount, 1e15, 60 ether)) : int256(bound(amount, 1e15, 40 ether));
        _diffExact(mainKey, mainId, TS_MAIN, _params(zeroForOne, amt));
    }

    // ------ SIM-5: zero-liquidity gaps — termination and equality ------

    function test_sim5_gapTraversal_down() public {
        // starts with ZERO active liquidity at tick 0, free-falls across the empty words
        // to -3000, then fills inside the island — the engine-accepted swap must simulate
        // identically and within a bounded gas envelope (non-termination would blow it).
        uint256 g0 = gasleft();
        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, gapId, TS_GAP, _params(true, -10 ether));
        uint256 used = g0 - gasleft();
        assertLt(used, 20_000_000, "SIM-5: simulate gas must stay bounded");
        assertLt(TickMath.getTickAtSqrtPrice(r.sqrtPriceAfterX96), -3000, "precondition: entered the island");
        _diffExact(gapKey, gapId, TS_GAP, _params(true, -10 ether));
    }

    function test_sim5_gapTraversal_up() public {
        uint256 g0 = gasleft();
        SwapSimulator.simulate(manager, gapId, TS_GAP, _params(false, -10 ether));
        uint256 used = g0 - gasleft();
        assertLt(used, 20_000_000, "SIM-5: simulate gas must stay bounded");
        _diffExact(gapKey, gapId, TS_GAP, _params(false, -10 ether));
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sim5_gapPool(uint256 amount, bool zeroForOne) public {
        // includes amounts exceeding the island capacity: the tail runs through trailing
        // empty words to the price limit
        int256 amt = -int256(bound(amount, 1e15, 60 ether));
        _diffExact(gapKey, gapId, TS_GAP, _params(zeroForOne, amt));
    }

    // ------ SIM-9: initialized position at the usable-tick extreme ------

    function test_sim9_minTickEdge() public {
        // 5e27 token0-in: drains the tiny base, free-falls ~880k ticks of empty words,
        // then lands INSIDE [-887270,-887260] (its ~9e27 capacity only half-consumed), so
        // the MIN_TICK clamp, the boundary crossing at -887260, and the final in-range
        // step must all price identically to the engine.
        SwapSimulator.Result memory r = _diffExact(edgeKey, edgeId, TS_EDGE, _params(true, -5e27));
        int24 tickAfter = TickMath.getTickAtSqrtPrice(r.sqrtPriceAfterX96);
        assertGe(tickAfter, EDGE_LOW_LOWER, "precondition: must stop inside the edge position");
        assertLt(tickAfter, EDGE_LOW_UPPER, "precondition: must stop inside the edge position");
    }

    function test_sim9_maxTickEdge() public {
        SwapSimulator.Result memory r = _diffExact(edgeKey, edgeId, TS_EDGE, _params(false, -5e27));
        int24 tickAfter = TickMath.getTickAtSqrtPrice(r.sqrtPriceAfterX96);
        assertGe(tickAfter, EDGE_HIGH_LOWER, "precondition: must stop inside the edge position");
        assertLt(tickAfter, EDGE_HIGH_UPPER, "precondition: must stop inside the edge position");
    }

    function test_sim9_minTickEdge_pastPosition_toLimit() public {
        // amount exceeding the edge-position capacity: crosses it entirely and runs to the
        // MIN price limit — the terminal clamp behavior must match the engine
        SwapSimulator.Result memory r = _diffExact(edgeKey, edgeId, TS_EDGE, _params(true, -2e28));
        assertEq(r.sqrtPriceAfterX96, TickMath.MIN_SQRT_PRICE + 1, "must run to the limit");
    }

    // ------ SIM-13: simulate reads only the passed pool's state ------

    function test_sim13_poolIsolation() public {
        SwapParams memory p = _params(true, -3 ether);
        SwapSimulator.Result memory r1 = SwapSimulator.simulate(manager, mainId, TS_MAIN, p);

        // mutate a DIFFERENT pool on the same manager: liquidity, bitmap, and slot0 all move
        _addRawLiquidity(isoKey, -60, 60, 1e18);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(isoKey, _params(false, -1 ether), settings, ZERO_BYTES);

        SwapSimulator.Result memory r2 = SwapSimulator.simulate(manager, mainId, TS_MAIN, p);
        assertEq(r1.sqrtPriceBeforeX96, r2.sqrtPriceBeforeX96, "SIM-13: foreign-pool state bled into before");
        assertEq(r1.sqrtPriceAfterX96, r2.sqrtPriceAfterX96, "SIM-13: foreign-pool state bled into after");
        assertEq(r1.amount0Delta, r2.amount0Delta, "SIM-13: foreign-pool state bled into delta0");
        assertEq(r1.amount1Delta, r2.amount1Delta, "SIM-13: foreign-pool state bled into delta1");
    }

    function test_sim13_poolIsolation_reverse() public {
        SwapParams memory p = _params(false, -1 ether);
        SwapSimulator.Result memory r1 = SwapSimulator.simulate(manager, isoId, TS_ISO, p);

        _addRawLiquidity(mainKey, -300, 300, 1e18);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(mainKey, _params(true, -2 ether), settings, ZERO_BYTES);

        SwapSimulator.Result memory r2 = SwapSimulator.simulate(manager, isoId, TS_ISO, p);
        assertEq(r1.sqrtPriceAfterX96, r2.sqrtPriceAfterX96, "SIM-13: foreign-pool state bled into after");
        assertEq(r1.amount0Delta, r2.amount0Delta, "SIM-13: foreign-pool state bled into delta0");
        assertEq(r1.amount1Delta, r2.amount1Delta, "SIM-13: foreign-pool state bled into delta1");
    }

    // ------ SIM-14: sequential swaps from mid-range (non-boundary) start states ------
    //
    // Note on scope: within ONE simulate call the tick-recompute else-branch value can
    // never influence the returned result — the loop only iterates again when a step fully
    // reached its target price (first branch), so a mid-range stop is always the LAST
    // iteration. What IS observable is correctness from arbitrary mid-range pre-states:
    // swap 2 starts at a price strictly inside a tick (set by swap 1's partial fill), and
    // its whole path — first bitmap scan included — must match the engine.

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sim14_sequentialMidRangeStarts(uint256 a1, uint256 a2, bool z1, bool z2) public {
        _diffAndAdvance(mainKey, mainId, TS_MAIN, _params(z1, -int256(bound(a1, 1e15, 3 ether))));
        _diffAndAdvance(mainKey, mainId, TS_MAIN, _params(z2, -int256(bound(a2, 1e15, 3 ether))));
    }

    // ------ SIM-15: stateless output bounds — range, direction, limit side ------

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sim15_rangeAndMonotone(
        uint256 amount,
        bool zeroForOne,
        bool exactIn,
        uint256 limitSel
    ) public view {
        int256 amt = exactIn ? -int256(bound(amount, 1, 1e26)) : int256(bound(amount, 1, 1e26));
        uint256 sel = bound(limitSel, 0, 2);
        uint160 limit;
        if (sel == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else if (sel == 1) {
            limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-3500) : int24(3500));
        } else {
            limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-100) : int24(100));
        }

        // gap pool: the hardest terrain (zero-liquidity start, islands, trailing emptiness)
        SwapSimulator.Result memory r = SwapSimulator.simulate(
            manager, gapId, TS_GAP, SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: limit})
        );

        assertGe(r.sqrtPriceAfterX96, TickMath.MIN_SQRT_PRICE, "SIM-15: price below MIN_SQRT_PRICE");
        assertLe(r.sqrtPriceAfterX96, TickMath.MAX_SQRT_PRICE, "SIM-15: price above MAX_SQRT_PRICE");
        if (zeroForOne) {
            assertLe(r.sqrtPriceAfterX96, r.sqrtPriceBeforeX96, "SIM-15: zeroForOne must not raise price");
            assertGe(r.sqrtPriceAfterX96, limit, "SIM-15: crossed its own price limit");
        } else {
            assertGe(r.sqrtPriceAfterX96, r.sqrtPriceBeforeX96, "SIM-15: oneForZero must not lower price");
            assertLe(r.sqrtPriceAfterX96, limit, "SIM-15: crossed its own price limit");
        }
    }

    // ------ SIM-12: simulate performs zero state mutation ------

    int24[16] internal MAIN_TICKS =
        [int24(-5000), -2560, -2550, -200, -100, -50, -30, -10, 10, 30, 50, 100, 200, 2550, 2560, 5000];

    function _mainStateHash() internal view returns (bytes32 h) {
        (uint160 sqrtP, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, mainId);
        uint128 liq = StateLibrary.getLiquidity(manager, mainId);
        (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthGlobals(manager, mainId);
        h = keccak256(abi.encode(sqrtP, tick, protocolFee, lpFee, liq, fg0, fg1));
        for (int16 w = -3; w <= 3; w++) {
            h = keccak256(abi.encode(h, StateLibrary.getTickBitmap(manager, mainId, w)));
        }
        for (uint256 i = 0; i < MAIN_TICKS.length; i++) {
            (uint128 lg, int128 ln) = StateLibrary.getTickLiquidity(manager, mainId, MAIN_TICKS[i]);
            h = keccak256(abi.encode(h, lg, ln));
        }
    }

    /// @dev Declared `view`: the compiler itself proves simulate cannot mutate state when
    ///      reached from here; the hash comparison additionally pins every StateLibrary-
    ///      visible field the simulator touches (slot0, liquidity, bitmap words, tick
    ///      liquidity, fee growth) across a multi-crossing simulation.
    function test_sim12_simulateIsPureRead() public view {
        bytes32 before_ = _mainStateHash();
        SwapSimulator.simulate(manager, mainId, TS_MAIN, _params(true, -20 ether));
        SwapSimulator.simulate(manager, mainId, TS_MAIN, _params(false, -20 ether));
        assertEq(_mainStateHash(), before_, "SIM-12: simulate mutated observable pool state");
    }
}
