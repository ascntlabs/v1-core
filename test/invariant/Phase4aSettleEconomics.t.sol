// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";
import {SimHookHarness} from "../harness/SimHookHarness.sol";
import {P4Ev} from "./helpers/P4Helpers.sol";

import {SimHook} from "../../src/SimHook.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Phase-4a settlement-economics scenarios: SETTLE-9 (no-op paths), SETTLE-15 (LPs accrue
///         exactly the lpFee rate; the take is a swapper cost), SETTLE-19 (event slot correctness
///         over all four direction/exactness quadrants), XSUB-5 (a maxFee-capped first swap
///         still seeds the accumulator with its FULL realized impact).
contract Phase4aSettleEconomicsTest is SimHookUtils {
    address internal constant TREASURY = address(0xBEEF);
    uint24 internal constant MAX_FEE_A = 10_000;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(-600, 600, 1e12, initSqrtP, false);
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(2000);
    }

    // ------ SETTLE-9: every no-op trigger takes nothing and emits nothing ------

    function test_settle9_noopPaths_takeNothingEmitNothing() public {
        swap(true, -1e9, false); // prime

        // (a) bps == 0: hookFee == 0 => no take, no event
        governance.setProtocolFeeBps(0);
        uint256 t0 = MockERC20(Currency.unwrap(currency0)).balanceOf(TREASURY);
        uint256 t1 = MockERC20(Currency.unwrap(currency1)).balanceOf(TREASURY);
        (, Vm.Log[] memory logsA) = swap(true, -5e9, false);
        assertEq(P4Ev.feeTakes(logsA).length, 0, "bps=0 swap must not emit ProtocolFeeTaken");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(TREASURY), t0, "bps=0 moved treasury c0");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(TREASURY), t1, "bps=0 moved treasury c1");

        // (b) dust: bps=2000, dynFee ~ 10 pips => hookFee = 2 pips; a ~1000-unit output makes
        //     take = floor(mag * 2 / 1e6) == 0 => no take, no event, swap still succeeds
        governance.setProtocolFeeBps(2000);
        (, Vm.Log[] memory logsB) = swap(true, -1000, false);
        assertEq(P4Ev.feeTakes(logsB).length, 0, "dust swap must round the take to zero silently");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(TREASURY), t0, "dust swap moved treasury c0");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(TREASURY), t1, "dust swap moved treasury c1");
    }

    // ------ SETTLE-19: event amount slot == unspecified currency, all 4 quadrants ------

    function test_settle19_eventSlotMatchesUnspecified_allQuadrants() public {
        swap(true, -1e9, false); // prime
        _quadrant(true, false, 5e9); // exact-in  0->1: unspecified = currency1 (output)
        _quadrant(false, false, 5e9); // exact-in  1->0: unspecified = currency0 (output)
        _quadrant(true, true, 2e9); // exact-out 0->1: unspecified = currency0 (input)
        _quadrant(false, true, 2e9); // exact-out 1->0: unspecified = currency1 (input)
    }

    function _quadrant(bool zeroForOne, bool exactOut, uint256 amount) internal {
        uint256 t0 = MockERC20(Currency.unwrap(currency0)).balanceOf(TREASURY);
        uint256 t1 = MockERC20(Currency.unwrap(currency1)).balanceOf(TREASURY);

        (, Vm.Log[] memory logs) = swap(zeroForOne, exactOut ? int256(amount) : -int256(amount), false);
        P4Ev.FeeTakenEv[] memory takes = P4Ev.feeTakes(logs);
        assertEq(takes.length, 1, "quadrant must produce exactly one take");

        bool exactInput = !exactOut;
        bool unspecIs0 = (exactInput != zeroForOne); // the hook's own selection rule, re-derived
        uint256 d0 = MockERC20(Currency.unwrap(currency0)).balanceOf(TREASURY) - t0;
        uint256 d1 = MockERC20(Currency.unwrap(currency1)).balanceOf(TREASURY) - t1;

        if (unspecIs0) {
            assertGt(uint256(takes[0].amount0), 0, "amount must sit in the currency0 slot");
            assertEq(uint256(takes[0].amount1), 0, "currency1 slot must be zero");
            assertEq(d0, uint256(takes[0].amount0), "treasury currency0 delta != event amount");
            assertEq(d1, 0, "treasury credited in the wrong currency");
        } else {
            assertGt(uint256(takes[0].amount1), 0, "amount must sit in the currency1 slot");
            assertEq(uint256(takes[0].amount0), 0, "currency0 slot must be zero");
            assertEq(d1, uint256(takes[0].amount1), "treasury currency1 delta != event amount");
            assertEq(d0, 0, "treasury credited in the wrong currency");
        }
    }

    // ------ SETTLE-15: LPs accrue exactly the lpFee rate; the take is a swapper cost ------

    function test_settle15_lpAccrualIsLpFeeRate_takeIsSwapperCost() public {
        swap(true, -1e9, false); // prime
        uint256 amt = 1e9;
        uint256 snap = vm.snapshotState();

        // leg 1: protocol fee OFF — the whole dynamicFee accrues to LPs
        governance.setProtocolFeeBps(0);
        (uint256 feeAmt0, uint24 dynFee0, uint256 out0,) = _measuredSwap(amt);
        assertApproxEqAbs(feeAmt0, (amt * dynFee0) / 1e6, 3, "bps=0: LP accrual != full dynamicFee rate");

        vm.revertToState(snap);

        // leg 2: protocol fee at the 20% cap — identical pre-state, identical swap
        governance.setProtocolFeeBps(2000);
        (uint256 feeAmt1, uint24 dynFee1, uint256 out1, uint256 take) = _measuredSwap(amt);
        assertEq(dynFee1, dynFee0, "identical pre-state must produce the identical dynamicFee");
        uint24 lpFee = dynFee1 - uint24((uint256(dynFee1) * 2000) / 10_000);
        assertApproxEqAbs(feeAmt1, (amt * lpFee) / 1e6, 3, "bps=2000: LP accrual != lpFee rate");
        assertLt(feeAmt1, feeAmt0, "LP accrual must shrink by the protocol slice");
        assertGt(take, 0, "protocol take must be non-zero at the cap");

        // the take is funded by the SWAPPER: their net output is (approximately) unchanged vs the
        // bps=0 world — the in-swap fee discount and the afterSwap take cancel (no double charge,
        // and nothing is deducted from LP balances). The two independent floorings (feeGrowth
        // rounding on the discounted lpFee + the take's mulDiv floor) compound to a few wei of
        // dust; the guard proves there is no SYSTEMATIC second charge (which would be ~hookFee-
        // sized, i.e. 0.2% of output here, not single-digit wei).
        assertApproxEqAbs(out0, out1, 64, "swapper net output must not bear a double charge");
    }

    function _measuredSwap(uint256 amt)
        internal
        returns (uint256 feeAmtFromGrowth, uint24 dynFee, uint256 out, uint256 take)
    {
        (uint256 gBefore,) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        uint128 liq = StateLibrary.getLiquidity(manager, poolId);
        (SwapValues memory sv, Vm.Log[] memory logs) = swap(true, -int256(amt), false);
        (uint256 gAfter,) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        feeAmtFromGrowth = FullMath.mulDiv(gAfter - gBefore, liq, FixedPoint128.Q128);
        dynFee = getBeforeSwapEventData(logs).dynamicFeePips;
        out = uint256(uint128(sv.amount1)); // swapper's received output (currency1)
        P4Ev.FeeTakenEv[] memory takes = P4Ev.feeTakes(logs);
        take = takes.length == 0 ? 0 : uint256(takes[0].amount1);
    }

    // ------ XSUB-5: a capped first swap still seeds the accumulator with its full impact ------

    /// @notice The first swap prices off cum = 0 (fee = clamp of its own simulated impact, so a
    ///         large-impact swap pays at most maxFee), yet its FULL realized impact seeds
    ///         cumPriceImpact — so the NEXT same-direction trader is charged k x the midpoint of
    ///         a leg starting at the whole accumulated imbalance.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_xsub5_cappedFirstSwapStillSeedsFullImpact(uint256 amtSeed) public {
        governance.setProtocolFeeBps(0); // isolate the fee economics from the protocol split
        uint256 amt = _bound(amtSeed, 5e10, 3e11); // impact ~3_000..18_000 pips, straddles maxFee

        (, Vm.Log[] memory logs1) = swap(true, -int256(amt), false);
        BeforeSwapEventData memory b1 = getBeforeSwapEventData(logs1);
        AfterSwapEventData memory a1 = getAfterSwapEventData(logs1);

        assertEq(b1.decayedCumPriceImpact, 0, "first swap must price off a zero accumulator");
        uint256 expected1 = b1.priceImpact > MAX_FEE_A ? MAX_FEE_A : b1.priceImpact;
        if (expected1 < b1.effectiveMinFee) expected1 = b1.effectiveMinFee;
        assertEq(uint256(b1.dynamicFeePips), expected1, "first swap fee != clamp of its own impact");
        (,,, int256 cum) = hook.poolData(poolId);
        assertEq(cum, a1.cumPriceImpact, "seeded accumulator mismatch");
        assertLt(cum, 0, "zeroForOne seed must be negative");

        // trader #2, same direction, same block: charged k x the midpoint of the leg
        // |cum| -> |cum|+P, i.e. exactly 2|cum| + estPI (k=2, no truncation)
        (, Vm.Log[] memory logs2) = swap(true, -1e9, false);
        BeforeSwapEventData memory b2 = getBeforeSwapEventData(logs2);
        assertEq(b2.decayedCumPriceImpact, cum, "same-block decay must be the identity");

        uint256 preClamp = 2 * uint256(-b2.decayedCumPriceImpact) + b2.priceImpact;
        uint256 expected = preClamp > MAX_FEE_A ? MAX_FEE_A : preClamp; // > effectiveMinFee here
        assertEq(uint256(b2.dynamicFeePips), expected, "increasing branch must charge k x midpoint = 2|cum| + estPI");
    }
}

/// @notice XSUB-3 (RESOLVED — regression pin). The hook consumes a CACHED protocolFeeBps in
///         beforeSwap but the LIVE governance.treasury() in afterSwap. Under the ORIGINAL split
///         that desync was an ACCEPTED RISK: a cache stranded above governance's value (a failed
///         subscriber push) combined with an unset treasury SILENTLY forfeited the protocol slice
///         to the swapper at LP expense — lpFee was reduced, the take no-opped, nothing reverted.
///
///         `_computeProtocolFeeSplit` now carves only while `governance.treasury() != address(0)`,
///         so the forfeit is unreachable by construction: with no treasury the split degrades to
///         "full dynamic fee to LPs". The finding is closed, and this test is the pin that keeps
///         it closed — it engineers the SAME stranded state via the harness cache setter (a
///         SimHook's own push cannot be made to fail) and proves the forfeit CANNOT happen, then
///         proves permissionless recovery via syncProtocolFee still works.
contract Phase4aStrandedCacheTest is SimHookUtils {
    SimHookHarness internal harness;

    function setUp() public {
        address hookAddress = deployCoreAndHookCustomDecimals("SimHookHarness.sol", "USDC", "USDT", 6, 6, false);
        harness = SimHookHarness(hookAddress);
        hook = SimHook(hookAddress);
        (, uint160 initSqrtP) = deployPool(hook, 0, 1, false);
        hook.configurePool(poolId, 10, 10, 10_000, 3600, 0, 2e6, 1e6);
        addLiquidity(-600, 600, 1e12, initSqrtP, false);
        // deliberately: governance.treasury == address(0), governance.protocolFeeBps == 0
    }

    /// @notice The XSUB-3 scenario, unchanged in construction and inverted in expectation: a
    ///         stranded nonzero cache with `treasury == address(0)` must be economically
    ///         INDISTINGUISHABLE from a clean cache. The differential is the proof — both legs run
    ///         from the same snapshot with the same input, so an exact equality on LP fee growth
    ///         says the split carved nothing, and an exact equality on the swapper's output says
    ///         nobody pocketed a slice on the way past.
    function test_xsub3_strandedCacheCannotForfeitSlice() public {
        swap(true, -1e9, false); // prime
        uint256 amt = 1e9;
        uint256 snap = vm.snapshotState();

        // clean leg: cache agrees with governance (both 0) — full dynamicFee accrues to LPs
        (uint256 gClean, uint256 outClean,) = _growthAndOut(amt);
        vm.revertToState(snap);

        // stranded leg: cache says 10% while governance says 0 and treasury is unset
        harness.harnessSetProtocolFeeBps(1000);
        assertEq(governance.protocolFeeBps(), 0, "governance must still say 0");
        assertEq(governance.treasury(), address(0), "treasury must be unset");

        (uint256 gStranded, uint256 outStranded, Vm.Log[] memory logsStranded) = _growthAndOut(amt);
        // SETTLE-9 slice: even if a rate had been stashed, an unset treasury no-ops the take
        assertEq(P4Ev.feeTakes(logsStranded).length, 0, "take must no-op on unset treasury");

        // XSUB-3 closed: the split refuses to carve without a live treasury, so LPs receive the
        // FULL dynamic fee and the swapper gains nothing. Exact equality, not a bound — any carve
        // at all would move both numbers.
        assertEq(gStranded, gClean, "stranded cache must not reduce LP fee growth by one wei");
        assertEq(outStranded, outClean, "swapper must not keep any forfeited protocol slice");

        // Direct read of the same guard at the split site, so a future regression is localised
        // rather than only visible through the pool's economics.
        assertEq(harness.protocolFeeBps(), 1000, "sanity: the cache is still stranded at 10%");
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(poolId, 1000);
        assertEq(lpFee, 1000, "split must hand the full dynamic fee to LPs with no treasury");
        assertEq(harness.readStash(poolId), 0, "split must stash nothing with no treasury");

        // recovery: permissionless pull re-syncs the cache to the authoritative value
        harness.syncProtocolFee();
        assertEq(harness.protocolFeeBps(), 0, "syncProtocolFee must clear the stranded cache");
        (uint256 gHealed,,) = _growthAndOut(amt);
        assertGt(gHealed, 0, "post-sync swap must accrue LP fees again");
    }

    function _growthAndOut(uint256 amt) internal returns (uint256 growthDelta, uint256 out, Vm.Log[] memory logs) {
        (uint256 gBefore,) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        SwapValues memory sv;
        (sv, logs) = swap(true, -int256(amt), false);
        (uint256 gAfter,) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        growthDelta = gAfter - gBefore;
        out = uint256(uint128(sv.amount1));
    }
}
