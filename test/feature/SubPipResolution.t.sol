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
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @notice KI-14, "Resolution is one pip everywhere" (Vulsight ASCNT-L-02).
///
///         Impact is measured in whole pips: `calculatePriceImpactCapped`'s final `mulDiv`
///         floors, and `_afterSwap` writes that integer straight into `cumPriceImpact` with no
///         fractional remainder retained between swaps. So a swap whose realized move is under
///         one pip books exactly zero, and a run of them walks the price while the meter reads
///         flat.
///
///         This is distinct from KI-14's low-price degradation: the pool here sits at tick 0,
///         far above `MIN_USABLE_SQRT_PRICE`. All that is required is depth — legs small enough
///         relative to `L` that each one individually stays under the threshold.
///
///         Recorded, not fixed. The bound is economic: every dust leg still pays
///         `effectiveMinFee` on its own notional plus per-swap gas, so the cost scales with the
///         number of legs. This test pins both halves — the meter stays at zero, AND every leg
///         paid the floor.
contract SubPipResolutionTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    PoolSwapTest.TestSettings internal S = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    int24 internal constant TS = 7; // config's own pool already occupies tickSpacing 1
    int24 internal constant TL = -63;
    int24 internal constant TU = 63;

    /// @dev Sized so each leg lands JUST under the one-pip threshold rather than orders of
    ///      magnitude below it — that is the case the finding is about, and it makes the
    ///      cumulative unbooked drift material rather than negligible.
    int256 internal constant DEEP_LIQUIDITY = 1e15;
    uint256 internal constant DUST = 25e7; // ~0.5 pip per leg: under the threshold, with margin
    uint256 internal constant LEGS = 20;

    PoolKey internal k;
    PoolId internal id;
    uint24 internal floorFee;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        governance.setProtocolFeeBps(0);

        (k, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TS, initSqrtP);
        hook.configurePool(id, 10, 10, 10_000, 1 hours, 0, 2e6, 1e6);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: DEEP_LIQUIDITY, salt: bytes32(0)}),
            ""
        );
        floorFee = 10; // minMinFee == maxMinFee for this config, so the floor is flat
    }

    function _dustLeg() internal returns (uint256 pips, uint256 impact) {
        vm.recordLogs();
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(DUST),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            S,
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        pips = uint256(getBeforeSwapEventData(logs).dynamicFeePips);
        impact = getAfterSwapEventData(logs).priceImpact;
    }

    /// @notice A run of sub-pip legs drifts the price while the accumulator never leaves zero —
    ///         and every leg pays the floor, which is what bounds the behaviour.
    function test_l02_subPipLegsDriftThePriceWithoutBookingImpact() public {
        (uint160 startSqrtP,,,) = manager.getSlot0(id);

        for (uint256 i = 0; i < LEGS; i++) {
            (uint256 pips, uint256 impact) = _dustLeg();

            assertEq(impact, 0, "each sub-pip leg must floor to zero booked impact");
            assertGe(pips, floorFee, "and must still pay at least effectiveMinFee");

            (,,, int256 cum) = hook.poolData(id);
            assertEq(cum, 0, "the accumulator never leaves zero across the run");
        }

        (uint160 endSqrtP,,,) = manager.getSlot0(id);
        assertLt(endSqrtP, startSqrtP, "the price nonetheless drifted");

        // Materiality: the drift must be worth several pips in aggregate, or this run proves
        // nothing beyond "tiny swaps are tiny". Price moves ~2x the sqrt move, so a relative
        // sqrt drift above 2.5e-6 is more than 5 pips of price — every one of them unbooked.
        uint256 drift = uint256(startSqrtP - endSqrtP);
        assertGt(drift * 400_000, uint256(startSqrtP), "the unbooked drift must exceed ~5 pips");

        (,,, int256 finalCum) = hook.poolData(id);
        assertEq(finalCum, 0, "and the meter still reads exactly zero after all of it");

        console.log("L-02 sqrtPriceX96 start / end:", uint256(startSqrtP), uint256(endSqrtP));
    }

    /// @notice The threshold is the mechanism, not the pool: one leg large enough to clear a
    ///         pip books normally. Pins that the zero above is resolution, not a dead accumulator.
    function test_l02_aboveThresholdTheMeterBooksNormally() public {
        vm.recordLogs();
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(DUST * 20),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            S,
            ""
        );
        uint256 impact = getAfterSwapEventData(vm.getRecordedLogs()).priceImpact;

        assertGt(impact, 0, "a leg above one pip must book impact");
        (,,, int256 cum) = hook.poolData(id);
        assertLt(cum, 0, "and must move the accumulator, signed by direction");
    }
}
