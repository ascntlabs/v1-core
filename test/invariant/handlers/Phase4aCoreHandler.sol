// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SimHook} from "../../../src/SimHook.sol";
import {AscntGovernance} from "../../../src/AscntGovernance.sol";
import {P4Ev} from "../helpers/P4Helpers.sol";

/// @notice Phase-4a stateful-core handler. Drives two pools (A: production-shaped stable pair,
///         B: adversarial extreme config, same currencies / different tickSpacing) on ONE SimHook,
///         plus governance fee-rate churn and time/block advancement.
///
///         Every swap action is REVERT-FREE by construction (bounded amounts, boundary-price
///         skip guards) and hard-asserts success — under `fail-on-revert = true` this makes the
///         whole campaign a continuous FEE-14 check ("the swap path never reverts on a configured
///         pool"). After each swap it re-derives the per-swap ghost checks for:
///           SETTLE-5/10 (take == own-swap split rate, treasury credited exactly, unlock closed),
///           SETTLE-9  (no-op paths take nothing and emit nothing),
///           SETTLE-16 (per-currency conservation: swapper + treasury + manager sum to zero),
///           SETTLE-19 (event amount sits in the unspecified currency's slot),
///           ACC-2     (bounded directional accumulator step), ACC-6 (timestamp sanity),
///           ACC-10    (cross-pool isolation), FEE-8 (cum > int256.min), FEE-15 (cap pre-values).
contract Phase4aCoreHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PIPS = 1e6;
    uint24 internal constant HOOK_MAX_FEE = 500_000; // SimHook.MAX_FEE

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable liqRouter;
    SimHook public immutable hook;
    AscntGovernance public immutable governance;
    address public immutable timelock;
    address public immutable treasury;

    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolId internal idA;
    PoolId internal idB;

    address internal token0;
    address internal token1;

    bytes32 internal constant HANDLER_SALT = bytes32("p4a");
    int24 internal constant TL = -600;
    int24 internal constant TU = 600;

    // ---- ghost variables ----
    uint256 public swapCount; // successful swaps (both pools)
    uint256 public takeCount; // swaps with a non-zero protocol take
    uint256 public noopTakeCount; // swaps proven to be legitimate no-op takes
    uint256 public skippedSwaps; // boundary-price skip guard hits
    uint256 public addCount;
    uint256 public removeCount;
    uint256 public jitBlockedRemoves;
    uint256 public warpCount;
    uint256 public feeSetCount;
    uint256 public ghostTakes0; // cumulative ProtocolFeeTaken in currency0
    uint256 public ghostTakes1; // cumulative ProtocolFeeTaken in currency1
    uint256 public handlerLiqA; // liquidity the handler itself added on pool A (its own salt)

    struct PoolSnap {
        uint160 spb;
        uint48 ts;
        int256 cum;
        bytes32 cfgHash;
        uint48 stamp;
    }

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _liqRouter,
        SimHook _hook,
        AscntGovernance _governance,
        address _timelock,
        address _treasury,
        PoolKey memory _keyA,
        PoolKey memory _keyB
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        liqRouter = _liqRouter;
        hook = _hook;
        governance = _governance;
        timelock = _timelock;
        treasury = _treasury;
        keyA = _keyA;
        keyB = _keyB;
        idA = _keyA.toId();
        idB = _keyB.toId();
        token0 = Currency.unwrap(_keyA.currency0);
        token1 = Currency.unwrap(_keyA.currency1);
        MockERC20(token0).approve(address(_swapRouter), type(uint256).max);
        MockERC20(token1).approve(address(_swapRouter), type(uint256).max);
        MockERC20(token0).approve(address(_liqRouter), type(uint256).max);
        MockERC20(token1).approve(address(_liqRouter), type(uint256).max);
    }

    // ------ actions ------

    function swapA(uint256 amountSeed, bool zeroForOne, bool exactOut) external {
        uint256 amount = exactOut ? _bound(amountSeed, 1e3, 1e10) : _bound(amountSeed, 1e3, 2e10);
        _swapChecked(keyA, idA, idB, zeroForOne, exactOut, amount);
    }

    function swapB(uint256 amountSeed, bool zeroForOne, bool exactOut) external {
        // B sits at the hook's maxFee cap — exact-out inputs inflate up to 2x, so keep output small.
        uint256 amount = exactOut ? _bound(amountSeed, 1e3, 1e9) : _bound(amountSeed, 1e4, 1e11);
        _swapChecked(keyB, idB, idA, zeroForOne, exactOut, amount);
    }

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + _bound(seed, 1, 3 hours));
        vm.roll(block.number + _bound(seed >> 128, 1, 60));
        warpCount++;
    }

    function addLiquidityA(uint256 amountSeed) external {
        uint256 liq = _bound(amountSeed, 1e8, 1e11);
        PoolSnap memory other = _snap(idB); // pool-B state must be untouched by pool-A adds
        // Collect accrued fees first so the add nets exactly its cost and the checked router's
        // add asserts hold; skipped on an empty position (v4 reverts a zero-delta update of one).
        if (handlerLiqA != 0) {
            liqRouter.modifyLiquidity(
                keyA, ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: 0, salt: HANDLER_SALT}), ""
            );
        }
        liqRouter.modifyLiquidity(
            keyA,
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: int256(liq), salt: HANDLER_SALT}),
            ""
        );
        handlerLiqA += liq;
        addCount++;
        _assertSnapUnchanged(other, idB, "addA touched pool B");
    }

    function removeLiquidityA(uint256 amountSeed) external {
        // Floor the remove at 1e6 liquidity units: a smaller remove over the [-600,600] range
        // rounds BOTH token amounts to zero and trips PoolModifyLiquidityTest's own
        // `assert(delta0>0||delta1>0)` (a test-router artifact, unrelated to the hook). Handler
        // adds are >= 1e8, so this floor never collapses the action.
        if (handlerLiqA < 1e6) return;
        uint256 toRemove = _bound(amountSeed, 1e6, handlerLiqA);
        PoolSnap memory other = _snap(idB);
        try liqRouter.modifyLiquidity(
            keyA,
            ModifyLiquidityParams({
                tickLower: TL,
                tickUpper: TU,
                liquidityDelta: -int256(toRemove),
                salt: HANDLER_SALT
            }),
            ""
        ) {
            handlerLiqA -= toRemove;
            removeCount++;
        } catch (bytes memory reason) {
            // The ONLY tolerated remove failure is the JIT block-lock; anything else is a bug.
            assertTrue(
                P4Ev.containsSelector(reason, SimHook.JitLockActive.selector), "removeA reverted for a non-JIT reason"
            );
            jitBlockedRemoves++;
        }
        _assertSnapUnchanged(other, idB, "removeA touched pool B");
    }

    function setProtocolFee(uint256 seed) external {
        uint16[5] memory choices = [uint16(0), 1, 250, 1000, 2000];
        uint16 bps = choices[seed % 5];
        vm.prank(timelock);
        governance.setProtocolFeeBps(bps);
        // push model: the hook's cache must now equal governance's value
        assertEq(hook.protocolFeeBps(), bps, "protocolFeeBps push did not land");
        feeSetCount++;
    }

    // ------ core checked swap ------

    struct SwapCtx {
        uint16 bps;
        uint24 maxFee;
        uint48 tsBefore;
        uint256 h0;
        uint256 h1;
        uint256 t0;
        uint256 t1;
        uint256 m0;
        uint256 m1;
        PoolSnap other;
    }

    function _swapChecked(
        PoolKey memory k,
        PoolId id,
        PoolId otherId,
        bool zeroForOne,
        bool exactOut,
        uint256 amount
    ) internal {
        // Boundary-price skip guard: at the absolute price bound the same-direction swap would
        // revert PriceLimitAlreadyExceeded inside v4-core — a v4 precondition, not a hook bug.
        {
            (uint160 sp,,,) = manager.getSlot0(id);
            if (zeroForOne && sp <= TickMath.MIN_SQRT_PRICE + 1) {
                skippedSwaps++;
                return;
            }
            if (!zeroForOne && sp >= TickMath.MAX_SQRT_PRICE - 1) {
                skippedSwaps++;
                return;
            }
        }

        SwapCtx memory c;
        c.bps = hook.protocolFeeBps();
        (,,, c.maxFee,,,,) = hook.poolConfig(id);
        (, c.tsBefore,,) = hook.poolData(id);
        c.other = _snap(otherId);
        c.h0 = MockERC20(token0).balanceOf(address(this));
        c.h1 = MockERC20(token1).balanceOf(address(this));
        c.t0 = MockERC20(token0).balanceOf(treasury);
        c.t1 = MockERC20(token1).balanceOf(treasury);
        c.m0 = MockERC20(token0).balanceOf(address(manager));
        c.m1 = MockERC20(token1).balanceOf(address(manager));

        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactOut ? int256(amount) : -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.recordLogs();
        // FEE-14: NOT wrapped in try/catch — any revert here fails the campaign (fail-on-revert).
        BalanceDelta delta =
            swapRouter.swap(k, p, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        swapCount++;

        _checkAccumulator(id, zeroForOne, logs);
        _checkSettlement(c, id, zeroForOne, exactOut, delta, logs);
        _assertSnapUnchanged(c.other, otherId, "swap bled into the other pool");
    }

    /// @dev ACC-2 / ACC-6 / FEE-8 / FEE-15(impact caps) — accumulator step + timestamp checks.
    function _checkAccumulator(PoolId id, bool zeroForOne, Vm.Log[] memory logs) internal view {
        P4Ev.BeforeSwapEv[] memory bevs = P4Ev.beforeSwaps(logs);
        P4Ev.AfterSwapEv[] memory aevs = P4Ev.afterSwaps(logs);
        assertEq(bevs.length, 1, "expected exactly one BeforeSwap");
        assertEq(aevs.length, 1, "expected exactly one AfterSwap");
        assertEq(bevs[0].poolId, PoolId.unwrap(id), "BeforeSwap poolId mismatch");
        assertEq(aevs[0].poolId, PoolId.unwrap(id), "AfterSwap poolId mismatch");

        (, uint48 tsAfter,, int256 cumAfter) = hook.poolData(id);

        // ACC-6: stamp == now, monotone, never in the future
        assertEq(uint256(tsAfter), block.timestamp, "lastSwapTimestamp != block.timestamp");
        assertLe(uint256(tsAfter), block.timestamp, "lastSwapTimestamp in the future");

        // FEE-8: saturation floor keeps cum abs/negation-safe forever
        assertTrue(cumAfter > type(int256).min, "cum reached int256.min (abs-unsafe)");

        // FEE-15 pre-values: the *Capped call sites must never be near their caps
        assertLe(bevs[0].priceImpact, PIPS, "simulated impact above 100% cap");
        assertLe(aevs[0].priceImpact, PIPS, "realized impact above 100% cap");

        // ACC-2: step = cum_after - decayedCum_before is directional and bounded by 1e6
        int256 step = cumAfter - bevs[0].decayedCum;
        if (zeroForOne) {
            assertLe(step, 0, "zeroForOne must not raise the accumulator");
        } else {
            assertGe(step, 0, "oneForZero must not lower the accumulator");
        }
        uint256 stepAbs = step >= 0 ? uint256(step) : uint256(-step);
        assertLe(stepAbs, PIPS, "accumulator step above 1e6");
        // the step must be exactly the emitted realized impact (event <-> storage coherence)
        assertEq(stepAbs, aevs[0].priceImpact, "accumulator step != realized impact");
        assertEq(cumAfter, aevs[0].cum, "storage cum != emitted cum");
    }

    /// @dev SETTLE-5/9/10/16/19 + FEE-15(split/take caps) — settlement ghost checks.
    function _checkSettlement(
        SwapCtx memory c,
        PoolId id,
        bool zeroForOne,
        bool exactOut,
        BalanceDelta delta,
        Vm.Log[] memory logs
    ) internal {
        P4Ev.BeforeSwapEv[] memory bevs = P4Ev.beforeSwaps(logs);
        P4Ev.FeeTakenEv[] memory takes = P4Ev.feeTakes(logs);
        uint24 dynFee = bevs[0].dynFee;
        assertLe(dynFee, c.maxFee, "dynamic fee above configured maxFee");
        assertLe(c.maxFee, HOOK_MAX_FEE, "maxFee above the hook cap");

        uint256 hookFee = (uint256(dynFee) * uint256(c.bps)) / 10_000;
        assertLe(hookFee, 100_000, "hookFee rate above the 20% x 50% ceiling");

        bool exactInput = !exactOut;
        bool unspecIs0 = (exactInput != zeroForOne);
        int128 unspec = unspecIs0 ? delta.amount0() : delta.amount1();
        uint256 unspecAbs = unspec >= 0 ? uint256(uint128(unspec)) : uint256(uint128(-unspec));

        uint256 dT0 = MockERC20(token0).balanceOf(treasury) - c.t0;
        uint256 dT1 = MockERC20(token1).balanceOf(treasury) - c.t1;

        if (takes.length == 0) {
            // SETTLE-9: no event => must be a LEGITIMATE no-op (rate 0 or rounds to 0), and the
            // treasury must not have moved.
            assertEq(dT0, 0, "no take event but treasury currency0 moved");
            assertEq(dT1, 0, "no take event but treasury currency1 moved");
            assertEq((unspecAbs * hookFee) / PIPS, 0, "take skipped although it should be non-zero");
            noopTakeCount++;
        } else {
            assertEq(takes.length, 1, "more than one ProtocolFeeTaken per swap");
            P4Ev.FeeTakenEv memory t = takes[0];
            assertEq(t.poolId, PoolId.unwrap(id), "take event poolId mismatch");
            assertEq(t.treasury, treasury, "take event treasury mismatch");

            // SETTLE-19: amount must sit in the unspecified currency's slot, other slot zero
            uint256 take = unspecIs0 ? uint256(t.amount0) : uint256(t.amount1);
            uint256 otherSlot = unspecIs0 ? uint256(t.amount1) : uint256(t.amount0);
            assertGt(take, 0, "take event with zero amount in the unspecified slot");
            assertEq(otherSlot, 0, "take event has amount in the specified slot");

            // SETTLE-16/5: treasury credited exactly the emitted take, in the right currency
            assertEq(unspecIs0 ? dT0 : dT1, take, "treasury delta != emitted take");
            assertEq(unspecIs0 ? dT1 : dT0, 0, "treasury credited in the wrong currency");

            // SETTLE-10: the settled amount matches THIS swap's split rate. The router delta is
            // post-hook-delta (v4 nets the +take on the unspecified currency), so the hook's own
            // pre-take magnitude is |unspec|+take on exact-input (output side) and |unspec|-take on
            // exact-output (input side).
            uint256 mag = exactInput ? unspecAbs + take : unspecAbs - take;
            assertEq(take, (mag * hookFee) / PIPS, "take != this swap's split rate");
            // FEE-15 / SETTLE-4: take strictly below the realized magnitude
            assertLt(take, mag, "take >= realized magnitude");

            if (unspecIs0) ghostTakes0 += take;
            else ghostTakes1 += take;
            takeCount++;
        }

        // SETTLE-16: per-currency conservation across swapper/treasury/manager.
        {
            int256 dH0 = int256(MockERC20(token0).balanceOf(address(this))) - int256(c.h0);
            int256 dM0 = int256(MockERC20(token0).balanceOf(address(manager))) - int256(c.m0);
            assertEq(dH0 + int256(dT0) + dM0, 0, "currency0 not conserved");
            int256 dH1 = int256(MockERC20(token1).balanceOf(address(this))) - int256(c.h1);
            int256 dM1 = int256(MockERC20(token1).balanceOf(address(manager))) - int256(c.m1);
            assertEq(dH1 + int256(dT1) + dM1, 0, "currency1 not conserved");
        }
    }

    // ------ ACC-10 cross-pool isolation helpers ------

    function _snap(PoolId id) internal view returns (PoolSnap memory s) {
        (s.spb, s.ts,, s.cum) = hook.poolData(id);
        (
            bool configured,
            uint24 minMinFee,
            uint24 maxMinFee,
            uint24 maxFee,
            uint48 timeDecayLength,
            uint48 jitLockBlocks,
            uint32 kPips,
            uint32 cPips
        ) = hook.poolConfig(id);
        s.cfgHash = keccak256(
            abi.encode(configured, minMinFee, maxMinFee, maxFee, timeDecayLength, jitLockBlocks, kPips, cPips)
        );
        s.stamp =
            hook.lastAddedLiquidityBlock(id, Position.calculatePositionKey(address(liqRouter), TL, TU, HANDLER_SALT));
    }

    function _assertSnapUnchanged(PoolSnap memory s, PoolId id, string memory why) internal view {
        (uint160 spb, uint48 ts,, int256 cum) = hook.poolData(id);
        assertEq(uint256(spb), uint256(s.spb), string.concat(why, " (sqrtPriceX96Before)"));
        assertEq(uint256(ts), uint256(s.ts), string.concat(why, " (lastSwapTimestamp)"));
        assertEq(cum, s.cum, string.concat(why, " (cumPriceImpact)"));
        PoolSnap memory now_ = _snap(id);
        assertEq(now_.cfgHash, s.cfgHash, string.concat(why, " (poolConfig)"));
        assertEq(uint256(now_.stamp), uint256(s.stamp), string.concat(why, " (jit stamp)"));
    }
}
