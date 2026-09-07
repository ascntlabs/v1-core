// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @notice An out-of-bounds `sqrtPriceLimitX96` must not hang the simulator.
///
/// PoolManager invokes beforeSwap BEFORE Pool.swap validates the price limit, so a limit
/// outside (MIN_SQRT_PRICE, MAX_SQRT_PRICE) — e.g. the v3-periphery convention of passing 0
/// for "no limit" — reached SwapSimulator unchecked. At a liquidity-exhausting amount the
/// walk clamped at MIN/MAX tick, every step became a zero-amount no-op, and the loop spun
/// until out-of-gas (~18.5M measured) where a hookless pool reverts cleanly in ~100-200k.
///
/// With the guard, the simulator no-ops, the hook quotes its minimum fee, and Pool.swap
/// rejects the whole tx with the canonical PriceLimitOutOfBounds — same outcome and same
/// order of gas as the identical malformed swap on a hookless pool.
contract PriceLimitBoundsTest is SimHookUtils {
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    /// @dev Far beyond total pool liquidity: the shape that spun out-of-gas pre-guard.
    ///      State-independent and free for the attacker — the tx reverts before settlement.
    int256 internal constant HUGE_EXACT_IN = -1e30;

    /// @dev Well under the ~18.5M OOG and the block gas limit; comfortably above the
    ///      hook-pool revert (vanilla ~100-200k + hook overhead).
    uint256 internal constant GAS_CEILING = 500_000;

    PoolKey internal vanillaKey; // same currencies, no hook: the gas-parity baseline

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(TICK_LOWER, TICK_UPPER, 1e12, initSqrtP, false);

        // warmup swap stamps the hook's swap clock so the OOB swaps hit steady-state paths
        swap(true, -1e8, false);
        vm.warp(block.timestamp + 60);

        // Hookless static-fee pool on the same currencies. Pool.swap's limit validation runs
        // before any liquidity is touched, so the baseline pool needs none.
        (vanillaKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, cfg.tickSpacing(), initSqrtP);
    }

    function _rawSwap(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint160 limit) internal {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            ts,
            ZERO_BYTES
        );
    }

    /// @dev The hook-pool swap must die on v4-core's own validation — a clean revert with
    ///      the canonical selector, not an out-of-gas.
    function _expectOob(bool zeroForOne, uint160 limit) internal {
        vm.expectPartialRevert(Pool.PriceLimitOutOfBounds.selector);
        _rawSwap(key, zeroForOne, HUGE_EXACT_IN, limit);
    }

    // ---- termination + parity: every out-of-bounds corner reverts with v4's error ----

    function test_oob_zeroForOne_limitZero_reverts() public {
        _expectOob(true, 0); // v3-periphery "no limit" convention
    }

    function test_oob_zeroForOne_limitMinSqrtPrice_reverts() public {
        _expectOob(true, TickMath.MIN_SQRT_PRICE); // exact boundary is invalid in v4 (<=)
    }

    function test_oob_zeroForOne_limitBelowMin_reverts() public {
        _expectOob(true, TickMath.MIN_SQRT_PRICE - 1);
    }

    function test_oob_oneForZero_limitUint160Max_reverts() public {
        _expectOob(false, type(uint160).max);
    }

    function test_oob_oneForZero_limitMaxSqrtPrice_reverts() public {
        _expectOob(false, TickMath.MAX_SQRT_PRICE); // exact boundary is invalid in v4 (>=)
    }

    function test_oob_oneForZero_limitAboveMax_reverts() public {
        _expectOob(false, TickMath.MAX_SQRT_PRICE + 1);
    }

    // ---- gas bound: the hook-pool revert stays in the hookless pool's gas order ----

    function _gasOfRevertingSwap(PoolKey memory k, bool zeroForOne, uint160 limit) internal returns (uint256 used) {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory p =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: HUGE_EXACT_IN, sqrtPriceLimitX96: limit});
        uint256 g0 = gasleft();
        try swapRouter.swap(k, p, ts, ZERO_BYTES) returns (BalanceDelta) {
            revert("OOB swap must revert");
        } catch {
            used = g0 - gasleft();
        }
    }

    function test_oobGas_zeroForOne_boundedLikeHookless() public {
        uint256 hookGas = _gasOfRevertingSwap(key, true, 0);
        uint256 vanillaGas = _gasOfRevertingSwap(vanillaKey, true, 0);
        assertLt(vanillaGas, GAS_CEILING, "baseline sanity: hookless OOB revert is cheap");
        assertLt(hookGas, GAS_CEILING, "hook-pool OOB revert must cost hookless-order gas, not ~18.5M");
    }

    function test_oobGas_oneForZero_boundedLikeHookless() public {
        uint256 hookGas = _gasOfRevertingSwap(key, false, type(uint160).max);
        uint256 vanillaGas = _gasOfRevertingSwap(vanillaKey, false, type(uint160).max);
        assertLt(vanillaGas, GAS_CEILING, "baseline sanity: hookless OOB revert is cheap");
        assertLt(hookGas, GAS_CEILING, "hook-pool OOB revert must cost hookless-order gas, not ~18.5M");
    }

    // ---- boundary sanity: the tightest LEGAL limits still swap normally ----
    // v4 rejects the exact MIN/MAX values, so MIN+1 / MAX-1 are the closest valid limits;
    // the guard's <= / >= comparisons must not clip them.

    function test_validBoundaryLimit_zeroForOne_swapsNormally() public {
        (uint160 before_,,,) = StateLibrary.getSlot0(manager, poolId);
        _rawSwap(key, true, -1e8, TickMath.MIN_SQRT_PRICE + 1);
        (uint160 after_,,,) = StateLibrary.getSlot0(manager, poolId);
        assertLt(after_, before_, "valid boundary limit: swap must execute and move price down");
    }

    function test_validBoundaryLimit_oneForZero_swapsNormally() public {
        (uint160 before_,,,) = StateLibrary.getSlot0(manager, poolId);
        _rawSwap(key, false, -1e8, TickMath.MAX_SQRT_PRICE - 1);
        (uint160 after_,,,) = StateLibrary.getSlot0(manager, poolId);
        assertGt(after_, before_, "valid boundary limit: swap must execute and move price up");
    }
}
