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

/// @notice Vulsight ASCNT-L-01, both effects. Recorded in KI-15 and `docs/invariants.md` #9.
///
///         `SwapSimulator` runs at fee = 0, so a quote is taken from a longer price path than
///         the real fee-bearing swap reaches, while `_afterSwap` books the realized move.
///         Nothing reconciles the two, and same-block decay is the identity.
///
///         EFFECT 1 — same-block tranches beat the one-shot quote even under UNIFORM liquidity.
///         Deliberately isolated from KI-15's amount-space divergence: this pool has one wide
///         range, so impact is proportional to notional along the whole path and the curvature
///         argument in `SplitAdditivity.t.sol` cannot apply. Whatever divergence remains here
///         comes from the quote/execution mismatch alone.
///
///         EFFECT 2 — the simulator's exact-input over-estimate is conservative in IMPACT units
///         but anti-conservative in FEE terms on the non-crossing corrective branch, where the
///         midpoint sum is 2C - p and the fee c*(C - p/2) is DECREASING in p. Overstating p
///         there makes the quote cheaper, not dearer.
contract QuoteVsExecutionTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    PoolSwapTest.TestSettings internal S = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    int24 internal constant TS = 11; // the config's own pool holds tickSpacing 1
    int24 internal constant TL = -8800;
    int24 internal constant TU = 8800;
    int256 internal constant UNIFORM_LIQUIDITY = 1e14;

    uint32 internal constant C_PIPS = 1e6; // 1.0x weight on the corrective branch

    PoolKey internal k;
    PoolId internal id;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        governance.setProtocolFeeBps(0);

        (k, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TS, initSqrtP);
        // maxFee high enough that nothing below clamps; kPips 2.0x, cPips 1.0x as shipped
        hook.configurePool(id, 1, 1, 500_000, 1 hours, 0, 2e6, C_PIPS);

        // ONE wide range: constant L along every path these tests take
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: UNIFORM_LIQUIDITY, salt: bytes32(0)}),
            ""
        );
    }

    struct Leg {
        uint256 pips;
        uint256 simImpact;
        uint256 realizedImpact;
        int256 standingCum;
    }

    function _leg(bool zeroForOne, uint256 amountIn) internal returns (Leg memory L) {
        vm.recordLogs();
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            S,
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);
        L.pips = uint256(b.dynamicFeePips);
        L.simImpact = b.priceImpact;
        L.standingCum = b.decayedCumPriceImpact;
        L.realizedImpact = getAfterSwapEventData(logs).priceImpact;
    }

    // ------ Effect 1 ------

    /// @notice Uniform liquidity, exact-input: the same gross notional sent as two same-block
    ///         tranches is quoted below the one-shot. Asserted as a direction plus a bound, not
    ///         as an equality against a closed form — the (1 - f/2) shape is an approximation and
    ///         an equality assertion on it would be flaky.
    function test_l01_sameBlockTranchesBeatTheOneShotUnderUniformLiquidity() public {
        uint256 amount = 2e11;

        uint256 t0 = vm.getBlockTimestamp();
        uint256 snap = vm.snapshotState();

        Leg memory one = _leg(true, amount);
        uint256 oneShotFee = amount * one.pips / 1e6;

        vm.revertToState(snap);
        vm.warp(t0); // same block: decay is the identity, so nothing washes the gap out

        Leg memory a = _leg(true, amount / 2);
        Leg memory b = _leg(true, amount - amount / 2);
        uint256 splitFee = (amount / 2) * a.pips / 1e6 + (amount - amount / 2) * b.pips / 1e6;

        assertEq(a.standingCum, int256(0), "precondition: the split starts from a clean meter");
        assertLt(one.pips, 500_000, "precondition: the one-shot quote is not clamped");
        assertLt(b.pips, 500_000, "precondition: no split leg is clamped");
        assertGt(one.simImpact, 0, "precondition: the swap moves the price materially");

        assertLt(splitFee, oneShotFee, "L-01: same-block tranches must come in under the one-shot");
        // the gap is bounded by the fee itself — it cannot exceed the one-shot total
        assertGt(splitFee * 2, oneShotFee, "L-01: and the gap is a fraction, not an order of magnitude");

        console.log("L-01 effect 1  one-shot fee / split fee:", oneShotFee, splitFee);
    }

    // ------ Effect 2 ------

    /// @notice On the non-crossing corrective branch the simulator overstates the impact (safe in
    ///         impact units) and that makes the QUOTE CHEAPER, because the branch prices
    ///         c*(C - p/2). Pins both halves: the over-estimate exists, and it moves the fee the
    ///         wrong way.
    function test_l01_correctiveBranchOverEstimateMakesTheQuoteCheaper() public {
        // build a standing imbalance
        _leg(true, 2e11);

        // Corrective leg sized as large as it can be WITHOUT crossing zero. Size matters here:
        // the sim/realized gap is the charged fee times the impact, so a small heal makes the
        // gap a pip or two and the branch's `/2` rounds the two candidate fees onto the same
        // integer — the effect would be real but invisible.
        Leg memory heal = _leg(false, 16e10);

        int256 cumAbs = heal.standingCum < 0 ? -heal.standingCum : heal.standingCum;
        assertGt(cumAbs, 0, "precondition: a standing imbalance exists");
        assertLt(int256(heal.simImpact), cumAbs, "precondition: the heal does not cross zero");

        // impact conservatism: the fee-free replay travels further than the real swap
        assertGt(heal.simImpact, heal.realizedImpact, "the exact-input replay must overstate impact");

        // fee anti-conservatism: this branch charges c * (2C - p) / 2, decreasing in p, so the
        // quote taken on the overstated p sits BELOW the one the realized move would have priced
        uint256 quoted = uint256(C_PIPS) * (2 * uint256(cumAbs) - heal.simImpact) / (2 * 1e6);
        uint256 onRealized = uint256(C_PIPS) * (2 * uint256(cumAbs) - heal.realizedImpact) / (2 * 1e6);

        assertEq(heal.pips, quoted, "the quote is c * midpoint(C, C - p_sim)");
        assertLt(quoted, onRealized, "L-01: impact conservatism inverts into a cheaper fee here");

        console.log("L-01 effect 2  sim / realized impact:", heal.simImpact, heal.realizedImpact);
        console.log("L-01 effect 2  quoted / on-realized pips:", quoted, onRealized);
    }
}
