// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SwapSimulator} from "../../src/lib/SwapSimulator.sol";
import {SwapQuoter} from "../utils/SwapQuoter.sol";
import {TestSwapQuoter} from "../utils/TestSwapQuoter.sol";

/// @notice Independent oracle test. Uses `SwapQuoter` (which runs the LIVE
///         engine via swap+revert) as ground truth, and asserts our math-replica
///         `SwapSimulator` matches it on sqrtPriceAfter AND signed token deltas.
///
///         If v4-core's Pool.swap math ever changes vs. our replica, this fuzz catches
///         it — the quoter automatically tracks v4-core, the simulator doesn't.
contract SwapSimulator_QuoterOracle is Test, ArtifactDeployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    Currency token0;
    Currency token1;

    PoolKey internal poolKey;
    PoolId internal poolId;

    TestSwapQuoter internal oracle;

    int24 constant TICK_SPACING = 10;
    uint24 constant POOL_FEE = 0; // fee=0 aligns with simulator's hard-coded fee=0
    int24 constant LIQ_LOWER = -5000;
    int24 constant LIQ_UPPER = 5000;
    uint256 constant LIQ_AMOUNT0 = 1_000 ether;

    function setUp() public {
        deployArtifactManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = currency0;
        token1 = currency1;

        uint160 init = TickMath.getSqrtPriceAtTick(0);
        (poolKey, poolId) = initPool(token0, token1, IHooks(address(0)), POOL_FEE, TICK_SPACING, init);

        _addPosition(LIQ_LOWER, LIQ_UPPER, LIQ_AMOUNT0);
        // Laddered spikes to force initialized-tick crossings on bigger swaps.
        for (int24 t = -1000; t <= 1000; t += 50) {
            if (t == 0) continue;
            _addPosition(t, LIQ_UPPER, 1 ether);
        }

        oracle = new TestSwapQuoter(manager);
    }

    function _addPosition(int24 lower, int24 upper, uint256 amount0) internal {
        uint160 sl = TickMath.getSqrtPriceAtTick(lower);
        uint160 su = TickMath.getSqrtPriceAtTick(upper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sl, su, amount0);
        modifyLiquidityRouter.modifyLiquidity{value: 1}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _runOracle(SwapParams memory params) internal {
        // Our replica
        SwapSimulator.Result memory sim = SwapSimulator.simulate(manager, poolId, TICK_SPACING, params);

        // Friend's quoter — runs real swap, then reverts. Returns signed deltas + sqrtPrice.
        SwapQuoter.SwapQuote memory q = oracle.quote(poolKey, params, "");

        assertEq(sim.sqrtPriceAfterX96, q.finalSqrtPriceX96, "sqrtPrice mismatch");
        assertEq(sim.amount0Delta, q.amount0, "amount0Delta mismatch");
        assertEq(sim.amount1Delta, q.amount1, "amount1Delta mismatch");
    }

    function testFuzz_oracle_exactIn_zeroForOne(uint128 amount) public {
        amount = uint128(bound(amount, 1e6 + 1, 100 ether - 1));
        _runOracle(
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(amount)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function testFuzz_oracle_exactIn_oneForZero(uint128 amount) public {
        amount = uint128(bound(amount, 1e6 + 1, 100 ether - 1));
        _runOracle(
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(amount)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function testFuzz_oracle_exactOut_zeroForOne(uint128 amount) public {
        amount = uint128(bound(amount, 1e6 + 1, 10 ether - 1));
        _runOracle(
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(uint256(amount)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function testFuzz_oracle_exactOut_oneForZero(uint128 amount) public {
        amount = uint128(bound(amount, 1e6 + 1, 10 ether - 1));
        _runOracle(
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(uint256(amount)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    /// @notice Tests that the SwapParams overload (borrow 1) honors a non-MIN/MAX
    ///         sqrtPriceLimitX96 — simulator must clamp at the limit exactly like
    ///         the live engine does.
    function testFuzz_oracle_withPriceLimit(uint128 amount, uint16 limitOffsetTicks) public {
        amount = uint128(bound(amount, 1e6 + 1, 100 ether - 1));
        limitOffsetTicks = uint16(bound(limitOffsetTicks, 2, 499));
        int24 limitTick = -int24(uint24(limitOffsetTicks));
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        _runOracle(SwapParams({zeroForOne: true, amountSpecified: -int256(uint256(amount)), sqrtPriceLimitX96: limit}));
    }

    function testFuzz_oracle_withPriceLimit_oneForZero(uint128 amount, uint16 limitOffsetTicks) public {
        amount = uint128(bound(amount, 1e6 + 1, 100 ether - 1));
        limitOffsetTicks = uint16(bound(limitOffsetTicks, 2, 499));
        int24 limitTick = int24(uint24(limitOffsetTicks)); // oneForZero pushes price UP
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        _runOracle(SwapParams({zeroForOne: false, amountSpecified: -int256(uint256(amount)), sqrtPriceLimitX96: limit}));
    }
}
