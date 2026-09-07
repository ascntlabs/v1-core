// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice The full-range seed premise (`docs/known-issues.md` KI-6, `docs/invariants.md` #6).
///
///         The protocol seeds every pool full-range at launch; the seed is not locked, so keeping
///         one full-range position in place at all times is the operating recommendation, which
///         keeps `L > 0` at every tick. This contract pins what that premise
///         buys, by running the same swaps against two pools that differ only by the seed:
///
///           unseeded — liquidity ONLY in [-5040,-3000] and [3000,5040]; spot at tick 0 sits in
///                      a zero-liquidity gap. This is the KI-6 / review scenario.
///           seeded   — the same two islands PLUS a full-range position.
///
///         On the unseeded pool a swap can move the price while exchanging exactly zero tokens,
///         so `_afterSwap`'s exact-zero guard fires and books nothing: the accumulator and the
///         book's end state disagree. That is the path-to-state inconsistency raised in review
///         (Vulsight ASCNT-M-01, LeftClaw #3), and the zero-cost gap walk behind it.
///
///         On the seeded pool neither is reachable: a price move necessarily exchanges tokens,
///         so the guard cannot coincide with a real move, the walk must be paid for, and a
///         round trip books both legs instead of only one.
///
///         The premise is operational — the deployment process mints the seed; nothing in the
///         contract enforces it. These tests are what pins it.
contract SeededPoolAccumulatorTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    PoolSwapTest.TestSettings internal S = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    // The two pools must differ in the key, or they are the same pool — tick spacing is the
    // only field free to vary here. Ticks below are multiples of 60, so they are usable under both spacings, so the islands
    // sit at identical prices in both.
    int24 internal constant TS_UNSEEDED = 20;
    int24 internal constant TS_SEEDED = 60;
    // widest usable ticks that are multiples of TS_SEEDED inside [MIN_TICK, MAX_TICK]
    int24 internal constant FULL_LOWER = -887220;
    int24 internal constant FULL_UPPER = 887220;
    // the swap stops here — inside the empty region, short of either island
    int24 internal constant LIMIT_TICK = -1000;
    int24 internal constant ISLAND_UPPER = -3000;

    /// @dev The excursion below runs from tick 0 to tick -1000, ≈9.5% of price — so a correctly
    ///      booked leg lands on the order of 1e5 pips. Assertions are floored well under that
    ///      rather than at zero, so none of them can pass on a one-pip move.
    int256 internal constant MATERIAL_IMPACT = 10_000; // 1%

    int256 internal constant SEED_LIQUIDITY = 1e9;
    int256 internal constant ISLAND_LIQUIDITY = 1e11;

    PoolKey internal unseededKey;
    PoolId internal unseededId;
    PoolKey internal seededKey;
    PoolId internal seededId;

    uint160 internal initSqrtP;
    uint160 internal limitSqrtP;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, initSqrtP) = setupSimHookAndPool(cfg, false);
        governance.setProtocolFeeBps(0);

        limitSqrtP = TickMath.getSqrtPriceAtTick(LIMIT_TICK);

        (unseededKey, unseededId) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TS_UNSEEDED, initSqrtP
        );
        (seededKey, seededId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TS_SEEDED, initSqrtP);

        hook.configurePool(unseededId, 10, 10, 10_000, 1 hours, 0, 2e6, 1e6);
        hook.configurePool(seededId, 10, 10, 10_000, 1 hours, 0, 2e6, 1e6);

        // both pools: two islands, nothing at spot
        _add(unseededKey, -5040, -3000, ISLAND_LIQUIDITY);
        _add(unseededKey, 3000, 5040, ISLAND_LIQUIDITY);
        _add(seededKey, -5040, -3000, ISLAND_LIQUIDITY);
        _add(seededKey, 3000, 5040, ISLAND_LIQUIDITY);

        // the seeded pool alone carries the full-range seed
        _add(seededKey, FULL_LOWER, FULL_UPPER, SEED_LIQUIDITY);

        assertEq(manager.getLiquidity(unseededId), 0, "precondition: unseeded pool is empty at spot");
        assertEq(
            uint256(manager.getLiquidity(seededId)), uint256(SEED_LIQUIDITY), "precondition: seeded pool has L at spot"
        );
    }

    // ------ helpers ------

    function _add(PoolKey memory k, int24 lower, int24 upper, int256 liq) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: bytes32(0)}), ""
        );
    }

    /// @dev exact-input, stopping at `limitSqrtP` (inside the empty region on the unseeded pool)
    function _downToLimit(int256 amountIn) internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -amountIn, sqrtPriceLimitX96: 0});
    }

    function _swapDown(PoolKey memory k, int256 amountIn) internal returns (BalanceDelta d) {
        SwapParams memory p = _downToLimit(amountIn);
        p.sqrtPriceLimitX96 = limitSqrtP;
        d = swapRouter.swap(k, p, S, "");
    }

    function _swapUp(PoolKey memory k, int256 amountIn) internal returns (BalanceDelta d) {
        d = swapRouter.swap(
            k, SwapParams({zeroForOne: false, amountSpecified: -amountIn, sqrtPriceLimitX96: initSqrtP}), S, ""
        );
    }

    function _cum(PoolId id) internal view returns (int256 c) {
        (,,, c) = hook.poolData(id);
    }

    function _price(PoolId id) internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(id);
    }

    // ------ the contrast case: no seed ------

    /// @notice Without the seed, a swap moves the price while exchanging exactly zero tokens, and
    ///         `_afterSwap` books nothing — the accumulator and the book's end state disagree.
    ///         Documented, and the reason the seed premise exists. KI-6.
    function test_m01_unseeded_zeroDeltaSwapMovesPriceButBooksNothing() public {
        uint160 before = _price(unseededId);
        int256 cumBefore = _cum(unseededId);

        BalanceDelta d = _swapDown(unseededKey, 1e9);

        assertEq(d.amount0(), 0, "no liquidity at spot: nothing is taken in");
        assertEq(d.amount1(), 0, "no liquidity at spot: nothing is paid out");
        assertLt(_price(unseededId), before, "the price nonetheless walked to the limit");
        assertEq(_cum(unseededId), cumBefore, "the exact-zero guard books the move as a no-op");
    }

    // ------ what the seed buys ------

    /// @notice With the seed, a price move always exchanges tokens, so the exact-zero guard can
    ///         never coincide with a real move: the injection half of ASCNT-M-01 is unreachable.
    function test_m01_seeded_priceMoveAlwaysExchangesTokens() public {
        uint160 before = _price(seededId);
        int256 cumBefore = _cum(seededId);

        BalanceDelta d = _swapDown(seededKey, 1e9);

        assertLt(_price(seededId), before, "precondition: the price moved");
        assertTrue(d.amount0() != 0 || d.amount1() != 0, "a price move must exchange tokens when L > 0");
        assertLt(_cum(seededId), cumBefore, "the move is booked, signed by direction");
        assertGt(_abs(_cum(seededId)), MATERIAL_IMPACT, "and booked at the excursion's real size");
    }

    /// @notice The scrubbing half: a closed price loop books BOTH legs, so the reverse path
    ///         unwinds the accumulator instead of leaving a standing reading the book no longer
    ///         supports. Compared against the one-way excursion, not against zero — the two legs
    ///         traverse the same path in opposite directions and cancel to rounding, not exactly.
    function test_m01_seeded_roundTripUnwindsTheAccumulator() public {
        _swapDown(seededKey, 1e9);
        int256 peak = _cum(seededId);
        assertLt(peak, 0, "precondition: the outbound leg loaded the meter");
        assertGt(_abs(peak), MATERIAL_IMPACT, "precondition: loaded it materially, not by a pip");

        // same block: decay is the identity, so any unwind here is the reverse leg being booked
        _swapUp(seededKey, 1e9);
        int256 afterLoop = _cum(seededId);

        assertGt(afterLoop, peak, "the reverse leg must be booked, not ignored");
        assertLt(_abs(afterLoop), _abs(peak) / 2, "the loop must substantially unwind the meter");
    }

    /// @notice LeftClaw #3: with the seed there is no free walk. The same swap that cost nothing
    ///         on the unseeded pool consumes input on the seeded one.
    function test_m01_seeded_gapWalkConsumesInput() public {
        BalanceDelta unseeded = _swapDown(unseededKey, 1e9);
        BalanceDelta seeded = _swapDown(seededKey, 1e9);

        assertEq(unseeded.amount0(), 0, "unseeded: the walk is free");
        assertLt(seeded.amount0(), 0, "seeded: the walk is paid for in input tokens");
    }

    /// @notice KI-2 / LeftClaw #4: the seed also bounds the tick walk. Inside KI-1's window the
    ///         fee-free replay scans bitmap words the real swap never visits; with zero liquidity
    ///         those words are free-run, so the walk is bounded only by the price limit the
    ///         swapper chose. With `L > 0` everywhere every step of the walk consumes input, so
    ///         the same order moves the price far less — the walk is input-bounded, not
    ///         limit-bounded.
    function test_ki2_seedBoundsTheWalkByInputRatherThanByPriceLimit() public {
        // a fully loose limit: nothing but liquidity stands between the order and the floor
        SwapParams memory loose =
            SwapParams({zeroForOne: true, amountSpecified: -1e8, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        swapRouter.swap(unseededKey, loose, S, "");
        int24 unseededTick = _tickOf(unseededId);

        swapRouter.swap(seededKey, loose, S, "");
        int24 seededTick = _tickOf(seededId);

        // The seeded pool charges liquidity for every tick crossed, so the same order lands far
        // short of where it free-runs to unseeded. Asserted as a wide margin rather than against
        // a fixed tick, so the fixture's liquidity can be retuned without silently weakening it.
        // Sized so the seed alone can absorb the order: seeded, it never reaches the island;
        // unseeded, the identical order free-runs across the empty region into it.
        assertGt(seededTick, ISLAND_UPPER, "seeded: the order is absorbed before the island");
        assertLe(unseededTick, ISLAND_UPPER, "unseeded: the order free-runs into the island");
    }

    function _tickOf(PoolId id) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }
}
