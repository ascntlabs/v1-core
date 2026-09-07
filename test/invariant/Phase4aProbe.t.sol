// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";
import {SimHook} from "../../src/SimHook.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice FEE-14 boundary. `configurePool` rejects maxFee == MAX_LP_FEE (1e6 = 100%) with
///         `FeeTooHigh`, so the largest admissible cap is MAX_LP_FEE - 1 and no swap can carry
///         the 100% override v4-core refuses for exact-output (`Pool.InvalidFeeForExactOut`).
///         On a pool at that cap a large exact-OUTPUT swap makes the fee=0 simulator report
///         ~100% price impact; under midpoint pricing the result is DIRECTION-DEPENDENT: into
///         the standing imbalance the fee quotes 2|cum| + P, clamps to maxFee and the swap
///         executes at 99.9999%; across zero the two-leg fee stays strictly below the cap for
///         any standing |cum| > 0. Both arms pinned so a regression in either surfaces.
contract Phase4aExactOutFeeCapTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;

    PoolSwapTest.TestSettings internal S = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    PoolKey internal k;
    PoolId internal id;
    uint160 internal initSqrtP;

    function _p(bool z, int256 a) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: z,
            amountSpecified: a,
            sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, initSqrtP) = setupSimHookAndPool(cfg, false);
        governance.setProtocolFeeBps(0);
        // fresh pool at the largest admissible cap: maxFee = MAX_LP_FEE - 1
        (k, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 2, initSqrtP);
        hook.configurePool(id, 1, 10, LPFeeLibrary.MAX_LP_FEE - 1, 900, 0, 2e6, 1e6);
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e12, salt: bytes32(0)}), ""
        );
        swapRouter.swap(k, _p(true, -1e9), S, ""); // priming swap builds a standing cum
    }

    /// @notice The cap itself is not configurable: MAX_LP_FEE reverts, MAX_LP_FEE - 1 (the
    ///         value the rest of this contract runs at) is the boundary.
    function test_fee14_configurePool_rejectsMaxLpFee() public {
        (, PoolId id2) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 3, initSqrtP);
        vm.expectRevert(SimHook.FeeTooHigh.selector);
        hook.configurePool(id2, 1, 10, LPFeeLibrary.MAX_LP_FEE, 900, 0, 2e6, 1e6);
    }

    /// @notice DIRECTION-DEPENDENT under midpoint pricing. The priming swap leaves cum < 0, so
    ///         a large exact-out INTO the imbalance (zeroForOne) quotes k x midpoint = 2|cum| + P
    ///         >= P = 1e6: the fee clamps to maxFee = MAX_LP_FEE - 1, a valid exact-output
    ///         override, and the swap executes. AGAINST the imbalance the swap CROSSES zero and
    ///         the two-leg fee C^2/(2P) + 2(P-C)^2/(2P) = 1e6 - 2C + 3C^2/(2e6) sits strictly
    ///         BELOW the cap for any standing C > 0 (endpoint pricing pegged both directions
    ///         via own-P).
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_fee14_largeExactOut_pegsIntoImbalance_nearCapAcrossZero(uint256 outSeed, bool zeroForOne) public {
        uint256 out = _bound(outSeed, 1e11, 5e11); // large relative to the 1e12 range depth

        (,,, int256 cum) = hook.poolData(id);
        uint256 absCum = uint256(-cum); // priming swap was zeroForOne => cum < 0
        assertGt(absCum, 0, "precondition: priming swap must leave a standing imbalance");
        assertLt(absCum, 1e6, "precondition: imbalance well below the impact cap");

        if (zeroForOne) {
            // into the imbalance: 2C + P with P pegged at 1e6 => fee clamps to maxFee < 1e6
            vm.recordLogs();
            swapRouter.swap(k, _p(true, int256(out)), S, ""); // must NOT revert
            BeforeSwapEventData memory b = getBeforeSwapEventData(vm.getRecordedLogs());
            assertEq(uint256(b.dynamicFeePips), uint256(LPFeeLibrary.MAX_LP_FEE - 1), "fee must clamp to maxFee");
        } else {
            // crossing: exact two-leg recompute at P = 1e6 (these sizes run the sim to the
            // price limit, pegging the impact cap; mulDiv floors reproduced exactly — ONE floor
            // per leg, since each leg applies its weight inside a single mulDiv)
            uint256 twoP = 2e6;
            uint256 E = 1e6 - absCum;
            uint256 expected = (absCum * absCum) / twoP + (2 * E * E) / twoP;

            vm.recordLogs();
            swapRouter.swap(k, _p(false, int256(out)), S, ""); // must NOT revert
            BeforeSwapEventData memory b = getBeforeSwapEventData(vm.getRecordedLogs());
            assertEq(b.priceImpact, 1e6, "simulator must peg the impact cap");
            assertEq(uint256(b.dynamicFeePips), expected, "crossing fee must equal the exact two-leg midpoint value");
            assertLt(uint256(b.dynamicFeePips), 1e6, "cap approached, never reached => no InvalidFeeForExactOut");
        }
    }

    /// @notice Normal trading at the cap: a large exact-input (fee clamps at maxFee, ~zero
    ///         output), a small exact-output and the restoring direction all succeed.
    function test_fee14_exactInAndSmallExactOutStillSucceed() public {
        // large exact-input: succeeds even though the fee clamps at maxFee
        swapRouter.swap(k, _p(true, -5e11), S, "");
        // small exact-output: fee well below the cap, succeeds
        swapRouter.swap(k, _p(false, int256(1e7)), S, "");
        // and the pool is still swappable in the restoring direction
        swapRouter.swap(k, _p(false, -1e9), S, "");
    }
}
