// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {Phase5ReentrancyBase} from "./base/Phase5ReentrancyBase.sol";
import {Phase5NestedSwapper} from "./helpers/Phase5NestedSwapper.sol";
import {Phase5RevertSink} from "./helpers/Phase5RevertSink.sol";
import {Phase5Decay} from "./helpers/Phase5Decay.sol";
import {Phase5TimelockProxy} from "./helpers/Phase5TimelockProxy.sol";
import {ReentrantERC20} from "../mocks/ReentrantERC20.sol";
import {ImpactOracle} from "../utils/ImpactOracle.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {SimHook} from "../../src/SimHook.sol";
import {AscntBaseHook} from "../../src/AscntBaseHook.sol";

/// @notice Phase-5 settlement-reentrancy suite — XSUB-1 (accumulator composition under a reentrant
///         take) and SETTLE-12 (the outer take is computed into locals before the external call),
///         plus one SETTLE-17 vector that shares this file's armed-token fixture, and two
///         lifecycle/access vectors (LIFE-1, LIFE-8) reached THROUGH the re-entry — supplementary
///         partial slices only; see the LIFE section banner below.
///
///         Fixture: an ERC-20/ERC-20 pool whose BOTH currencies are `ReentrantERC20`. Swaps are
///         exact-input zeroForOne by default, so the UNSPECIFIED currency (the one the protocol take
///         is drawn from, `AscntBaseHook.sol:171-186`) is `currency1`. Arming `currency1` therefore
///         fires the adversary from inside `PoolManager.take` -> `ERC20.transfer(treasury, …)`, i.e.
///         while `SimHook._afterSwap` is still on the stack at SimHook.sol:299.
///
///         `ReentrantERC20` fires its callback BEFORE the balance movement. The complementary
///         callback position (fire AFTER the credit, the ERC-777 / hook-on-transfer shape) is
///         covered by `PostTransferReentrancy.t.sol`, which re-runs the two flagship vectors
///         through `Phase5PostTransferToken`.
///
///         What the re-entered call can legally do: the manager is UNLOCKED (the outer
///         `unlock` is still open), so `swap` / `take` / `settle` are all callable — but a FRESH
///         `unlock` reverts `AlreadyUnlocked` (asserted in
///         `test_XSUB1_freshUnlockReentry_rejectedByV4Lock`). The realistic adversary is therefore a
///         contract that rides the open unlock and settles its own deltas, which is what
///         `Phase5NestedSwapper` does.
///
///         Event ordering used throughout (it is itself evidence of the effects-before-interactions
///         ordering): the outer `BeforeSwap` and `AfterSwap` are both emitted BEFORE the take, so
///         with a nested swap the log stream is
///         `BeforeSwap(outer), AfterSwap(outer), BeforeSwap(nested), AfterSwap(nested),
///          ProtocolFeeTaken(nested), ProtocolFeeTaken(outer)` — the outer take event is LAST
///         because it is emitted after `unspecified.take` returns.
///
///         WHY THE STASH IS SAFE: not because the beforeSwap -> afterSwap bracket is free of
///         re-entry — it is not. `test_SETTLE12_nestedSwapClobbersStash_outerTakeUnchanged` below
///         proves a nested swap DOES overwrite the stash mid-bracket. Correctness rests on
///         ordering instead: `_loadHookFee` strictly precedes the only external call, so each
///         frame reads its own value before anything can re-enter and replace it.
contract Phase5NestedSwapDuringTakeTest is Phase5ReentrancyBase {
    using StateLibrary for IPoolManager;

    ReentrantERC20 internal token0;
    ReentrantERC20 internal token1;
    Phase5NestedSwapper internal attacker; // triggered by currency1 (the usual unspecified side)
    Phase5NestedSwapper internal attacker0; // triggered by currency0 (for depth-2 nesting)
    Phase5RevertSink internal sink;

    address internal constant TREASURY_2 = address(0x7EA52);

    PoolKey internal keyB;
    PoolId internal poolIdB;

    // A non-degenerate min-fee ramp (minMinFee != maxMinFee) so `calculateEffectiveMinFee` does not
    // return on its first branch and the ramp is actually exercised by the time-gap vectors.
    uint24 internal constant MIN_MIN_FEE = 100;
    uint24 internal constant MAX_MIN_FEE = 500;
    uint24 internal constant MAX_FEE = 200_000;
    uint256 internal constant DECAY = 1 hours;
    uint16 internal constant BPS = 1_000; // 10%
    uint16 internal constant CAP_BPS = 2_000; // AscntGovernance.MAX_PROTOCOL_FEE_BPS

    int256 internal constant WARMUP = 2e19;
    int256 internal constant OUTER = 5e19;
    int256 internal constant NESTED = 3e19;

    function setUp() public {
        _deployProtocol();

        ReentrantERC20 a = new ReentrantERC20("Phase5A", "P5A", 18);
        ReentrantERC20 b = new ReentrantERC20("Phase5B", "P5B", 18);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        _useTokens(address(a), address(b));
        token0 = ReentrantERC20(Currency.unwrap(currency0));
        token1 = ReentrantERC20(Currency.unwrap(currency1));

        (key, poolId) = _initAndConfigure(1, 0, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, DECAY, 0);
        _addLiquidity(key, TICK_LOWER, TICK_UPPER, 1e21);

        // Second pool on the SAME currencies (different tickSpacing => different poolId) for the
        // cross-pool nesting vector.
        (keyB, poolIdB) = _initAndConfigure(10, 0, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, DECAY, 0);
        _addLiquidity(keyB, TICK_LOWER, TICK_UPPER, 1e21);

        _enableProtocolFee(BPS, TREASURY);

        attacker = new Phase5NestedSwapper(manager, hook, address(token1), key, poolId);
        token0.mint(address(attacker), 1e26);
        token1.mint(address(attacker), 1e26);

        attacker0 = new Phase5NestedSwapper(manager, hook, address(token0), key, poolId);
        token0.mint(address(attacker0), 1e26);
        token1.mint(address(attacker0), 1e26);

        sink = new Phase5RevertSink();

        // Warm-up swap stamps the swap clock so outer AND nested both run with live state.
        _swap(key, true, -WARMUP);
    }

    // ------ arming helpers ------

    function _armNestedSwap(PoolKey memory k, PoolId id, bool zeroForOne, int256 amount) internal {
        attacker.setNested(k, id, zeroForOne, amount);
        token1.arm(address(attacker), abi.encodeCall(Phase5NestedSwapper.onTakeSwap, ()), true, false, true);
    }

    /// @dev Arm the CURRENCY0 side. A oneForZero exact-input swap's unspecified currency is
    ///      currency0, so its take transfers token0 — token1's adversary would never fire.
    function _armNestedSwapOnCurrency0(PoolKey memory k, PoolId id, bool zeroForOne, int256 amount) internal {
        attacker0.setWatch(k, id);
        attacker0.setNested(k, id, zeroForOne, amount);
        token0.arm(address(attacker0), abi.encodeCall(Phase5NestedSwapper.onTakeSwap, ()), true, false, true);
    }

    function _armObserve() internal {
        token1.arm(address(attacker), abi.encodeCall(Phase5NestedSwapper.onTakeObserve, ()), true, false, true);
    }

    function _lastTake(Vm.Log[] memory logs) internal pure returns (TakeEvent memory) {
        TakeEvent[] memory takes = _takeEvents(logs);
        require(takes.length > 0, "no ProtocolFeeTaken");
        return takes[takes.length - 1];
    }

    // =====================================================================================
    // XSUB-1 — accumulator composition under a reentrant take
    // =====================================================================================

    /// @notice XSUB-1, primary vector: a nested SAME-POOL, SAME-DIRECTION swap executed from inside
    ///         the outer swap's treasury take.
    ///
    ///         Correct behavior: because `_afterSwap` writes `cumPriceImpact` / `lastSwapTimestamp`
    ///         (SimHook.sol:288-289) BEFORE the external take (SimHook.sol:299), the nested swap
    ///         starts from fully-written state and its own contribution simply appends. Final
    ///         accumulator must equal `decay(cum_prev) + realized_outer + realized_nested` exactly,
    ///         with each swap counted once.
    ///
    ///         The realized impacts are recomputed from slot0 prices captured OUTSIDE the hook (the
    ///         test's pre-swap read + the adversary's mid-take and post-nested reads), so this
    ///         assertion cannot be satisfied by construction from the hook's own event values.
    function test_XSUB1_nestedSameDirection_accumulatorComposesExactlyOnce() public {
        // A non-zero gap makes BOTH time-keyed terms non-trivial: the decay factor (5/6) and the
        // min-fee ramp (100 -> 166 of the 100..500 ramp).
        vm.warp(block.timestamp + 600);

        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(poolId);
        // vm.getBlockTimestamp(): opaque read the via-IR optimizer can't fold across vm.warp
        // (TIMESTAMP-fold hazard); lastTsBefore is a contract read.
        uint256 dt = vm.getBlockTimestamp() - lastTsBefore;
        assertEq(dt, 600, "decay gap");
        assertTrue(cumBefore != 0, "warmup must have seeded the accumulator");

        (uint160 sqrtBefore,,,) = manager.getSlot0(poolId);

        _armNestedSwap(key, poolId, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 1, "exactly one re-entry");
        assertEq(token1.reenterCount(), 1, "token fired its callback once");

        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(bs.length, 2, "one BeforeSwap per swap (outer, nested)");
        assertEq(as_.length, 2, "one AfterSwap per swap (outer, nested) - no double counting");
        assertEq(as_[0].poolId, PoolId.unwrap(poolId));
        assertEq(as_[1].poolId, PoolId.unwrap(poolId));

        // the time-keyed floor really moved off `minMinFee` (independent ramp transcription)
        assertEq(
            bs[0].effectiveMinFee,
            Phase5Decay.effectiveMinFee(MIN_MIN_FEE, MAX_MIN_FEE, dt, DECAY),
            "outer floor = ramp(dt)"
        );
        assertGt(bs[0].effectiveMinFee, MIN_MIN_FEE, "ramp must have moved or it is untested");
        // RAMP-1: the floor is block-scoped (ramp of `now - rampAnchor`, settled once per block),
        // so the nested same-block swap sees the OUTER swap's floor — pre-rampAnchor it dropped
        // to minMinFee at dt == 0, which is exactly the dust-reset bypass the anchor closed.
        assertEq(bs[1].effectiveMinFee, bs[0].effectiveMinFee, "nested swap shares its block's floor");

        uint160 sqrtMid = attacker.sqrtAtReentry();
        uint160 sqrtEnd = attacker.sqrtAfterNested();
        assertTrue(sqrtMid < sqrtBefore, "outer zeroForOne pushed price down");
        assertTrue(sqrtEnd < sqrtMid, "nested zeroForOne pushed it further down");

        // --- independent oracle ---
        uint256 impactOuter = ImpactOracle.priceImpactPips(sqrtBefore, sqrtMid);
        uint256 impactNested = ImpactOracle.priceImpactPips(sqrtMid, sqrtEnd);
        assertGt(impactOuter, 0, "outer impact must be measurable");
        assertGt(impactNested, 0, "nested impact must be measurable");

        assertEq(as_[0].priceImpact, impactOuter, "outer realized impact vs independent oracle");
        assertEq(as_[1].priceImpact, impactNested, "nested realized impact vs independent oracle");

        // --- composition ---
        int256 decayed = Phase5Decay.decay(cumBefore, dt, DECAY);
        assertTrue(decayed != cumBefore, "the decay term must bite or it is not being tested");
        int256 expectedOuterCum = decayed + ImpactOracle.directional(true, impactOuter);
        assertEq(as_[0].cumPriceImpact, expectedOuterCum, "outer cum = decay(prev) + dir(outer)");

        // The nested swap re-decays with dt == 0 (the outer just stamped lastSwapTimestamp), which
        // is the identity, then appends its own realized impact.
        int256 expectedFinalCum =
            Phase5Decay.decay(expectedOuterCum, 0, DECAY) + ImpactOracle.directional(true, impactNested);
        assertEq(as_[1].cumPriceImpact, expectedFinalCum, "nested cum = outer cum + dir(nested)");

        (uint160 storedSqrtBefore, uint48 storedTs,, int256 storedCum) = hook.poolData(poolId);
        assertEq(storedCum, expectedFinalCum, "stored accumulator == composed value");

        // sqrtPriceX96Before is not cross-corrupted: the outer consumed its snapshot in _afterSwap
        // (before the take), and the nested swap installed its own.
        assertEq(bs[0].sqrtPriceX96Before, sqrtBefore, "outer snapshot = pre-swap price");
        assertEq(bs[1].sqrtPriceX96Before, sqrtMid, "nested snapshot = mid price, not the outer's");
        assertEq(storedSqrtBefore, sqrtMid, "final stored snapshot belongs to the nested swap");
        // opaque timestamp read (TIMESTAMP-fold hazard); storedTs is a contract read
        assertEq(storedTs, uint48(vm.getBlockTimestamp()), "lastSwapTimestamp consistent");
    }

    /// @notice XSUB-1, signed composition: the nested swap runs in the OPPOSITE direction, so its
    ///         contribution must SUBTRACT from the accumulator. A sign/ordering bug (e.g. the
    ///         nested swap reading a stale `sqrtPriceX96Before`) shows up here as the wrong
    ///         magnitude, not merely the wrong total. Run across a non-zero time gap so the decay
    ///         term is live here too.
    function test_XSUB1_nestedOppositeDirection_accumulatorComposesSigned() public {
        vm.warp(block.timestamp + 900);

        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(poolId);
        // opaque timestamp read (TIMESTAMP-fold hazard); lastTsBefore is a contract read
        uint256 dt = vm.getBlockTimestamp() - lastTsBefore;
        assertEq(dt, 900);
        (uint160 sqrtBefore,,,) = manager.getSlot0(poolId);

        _armNestedSwap(key, poolId, false, -NESTED); // oneForZero, exact input
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(as_.length, 2, "each swap recorded exactly once");

        uint160 sqrtMid = attacker.sqrtAtReentry();
        uint160 sqrtEnd = attacker.sqrtAfterNested();
        assertTrue(sqrtEnd > sqrtMid, "nested oneForZero pushed the price back up");

        uint256 impactOuter = ImpactOracle.priceImpactPips(sqrtBefore, sqrtMid);
        uint256 impactNested = ImpactOracle.priceImpactPips(sqrtMid, sqrtEnd);
        assertGt(impactNested, 0);

        int256 decayed = Phase5Decay.decay(cumBefore, dt, DECAY);
        assertTrue(decayed != cumBefore, "decay term is live");
        int256 expectedOuterCum = decayed + ImpactOracle.directional(true, impactOuter);
        int256 expectedFinalCum =
            Phase5Decay.decay(expectedOuterCum, 0, DECAY) + ImpactOracle.directional(false, impactNested);

        assertEq(as_[0].cumPriceImpact, expectedOuterCum, "outer leg");
        assertEq(as_[1].cumPriceImpact, expectedFinalCum, "nested leg subtracts");
        assertTrue(expectedFinalCum > expectedOuterCum, "opposite direction must reduce imbalance");

        (,,, int256 storedCum) = hook.poolData(poolId);
        assertEq(storedCum, expectedFinalCum, "stored accumulator == signed composition");
    }

    /// @notice XSUB-1, effects-before-interactions: an observer re-entered during the take sees the
    ///         outer swap's accumulator ALREADY final. If the take ran before the state write, the
    ///         mid-take read would show the pre-swap accumulator and a nested swap could compose
    ///         against stale state.
    function test_XSUB1_effectsWrittenBeforeInteraction_observerSeesFinalState() public {
        vm.warp(block.timestamp + 1500);
        (uint160 sqrtBefore,,,) = manager.getSlot0(poolId);

        _armObserve();
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 1, "observer ran inside the take");

        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        assertEq(as_.length, 1, "no nested swap here");

        assertEq(attacker.cumAtReentry(), as_[0].cumPriceImpact, "cum written before the external take");
        // opaque timestamp read (TIMESTAMP-fold hazard); lastTsAtReentry is a contract read
        assertEq(attacker.lastTsAtReentry(), uint48(vm.getBlockTimestamp()), "timestamp written before the take");
        assertEq(attacker.dataSqrtBeforeAtReentry(), sqrtBefore, "snapshot intact during the take");

        // and nothing moves after the take returns
        (uint160 storedSqrtBefore, uint48 storedTs,, int256 storedCum) = hook.poolData(poolId);
        assertEq(storedCum, attacker.cumAtReentry(), "no post-take accumulator write");
        assertEq(storedTs, attacker.lastTsAtReentry());
        assertEq(storedSqrtBefore, attacker.dataSqrtBeforeAtReentry());

        // The stash still holds the OUTER swap's rate at re-entry time.
        uint24 expectedHookFee = uint24((uint256(bs[0].dynamicFeePips) * BPS) / 10_000);
        assertEq(attacker.stashAtReentry(), expectedHookFee, "stash = split of this swap's dynamic fee");
        assertGt(expectedHookFee, 0, "rate must be non-zero or the probe is vacuous");
    }

    /// @notice XSUB-1 at depth 2. The outer swap's take (currency1) re-enters a oneForZero swap,
    ///         whose own take (currency0) re-enters a third zeroForOne swap. Three swaps, three
    ///         accumulator writes, one linear composition — nothing is lost, duplicated, or
    ///         attributed to the wrong leg. Depth stops at 2 because `ReentrantERC20`'s one-shot
    ///         guard blocks currency1 from firing again while its callback is on the stack.
    function test_XSUB1_twoLevelNesting_eachSwapRecordedExactlyOnce() public {
        vm.warp(block.timestamp + 1200);

        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(poolId);
        // opaque timestamp read (TIMESTAMP-fold hazard); lastTsBefore is a contract read
        uint256 dt = vm.getBlockTimestamp() - lastTsBefore;
        assertEq(dt, 1200);
        (uint160 p0,,,) = manager.getSlot0(poolId);

        // depth 2: fires from inside the depth-1 swap's own take (currency0 side)
        attacker0.setNested(key, poolId, true, -NESTED / 2);
        token0.arm(address(attacker0), abi.encodeCall(Phase5NestedSwapper.onTakeSwap, ()), true, false, true);
        // depth 1: fires from inside the outer swap's take (currency1 side)
        _armNestedSwap(key, poolId, false, -NESTED);

        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 1, "depth-1 re-entry fired once");
        assertEq(attacker0.fired(), 1, "depth-2 re-entry fired once");

        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(bs.length, 3, "three swaps");
        assertEq(as_.length, 3, "three accumulator updates - no double counting");
        assertEq(takes.length, 3, "three settlements");

        uint160 p1 = attacker.sqrtAtReentry(); // after outer
        uint160 p2 = attacker0.sqrtAtReentry(); // after depth-1
        uint160 p3 = attacker0.sqrtAfterNested(); // after depth-2
        assertEq(attacker.sqrtAfterNested(), p3, "depth-1 observes the depth-2 price on return");

        int256 decayed = Phase5Decay.decay(cumBefore, dt, DECAY);
        assertTrue(decayed != cumBefore, "decay term is live");
        int256 c1 = decayed + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p0, p1));
        int256 c2 = c1 + ImpactOracle.directional(false, ImpactOracle.priceImpactPips(p1, p2));
        int256 c3 = c2 + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p2, p3));

        assertEq(as_[0].cumPriceImpact, c1, "outer leg");
        assertEq(as_[1].cumPriceImpact, c2, "depth-1 leg composes on the outer's written state");
        assertEq(as_[2].cumPriceImpact, c3, "depth-2 leg composes on the depth-1 state");

        (uint160 storedSqrtBefore,,, int256 storedCum) = hook.poolData(poolId);
        assertEq(storedCum, c3, "final accumulator == 3-leg composition");
        assertEq(storedSqrtBefore, p2, "deepest swap owns the final snapshot");
    }

    /// @notice XSUB-1, non-swap mid-unlock action: adding liquidity is also legal while the manager
    ///         is unlocked. It must not touch the accumulator (no swap happened) nor the in-flight
    ///         settlement, even though it lands between the hook's state write and its transfer.
    function test_XSUB1_reentrantAddLiquidityDuringTake_leavesAccumulatorAndTakeIntact() public {
        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        int256 controlCum = _afterSwapEvents(ctrlLogs)[0].cumPriceImpact;
        uint128 controlTake = _lastTake(ctrlLogs).amount1;
        vm.revertToState(snap);

        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), 1e19
        );
        attacker.setNestedLiquidity(TICK_LOWER, TICK_UPPER, int256(uint256(liq)));
        token1.arm(address(attacker), abi.encodeCall(Phase5NestedSwapper.onTakeAddLiquidity, ()), true, false, true);

        uint128 liqBefore = manager.getLiquidity(poolId);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 1, "the LP add executed mid-settlement");
        assertGt(manager.getLiquidity(poolId), liqBefore, "and it really landed");

        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(as_.length, 1, "an LP op is not a swap - no extra accumulator write");
        assertEq(as_[0].cumPriceImpact, controlCum, "accumulator identical to the no-re-entry control");
        assertEq(_lastTake(logs).amount1, controlTake, "outer take unchanged");

        (,,, int256 storedCum) = hook.poolData(poolId);
        assertEq(storedCum, controlCum);
    }

    /// @notice XSUB-1: a FRESH `PoolManager.unlock` from inside the take is rejected by v4's lock,
    ///         so the only reachable re-entry shape is one that rides the open unlock. Documents
    ///         the boundary the other tests operate inside; the outer swap is otherwise unaffected.
    function test_XSUB1_freshUnlockReentry_rejectedByV4Lock() public {
        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        uint128 controlTake = _lastTake(ctrlLogs).amount1;
        vm.revertToState(snap);

        token1.arm(address(attacker), abi.encodeCall(Phase5NestedSwapper.onTakeTryFreshUnlock, ()), true, false, true);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 1, "re-entry attempt ran");
        assertEq(
            attacker.unlockErrorSelector(), IPoolManager.AlreadyUnlocked.selector, "v4 must reject a nested unlock"
        );
        assertEq(_lastTake(logs).amount1, controlTake, "failed re-entry leaves the take untouched");
    }

    /// @notice XSUB-1, saturation branch: the recurrence is specified with a SATURATING add, and a
    ///         re-entrant nested swap must not be able to push the accumulator past the clamp (a
    ///         wrapping add would flip a maximally-positive imbalance to maximally-negative and
    ///         invert every subsequent fee). The accumulator is pre-loaded near `int256.max` with a
    ///         direct storage poke — a state the contract can hold but that no swap sequence can
    ///         reach inside a test — and everything after the poke runs the real path.
    function test_XSUB1_saturatingAccumulatorHoldsUnderReentry() public {
        int256 nearMax = type(int256).max - 10;
        uint256 snap = vm.snapshotState();

        // Both legs run oneForZero (positive contribution), so the outer swap's UNSPECIFIED
        // currency is currency0 — the re-entry has to be armed on token0.
        // --- arm A: nested leg in the SAME (positive) direction => must clamp, not wrap ---
        _pokeCumPriceImpact(poolId, nearMax);
        (uint160 p0,,,) = manager.getSlot0(poolId);
        _armNestedSwapOnCurrency0(key, poolId, false, -NESTED); // nested oneForZero: positive
        (, Vm.Log[] memory logs) = _swap(key, false, -OUTER); // outer oneForZero: positive too

        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(attacker0.fired(), 1, "the currency0 take fired the re-entry");
        assertEq(as_.length, 2, "two accumulator updates");

        uint256 iOuter = ImpactOracle.priceImpactPips(p0, attacker0.sqrtAtReentry());
        uint256 iNested = ImpactOracle.priceImpactPips(attacker0.sqrtAtReentry(), attacker0.sqrtAfterNested());
        assertGt(iOuter, 10, "outer impact must exceed the 10-pip headroom or nothing saturates");

        int256 e1 = Phase5Decay.addSat(Phase5Decay.decay(nearMax, 0, DECAY), ImpactOracle.directional(false, iOuter));
        assertEq(e1, type(int256).max, "the outer leg must actually hit the clamp");
        int256 e2 = Phase5Decay.addSat(e1, ImpactOracle.directional(false, iNested));

        assertEq(as_[0].cumPriceImpact, e1, "outer leg saturates");
        assertEq(as_[1].cumPriceImpact, e2, "nested leg composes on the saturated value");
        (,,, int256 stored) = hook.poolData(poolId);
        assertEq(stored, type(int256).max, "stays clamped - no wrap under re-entry");
        assertGt(stored, 0, "a wrapping add would have flipped the sign");

        // --- arm B: nested leg in the OPPOSITE direction => comes back DOWN from the clamp ---
        vm.revertToState(snap);
        _pokeCumPriceImpact(poolId, nearMax);
        (uint160 q0,,,) = manager.getSlot0(poolId);
        _armNestedSwapOnCurrency0(key, poolId, true, -NESTED); // nested zeroForOne: negative
        (, Vm.Log[] memory logsB) = _swap(key, false, -OUTER);

        assertEq(attacker0.fired(), 1, "the currency0 take fired the re-entry");
        uint256 jOuter = ImpactOracle.priceImpactPips(q0, attacker0.sqrtAtReentry());
        uint256 jNested = ImpactOracle.priceImpactPips(attacker0.sqrtAtReentry(), attacker0.sqrtAfterNested());
        assertGt(jOuter, 10, "outer leg must saturate here too");
        assertGt(jNested, 0, "nested leg must move the price");

        int256 f1 = Phase5Decay.addSat(Phase5Decay.decay(nearMax, 0, DECAY), ImpactOracle.directional(false, jOuter));
        int256 f2 = Phase5Decay.addSat(f1, ImpactOracle.directional(true, jNested));
        assertEq(f2, type(int256).max - int256(jNested), "unsaturating is a plain subtraction");

        AfterSwapEvent[] memory asB = _afterSwapEvents(logsB);
        assertEq(asB[0].cumPriceImpact, f1);
        assertEq(asB[1].cumPriceImpact, f2, "the clamp is not sticky - the nested leg unwinds it");
    }

    /// @notice XSUB-1, the economic statement behind the ordering: re-entering buys NO fee
    ///         discount. A swap nested inside another swap's settlement is charged exactly what the
    ///         same swap would be charged if it were submitted sequentially, from the same pool
    ///         state and timestamp — because the accumulator is already final when the nested
    ///         `_beforeSwap` reads it. If the take ran before the state write, the nested swap would
    ///         price off a stale (smaller) accumulator and undercut the honest sequential swapper.
    function test_XSUB1_reentryBuysNoFeeDiscount_nestedFeeEqualsSequentialFee() public {
        uint256 snap = vm.snapshotState();

        // --- sequential: swap A, then swap B in the same block ---
        _swap(key, true, -OUTER);
        (, Vm.Log[] memory seqLogs) = _swap(key, true, -NESTED);
        BeforeSwapEvent memory seqB = _beforeSwapEvents(seqLogs)[0];
        AfterSwapEvent memory seqAfter = _afterSwapEvents(seqLogs)[0];

        vm.revertToState(snap);

        // --- nested: swap B fires inside swap A's treasury take ---
        _armNestedSwap(key, poolId, true, -NESTED);
        (, Vm.Log[] memory nestLogs) = _swap(key, true, -OUTER);
        BeforeSwapEvent memory nestB = _beforeSwapEvents(nestLogs)[1];
        AfterSwapEvent memory nestAfter = _afterSwapEvents(nestLogs)[1];

        assertEq(nestB.decayedCumPriceImpact, seqB.decayedCumPriceImpact, "same accumulator input");
        assertEq(nestB.priceImpact, seqB.priceImpact, "same simulated impact");
        assertEq(nestB.dynamicFeePips, seqB.dynamicFeePips, "same dynamic fee - re-entry is not cheaper");
        assertEq(nestAfter.cumPriceImpact, seqAfter.cumPriceImpact, "same accumulator outcome");
        assertGt(nestB.dynamicFeePips, MAX_MIN_FEE, "fee must be off the floor or the comparison is blind");
    }

    /// @notice XSUB-1 fuzzed over both legs AND over the inter-swap gap: for any outer/nested size,
    ///         any nested direction and any elapsed time (spanning `0 < dt < L` and `dt >= L`, where
    ///         the decay term collapses to zero), the accumulator ends at
    ///         `decay(prev, dt) + dir(realized_outer) + dir(realized_nested)`, measured against
    ///         slot0 prices captured outside the hook.
    function testFuzz_XSUB1_compositionHoldsForAnyNesting(
        uint256 outerSeed,
        uint256 nestedSeed,
        bool nestedDir,
        uint256 dtSeed
    ) public {
        uint256 dtWarp = bound(dtSeed, 0, 2 * DECAY); // spans both decay regimes
        vm.warp(block.timestamp + dtWarp);

        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(poolId);
        // opaque timestamp read (TIMESTAMP-fold hazard); lastTsBefore is a contract read
        uint256 dt = vm.getBlockTimestamp() - lastTsBefore;
        assertEq(dt, dtWarp, "the warp is the only source of elapsed time");
        (uint160 p0,,,) = manager.getSlot0(poolId);

        _armNestedSwap(key, poolId, nestedDir, -int256(bound(nestedSeed, 1e16, 1e20)));
        (, Vm.Log[] memory logs) = _swap(key, true, -int256(bound(outerSeed, 1e17, 1e20)));

        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        assertEq(_afterSwapEvents(logs).length, 2, "exactly two accumulator updates");
        assertEq(
            bs[0].effectiveMinFee,
            Phase5Decay.effectiveMinFee(MIN_MIN_FEE, MAX_MIN_FEE, dt, DECAY),
            "min-fee ramp at the fuzzed gap"
        );

        uint160 p1 = attacker.sqrtAtReentry();
        uint160 p2 = attacker.sqrtAfterNested();

        int256 expected = Phase5Decay.decay(cumBefore, dt, DECAY)
            + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p0, p1));
        expected += ImpactOracle.directional(nestedDir, ImpactOracle.priceImpactPips(p1, p2));

        (,,, int256 storedCum) = hook.poolData(poolId);
        assertEq(storedCum, expected, "composition under re-entry");
    }

    /// @notice XSUB-1 fuzzed over the POOL CONFIGURATION as well as the trade and the clock. Each
    ///         run stands up a fresh pool (a distinct tick spacing yields a distinct poolId) with a
    ///         fuzzed config — a non-degenerate min-fee ramp, fuzzed `maxFee` and
    ///         `timeDecayLength` — and a fuzzed `protocolFeeBps`, then runs
    ///         warm-up -> warp(dt) -> outer swap with a nested swap inside its take.
    ///
    ///         This is what stops the composition property from being pinned to one hard-coded
    ///         shape: the decay length, the ramp endpoints, the fee clamp and the protocol split all
    ///         move, and the accumulator recurrence plus the ramp must hold against independent
    ///         transcriptions in every run.
    /// @dev Fuzzed config + protocol bps, derived from the seeds in `_deriveFuzzedCfg`.
    ///      Held in memory (one stack slot) rather than as locals: inlined, they push the
    ///      instrumented via-IR frame past 16 slots and `forge coverage --ir-minimum` fails
    ///      stack-too-deep.
    struct FuzzedCfg {
        uint24 minMin;
        uint24 maxMin;
        uint24 maxFee;
        uint256 decayLen;
        uint16 bps;
    }

    /// @dev Every bound respects configurePool's own lattice.
    function _deriveFuzzedCfg(uint256 cfgSeed, uint16 bpsSeed) private pure returns (FuzzedCfg memory c) {
        c.minMin = uint24(bound(cfgSeed % 1e4, 100, 5_000));
        c.maxMin = uint24(bound(uint256(keccak256(abi.encode(cfgSeed, "mm"))), c.minMin + 1, 50_000));
        // maxFee ranges all the way DOWN to maxMin (the lattice floor), not just the comfortable
        // [10%, 50%] headroom band: at the low end it sits far below the raw impact-derived fee of
        // a 1e17..1e20 trade, so the cap genuinely BINDS in a substantial share of runs and the
        // clamp assertion below is live, not inert. The binding case is additionally pinned
        // deterministically by `test_XSUB1_maxFeeClampBindsUnderReentry`.
        c.maxFee = uint24(bound(uint256(keccak256(abi.encode(cfgSeed, "mx"))), c.maxMin, 500_000));
        c.decayLen = bound(uint256(keccak256(abi.encode(cfgSeed, "dl"))), 300, 1 days);
        // bps >= 500 with minMin >= 100 guarantees a non-zero stashed rate, i.e. the take (and so
        // the re-entry) always fires; the cap itself is covered deterministically elsewhere.
        c.bps = uint16(bound(uint256(bpsSeed), 500, CAP_BPS));
    }

    /// @dev Run context for `testFuzz_XSUB1_compositionAcrossFuzzedConfigAndTime`, carried across
    ///      the setup/verify frame split as one memory pointer (same stack-depth reasoning as
    ///      `FuzzedCfg` above).
    struct Xsub1Run {
        PoolKey k;
        PoolId id;
        uint256 dt;
        int256 cumBefore;
        int256 outer;
        int256 nested;
        bool nestedDir;
    }

    function testFuzz_XSUB1_compositionAcrossFuzzedConfigAndTime(
        uint256 tsSeed,
        uint256 cfgSeed,
        uint256 dtSeed,
        uint256 tradeSeed,
        bool nestedDir,
        uint16 bpsSeed
    ) public {
        FuzzedCfg memory cfg = _deriveFuzzedCfg(cfgSeed, bpsSeed);

        Xsub1Run memory r;
        r.nestedDir = nestedDir;
        r.outer = -int256(bound(tradeSeed, 1e17, 1e20));
        r.nested = -int256(bound(uint256(keccak256(abi.encode(tradeSeed, "n"))), 1e16, 1e20));

        _xsub1Setup(cfg, r, tsSeed, dtSeed);
        _xsub1RunAndAssert(cfg, r);
    }

    /// @dev Frame 1: fresh pool + liquidity + protocol bps, warm-up swap, fuzzed warp. Fills
    ///      `r.k`, `r.id`, `r.dt`, `r.cumBefore`.
    function _xsub1Setup(FuzzedCfg memory cfg, Xsub1Run memory r, uint256 tsSeed, uint256 dtSeed) private {
        (PoolKey memory kf, PoolId idf) =
            _initAndConfigure(_freshTickSpacing(tsSeed), 0, cfg.minMin, cfg.maxMin, cfg.maxFee, cfg.decayLen, 0);
        r.k = kf;
        r.id = idf;
        _addLiquidity(kf, TICK_LOWER, TICK_UPPER, 1e21);
        _setProtocolFeeBps(cfg.bps);

        // warm-up swap: seeds a non-zero accumulator and stamps the swap clock
        _swap(kf, true, -WARMUP);
        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(idf);
        assertTrue(cumBefore != 0, "warm-up seeded the accumulator");
        r.cumBefore = cumBefore;

        vm.warp(block.timestamp + bound(dtSeed, 0, 2 * cfg.decayLen));
        // opaque timestamp read (TIMESTAMP-fold hazard); lastTsBefore is a contract read
        r.dt = vm.getBlockTimestamp() - lastTsBefore;
    }

    /// @dev Frame 2: the outer swap with the armed nested swap inside its take, then the full
    ///      fee-pipeline and accumulator-composition assertions.
    function _xsub1RunAndAssert(FuzzedCfg memory cfg, Xsub1Run memory r) private {
        uint256 dt = r.dt;
        (uint160 p0,,,) = manager.getSlot0(r.id);
        attacker.setWatch(r.k, r.id);
        _armNestedSwap(r.k, r.id, r.nestedDir, r.nested);
        (, Vm.Log[] memory logs) = _swap(r.k, true, r.outer);

        assertEq(attacker.fired(), 1, "the take fired the re-entry");
        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        assertEq(_afterSwapEvents(logs).length, 2, "exactly two accumulator updates");
        assertGt(attacker.stashAtReentry(), 0, "a non-zero protocol rate was stashed");

        // The full fee pipeline (raw scenario fee -> floor -> cap), transcribed and asserted as an
        // EQUALITY, so the cap dimension is live in every run where it binds (a bare `<= maxFee`
        // can never bind when maxFee has headroom). The raw inputs (simulated impact, decayed cum)
        // are the hook's own emitted intermediates: this assertion pins the floor/cap ARITHMETIC;
        // impact provenance is the composition oracle's job (below, against slot0 prices).
        {
            uint24 effMin = Phase5Decay.effectiveMinFee(cfg.minMin, cfg.maxMin, dt, cfg.decayLen);
            assertEq(bs[0].effectiveMinFee, effMin, "min-fee ramp under the fuzzed config");
            // outer swap is zeroForOne and the warm-up seeded cum <= 0 (decay preserves the
            // sign), so the increasing-imbalance branch always fires: raw = k x midpoint of
            // the |cum| -> |estCum| leg = |cum| + |estCum| exactly (k = 2, no truncation)
            int256 estCum = Phase5Decay.addSat(bs[0].decayedCumPriceImpact, -int256(bs[0].priceImpact));
            uint256 raw = uint256(-bs[0].decayedCumPriceImpact) + (estCum < 0 ? uint256(-estCum) : uint256(estCum));
            uint24 expectedFee = raw < effMin ? effMin : (raw > cfg.maxFee ? cfg.maxFee : uint24(raw));
            assertEq(bs[0].dynamicFeePips, expectedFee, "fee == cap(floor(raw)) under the fuzzed config");
        }

        // the accumulator recurrence, against independent decay + impact transcriptions
        int256 expected = Phase5Decay.addSat(
            Phase5Decay.decay(r.cumBefore, dt, cfg.decayLen),
            ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p0, attacker.sqrtAtReentry()))
        );
        expected = Phase5Decay.addSat(
            expected,
            ImpactOracle.directional(
                r.nestedDir, ImpactOracle.priceImpactPips(attacker.sqrtAtReentry(), attacker.sqrtAfterNested())
            )
        );

        (,,, int256 storedCum) = hook.poolData(r.id);
        assertEq(storedCum, expected, "composition under re-entry, fuzzed config");
    }

    /// @notice XSUB-1 with the maxFee cap PROVABLY BINDING. The config fuzz above asserts the full
    ///         fee pipeline wherever the fuzzed cap happens to bind, but a statistical campaign
    ///         cannot guarantee a binding run — this vector can. A fresh pool is configured with a
    ///         tight cap (1_000 pips = 0.1%, far below the ~6000-pip raw impact of the OUTER trade
    ///         on this fixture), and both the outer leg and the nested leg that re-enters inside
    ///         its take must price at EXACTLY the cap — while the accumulator composition, which is
    ///         fed by realized prices rather than by the clamped fee, still holds under re-entry.
    function test_XSUB1_maxFeeClampBindsUnderReentry() public {
        uint24 tightMaxFee = 1_000; // 0.1%; MAX_MIN_FEE (500) <= 1_000 keeps the config lattice valid
        (PoolKey memory kc, PoolId idc) = _initAndConfigure(5, 0, MIN_MIN_FEE, MAX_MIN_FEE, tightMaxFee, DECAY, 0);
        _addLiquidity(kc, TICK_LOWER, TICK_UPPER, 1e21);
        _swap(kc, true, -WARMUP); // warm-up swap seeds the accumulator

        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(idc);
        assertTrue(cumBefore != 0, "warm-up seeded the accumulator");
        (uint160 p0,,,) = manager.getSlot0(idc);

        attacker.setWatch(kc, idc);
        _armNestedSwap(kc, idc, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(kc, true, -OUTER);

        assertEq(attacker.fired(), 1, "the take fired the re-entry");
        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(bs.length, 2, "outer + nested");
        assertEq(as_.length, 2, "one accumulator write each");

        // the cap must actually BIND on both legs: each leg's raw simulated impact alone already
        // exceeds it, so the equality below cannot be satisfied by an unclamped fee
        assertGt(bs[0].priceImpact, uint256(tightMaxFee), "outer raw impact exceeds the cap");
        assertGt(bs[1].priceImpact, uint256(tightMaxFee), "nested raw impact exceeds the cap");
        assertEq(bs[0].dynamicFeePips, tightMaxFee, "outer fee == maxFee: the cap binds");
        assertEq(bs[1].dynamicFeePips, tightMaxFee, "nested fee == maxFee: the cap binds mid-take too");

        // and the composition is indifferent to the clamp (prices feed the accumulator, fees do not)
        int256 c1 = Phase5Decay.decay(cumBefore, block.timestamp - lastTsBefore, DECAY)
            + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p0, attacker.sqrtAtReentry()));
        int256 c2 = c1
            + ImpactOracle.directional(
                true, ImpactOracle.priceImpactPips(attacker.sqrtAtReentry(), attacker.sqrtAfterNested())
            );
        assertEq(as_[0].cumPriceImpact, c1, "outer leg composes at the cap");
        assertEq(as_[1].cumPriceImpact, c2, "nested leg composes at the cap");
        (,,, int256 storedClamped) = hook.poolData(idc);
        assertEq(storedClamped, c2, "stored accumulator == composition");
    }

    /// @notice The outer swap is the pool's FIRST swap (pricing off cum = 0 with a never-stamped
    ///         swap clock), and the nested swap that fires inside its take is therefore the
    ///         pool's second swap, running with `timeSinceLastSwap == 0` off the freshly written
    ///         state. Uses the untouched pool B.
    function test_XSUB1_nestedSwapDuringFirstSwapTake_composesFromFreshPool() public {
        (, uint48 tsBefore,, int256 cumBefore) = hook.poolData(poolIdB);
        assertEq(uint256(tsBefore), 0, "pool B must still be unswapped");
        assertEq(cumBefore, 0);

        (uint160 p0,,,) = manager.getSlot0(poolIdB);

        attacker.setWatch(keyB, poolIdB);
        _armNestedSwap(keyB, poolIdB, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(keyB, true, -OUTER);

        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(bs.length, 2);
        assertEq(as_.length, 2);

        // outer priced normally off a zero accumulator: k x midpoint of the 0 -> P leg = P
        assertEq(bs[0].decayedCumPriceImpact, 0, "first swap must see a zero accumulator");
        assertGt(bs[0].priceImpact, 0, "first swap simulates a real impact");
        {
            uint256 raw = bs[0].priceImpact;
            uint24 expected =
                raw < bs[0].effectiveMinFee ? bs[0].effectiveMinFee : (raw > MAX_FEE ? MAX_FEE : uint24(raw));
            assertEq(bs[0].dynamicFeePips, expected, "first swap fee != fresh-push recompute");
        }
        // nested runs off the freshly written state, not a zero accumulator
        assertEq(bs[1].decayedCumPriceImpact, as_[0].cumPriceImpact, "nested reads the outer's write");

        uint160 p1 = attacker.sqrtAtReentry();
        uint160 p2 = attacker.sqrtAfterNested();
        int256 c1 = ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p0, p1));
        int256 c2 = c1 + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p1, p2));

        assertEq(as_[0].cumPriceImpact, c1, "first swap seeds the accumulator");
        assertEq(as_[1].cumPriceImpact, c2, "nested swap appends, from the freshly written state");

        (, uint48 tsAfter,, int256 storedCum) = hook.poolData(poolIdB);
        assertEq(uint256(tsAfter), block.timestamp, "swap clock stamped");
        assertEq(storedCum, c2);

        // the outer's stashed rate is its own fee's protocol slice, and the nested clobbered it
        assertEq(attacker.stashAtReentry(), uint24((uint256(bs[0].dynamicFeePips) * BPS) / 10_000));
        assertTrue(attacker.stashAfterNested() != attacker.stashAtReentry(), "stash clobbered");
    }

    /// @notice XSUB-1 with the trigger token left armed for the WHOLE transaction, so the re-entry
    ///         is not "exactly once by construction": after the hook's take completes, the router's
    ///         own output transfer fires the adversary a SECOND time, still inside the same unlock.
    ///         Three swaps land in one user transaction and the composition must still be linear —
    ///         and the outer swap's settled amount must still match its no-re-entry control.
    function test_XSUB1_tokenArmedAllTx_secondReentryDuringRouterTakeStillComposes() public {
        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        uint128 controlTake = _lastTake(ctrlLogs).amount1;
        vm.revertToState(snap);

        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(poolId);
        uint256 dt = block.timestamp - lastTsBefore;
        (uint160 p0,,,) = manager.getSlot0(poolId);

        attacker.setDisarmAfterFiring(false); // stays armed for the rest of the transaction
        _armNestedSwap(key, poolId, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 2, "a second, later re-entry really happened");
        assertEq(token1.reenterCount(), 2, "token fired twice in one transaction");

        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(as_.length, 3, "outer + two nested swaps, each recorded exactly once");

        Phase5NestedSwapper.Firing memory f0 = attacker.firingAt(0); // inside the hook's take
        Phase5NestedSwapper.Firing memory f1 = attacker.firingAt(1); // inside the router's take
        assertEq(f0.sqrtAfterNested, f1.sqrtAtReentry, "price is stable across the hook-take -> router-take boundary");

        int256 c1 = Phase5Decay.decay(cumBefore, dt, DECAY)
            + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p0, f0.sqrtAtReentry));
        int256 c2 =
            c1 + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(f0.sqrtAtReentry, f0.sqrtAfterNested));
        int256 c3 =
            c2 + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(f1.sqrtAtReentry, f1.sqrtAfterNested));

        assertEq(as_[0].cumPriceImpact, c1, "outer leg");
        assertEq(as_[1].cumPriceImpact, c2, "first nested leg (hook take)");
        assertEq(as_[2].cumPriceImpact, c3, "second nested leg (router take)");
        (,,, int256 storedCum) = hook.poolData(poolId);
        assertEq(storedCum, c3, "final accumulator == 3-leg composition");

        // Settlement order: nested#1 (inside the outer take), then the outer, then nested#2.
        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 3, "three settlements");
        assertEq(takes[1].amount1, controlTake, "the outer take is still control-identical");
    }

    // =====================================================================================
    // SETTLE-12 — hookFee + take128 are computed into locals BEFORE the external take
    // =====================================================================================

    /// @notice SETTLE-12, primary vector. The nested swap PROVABLY overwrites the pool's transient
    ///         hookFee stash (asserted via `SimHookHarness.readStash` sampled on both sides of the
    ///         nested swap), yet the outer swap settles the exact amount it would have settled with
    ///         no re-entry at all — because `_takeProtocolFeeOnAfterSwap` loads the stash and
    ///         computes `take128` into locals before calling out (`AscntBaseHook.sol:165-186`).
    ///
    ///         This is also the vector that disproves the "no hook re-entry in this bracket" comment
    ///         at `AscntBaseHook.sol:198-204` — see the contract-level note above.
    ///
    ///         The unlock closing is itself the proof that the RETURNED delta equals the amount
    ///         taken: v4 credits the hook `hookDeltaUnspecified` and debits it `take128`; any
    ///         divergence leaves the hook with a non-zero delta and reverts `CurrencyNotSettled`.
    ///
    ///         Honest scope note: `outerTake == controlTake` below cannot fail by construction —
    ///         the emitted amount IS `take128`, the argument of the in-flight `unspecified.take`,
    ///         and the re-entry fires inside that very call, after the amount is already fixed. An
    ///         implementation that re-read the clobbered stash after the call would have to settle
    ///         a SECOND amount, and the load-bearing check for that is the unlock closing
    ///         (`CurrencyNotSettled`) plus the treasury-sum assertion. The falsifiable content
    ///         here is the stash-clobber demonstration and the settlement conservation, not the
    ///         event-amount equality (kept as corroboration).
    function test_SETTLE12_nestedSwapClobbersStash_outerTakeUnchanged() public {
        uint256 snap = vm.snapshotState();

        // --- control: identical outer swap, no re-entry ---
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        TakeEvent[] memory ctrlTakes = _takeEvents(ctrlLogs);
        assertEq(ctrlTakes.length, 1, "control: single take");
        uint128 controlTake = ctrlTakes[0].amount1;
        assertGt(controlTake, 0, "control take must be non-zero or the comparison is vacuous");

        vm.revertToState(snap);

        // --- attack: same outer swap, nested swap fires mid-take ---
        uint256 treasuryBefore = token1.balanceOf(TREASURY);
        _armNestedSwap(key, poolId, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 2, "nested take settles first, outer take last");
        uint128 nestedTake = takes[0].amount1;
        uint128 outerTake = takes[1].amount1;

        // the stash really was clobbered mid-settlement
        assertGt(attacker.stashAtReentry(), 0, "outer rate stashed");
        assertTrue(
            attacker.stashAfterNested() != attacker.stashAtReentry(),
            "nested swap must overwrite the stash, else this test proves nothing"
        );

        assertEq(outerTake, controlTake, "outer settled amount is immune to the stash clobber");
        assertEq(
            token1.balanceOf(TREASURY) - treasuryBefore,
            uint256(nestedTake) + uint256(outerTake),
            "treasury received exactly both takes (no lost/duplicated settlement)"
        );
    }

    /// @notice SETTLE-12 / cross-pool isolation: nesting a swap on a DIFFERENT pool of the same hook
    ///         leaves the outer pool's transient stash byte-identical AND its whole `poolData` tuple
    ///         untouched — including `sqrtPriceX96Before`, which XSUB-1 names explicitly. The two
    ///         pools sit in different transient slots (`keccak256(poolId, _HOOK_FEE_STASH)`) and
    ///         different storage entries.
    function test_SETTLE12_nestedSwapOnSecondPool_outerStateAndTakeUntouched() public {
        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        uint128 controlTake = _lastTake(ctrlLogs).amount1;
        vm.revertToState(snap);

        _armNestedSwap(keyB, poolIdB, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 2, "one take per pool");
        assertEq(takes[0].poolId, PoolId.unwrap(poolIdB), "pool B settles first (inside the take)");
        assertEq(takes[1].poolId, PoolId.unwrap(poolId), "outer pool settles last");

        assertEq(
            attacker.stashAfterNested(), attacker.stashAtReentry(), "a swap on pool B must not touch pool A's stash"
        );
        assertGt(attacker.nestedStashAfter(), 0, "pool B stashed its own rate");

        // pool A's full runtime tuple, sampled on both sides of the pool-B swap
        assertEq(attacker.cumAfterNested(), attacker.cumAtReentry(), "pool A accumulator not cross-written");
        assertEq(
            attacker.dataSqrtBeforeAfterNested(),
            attacker.dataSqrtBeforeAtReentry(),
            "pool A sqrtPriceX96Before not cross-corrupted"
        );
        assertEq(attacker.lastTsAfterNested(), attacker.lastTsAtReentry(), "pool A lastSwapTimestamp not cross-written");
        assertEq(_lastTake(logs).amount1, controlTake, "outer take unchanged");
    }

    /// @notice SETTLE-12, fuzzed over the nested trade, the elapsed time AND the protocol rate
    ///         (`1 <= bps <= 2000` — the full band from the smallest expressible rate up to and
    ///         including the governance cap): whatever the nested swap does, the outer swap's
    ///         settled amount equals its no-re-entry control and the unlock still closes.
    ///
    ///         Two regimes, both asserted (no rounding band is silently excluded):
    ///           - split > 0 (most of the domain): the take transfers, the re-entry lands inside
    ///             `unspecified.take`, and the last `ProtocolFeeTaken` on this pool is unambiguously
    ///             the outer swap's (emitted after the take returns, i.e. after any nested
    ///             settlement). The stash samples are content-checked against each leg's emitted
    ///             fee, so the outer-stash / nested-clobber writes are verified even when the two
    ///             rates coincide numerically.
    ///           - split == 0 (low bps, where `fee * bps / 1e4` truncates to zero — reachable from
    ///             ~bps <= 16 at this fixture's ~6000-pip outer fee): the outer swap performs NO
    ///             take, so there is no in-take window; the adversary fires on the router's output
    ///             transfer instead and only the nested swap may settle. `bps == 0` (the cache-off
    ///             path) stays deterministic in `test_SETTLE12_feeDisabled_noTakeAndNoInTakeReentry`.
    function testFuzz_SETTLE12_outerTakeInvariantToNestedSwap(
        uint256 amountSeed,
        bool nestedZeroForOne,
        uint256 dtSeed,
        uint16 bpsSeed
    ) public {
        int256 nested = -int256(bound(amountSeed, 1e16, 1e20));
        uint16 bps = uint16(bound(uint256(bpsSeed), 1, CAP_BPS));
        vm.warp(block.timestamp + bound(dtSeed, 0, 2 * DECAY));
        _setProtocolFeeBps(bps);

        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        uint256 controlTake = _takeAmountOrZero(ctrlLogs, poolId);
        vm.revertToState(snap);

        _armNestedSwap(key, poolId, nestedZeroForOne, nested);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 1, "the re-entry ran (in-take, or on the router transfer)");
        assertEq(_afterSwapEvents(logs).length, 2, "and the nested swap really executed");

        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        uint24 outerSplit = uint24((uint256(bs[0].dynamicFeePips) * bps) / 10_000);
        uint24 nestedSplit = uint24((uint256(bs[1].dynamicFeePips) * bps) / 10_000);

        if (controlTake > 0) {
            // in-take regime. With split >= 1 pip and a ~5e19 unspecified leg the take is >= ~5e13
            // wei, so `controlTake > 0` here is arithmetic, not assumption.
            assertEq(_takeAmountOrZero(logs, poolId), controlTake, "outer take invariant to the nested swap");
            assertEq(attacker.stashAtReentry(), outerSplit, "the OUTER split sat in the stash mid-take");
            assertGt(outerSplit, 0, "a settling take implies a non-zero stashed rate");
            assertEq(attacker.stashAfterNested(), nestedSplit, "the NESTED split overwrote it");
            // Anti-vacuity: when both legs' fees collapse to the SAME uint24 split (possible at
            // low bps, where the pips->split map is coarse), the overwrite is indistinguishable
            // from a no-write, so the run demonstrates nothing about the clobber — discard it
            // rather than let it pass silently. Rejections are a few percent of runs at most.
            vm.assume(attacker.stashAfterNested() != attacker.stashAtReentry());
        } else {
            // rounding-band regime: the split itself truncated to zero, the hook transferred
            // nothing, and no in-take window existed.
            assertEq(outerSplit, 0, "a zero control take must come from the split rounding to zero");
            assertEq(_takeEvents(ctrlLogs).length, 0, "control: no settlement at all");
            assertEq(attacker.stashAtReentry(), 0, "the zero rate really was stashed for the outer swap");
            assertEq(
                _takeEvents(logs).length,
                nestedSplit > 0 ? 1 : 0,
                "only the nested swap may settle when the outer split is zero"
            );
        }
    }

    /// @notice SETTLE-12 degenerate end of the rate range: with `protocolFeeBps == 0` the hook
    ///         performs NO take, so there is no in-settlement re-entry window at all. The armed
    ///         token still fires — on the ROUTER's own output transfer, after `manager.swap` has
    ///         returned — and the nested swap that runs there must still compose normally and must
    ///         not conjure a settlement out of nothing.
    function test_SETTLE12_feeDisabled_noTakeAndNoInTakeReentry() public {
        _setProtocolFeeBps(0);
        assertEq(hook.protocolFeeBps(), 0, "fee disabled everywhere");

        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(poolId);
        uint256 dt = block.timestamp - lastTsBefore;
        (uint160 p0,,,) = manager.getSlot0(poolId);

        _armNestedSwap(key, poolId, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(_takeEvents(logs).length, 0, "no settlement at all when the rate is zero");
        assertEq(attacker.fired(), 1, "the token still fired - on the router's transfer");
        assertEq(attacker.stashAtReentry(), 0, "and the stashed rate really was zero");

        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(as_.length, 2, "outer + nested, each recorded once");
        int256 c1 = Phase5Decay.decay(cumBefore, dt, DECAY)
            + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p0, attacker.sqrtAtReentry()));
        int256 c2 = c1
            + ImpactOracle.directional(
                true, ImpactOracle.priceImpactPips(attacker.sqrtAtReentry(), attacker.sqrtAfterNested())
            );
        assertEq(as_[0].cumPriceImpact, c1, "outer leg");
        assertEq(as_[1].cumPriceImpact, c2, "nested leg");
    }

    /// @notice SETTLE-12 at the governance ceiling: a take actually SETTLES at
    ///         `MAX_PROTOCOL_FEE_BPS` (20%) — the largest slice the protocol can ever charge — and
    ///         is still immune to the mid-take stash clobber. Complements
    ///         `test_SETTLE12_bpsChangeMidTake_...`, which only proves the OLD rate was used.
    function test_SETTLE12_takeAtGovernanceCap_settlesAtCappedRateAndResistsClobber() public {
        _setProtocolFeeBps(CAP_BPS);
        assertEq(hook.protocolFeeBps(), CAP_BPS);
        assertEq(governance.MAX_PROTOCOL_FEE_BPS(), CAP_BPS, "this really is the ceiling");

        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        BeforeSwapEvent memory ctrlBs = _beforeSwapEvents(ctrlLogs)[0];
        uint128 controlTake = _lastTake(ctrlLogs).amount1;
        vm.revertToState(snap);

        _armNestedSwap(key, poolId, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        uint24 expectedStash = uint24((uint256(ctrlBs.dynamicFeePips) * CAP_BPS) / 10_000);
        assertGt(expectedStash, 0);
        assertEq(attacker.stashAtReentry(), expectedStash, "stashed rate is the capped slice");
        assertTrue(attacker.stashAfterNested() != attacker.stashAtReentry(), "stash clobbered mid-take");
        assertEq(_takeEvents(logs)[1].amount1, controlTake, "capped take is control-identical");

        // and the LP still receives the complement of the same dynamic fee
        BeforeSwapEvent memory bs0 = _beforeSwapEvents(logs)[0];
        assertEq(bs0.dynamicFeePips, ctrlBs.dynamicFeePips, "the swapper's total fee did not move");
    }

    /// @notice SETTLE-12, governance vector: the adversary flips `protocolFeeBps` to the 20% cap
    ///         mid-take (the armed token calls the timelock proxy, which pushes the new rate into
    ///         the hook's cache in the same transaction). The outer take must still settle at the
    ///         rate stashed during ITS `beforeSwap`.
    ///
    ///         Honest scope note (same as the primary vector): the rate flip lands INSIDE the
    ///         `unspecified.take(...)` whose amount was already computed from the stashed rate, so
    ///         `takes[0].amount1 == controlTake` cannot fail by construction — no implementation
    ///         could re-price an amount that is the argument of the call the re-entry is running
    ///         in. What is falsifiable is that the unlock still CLOSES (`CurrencyNotSettled`
    ///         otherwise) and that the mid-transaction cache write really happened (asserted
    ///         against both the hook cache and governance). A rate read AFTER the take would be
    ///         caught by `test_SETTLE12_rotationInsideNestedTake_...`, which pins per-call-time
    ///         resolution on the falsifiable treasury field instead.
    function test_SETTLE12_bpsChangeMidTake_outerTakeUsesStashedRate() public {
        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        uint128 controlTake = _lastTake(ctrlLogs).amount1;
        vm.revertToState(snap);

        token1.arm(
            address(timelockProxy),
            abi.encodeCall(
                timelockProxy.exec, (address(governance), abi.encodeCall(AscntGovernance.setProtocolFeeBps, (CAP_BPS)))
            ),
            true,
            false,
            true
        );

        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(hook.protocolFeeBps(), CAP_BPS, "cache really moved mid-settlement");
        assertEq(governance.protocolFeeBps(), CAP_BPS);

        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 1, "only the outer swap settles here");
        assertEq(takes[0].amount1, controlTake, "outer take used the rate stashed in beforeSwap");
    }

    /// @notice SETTLE-12 on the EXACT-OUTPUT quadrant: the take is drawn from the INPUT side
    ///         (unspecified = currency1 for an exact-output oneForZero swap), so the reentrant
    ///         token still fires — and the settled amount is still control-identical.
    function test_SETTLE12_exactOutputOuterSwap_takeUnchangedByNestedSwap() public {
        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, false, int256(2e19));
        uint128 controlTake = _lastTake(ctrlLogs).amount1;
        assertGt(controlTake, 0);
        vm.revertToState(snap);

        _armNestedSwap(key, poolId, true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, false, int256(2e19));

        assertEq(attacker.fired(), 1, "exact-output swaps route the take through currency1 too");
        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 2);
        assertEq(takes[1].amount1, controlTake, "outer exact-output take unchanged");
    }

    /// @notice SETTLE-12 companion, NARROW claim: the `ProtocolFeeTaken` event is emitted from the
    ///         `_treasury` LOCAL (`AscntBaseHook.sol:168`), not from a re-read of
    ///         `governance.treasury()` after the transfer.
    ///
    ///         Honest scope note: the fund-destination assertions below cannot fail by construction
    ///         — `_treasury` is the recipient ARGUMENT of `unspecified.take(...)` and the re-entry
    ///         fires inside that very call, so no implementation could redirect the money at that
    ///         point. They are kept as corroboration. The falsifiable content is the event field:
    ///         a refactor that moved the `governance.treasury()` read below the take would emit
    ///         TREASURY_2 here and this test would fail.
    function test_SETTLE12_treasuryResolvedIntoLocal_eventRecordsPreCallTreasury() public {
        token1.arm(
            address(timelockProxy),
            abi.encodeCall(
                timelockProxy.exec, (address(governance), abi.encodeCall(AscntGovernance.setTreasury, (TREASURY_2)))
            ),
            true,
            false,
            true
        );

        uint256 treasuryBefore = token1.balanceOf(TREASURY);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(governance.treasury(), TREASURY_2, "rotation really happened during the swap");

        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 1);
        assertEq(takes[0].treasury, TREASURY, "event records the treasury resolved BEFORE the call");
        assertEq(
            token1.balanceOf(TREASURY) - treasuryBefore,
            takes[0].amount1,
            "funds landed at the pre-call treasury (corroboration)"
        );
        assertEq(token1.balanceOf(TREASURY_2), 0, "corroboration: nothing reached the new treasury");
    }

    /// @notice SETTLE-12, the FALSIFIABLE rotation vector: the adversary rotates the treasury and
    ///         THEN runs a nested swap, all from inside the outer swap's take. Two takes therefore
    ///         settle in one transaction under two different treasuries — the nested one resolves
    ///         `governance.treasury()` fresh (TREASURY_2), the outer one keeps the value it
    ///         resolved before its own external call (TREASURY). An implementation that resolved
    ///         the treasury once per transaction, or re-read it late, would collapse these two.
    function test_SETTLE12_rotationInsideNestedTake_eachTakeResolvesTreasuryAtItsOwnCallTime() public {
        attacker.setNested(key, poolId, true, -NESTED);
        // rotate first, then nest: the nested swap's own afterSwap must see the NEW treasury
        Phase5RotateThenSwap rotator =
            new Phase5RotateThenSwap(timelockProxy, address(governance), attacker, TREASURY_2, token1);
        token1.arm(address(rotator), abi.encodeCall(Phase5RotateThenSwap.run, ()), true, false, true);

        uint256 t1Before = token1.balanceOf(TREASURY);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(governance.treasury(), TREASURY_2, "rotation landed mid-take");
        assertEq(attacker.fired(), 1, "the nested swap ran after the rotation");

        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 2, "nested take, then the outer take");
        assertEq(takes[0].treasury, TREASURY_2, "the NESTED take resolved the rotated treasury");
        assertEq(takes[1].treasury, TREASURY, "the OUTER take kept its pre-call treasury");

        assertEq(token1.balanceOf(TREASURY) - t1Before, takes[1].amount1, "outer slice to the old treasury");
        assertEq(token1.balanceOf(TREASURY_2), takes[0].amount1, "nested slice to the new treasury");
    }

    // =====================================================================================
    // LIFE-1 / LIFE-8 — the hook's configuration surface, reached THROUGH the re-entry
    //
    // (These assert nothing about accumulator composition; the re-entry is only the delivery
    //  vehicle. The properties they pin are the one-time-configure guard (LIFE-1) and the
    //  owner-or-poolDeployer gate (LIFE-8).)
    //
    // COVERAGE SCOPE — supplementary/partial, NOT a discharge of either catalog ID. LIFE-1
    // (CRITICAL) demands that no stored config field ever changes for the life of the contract;
    // the vector below checks six fields after two rejected calls from one (authorized) caller
    // via one delivery path. LIFE-8 (HIGH) demands the full authority gate; the vector below
    // exercises one unauthorized caller. Primary coverage for both IDs belongs to the lifecycle
    // phase (`test/access/Phase2_LifecycleAccess.t.sol`); what these two add is only the
    // "…and being inside a live settlement does not change that" slice. A coverage matrix must
    // not count phase 5 as owning LIFE-1/LIFE-8.
    // =====================================================================================

    /// @notice LIFE-1 via a reentrant caller: `configurePool` on the LIVE pool cannot mutate its
    ///         parameters even when the caller is authorized and even from inside a settlement —
    ///         config is one-time, so it reverts `PoolAlreadyConfigured`. POST fault-isolation
    ///         (SETTLE-17): the bubbled failure does not kill the settlement — the hook
    ///         catches it and degrades to claims. The bubble also rolls back the mock's one-shot
    ///         disarm, so the still-armed token then kills the ROUTER's own take: the swap still
    ///         fails, but demonstrably OUTSIDE the hook (no `HookCallFailed` wrapper), and the
    ///         config guard fired all the same.
    function test_LIFE1_reentrantConfigurePool_cannotMutateLiveConfig() public {
        // Authorize the token itself as poolDeployer so the re-entrant call clears the authority
        // gate — otherwise this would only re-test access control, not the one-time guard.
        _timelockCall(abi.encodeCall(AscntGovernance.setPoolDeployer, (address(token1))));

        token1.arm(
            address(hook),
            abi.encodeCall(SimHook.configurePool, (poolId, 1, 1, 1_000, 1 hours, 0, 2e6, 1e6)),
            true,
            false,
            true
        );

        (bool ok, bytes memory err) = _trySwap(key, true, -OUTER);
        assertFalse(ok, "the still-armed token breaks the router's take, so the swap fails");
        assertTrue(_blobContains(err, SimHook.PoolAlreadyConfigured.selector), "one-time config guard fired");
        assertFalse(
            _blobContains(err, Hooks.HookCallFailed.selector),
            "but NOT inside the hook: the settlement caught the bubbled failure (SETTLE-17 isolation)"
        );

        // Non-bubbling variant: the re-entry still fails, the swap settles normally, config intact.
        token1.arm(
            address(hook),
            abi.encodeCall(SimHook.configurePool, (poolId, 1, 1, 1_000, 1 hours, 0, 2e6, 1e6)),
            true,
            false,
            false
        );
        (ok,) = _trySwap(key, true, -OUTER);
        assertTrue(ok, "swallowed re-entry failure leaves the swap intact");

        (
            bool configured,
            uint24 minMinFee,
            uint24 maxMinFee,
            uint24 maxFee,
            uint48 decayLen,
            uint48 jitLock,
            uint32 kPips,
            uint32 cPips
        ) = hook.poolConfig(poolId);
        assertTrue(configured);
        assertEq(minMinFee, MIN_MIN_FEE, "minMinFee immutable");
        assertEq(maxMinFee, MAX_MIN_FEE, "maxMinFee immutable");
        assertEq(maxFee, MAX_FEE, "maxFee immutable");
        assertEq(decayLen, uint48(DECAY), "timeDecayLength immutable");
        assertEq(jitLock, 0, "jitLockBlocks immutable");
        assertEq(kPips, 2e6, "kPips immutable");
        assertEq(cPips, 1e6, "cPips immutable");
    }

    /// @notice LIFE-8 via a reentrant caller: the same `configurePool` attempt, unauthorized (the
    ///         token is neither owner nor poolDeployer) — the authority gate rejects it first, and
    ///         being inside a live settlement does not bypass it. Targets pool B, which is already
    ///         configured, so the ONLY thing that can produce this selector is the gate.
    function test_LIFE8_reentrantConfigurePool_unauthorizedIsRejected() public {
        assertTrue(address(token1) != governance.owner(), "the token must not be the owner");
        assertTrue(address(token1) != governance.poolDeployer(), "nor the poolDeployer");

        token1.arm(
            address(hook),
            abi.encodeCall(SimHook.configurePool, (poolIdB, 1, 1, 1_000, 1 hours, 0, 2e6, 1e6)),
            true,
            false,
            true
        );

        (bool ok, bytes memory err) = _trySwap(key, true, -OUTER);
        assertFalse(ok);
        assertTrue(
            _blobContains(err, AscntBaseHook.NotOwnerOrPoolDeployer.selector),
            "unauthorized reentrant configure is gated"
        );
        assertFalse(
            _blobContains(err, SimHook.PoolAlreadyConfigured.selector), "the gate fires BEFORE the one-time guard"
        );
    }

    // =====================================================================================
    // SETTLE-17 — the take IS fault-isolated (armed-token variant)
    // =====================================================================================

    /// @notice SETTLE-17 via the shared reentrant mock: an unspecified-currency token whose
    ///         `transfer` reverts on every attempt (a "paused token" — the bubbled failure rolls
    ///         back the mock's own disarm, so it stays armed all transaction) cannot raise a
    ///         failure INSIDE the hook. The hook's take catches the revert and degrades to
    ///         claims; the swap then dies at the ROUTER's own take of the same token — a failure
    ///         no hook can absorb, since v4 must ultimately deliver output in that token.
    ///
    ///         Attribution: a take without fault isolation would fail the fee-ON case WITH
    ///         `HookCallFailed` while the fee-OFF control fails WITHOUT it. Here both cases
    ///         converge on the control's signature — `ERC20TransferFailed` with NO
    ///         `HookCallFailed` — which is precisely the isolation property: the settlement path
    ///         contributes no failure of its own.
    function test_SETTLE17_revertingTransferDuringTake_failureMovesOutsideHook() public {
        token1.arm(address(sink), abi.encodeCall(Phase5RevertSink.boom, ()), true, false, true);

        (bool ok, bytes memory err) = _trySwap(key, true, -OUTER);
        assertFalse(ok, "a token that reverts every transfer still makes the pool unusable");
        assertTrue(
            _blobContains(err, CurrencyLibrary.ERC20TransferFailed.selector),
            "v4 wraps the token failure as ERC20TransferFailed"
        );
        assertFalse(
            _blobContains(err, Hooks.HookCallFailed.selector),
            "but the failure is NOT inside the hook: the take caught its copy (SETTLE-17 isolation)"
        );

        // Control: with the protocol fee disabled the hook never transfers at all; the failure
        // signature must be IDENTICAL to the fee-on case — proving the hook's settlement adds no
        // failure surface of its own.
        _timelockCall(abi.encodeCall(AscntGovernance.setProtocolFeeBps, (0)));
        (bool ok2, bytes memory err2) = _trySwap(key, true, -OUTER);
        assertFalse(ok2, "armed token still breaks the router's own take");
        assertTrue(_blobContains(err2, CurrencyLibrary.ERC20TransferFailed.selector), "same ERC20TransferFailed shape");
        assertFalse(_blobContains(err2, Hooks.HookCallFailed.selector), "and still no hook-originated failure");
    }
}

/// @notice Two-step re-entry payload: rotate the treasury through the (permissionless) timelock
///         proxy, THEN run the adversary's nested swap, so the nested swap's own settlement
///         resolves a different treasury than the in-flight outer settlement. Disarms the trigger
///         so exactly one re-entry fires.
contract Phase5RotateThenSwap {
    Phase5TimelockProxy public immutable timelockProxy;
    address public immutable governanceAddr;
    Phase5NestedSwapper public immutable attacker;
    address public immutable newTreasury;
    ReentrantERC20 public immutable trigger;

    constructor(
        Phase5TimelockProxy _timelockProxy,
        address _governance,
        Phase5NestedSwapper _attacker,
        address _newTreasury,
        ReentrantERC20 _trigger
    ) {
        timelockProxy = _timelockProxy;
        governanceAddr = _governance;
        attacker = _attacker;
        newTreasury = _newTreasury;
        trigger = _trigger;
    }

    function run() external {
        timelockProxy.exec(governanceAddr, abi.encodeCall(AscntGovernance.setTreasury, (newTreasury)));
        attacker.onTakeSwap(); // the adversary disarms the trigger on its way out
        trigger.disarm(); // belt and braces: the nested swap must be the last re-entry
    }
}
