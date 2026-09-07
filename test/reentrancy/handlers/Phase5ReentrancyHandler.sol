// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {AscntGovernance} from "../../../src/AscntGovernance.sol";
import {SimHookHarness} from "../../harness/SimHookHarness.sol";
import {ReentrantERC20} from "../../mocks/ReentrantERC20.sol";
import {Phase5NestedSwapper} from "../helpers/Phase5NestedSwapper.sol";
import {Phase5TimelockProxy} from "../helpers/Phase5TimelockProxy.sol";
import {Phase5Decay} from "../helpers/Phase5Decay.sol";
import {ImpactOracle} from "../../utils/ImpactOracle.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Stateful-fuzz handler for the settlement-reentrancy surface (XSUB-1 / SETTLE-12).
///
///         Where the deterministic suites pin exact values at exact landmarks, this handler sweeps
///         the STATE DIMENSION that stateful fuzzing exists for: random action
///         sequences of (arm-or-not, quadrant, size) swaps interleaved with time jumps, protocol-fee
///         changes and liquidity adds, so the accumulator and the settlement are exercised across
///         arbitrary histories rather than from a frozen `setUp`.
///
///         Every action is fault-tolerant (reverts are counted, not propagated) because a random
///         sequence legitimately produces impossible swaps; `fail-on-revert = false` in the suite.
///         Because the try/catch makes forge's own `reverts: 0` summary uninformative, degeneracy
///         is tracked explicitly: `failedSwapCount` counts swaps that fell into the catch, and the
///         suite's `afterInvariant` asserts RATIOS against it (committed swaps and oracle checks
///         as a fraction of attempts), so a sequence that mostly no-ops fails loudly instead of
///         passing on a handful of survivors.
contract Phase5ReentrancyHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    PoolModifyLiquidityTest internal immutable lpRouter;
    SimHookHarness internal immutable hook;
    AscntGovernance internal immutable governance;
    Phase5TimelockProxy internal immutable timelockProxy;
    ReentrantERC20 internal immutable token0;
    ReentrantERC20 internal immutable token1;
    Phase5NestedSwapper internal immutable attacker1; // fires from currency1 takes
    Phase5NestedSwapper internal immutable attacker0; // fires from currency0 takes
    address internal immutable treasury;

    PoolKey internal key;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    // ---- ghosts ----
    uint256 public callCount; // every handler action, whatever it did (campaign-size diagnostic)
    uint256 public swapCount; // outer swaps that committed
    uint256 public failedSwapCount; // outer swaps that degenerated into the catch (did nothing)
    uint256 public reentryCount; // adversary callbacks that ran (each may add one nested swap)
    uint256 public takeCount; // outer swaps after which the treasury grew
    uint256 public lpAddCount;
    uint256 public bpsChangeCount;
    bool public treasuryEverDecreased;

    /// @dev XSUB-1 chain oracle ghosts. `chainChecks` counts committed swaps whose FULL accumulator
    ///      chain (outer leg plus every nested leg that ran inside its take) was recomputed from an
    ///      event-independent price/decay transcription and compared to the hook's stored value;
    ///      `chainMismatch` latches if any of them diverged. Assertions cannot live in the handler
    ///      itself — with `fail-on-revert = false` a reverting assert would be swallowed — so the
    ///      suite reads these flags from an invariant.
    uint256 public chainChecks;
    bool public chainMismatch;
    bool public impactMismatch;

    uint256 internal immutable decayLength;

    bytes32 internal constant AFTER_SWAP_SIG = keccak256("AfterSwap(bytes32,uint160,uint256,int256)");

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _lpRouter,
        SimHookHarness _hook,
        AscntGovernance _governance,
        Phase5TimelockProxy _timelockProxy,
        ReentrantERC20 _token0,
        ReentrantERC20 _token1,
        Phase5NestedSwapper _attacker0,
        Phase5NestedSwapper _attacker1,
        address _treasury,
        PoolKey memory _key,
        PoolId _poolId,
        uint256 _decayLength
    ) {
        decayLength = _decayLength;
        manager = _manager;
        swapRouter = _swapRouter;
        lpRouter = _lpRouter;
        hook = _hook;
        governance = _governance;
        timelockProxy = _timelockProxy;
        token0 = _token0;
        token1 = _token1;
        attacker0 = _attacker0;
        attacker1 = _attacker1;
        treasury = _treasury;
        key = _key;
        poolId = _poolId;

        _token0.approve(address(_swapRouter), type(uint256).max);
        _token1.approve(address(_swapRouter), type(uint256).max);
        _token0.approve(address(_lpRouter), type(uint256).max);
        _token1.approve(address(_lpRouter), type(uint256).max);
    }

    /// @notice Total accumulator WRITES the hook could have performed so far: one per committed
    ///         outer swap plus at most one per adversary callback. The magnitude bound invariant is
    ///         stated against this (each write moves `|cum|` by at most `PIPS_SCALE`).
    function accumulatorWriteCeiling() external view returns (uint256) {
        return swapCount + reentryCount;
    }

    // ------ actions ------

    /// @notice The core action: optionally arm one or both currencies with a nested swap, then run
    ///         an outer swap in a fuzz-chosen quadrant. Arming BEFORE the swap is what puts the
    ///         re-entry inside `unspecified.take`.
    function swapMaybeArmed(uint256 amtSeed, uint256 armSeed, uint8 mode) external {
        callCount++;
        _maybeArm(armSeed);

        int256 mag = int256(bound(amtSeed, 1e12, 1e20));
        bool zeroForOne = mode % 2 == 0;
        bool exactInput = (mode / 2) % 2 == 0;

        uint256 t0 = token0.balanceOf(treasury);
        uint256 t1 = token1.balanceOf(treasury);
        uint256 firedBefore = attacker0.fired() + attacker1.fired();

        // state the independent chain oracle starts from, captured OUTSIDE the hook
        (uint160 priceBefore,,,) = manager.getSlot0(poolId);
        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(poolId);

        vm.recordLogs();
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInput ? -mag : mag,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            swapCount++;
            _checkAccumulatorChain(priceBefore, cumBefore, block.timestamp - lastTsBefore);
        } catch {
            failedSwapCount++;
        }

        uint256 n0 = token0.balanceOf(treasury);
        uint256 n1 = token1.balanceOf(treasury);
        if (n0 < t0 || n1 < t1) treasuryEverDecreased = true;
        if (n0 > t0 || n1 > t1) takeCount++;
        reentryCount += (attacker0.fired() + attacker1.fired()) - firedBefore;

        // leave no armed token behind: the next action starts from a clean trigger state
        token0.disarm();
        token1.disarm();
    }

    function advanceTime(uint256 seed) external {
        callCount++;
        vm.warp(block.timestamp + bound(seed, 0, 3 hours));
    }

    function setProtocolFeeBps(uint16 seed) external {
        callCount++;
        uint16 bps = uint16(bound(uint256(seed), 0, governance.MAX_PROTOCOL_FEE_BPS()));
        timelockProxy.exec(address(governance), abi.encodeCall(AscntGovernance.setProtocolFeeBps, (bps)));
        bpsChangeCount++;
    }

    function addLiquidity(uint256 seed) external {
        callCount++;
        uint256 amount0 = bound(seed, 1e18, 1e21);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), amount0
        );
        if (liq == 0) return;
        try lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        ) {
            lpAddCount++;
        } catch {}
    }

    // ------ internals ------

    /// @dev XSUB-1's recurrence, recomputed for EVERY leg of the transaction — the outer swap plus
    ///      each nested swap that re-entered inside its take — without reading the hook's stored
    ///      state or trusting its emitted impacts (see Phase5Decay's header for what this oracle
    ///      can and cannot falsify).
    ///
    ///      The price chain is taken from the pre-swap `slot0` read (captured by this handler,
    ///      outside the hook) plus each `AfterSwap` event's post-swap price, so the impacts are
    ///      recomputed rather than trusted; each leg's direction is INFERRED from the price
    ///      movement (a zeroForOne leg can only lower the price), so no knowledge of what the
    ///      adversary did is required; and only the first leg decays (subsequent legs run in the
    ///      same block, the outer having just stamped `lastSwapTimestamp`).
    ///
    ///      This is the sharp version of the property: a lost, duplicated or mis-signed leg, a
    ///      skipped decay step, or a wrapping add all break the equality.
    function _checkAccumulatorChain(uint160 priceBefore, int256 cumBefore, uint256 dtFirst) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        int256 expected = cumBefore;
        uint160 p = priceBefore;
        uint256 dt = dtFirst;
        uint256 legs;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != AFTER_SWAP_SIG) continue;
            if (logs[i].topics[1] != PoolId.unwrap(poolId)) continue;
            (uint160 priceAfter, uint256 emittedImpact,) = abi.decode(logs[i].data, (uint160, uint256, int256));

            uint256 impact = ImpactOracle.priceImpactPips(p, priceAfter);
            if (impact != emittedImpact) impactMismatch = true;

            expected = Phase5Decay.decay(expected, dt, decayLength);
            expected = Phase5Decay.addSat(expected, ImpactOracle.directional(priceAfter < p, impact));

            p = priceAfter;
            dt = 0; // every later leg runs in the same block as the outer swap
            legs++;
        }

        if (legs == 0) return;

        (,,, int256 cumNow) = hook.poolData(poolId);
        if (cumNow != expected) chainMismatch = true;
        chainChecks++;
    }

    /// @dev Arms BOTH currencies, so whichever side turns out to be the swap's unspecified
    ///      currency has an adversary waiting on it (and a nested swap whose own take lands on the
    ///      other side re-enters at depth 2). `bubble` is rare on purpose: a bubbled failure aborts
    ///      the outer swap, which is a covered case but must not dominate the sequence.
    function _maybeArm(uint256 armSeed) internal {
        if (armSeed % 8 == 0) return; // ~12% of swaps run with no re-entry at all

        bool bubble = (armSeed / 8) % 4 == 0;
        bool nestedDir = (armSeed / 32) % 2 == 0;
        int256 nestedMag = int256(bound(uint256(keccak256(abi.encode(armSeed))), 1e12, 1e19));
        bool observeOnly = (armSeed / 64) % 8 == 0;

        bytes memory payload = observeOnly
            ? abi.encodeCall(Phase5NestedSwapper.onTakeObserve, ())
            : abi.encodeCall(Phase5NestedSwapper.onTakeSwap, ());

        attacker1.setNested(key, poolId, nestedDir, -nestedMag);
        token1.arm(address(attacker1), payload, true, false, bubble);
        attacker0.setNested(key, poolId, !nestedDir, -nestedMag);
        token0.arm(address(attacker0), payload, true, false, bubble);
    }
}
