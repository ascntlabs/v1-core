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
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SwapSimulator} from "../../src/lib/SwapSimulator.sol";

/// @notice Asserts `SwapSimulator.simulate` (the single entry point used by
///         `SimHook._beforeSwap`) matches the live engine on both the pre-swap
///         and post-swap `sqrtPriceX96`, under fee=0. Covers both directions ×
///         exact-in / exact-out × random swap sizes. Also pins the simulator's
///         `sqrtPriceBeforeX96` against an independent `StateLibrary.getSlot0`
///         read so the in-loop optimisation is verified.
contract SwapSimulatorTest is Test, ArtifactDeployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    Currency token0;
    Currency token1;

    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 constant TICK_SPACING = 10;
    uint24 constant POOL_FEE = 0; // fee=0 so simulator output equals real result
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

        // Wide base position + spike positions every 50 ticks to populate the bitmap.
        _addPosition(LIQ_LOWER, LIQ_UPPER, LIQ_AMOUNT0);
        for (int24 t = -1000; t <= 1000; t += 50) {
            if (t == 0) continue;
            _addPosition(t, LIQ_UPPER, 1 ether);
        }
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
            ZERO_BYTES
        );
    }

    function _currentSqrtPrice() internal view returns (uint160 sp) {
        (sp,,,) = StateLibrary.getSlot0(manager, poolId);
    }

    /// @dev Builds a SwapParams with MIN/MAX limit (the production-call shape).
    function _simParams(bool zeroForOne, int256 amt) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amt,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _doRealSwap(bool zeroForOne, int256 amt) internal returns (uint160 sqrtAfter) {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(poolKey, _simParams(zeroForOne, amt), ts, ZERO_BYTES);
        sqrtAfter = _currentSqrtPrice();
    }

    /// @dev Shared assertion body for the 4 direction × in/out fuzz tests below.
    ///      Captures slot0 directly, runs the simulator, runs the real swap, and asserts
    ///      that BOTH the simulator's `before` and `after` match the engine's view.
    function _assertSimMatchesReal(bool zeroForOne, int256 amt) internal {
        uint160 directSlot0Before = _currentSqrtPrice();

        SwapSimulator.Result memory r =
            SwapSimulator.simulate(manager, poolId, TICK_SPACING, _simParams(zeroForOne, amt));

        assertEq(r.sqrtPriceBeforeX96, directSlot0Before, "simBefore != direct getSlot0");

        uint160 realAfter = _doRealSwap(zeroForOne, amt);

        assertEq(r.sqrtPriceAfterX96, realAfter, "simAfter != live engine sqrtPriceAfter");
    }

    /// @notice exact-input zeroForOne, varied magnitude
    function testFuzz_exactInZeroForOne_matchesReal(uint128 amount) public {
        amount = uint128(bound(amount, 1e6 + 1, 100 ether - 1));
        _assertSimMatchesReal(true, -int256(uint256(amount)));
    }

    /// @notice exact-input oneForZero, varied magnitude
    function testFuzz_exactInOneForZero_matchesReal(uint128 amount) public {
        amount = uint128(bound(amount, 1e6 + 1, 100 ether - 1));
        _assertSimMatchesReal(false, -int256(uint256(amount)));
    }

    /// @notice exact-output zeroForOne, varied magnitude
    function testFuzz_exactOutZeroForOne_matchesReal(uint128 amount) public {
        vm.assume(amount > 1e6 && amount < 10 ether);
        _assertSimMatchesReal(true, int256(uint256(amount)));
    }

    /// @notice exact-output oneForZero, varied magnitude
    function testFuzz_exactOutOneForZero_matchesReal(uint128 amount) public {
        vm.assume(amount > 1e6 && amount < 10 ether);
        _assertSimMatchesReal(false, int256(uint256(amount)));
    }

    // ----- targeted small-amount cases for tick-bitmap edge behavior -----

    function test_tinySwap_staysInTick() public {
        uint160 before_ = _currentSqrtPrice();
        SwapSimulator.Result memory r =
            SwapSimulator.simulate(manager, poolId, TICK_SPACING, _simParams(true, -int256(uint256(1e10))));
        assertEq(r.sqrtPriceBeforeX96, before_, "tiny swap: simBefore != direct getSlot0");

        uint160 realAfter = _doRealSwap(true, -int256(uint256(1e10)));
        assertEq(r.sqrtPriceAfterX96, realAfter, "tiny swap: simAfter != real");
        assertLt(realAfter, before_, "tiny zeroForOne swap should still move price down");
    }

    function test_largeSwapCrossesManyTicks() public {
        uint160 before_ = _currentSqrtPrice();
        SwapSimulator.Result memory r =
            SwapSimulator.simulate(manager, poolId, TICK_SPACING, _simParams(true, -int256(uint256(10 ether))));
        assertEq(r.sqrtPriceBeforeX96, before_, "large swap: simBefore != direct getSlot0");

        uint160 realAfter = _doRealSwap(true, -int256(uint256(10 ether)));
        assertEq(r.sqrtPriceAfterX96, realAfter, "large swap: simAfter != real");
    }

    // ----- liquidity exhaustion: amount far beyond the pool, price runs to the limit -----
    // Exercises the simulator's empty-bitmap-word walking and MIN/MAX tick clamps — the
    // catastrophic-swap shape the hook exists to price. Divergence here mis-prices it.

    function test_liquidityExhaustion_zeroForOne_matchesReal() public {
        int256 amt = -int256(uint256(1_000_000 ether)); // >> total pool liquidity
        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, poolId, TICK_SPACING, _simParams(true, amt));
        uint160 realAfter = _doRealSwap(true, amt);
        assertEq(r.sqrtPriceAfterX96, realAfter, "exhaustion zeroForOne: simAfter != real");
        assertEq(realAfter, TickMath.MIN_SQRT_PRICE + 1, "engine should run to the price limit");
    }

    function test_liquidityExhaustion_oneForZero_matchesReal() public {
        int256 amt = -int256(uint256(1_000_000 ether));
        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, poolId, TICK_SPACING, _simParams(false, amt));
        uint160 realAfter = _doRealSwap(false, amt);
        assertEq(r.sqrtPriceAfterX96, realAfter, "exhaustion oneForZero: simAfter != real");
        assertEq(realAfter, TickMath.MAX_SQRT_PRICE - 1, "engine should run to the price limit");
    }

    function test_liquidityExhaustion_exactOutput_matchesReal() public {
        // Requesting more output than the pool holds: partial fill at the limit.
        int256 amt = int256(uint256(1_000_000 ether));
        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, poolId, TICK_SPACING, _simParams(true, amt));
        uint160 realAfter = _doRealSwap(true, amt);
        assertEq(r.sqrtPriceAfterX96, realAfter, "exhaustion exact-out: simAfter != real");
    }

    // (the simulator's `before == direct getSlot0` property is asserted inside
    // `_assertSimMatchesReal`, which all four directional fuzzes run through)

    // ----- degenerate input: zero amountSpecified -----

    /// @notice Unreachable via v4 swaps (the manager rejects them) but reachable as a
    ///         library call: a zero-amount simulation must be a clean no-op.
    function test_zeroAmount_isNoOp() public view {
        uint160 before_ = _currentSqrtPrice();
        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, poolId, TICK_SPACING, _simParams(true, 0));
        assertEq(r.sqrtPriceBeforeX96, before_, "zero-amount: before mismatch");
        assertEq(r.sqrtPriceAfterX96, before_, "zero-amount: price must not move");
        assertEq(r.amount0Delta, 0, "zero-amount: no delta0");
        assertEq(r.amount1Delta, 0, "zero-amount: no delta1");
    }

    // ----- Out-of-bounds price limit must terminate as a zero-impact no-op -----
    // PoolManager runs beforeSwap BEFORE Pool.swap validates sqrtPriceLimitX96, so a limit
    // outside (MIN_SQRT_PRICE, MAX_SQRT_PRICE) reaches the simulator unchecked. Without the
    // bounds guard, a liquidity-exhausting amount clamps the walk at MIN/MAX tick where every
    // step is a zero-amount no-op and the loop spins until out-of-gas.

    function _assertOobLimitNoOp(bool zeroForOne, uint160 limit, int256 amt) internal view {
        uint160 before_ = _currentSqrtPrice();
        SwapSimulator.Result memory r = SwapSimulator.simulate(
            manager,
            poolId,
            TICK_SPACING,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: limit})
        );
        assertEq(r.sqrtPriceBeforeX96, before_, "OOB limit: before mismatch");
        assertEq(r.sqrtPriceAfterX96, r.sqrtPriceBeforeX96, "OOB limit: price must not move");
        assertEq(r.amount0Delta, 0, "OOB limit: no delta0");
        assertEq(r.amount1Delta, 0, "OOB limit: no delta1");
    }

    /// @notice zeroForOne with limit <= MIN_SQRT_PRICE at a liquidity-exhausting amount:
    ///         must return zero impact (and, implicitly, terminate).
    function test_oobLimit_zeroForOne_isNoOp() public view {
        int256 amt = -1e30; // >> total pool liquidity: pre-guard, this spun until out-of-gas
        _assertOobLimitNoOp(true, 0, amt); // v3-periphery "no limit" convention
        _assertOobLimitNoOp(true, TickMath.MIN_SQRT_PRICE, amt);
        _assertOobLimitNoOp(true, TickMath.MIN_SQRT_PRICE - 1, amt);
    }

    /// @notice oneForZero with limit >= MAX_SQRT_PRICE: the mirror hang at MAX_TICK.
    function test_oobLimit_oneForZero_isNoOp() public view {
        int256 amt = -1e30;
        _assertOobLimitNoOp(false, type(uint160).max, amt);
        _assertOobLimitNoOp(false, TickMath.MAX_SQRT_PRICE, amt);
        _assertOobLimitNoOp(false, TickMath.MAX_SQRT_PRICE + 1, amt);
    }

    /// @notice exact-output shape hangs the same way pre-guard: remaining can never reach zero
    ///         once liquidity is exhausted.
    function test_oobLimit_exactOutput_isNoOp() public view {
        _assertOobLimitNoOp(true, TickMath.MIN_SQRT_PRICE, 1e30);
        _assertOobLimitNoOp(false, TickMath.MAX_SQRT_PRICE, 1e30);
    }

    // (boundary sanity for the guard's strict comparisons: the liquidity-exhaustion tests
    // above already drive the walk to the tightest LEGAL limits, MIN_SQRT_PRICE + 1 and
    // MAX_SQRT_PRICE - 1, and assert it matches the live engine)
}
