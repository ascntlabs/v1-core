// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title  SwapSimulator
/// @notice Read-only computation of a hypothetical swap's effect on a v4 pool.
///         Returns pre-/post-swap `sqrtPriceX96` and signed amount deltas. Never
///         mutates state.
/// @dev    Simulates at **fee = 0**, so this is not the swap v4 will execute. Exact-output is
///         exact (fee-independent path); exact-input over-estimates impact by ~fee/1e6, and
///         unboundedly so past the book's capacity — KI-1. The over-estimate is conservative in
///         impact units only; on the corrective branch it makes the quote cheaper — #9.
///
/// @dev    ATTRIBUTION / UPSTREAM PROVENANCE.
///         The step primitives are Uniswap v4-core, MIT licence, Copyright (c) Uniswap Labs,
///         used unmodified via import: `SwapMath.computeSwapStep`, `SwapMath.getSqrtPriceTarget`,
///         `TickMath`, `LiquidityMath`, `BitMath`, `TickBitmap`, `StateLibrary`.
///         `_nextInitializedTickWithinOneWord` is adapted from v4-core
///         `src/libraries/TickBitmap.sol` (MIT), changed only to read the bitmap through
///         `StateLibrary` (extsload) rather than from local storage.
///
///         `_simulate` follows the tick-traversal of v4-core's `Pool.swap`, which is
///         **BUSL-1.1**, not MIT — converting on its Change Date (2027-06-15, or earlier per
///         `v4-core-license-date.uniswap.eth`). The correspondence is a correctness
///         requirement: re-verify against the live engine on every upstream change.
library SwapSimulator {
    using StateLibrary for IPoolManager;

    /// @notice Simulation result. Sign convention on deltas matches v4 `BalanceDelta`:
    ///         negative = swapper pays the pool, positive = swapper receives.
    struct Result {
        uint160 sqrtPriceBeforeX96;
        uint160 sqrtPriceAfterX96;
        int256 amount0Delta;
        int256 amount1Delta;
    }

    /// @notice Run the simulation. Honors `params.sqrtPriceLimitX96`.
    function simulate(
        IPoolManager manager,
        PoolId poolId,
        int24 tickSpacing,
        SwapParams memory params
    ) internal view returns (Result memory result) {
        result = _simulate(
            manager, poolId, tickSpacing, params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96
        );
    }

    /// @dev Per-step scratch, kept in memory (stack-too-deep as locals).
    struct _Step {
        uint160 sqrtPriceNext;
        uint160 sqrtAfterStep;
        int24 tickNext;
        bool initialized;
        uint256 amountIn;
        uint256 amountOut;
    }

    /// @dev Iterates `SwapMath.computeSwapStep` at `feePips = 0` until the amount is consumed
    ///      or the limit is reached.
    function _simulate(
        IPoolManager manager,
        PoolId poolId,
        int24 tickSpacing,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) private view returns (Result memory result) {
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(poolId);
        result.sqrtPriceBeforeX96 = sqrtP;

        // backstop for direct library use; PoolManager.swap rejects zero amounts first
        if (amountSpecified == 0) {
            result.sqrtPriceAfterX96 = sqrtP;
            return result;
        }

        // already past the limit: Pool.swap will revert, so skip the walk
        if (zeroForOne ? sqrtPriceLimitX96 >= sqrtP : sqrtPriceLimitX96 <= sqrtP) {
            result.sqrtPriceAfterX96 = sqrtP;
            return result;
        }

        /// @dev Out-of-bounds limit: the walk would spin to out-of-gas. Return zero impact
        ///      rather than revert — `Pool.swap` re-checks this right after the hook returns and
        ///      reverts canonically, so the quote is never consequential.
        if (zeroForOne ? sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE : sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
            result.sqrtPriceAfterX96 = sqrtP;
            return result;
        }

        uint128 liquidity = manager.getLiquidity(poolId);

        int256 remaining = amountSpecified;
        //   exact input:  tracks total amountOut as it accrues (signed at return)
        //   exact output: tracks total amountIn as it accrues
        uint256 amountOtherSide = 0;

        _Step memory step;
        while (remaining != 0 && sqrtP != sqrtPriceLimitX96) {
            (step.tickNext, step.initialized) =
                _nextInitializedTickWithinOneWord(manager, poolId, tick, tickSpacing, zeroForOne);

            if (step.tickNext <= TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
            if (step.tickNext >= TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;

            step.sqrtPriceNext = TickMath.getSqrtPriceAtTick(step.tickNext);

            (step.sqrtAfterStep, step.amountIn, step.amountOut,) = SwapMath.computeSwapStep(
                sqrtP,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNext, sqrtPriceLimitX96),
                liquidity,
                remaining,
                0
            );

            unchecked {
                if (amountSpecified < 0) {
                    // exact input: remaining (negative) trends to zero; track output
                    remaining += int256(step.amountIn);
                    amountOtherSide += step.amountOut;
                } else {
                    // exact output: remaining (positive) trends to zero; track input
                    remaining -= int256(step.amountOut);
                    amountOtherSide += step.amountIn;
                }
            }

            if (step.sqrtAfterStep == step.sqrtPriceNext) {
                if (step.initialized) {
                    (, int128 liquidityNet) = manager.getTickLiquidity(poolId, step.tickNext);
                    // net is recorded for upward traversal; downward applies its opposite.
                    // v4 rejects int128.min as a net value, so the negation cannot overflow.
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }
                    liquidity = LiquidityMath.addDelta(liquidity, liquidityNet);
                }
                unchecked {
                    tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (step.sqrtAfterStep != sqrtP) {
                tick = TickMath.getTickAtSqrtPrice(step.sqrtAfterStep);
            }

            sqrtP = step.sqrtAfterStep;
        }

        result.sqrtPriceAfterX96 = sqrtP;

        int256 specifiedConsumed;
        unchecked {
            specifiedConsumed = amountSpecified - remaining;
        }
        if (zeroForOne) {
            if (amountSpecified < 0) {
                result.amount0Delta = specifiedConsumed;
                result.amount1Delta = int256(amountOtherSide);
            } else {
                result.amount1Delta = specifiedConsumed;
                result.amount0Delta = -int256(amountOtherSide);
            }
        } else {
            if (amountSpecified < 0) {
                result.amount1Delta = specifiedConsumed;
                result.amount0Delta = int256(amountOtherSide);
            } else {
                result.amount0Delta = specifiedConsumed;
                result.amount1Delta = -int256(amountOtherSide);
            }
        }
    }

    /// @dev Port of v4-core `TickBitmap.nextInitializedTickWithinOneWord`, reading through
    ///      `StateLibrary` instead of local storage. Must track upstream.
    function _nextInitializedTickWithinOneWord(
        IPoolManager manager,
        PoolId poolId,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) private view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = manager.getTickBitmap(poolId, wordPos) & mask;

                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = manager.getTickBitmap(poolId, wordPos) & mask;

                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}
