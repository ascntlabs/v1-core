// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SwapSimulator} from "../../src/lib/SwapSimulator.sol";
import {ImpactOracle} from "../utils/ImpactOracle.sol";

/// @notice phase3-differential — SIM-1 / SIM-2 / SIM-3 / SIM-4 on a FEE-BEARING pool.
///
/// The existing suites (test/base/SwapSimulator.t.sol, SwapSimulator_QuoterOracle.t.sol)
/// prove sim == engine on fee=0 pools only, where the simulator's hard-coded fee=0 makes
/// the comparison trivial. The production pools charge a dynamic LP fee, so the properties
/// that actually protect the fee mechanism live on fee>0 pools:
///   SIM-1: exact-OUTPUT results remain byte-exact (the output amount alone drives the
///          price path; the engine's fee loads only the input side),
///   SIM-2: exact-INPUT results never UNDERSTATE the price move (fee=0 sim pushes the
///          full gross input through the curve; the engine siphons the fee off first),
///   SIM-3: the exact-input overstatement is bounded ~O(fee), not amount-amplified,
///   SIM-4: a binding sqrtPriceLimit is honored bit-exactly on the fee pool too.
contract Phase3_SimFeePoolDiffTest is Test, ArtifactDeployers {
    using StateLibrary for *;

    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_SPACING = 10;
    uint24 internal constant POOL_FEE = 3000; // 0.30% — large enough to make fee effects visible
    int24 internal constant LIQ_LOWER = -5000;
    int24 internal constant LIQ_UPPER = 5000;

    function setUp() public {
        deployArtifactManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 init = TickMath.getSqrtPriceAtTick(0);
        (poolKey, poolId) = initPool(currency0, currency1, IHooks(address(0)), POOL_FEE, TICK_SPACING, init);

        // deep base + tick spikes so larger swaps cross initialized ticks (same shape as
        // the fee=0 base suite, so any divergence is attributable to the fee)
        _addPosition(LIQ_LOWER, LIQ_UPPER, 1_000 ether);
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

    function _params(bool zeroForOne, int256 amt, uint160 limit) internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: limit});
    }

    function _minMaxLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _doRealSwap(SwapParams memory p) internal returns (uint160 sqrtAfter) {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(poolKey, p, ts, ZERO_BYTES);
        (sqrtAfter,,,) = StateLibrary.getSlot0(manager, poolId);
    }

    // ---- SIM-1: exact-output on a fee pool is byte-exact ----

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sim1_exactOut_feePool_exact(uint256 amount, bool zeroForOne) public {
        int256 amt = int256(bound(amount, 1e6, 10 ether));
        SwapParams memory p = _params(zeroForOne, amt, _minMaxLimit(zeroForOne));

        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, poolId, TICK_SPACING, p);
        uint160 realAfter = _doRealSwap(p);

        assertEq(r.sqrtPriceAfterX96, realAfter, "SIM-1: exact-output must be fee-independent and exact");
    }

    // ---- SIM-2: exact-input on a fee pool never understates the move ----

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sim2_exactIn_neverUnderstates(uint256 amount, bool zeroForOne) public {
        int256 amt = -int256(bound(amount, 1e6, 100 ether));
        SwapParams memory p = _params(zeroForOne, amt, _minMaxLimit(zeroForOne));

        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, poolId, TICK_SPACING, p);
        uint160 realAfter = _doRealSwap(p);

        if (zeroForOne) {
            assertLe(r.sqrtPriceAfterX96, realAfter, "SIM-2: sim must move price at least as far down");
        } else {
            assertGe(r.sqrtPriceAfterX96, realAfter, "SIM-2: sim must move price at least as far up");
        }

        // impact-space corollary (|r-1|/sqrt(r) is monotone in the move ratio from the
        // shared base price): sim >= real
        uint256 impactSim = ImpactOracle.priceImpactPips(r.sqrtPriceBeforeX96, r.sqrtPriceAfterX96);
        uint256 impactReal = ImpactOracle.priceImpactPips(r.sqrtPriceBeforeX96, realAfter);
        assertGe(impactSim, impactReal, "SIM-2: simulated impact must never understate realized");
    }

    // ---- SIM-3: the exact-input overstatement is bounded ~O(fee) ----

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sim3_overstatementBounded(uint256 amount, bool zeroForOne) public {
        int256 amt = -int256(bound(amount, 1e9, 50 ether));
        SwapParams memory p = _params(zeroForOne, amt, _minMaxLimit(zeroForOne));

        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, poolId, TICK_SPACING, p);
        uint160 realAfter = _doRealSwap(p);

        uint256 impactSim = ImpactOracle.priceImpactPips(r.sqrtPriceBeforeX96, r.sqrtPriceAfterX96);
        uint256 impactReal = ImpactOracle.priceImpactPips(r.sqrtPriceBeforeX96, realAfter);
        assertGe(impactSim, impactReal, "precondition (SIM-2)");
        uint256 gap = impactSim - impactReal;

        // BOUND DERIVATION (not hand-tuned): the engine drives the price with the net
        // input x*(1-f), the simulator with the gross x (f = POOL_FEE/1e6). With constant
        // liquidity the impact is
        //   zeroForOne (price falls, concave in input):  g(a) = 1 - 1/(1+a)^2,
        //   oneForZero (price rises, convex in input):   g(b) = (1+b)^2 - 1,
        // giving a relative gap (g(gross)-g(net))/g(net) of at most f/(1-f) on the concave
        // side and f*(2-f)/(1-f)^2 < 2f/(1-2f) on the convex side (the convex bound
        // dominates). The doc's "fee/1e6" figure is the small-impact limit of the same
        // expression. +2 pips absorbs the two independent mulDiv floors (one per impact).
        uint256 bound_ = FullMath.mulDiv(impactReal, 2 * uint256(POOL_FEE), 1e6 - 2 * uint256(POOL_FEE)) + 2;
        assertLe(gap, bound_, "SIM-3: overstatement must stay O(fee), never amount-amplified");
    }

    // ---- SIM-4: a binding price limit is honored bit-exactly on the fee pool ----

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sim4_bindingLimit_stopsExactlyAtLimit(uint256 amount, uint256 offset, bool zeroForOne) public {
        // amounts large enough that the ENGINE reaches the limit (the sim, which travels
        // at least as far per SIM-2, then must reach it too)
        int256 amt = -int256(bound(amount, 200 ether, 500 ether));
        int24 offTicks = int24(uint24(bound(offset, 10, 300)));
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? -offTicks : offTicks);
        SwapParams memory p = _params(zeroForOne, amt, limit);

        SwapSimulator.Result memory r = SwapSimulator.simulate(manager, poolId, TICK_SPACING, p);
        uint160 realAfter = _doRealSwap(p);

        // precondition, asserted loudly instead of silently vacuous
        assertEq(realAfter, limit, "test precondition: engine must bind at the limit");
        assertEq(r.sqrtPriceAfterX96, limit, "SIM-4: sim must stop exactly at the binding limit");
    }
}
