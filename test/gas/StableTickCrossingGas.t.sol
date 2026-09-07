// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SwapSimulator} from "../../src/lib/SwapSimulator.sol";

/// @notice Measures the per-initialized-tick-crossing gas cost on a vanilla v4
///         stable-pool-style configuration (tickSpacing=10, init tick=0, low fee).
///
///         Two scenarios per pool kind:
///         (A) Wide single position — swap walks bitmap WORDS but crosses no initialized ticks.
///             Establishes baseline: cost of "swap step + 1 bitmap SLOAD, no cross".
///         (B) Laddered positions — initialized ticks at every multiple of tickSpacing
///             below the start. Each step of the swap crosses an initialized tick.
///             Difference vs. (A) gives the per-crossing cost.
contract StableTickCrossingGas is Test, ArtifactDeployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    Currency token0;
    Currency token1;

    int24 constant TICK_SPACING = 10;
    uint24 constant POOL_FEE = 100; // 0.01% — typical stable
    int24 constant LADDER_LO = -500;
    int24 constant WIDE_LO = -10_000; // wide enough that the swap stays inside the word
    int24 constant HI = 10_000;
    uint256 constant BASE_LIQ = 100 ether; // bulk liquidity
    uint256 constant SPIKE_LIQ = 0.1 ether; // thin "spike" position per tick boundary

    uint24 poolNonce;

    function setUp() public {
        deployArtifactManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = currency0;
        token1 = currency1;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Pool builders
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Initialize a fresh pool with a varying fee so PoolKey is unique each call.
    function _newPool() internal returns (PoolKey memory key, PoolId id) {
        poolNonce++;
        uint24 fee = POOL_FEE + poolNonce;
        uint160 init = TickMath.getSqrtPriceAtTick(0);
        (key, id) = initPool(token0, token1, IHooks(address(0)), fee, TICK_SPACING, init);
    }

    function _addPosition(PoolKey memory key, int24 lower, int24 upper, uint256 amount0) internal {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount0);
        modifyLiquidityRouter.modifyLiquidity{value: 1}(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /// @dev Single wide position. No initialized ticks inside swap range.
    function _buildWidePool() internal returns (PoolKey memory key, PoolId id) {
        (key, id) = _newPool();
        _addPosition(key, WIDE_LO, HI, BASE_LIQ);
    }

    /// @dev Wide base position + thin "spike" positions whose LOWER tick is at
    ///      every multiple of TICK_SPACING down to LADDER_LO. Each thin position
    ///      shares upper = HI (already initialized by base) so only the lower
    ///      ticks get freshly initialized in the bitmap.
    function _buildLadderedPool() internal returns (PoolKey memory key, PoolId id) {
        (key, id) = _newPool();
        _addPosition(key, WIDE_LO, HI, BASE_LIQ);
        // Thin spike positions: lower at -10, -20, -30, ..., LADDER_LO.
        // Each lower tick becomes an initialized tick the swap will cross.
        for (int24 t = -TICK_SPACING; t >= LADDER_LO; t -= TICK_SPACING) {
            _addPosition(key, t, HI, SPIKE_LIQ);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Swap helper
    // ────────────────────────────────────────────────────────────────────────

    function _swap(PoolKey memory key, int256 amountSpecified) internal returns (uint256 gasUsed) {
        SwapParams memory p = SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        uint256 g0 = gasleft();
        swapRouter.swap(key, p, ts, ZERO_BYTES);
        gasUsed = g0 - gasleft();
    }

    function _curTick(PoolId id) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(manager, id);
    }

    function _abs(int24 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(uint24(x)) : uint256(uint24(-x));
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Main: gas vs. ticks crossed, both pool kinds
    // ────────────────────────────────────────────────────────────────────────

    function test_gasVsTicksCrossed() public {
        // Swap sizes calibrated to produce 0/1/few/many tick movement on these
        // concentrated pools. Same array used on both pool kinds.
        int256[6] memory swapAmounts = [
            int256(-0.001 ether),
            int256(-0.01 ether),
            int256(-0.05 ether),
            int256(-0.2 ether),
            int256(-1 ether),
            int256(-5 ether)
        ];

        console.log("");
        console.log("===========================================================================");
        console.log(" SCENARIO A: WIDE SINGLE POSITION");
        console.log(" Only ticks initialized: WIDE_LO, HI. Swap should cross 0 of them.");
        console.log(" Measures baseline = (slot0 SLOAD) + (1+ bitmap SLOADs) + (SwapMath) + writes.");
        console.log("===========================================================================");
        for (uint256 i = 0; i < swapAmounts.length; i++) {
            (PoolKey memory key, PoolId id) = _buildWidePool();
            // pre-warm slot0 + feeGrowthGlobal so we don't pay first-ever-touch costs
            _swap(key, int256(-100));
            int24 preTick = _curTick(id);
            uint256 gas = _swap(key, swapAmounts[i]);
            int24 postTick = _curTick(id);
            uint256 tickDelta = _abs(postTick - preTick);
            console.log("  swap_wei =", uint256(-swapAmounts[i]));
            console.log("    pre_tick  =", int256(preTick));
            console.log("    post_tick =", int256(postTick));
            console.log("    tick_delta =", tickDelta);
            console.log("    gas       =", gas);
        }

        console.log("");
        console.log("===========================================================================");
        console.log(" SCENARIO B: LADDERED POSITIONS (initialized tick every 10)");
        console.log(" Each step crosses an initialized tick (incl. crossTick SLOAD + liq update).");
        console.log("===========================================================================");
        for (uint256 i = 0; i < swapAmounts.length; i++) {
            (PoolKey memory key, PoolId id) = _buildLadderedPool();
            _swap(key, int256(-100));
            int24 preTick = _curTick(id);
            uint256 gas = _swap(key, swapAmounts[i]);
            int24 postTick = _curTick(id);
            uint256 tickDelta = _abs(postTick - preTick);
            uint256 ticksCrossed = tickDelta / uint256(uint24(TICK_SPACING));
            // Pin each rung so a regression in the tick-crossing path is a snapshot diff, not a
            // console number nobody re-reads.
            assertGt(gas, 0, "laddered swap must consume gas");
            vm.snapshotValue(
                string.concat("tickCrossing laddered: swap_wei=", vm.toString(uint256(-swapAmounts[i]))), gas
            );
            console.log("  swap_wei =", uint256(-swapAmounts[i]));
            console.log("    pre_tick    =", int256(preTick));
            console.log("    post_tick   =", int256(postTick));
            console.log("    tick_delta  =", tickDelta);
            console.log("    ticks_crossed (init) =", ticksCrossed);
            console.log("    gas         =", gas);
        }

        console.log("");
        console.log(" The per-tick-crossing cost is (gas_B[i] - gas_A[i_with_similar_tickDelta]) / ticks_crossed.");
        console.log(" Eyeball A's gas as the floor; subtract from B's gas for similar tick-delta rows.");
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Simulator marginal overhead
    //
    //  For each swap amount we measure THREE numbers:
    //   (1) sim COLD  — simulator called once, after pool warmup but before any
    //                   call has read this swap's tick/bitmap slots. Captures
    //                   the cold SLOAD cost the simulator pays the first time.
    //   (2) sim WARM  — simulator called again immediately after (1). Same
    //                   reads, now warm. Captures the pure compute cost.
    //   (3) swap GAS  — the actual `poolManager.swap` that follows. Its SLOADs
    //                   are now warm thanks to (1), so it pays only ~100/SLOAD.
    //
    //  The NET production overhead of adding simulation in beforeSwap ≈
    //    sim COLD - (cold-SLOAD savings the real swap picks up because slots
    //               are warm). For 0-crossing stable swaps this nets to ~math
    //               cost only.
    // ────────────────────────────────────────────────────────────────────────

    function _measureSim(PoolId id, int256 amt) internal view returns (uint256 used) {
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: amt, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        uint256 g0 = gasleft();
        SwapSimulator.simulate(manager, id, TICK_SPACING, p);
        used = g0 - gasleft();
    }

    function test_simulatorMarginalOverhead() public {
        int256[4] memory swapAmounts = [
            int256(-0.001 ether), // tiny
            int256(-0.05 ether), // moderate
            int256(-0.2 ether), // medium
            int256(-1 ether) // large
        ];

        console.log("");
        console.log("===========================================================================");
        console.log(" SIMULATOR MARGINAL OVERHEAD - SCENARIO A (wide pool, 0 init crossings)");
        console.log("===========================================================================");
        for (uint256 i = 0; i < swapAmounts.length; i++) {
            (PoolKey memory key, PoolId id) = _buildWidePool();
            _swap(key, int256(-100)); // warmup so slot0 + global slots are warm

            uint256 simCold = _measureSim(id, swapAmounts[i]);
            uint256 simWarm = _measureSim(id, swapAmounts[i]);

            int24 preTick = _curTick(id);
            uint256 swapGas = _swap(key, swapAmounts[i]);
            int24 postTick = _curTick(id);

            console.log("  swap_wei =", uint256(-swapAmounts[i]));
            console.log("    pre_tick =", int256(preTick));
            console.log("    post_tick =", int256(postTick));
            console.log("    tick_delta =", _abs(postTick - preTick));
            console.log("    sim COLD gas =", simCold);
            console.log("    sim WARM gas =", simWarm);
            console.log("    real swap gas (slots warmed by sim) =", swapGas);
        }

        console.log("");
        console.log("===========================================================================");
        console.log(" SIMULATOR MARGINAL OVERHEAD - SCENARIO B (laddered, init tick every 10)");
        console.log("===========================================================================");
        for (uint256 i = 0; i < swapAmounts.length; i++) {
            (PoolKey memory key, PoolId id) = _buildLadderedPool();
            _swap(key, int256(-100));

            uint256 simCold = _measureSim(id, swapAmounts[i]);
            uint256 simWarm = _measureSim(id, swapAmounts[i]);

            int24 preTick = _curTick(id);
            uint256 swapGas = _swap(key, swapAmounts[i]);
            int24 postTick = _curTick(id);
            uint256 tickDelta = _abs(postTick - preTick);
            uint256 ticksCrossed = tickDelta / uint256(uint24(TICK_SPACING));

            console.log("  swap_wei =", uint256(-swapAmounts[i]));
            console.log("    pre_tick =", int256(preTick));
            console.log("    post_tick =", int256(postTick));
            console.log("    tick_delta =", tickDelta);
            console.log("    ticks_crossed (init) =", ticksCrossed);
            console.log("    sim COLD gas =", simCold);
            console.log("    sim WARM gas =", simWarm);
            console.log("    real swap gas (slots warmed by sim) =", swapGas);
        }

        console.log("");
        console.log(" sim WARM is the pure compute cost (no cold SLOADs).");
        console.log(" sim COLD - sim WARM ~= cold SLOAD cost the simulator pays.");
        console.log(" In production: simulator runs first (pays cold), real swap follows (now warm).");
        console.log(" Net cost vs vanilla-no-hook ~= sim COLD - cold-SLOAD savings the real swap captures.");
    }
}
