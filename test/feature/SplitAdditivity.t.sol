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

/// @notice KI-15 characterization: the midpoint fee is additive in IMPACT units, not in fee
///         totals. These tests are not bug demonstrations — they pin the documented behaviour
///         so it cannot change silently, and so the direction of the error is on record.
///
/// The algebra, for a downward exact-input swap of notional `A` split into legs `a1 + a2` with
/// impacts `p1 + p2 = P`:
///
///     one-shot  = (k/2) · A · P
///     split     = (k/2) · [a1·p1 + a2·(p1 + P)]
///     split − one-shot = (k/2) · [p1·A − a1·P]
///
/// so `split < one-shot  ⟺  p1/P < a1/A` — splitting is cheaper exactly when the first leg's
/// share of the *impact* is below its share of the *notional*. With equal-notional halves that
/// reduces to `p1 < P/2`:
///
///   CONVEX  (dense at spot, thin beyond): the first half of the notional buys little price
///           movement, so p1 < P/2 and the split total lands BELOW the one-shot.
///   CONCAVE (thin at spot, dense beyond): the first half moves price a lot, so p1 > P/2 and
///           the split total lands ABOVE the one-shot.
///
/// A fee-optimising router takes whichever is cheaper, so in practice the pool sees
/// min(one-shot, best split) — recorded in KI-15 rather than argued away.
///
/// Method follows `Phase3_Xsub4_BpsCoupling`: one pool, two runs from a byte-identical
/// pre-state via snapshotState / revertToState, so the two runs differ only in how the order
/// was chopped up.
contract SplitAdditivityTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    PoolSwapTest.TestSettings internal S = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    // both spacings accept every tick below (all multiples of 30)
    int24 internal constant TS_CONVEX = 10;
    int24 internal constant TS_CONCAVE = 30;

    int24 internal constant INNER_LOWER = -60;
    int24 internal constant INNER_UPPER = 60;
    int24 internal constant OUTER_LOWER = -6000;

    int128 internal constant DEEP = 1e13;
    int128 internal constant THIN = 1e12;

    PoolKey internal convexKey;
    PoolId internal convexId;
    PoolKey internal concaveKey;
    PoolId internal concaveId;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        governance.setProtocolFeeBps(0);

        (convexKey, convexId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TS_CONVEX, initSqrtP);
        (concaveKey, concaveId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TS_CONCAVE, initSqrtP);

        // maxFee high enough that nothing below clamps — a clamped quote would make both runs
        // trivially equal and the comparison meaningless (the "clamp slack" caveat in #3).
        hook.configurePool(convexId, 1, 1, 500_000, 1 hours, 0, 2e6, 1e6);
        hook.configurePool(concaveId, 1, 1, 500_000, 1 hours, 0, 2e6, 1e6);

        // convex: dense at spot, thin beyond
        _add(convexKey, INNER_LOWER, INNER_UPPER, DEEP);
        _add(convexKey, OUTER_LOWER, INNER_LOWER, THIN);

        // concave: thin at spot, dense beyond
        _add(concaveKey, INNER_LOWER, INNER_UPPER, THIN);
        _add(concaveKey, OUTER_LOWER, INNER_LOWER, DEEP);
    }

    // ------ helpers ------

    function _add(PoolKey memory k, int24 lower, int24 upper, int128 liq) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(liq), salt: bytes32(0)}),
            ""
        );
    }

    /// @dev one downward exact-input leg; returns the quoted rate and the impact it booked
    function _leg(PoolKey memory k, uint256 amountIn) internal returns (uint256 pips, uint256 impact) {
        vm.recordLogs();
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            S,
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        pips = uint256(getBeforeSwapEventData(logs).dynamicFeePips);
        impact = getAfterSwapEventData(logs).priceImpact;
    }

    /// @dev The two runs do NOT land on the same terminal accumulator, and this pins why.
    ///      Midpoint additivity is a property of the accumulator traversal over a GIVEN price
    ///      path. Fee-bearing execution means the two runs do not take the same path: the
    ///      cheaper route surrenders less of its notional to fees, so more of it reaches the
    ///      curve and the price travels further, booking MORE impact. So the terminal
    ///      accumulator moves with the fee total, in the opposite direction — the cheaper route
    ///      ends with the larger |cum|. (L-01 Effect 1; KI-15.)
    ///
    ///      Two smaller effects run alongside and are not separated here:
    ///      `calculatePriceImpactCapped` is an endpoint reading against the geometric mean
    ///      rather than an additive route coordinate, and each leg's quote comes from a fee-free
    ///      replay while state advances by the realized move.
    function _assertCheaperRouteTravelsFurther(uint256 feeA, int256 cumA, uint256 feeB, int256 cumB) internal pure {
        int256 magA = cumA < 0 ? -cumA : cumA;
        int256 magB = cumB < 0 ? -cumB : cumB;
        if (feeA < feeB) {
            require(magA >= magB, "the cheaper route must not book less impact");
        } else if (feeB < feeA) {
            require(magB >= magA, "the cheaper route must not book less impact");
        }
    }

    function _tick(PoolId id) internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _cum(PoolId id) internal view returns (int256 c) {
        (,,, c) = hook.poolData(id);
    }

    /// @dev Runs one-shot then, from a byte-identical pre-state, the same notional as two equal
    ///      same-block halves. Returns both fee totals in input-token units and both terminal
    ///      accumulators. Fee is rate x notional: for an exact-input leg that is fully consumed,
    ///      the notional v4 charges on IS the specified amount.
    function _compare(
        PoolKey memory k,
        PoolId id,
        uint256 amount
    )
        internal
        returns (uint256 oneShotFee, uint256 splitFee, int256 cumOneShot, int256 cumSplit, uint256 p1, uint256 pTotal)
    {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 snap = vm.snapshotState();

        (uint256 pipsOne, uint256 impactOne) = _leg(k, amount);
        oneShotFee = amount * pipsOne / 1e6;
        cumOneShot = _cum(id);
        pTotal = impactOne;
        int24 endTick = _tick(id);

        vm.revertToState(snap);
        vm.warp(t0);

        (uint256 pipsA, uint256 impactA) = _leg(k, amount / 2);
        (uint256 pipsB,) = _leg(k, amount - amount / 2);
        splitFee = (amount / 2) * pipsA / 1e6 + (amount - amount / 2) * pipsB / 1e6;
        cumSplit = _cum(id);
        p1 = impactA;

        // preconditions: the swap must actually cross out of the inner band, or the pool is
        // uniform along the path and there is nothing to characterize.
        assertLt(endTick, INNER_LOWER, "precondition: the one-shot must leave the inner band");
        assertGt(endTick, OUTER_LOWER, "precondition: and must not exhaust the outer band");
        assertLt(pipsOne, 500_000, "precondition: the quote must not be clamped at maxFee");
        assertLt(pipsB, 500_000, "precondition: no split leg may be clamped either");
    }

    // ------ the two directions ------

    /// @notice Dense at spot, thin beyond: the split total lands below the one-shot.
    function test_ki15_convexProfile_splitPaysLess() public {
        (uint256 oneShot, uint256 split, int256 cumOne, int256 cumSplit, uint256 p1, uint256 pTotal) =
            _compare(convexKey, convexId, 6e10);

        assertLt(p1 * 2, pTotal, "convex: the first half of the notional causes under half the impact");
        assertLt(split, oneShot, "convex: splitting must pay strictly less");
        // quantification for the audit notes
        console.log("KI-15 convex  one-shot fee / split fee:", oneShot, split);
        console.log("KI-15 convex  |cum| one-shot / split:", uint256(-cumOne), uint256(-cumSplit));
        _assertCheaperRouteTravelsFurther(oneShot, cumOne, split, cumSplit);
    }

    /// @notice Thin at spot, dense beyond: the split total lands above the one-shot. This is the
    ///         half that makes the error two-sided, and the reason KI-15 does not claim the
    ///         one-shot is uniformly an overcharge.
    function test_ki15_concaveProfile_splitPaysMore() public {
        (uint256 oneShot, uint256 split, int256 cumOne, int256 cumSplit, uint256 p1, uint256 pTotal) =
            _compare(concaveKey, concaveId, 1e10);

        assertGt(p1 * 2, pTotal, "concave: the first half of the notional causes over half the impact");
        assertGt(split, oneShot, "concave: splitting must pay strictly more");
        console.log("KI-15 concave one-shot fee / split fee:", oneShot, split);
        console.log("KI-15 concave |cum| one-shot / split:", uint256(-cumOne), uint256(-cumSplit));
        _assertCheaperRouteTravelsFurther(oneShot, cumOne, split, cumSplit);
    }

    /// @notice Whatever the geometry, no leg is ever quoted below the floor.
    function test_ki15_everyLegRespectsTheFloor() public {
        (uint256 pipsA,) = _leg(convexKey, 3e10);
        (uint256 pipsB,) = _leg(convexKey, 3e10);
        (,,, uint24 maxFee,,,,) = hook.poolConfig(convexId);

        assertGe(pipsA, 1, "leg 1 at or above effectiveMinFee");
        assertGe(pipsB, 1, "leg 2 at or above effectiveMinFee");
        assertLe(pipsA, maxFee, "leg 1 at or below maxFee");
        assertLe(pipsB, maxFee, "leg 2 at or below maxFee");
    }
}
