// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @dev Two configured, actively-swapped pools on ONE hook instance: poolData and poolConfig
///      must be fully isolated per poolId. The whole design assumes this; nothing else
///      exercises it with two live pools.
contract MultiPoolIsolationTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;

    StablePairPoolConfig internal cfg;
    PoolKey internal key2;
    PoolId internal poolId2;

    function setUp() public {
        cfg = new StablePairPoolConfig();
        (, uint160 sp) = setupSimHookAndPool(cfg, false);
        addLiquidity(-2000, 2000, 1_000_000e6, sp, false);

        // Second pool on the SAME hook: same currencies, different tickSpacing => fresh pool id.
        key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing() + 1,
            hooks: IHooks(address(hook))
        });
        poolId2 = key2.toId();
        manager.initialize(key2, TickMath.getSqrtPriceAtTick(0));
        hook.configurePool(
            poolId2,
            cfg.minMinFee(),
            cfg.maxMinFee(),
            cfg.maxFee(),
            cfg.timeDecayLength(),
            cfg.jitLockBlocks(),
            cfg.kPips(),
            cfg.cPips()
        );
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: -2000,
                tickUpper: 2000,
                liquidityDelta: int256(1_000_000e6),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _swap2(bool zeroForOne, int256 amt) internal returns (BeforeSwapEventData memory b) {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amt,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.recordLogs();
        swapRouter.swap(key2, p, ts, ZERO_BYTES);
        b = getBeforeSwapEventData(vm.getRecordedLogs());
    }

    function test_poolStateIsolated_acrossPools() public {
        // build cum on pool 1
        swap(true, -20_000e6, false);
        swap(true, -20_000e6, false);
        (, uint48 ts1,, int256 cum1) = hook.poolData(poolId);
        assertTrue(cum1 != 0, "pool1 must carry a standing cum");

        // pool 2's FIRST swap must price off a zero accumulator — fresh state, no bleed from pool 1
        BeforeSwapEventData memory b2 = _swap2(true, -20_000e6);
        assertEq(b2.decayedCumPriceImpact, 0, "pool2 must start from cum = 0");
        uint256 expectedFee2 = FullMath.mulDiv(b2.priceImpact, cfg.kPips(), 2e6);
        if (expectedFee2 < b2.effectiveMinFee) expectedFee2 = b2.effectiveMinFee;
        if (expectedFee2 > cfg.maxFee()) expectedFee2 = cfg.maxFee();
        assertEq(b2.dynamicFeePips, expectedFee2, "pool2 prices its own impact, not pool1's dynamic fee");
        assertEq(b2.poolId, PoolId.unwrap(poolId2), "event must belong to pool2");

        // pool 1 runtime state untouched by pool 2 activity
        (, uint48 ts1After,, int256 cum1After) = hook.poolData(poolId);
        assertEq(cum1After, cum1, "pool2 swap must not touch pool1 cum");
        assertEq(ts1After, ts1, "pool2 swap must not touch pool1 swap clock");

        // and pool 2 now carries its OWN cum, still not visible to pool 1
        (,,, int256 cum2) = hook.poolData(poolId2);
        assertTrue(cum2 != 0, "pool2 accumulates its own cum");
        assertTrue(cum2 != cum1, "cums evolve independently");
    }
}
