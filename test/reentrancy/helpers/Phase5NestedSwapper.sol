// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {SimHookHarness} from "../../harness/SimHookHarness.sol";

/// @dev Minimal surface the adversary needs on its trigger token. Both `ReentrantERC20` (fires
///      BEFORE the balance move) and `Phase5PostTransferToken` (fires AFTER it) satisfy this, so
///      the same adversary drives both callback positions.
interface IPhase5Trigger {
    function disarm() external;
}

/// @dev Minimal ERC-20 read surface for the mid-take balance probe.
interface IPhase5BalanceOf {
    function balanceOf(address who) external view returns (uint256);
}

/// @notice The adversary for the phase-5 settlement-reentrancy suites.
///
///         It is invoked by an armed token's transfer callback while the PoolManager is *already
///         unlocked* and `SimHook._afterSwap` is mid-flight inside `unspecified.take(...)`. That is
///         the only re-entry shape v4 actually permits: a fresh `PoolManager.unlock` reverts
///         `AlreadyUnlocked` (see `onTakeTryFreshUnlock`, which asserts exactly that), so a
///         reentrant swap must ride the outer unlock and settle its own deltas directly against
///         the manager.
///
///         Every entry point snapshots hook state *at the moment of re-entry* — i.e. after the
///         outer `_afterSwap` wrote `cumPriceImpact` / `lastSwapTimestamp` (SimHook.sol:288-289)
///         but before the take completed. Those snapshots, plus the slot0 prices captured on both
///         sides of the nested action, give the tests a price/impact oracle that is INDEPENDENT of
///         the hook's own `BeforeSwap` / `AfterSwap` events.
///
///         Observations are recorded twice: into the flat scalar fields (convenient when exactly
///         one firing happens, which the single-firing tests assert) and appended to `firings`
///         so multi-firing vectors (token left armed for the whole transaction) can attribute each
///         observation to its firing.
///
///         By default each handler disarms the trigger token before returning, so exactly one
///         re-entry fires per outer swap (the token would otherwise fire again on the router's own
///         output take, after `manager.swap` returns). `setDisarmAfterFiring(false)` switches that
///         off — used by the vector that deliberately exercises the second, router-side firing.
contract Phase5NestedSwapper {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    SimHookHarness public immutable hook;
    IPhase5Trigger public immutable trigger;

    // ---- configuration ----
    PoolKey internal watchKey; // pool observed (the OUTER swap's pool)
    PoolId internal watchId;
    PoolKey internal nestedKey; // pool the nested swap executes on (may equal watchKey)
    PoolId internal nestedId;
    bool public nestedZeroForOne;
    int256 public nestedAmountSpecified;
    bool public disarmAfterFiring = true;

    // optional mid-take ERC-20 balance probe (post-transfer-callback attribution)
    address public probeToken;
    address public probeWho;

    // liquidity re-entry parameters (`onTakeAddLiquidity`)
    int24 public lpTickLower;
    int24 public lpTickUpper;
    int256 public lpLiquidityDelta;

    // ---- per-firing observations ----
    struct Firing {
        uint160 sqrtAtReentry;
        uint160 sqrtAfterNested;
        uint24 stashAtReentry;
        uint24 stashAfterNested;
        int256 cumAtReentry;
        int256 cumAfterNested;
        uint160 dataSqrtBeforeAtReentry;
        uint160 dataSqrtBeforeAfterNested;
        uint48 lastTsAtReentry;
        uint48 lastTsAfterNested;
    }

    Firing[] internal _firings;

    // ---- flat observations (last firing; == firing 0 for the single-firing tests) ----
    uint256 public fired;
    /// @dev slot0 price at re-entry == the price the outer `_afterSwap` read at SimHook.sol:276.
    uint160 public sqrtAtReentry;
    /// @dev slot0 price after the nested action completed.
    uint160 public sqrtAfterNested;
    /// @dev watched pool's transient hookFee stash, before / after the nested action.
    uint24 public stashAtReentry;
    uint24 public stashAfterNested;
    /// @dev nested pool's stash after its own beforeSwap ran.
    uint24 public nestedStashAfter;
    /// @dev watched pool's `poolData` as seen mid-take (effects-before-interactions probe).
    int256 public cumAtReentry;
    uint160 public dataSqrtBeforeAtReentry;
    uint48 public lastTsAtReentry;
    /// @dev watched pool's `poolData` re-read AFTER the nested action (cross-pool isolation probe).
    int256 public cumAfterNested;
    uint160 public dataSqrtBeforeAfterNested;
    uint48 public lastTsAfterNested;
    /// @dev hook's cached protocolFeeBps as seen mid-take.
    uint16 public cachedBpsAtReentry;
    /// @dev `probeToken.balanceOf(probeWho)` as seen mid-take (0 when the probe is unset).
    uint256 public balanceAtReentry;
    /// @dev error selector returned by the attempted fresh `unlock` re-entry.
    bytes4 public unlockErrorSelector;
    /// @dev raw delta returned by the nested swap (net of the nested hook delta).
    int128 public nestedAmount0;
    int128 public nestedAmount1;

    constructor(
        IPoolManager _manager,
        SimHookHarness _hook,
        address _trigger,
        PoolKey memory _watchKey,
        PoolId _watchId
    ) {
        manager = _manager;
        hook = _hook;
        trigger = IPhase5Trigger(_trigger);
        watchKey = _watchKey;
        watchId = _watchId;
        nestedKey = _watchKey;
        nestedId = _watchId;
    }

    // ------ configuration ------

    /// @notice Re-point the observation target (the pool whose state is sampled mid-take).
    function setWatch(PoolKey memory k, PoolId id) external {
        watchKey = k;
        watchId = id;
    }

    function setNested(PoolKey memory k, PoolId id, bool zeroForOne, int256 amountSpecified) external {
        nestedKey = k;
        nestedId = id;
        nestedZeroForOne = zeroForOne;
        nestedAmountSpecified = amountSpecified;
    }

    function setDisarmAfterFiring(bool v) external {
        disarmAfterFiring = v;
    }

    function setBalanceProbe(address token, address who) external {
        probeToken = token;
        probeWho = who;
    }

    function setNestedLiquidity(int24 lower, int24 upper, int256 liquidityDelta) external {
        lpTickLower = lower;
        lpTickUpper = upper;
        lpLiquidityDelta = liquidityDelta;
    }

    function firingCount() external view returns (uint256) {
        return _firings.length;
    }

    function firingAt(uint256 i) external view returns (Firing memory) {
        return _firings[i];
    }

    // ------ re-entry entry points (armed as trigger-token callbacks) ------

    /// @notice Observe-only re-entry: reads hook state mid-take and returns. Used to prove the
    ///         accumulator write is complete *before* the external transfer (CEI ordering).
    function onTakeObserve() external {
        Firing memory f = _observeBefore();
        _observeAfter(f);
        _record(f);
        _finish();
    }

    /// @notice The XSUB-1 / SETTLE-12 vector: a full nested `PoolManager.swap` executed from inside
    ///         the outer swap's protocol-fee take, settling its own deltas against the live unlock.
    function onTakeSwap() external {
        Firing memory f = _observeBefore();

        SwapParams memory p = SwapParams({
            zeroForOne: nestedZeroForOne,
            amountSpecified: nestedAmountSpecified,
            sqrtPriceLimitX96: nestedZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta d = manager.swap(nestedKey, p, "");
        nestedAmount0 = d.amount0();
        nestedAmount1 = d.amount1();
        _settleDeltas(nestedKey, d);

        _observeAfter(f);
        nestedStashAfter = hook.readStash(nestedId);
        _record(f);
        _finish();
    }

    /// @notice Adds liquidity from inside the outer swap's take. `modifyLiquidity` is legal while
    ///         the manager is unlocked, so this is a reachable mid-settlement action; the hook must
    ///         come out with its accumulator and its take untouched.
    function onTakeAddLiquidity() external {
        Firing memory f = _observeBefore();

        (BalanceDelta callerDelta,) = manager.modifyLiquidity(
            nestedKey,
            ModifyLiquidityParams({
                tickLower: lpTickLower,
                tickUpper: lpTickUpper,
                liquidityDelta: lpLiquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
        nestedAmount0 = callerDelta.amount0();
        nestedAmount1 = callerDelta.amount1();
        _settleDeltas(nestedKey, callerDelta);

        _observeAfter(f);
        nestedStashAfter = hook.readStash(nestedId);
        _record(f);
        _finish();
    }

    /// @notice Attempts a FRESH `PoolManager.unlock` from inside the take — the classic reentrancy
    ///         shape. v4 must reject it (`AlreadyUnlocked`); the selector is recorded so the test
    ///         can assert the rejection instead of merely observing "nothing bad happened".
    function onTakeTryFreshUnlock() external {
        Firing memory f = _observeBefore();
        try manager.unlock("") returns (bytes memory) {
            unlockErrorSelector = bytes4(0);
        } catch (bytes memory err) {
            unlockErrorSelector = err.length >= 4 ? bytes4(err) : bytes4(0);
        }
        _observeAfter(f);
        _record(f);
        _finish();
    }

    // ------ internals ------

    function _observeBefore() internal returns (Firing memory f) {
        (f.sqrtAtReentry,,,) = manager.getSlot0(watchId);
        f.stashAtReentry = hook.readStash(watchId);
        cachedBpsAtReentry = hook.protocolFeeBps();
        if (probeToken != address(0)) {
            balanceAtReentry = IPhase5BalanceOf(probeToken).balanceOf(probeWho);
        }
        (f.dataSqrtBeforeAtReentry, f.lastTsAtReentry,, f.cumAtReentry) = hook.poolData(watchId);
    }

    /// @dev Re-read the watched pool's live price, stash, and poolData after the nested action.
    function _observeAfter(Firing memory f) internal view {
        (f.sqrtAfterNested,,,) = manager.getSlot0(watchId);
        f.stashAfterNested = hook.readStash(watchId);
        (f.dataSqrtBeforeAfterNested, f.lastTsAfterNested,, f.cumAfterNested) = hook.poolData(watchId);
    }

    function _record(Firing memory f) internal {
        _firings.push(f);
        fired++;

        sqrtAtReentry = f.sqrtAtReentry;
        sqrtAfterNested = f.sqrtAfterNested;
        stashAtReentry = f.stashAtReentry;
        stashAfterNested = f.stashAfterNested;
        cumAtReentry = f.cumAtReentry;
        dataSqrtBeforeAtReentry = f.dataSqrtBeforeAtReentry;
        lastTsAtReentry = f.lastTsAtReentry;
        cumAfterNested = f.cumAfterNested;
        dataSqrtBeforeAfterNested = f.dataSqrtBeforeAfterNested;
        lastTsAfterNested = f.lastTsAfterNested;
    }

    function _finish() internal {
        if (disarmAfterFiring) trigger.disarm();
    }

    /// @dev Pay what we owe, collect what we are owed — directly against the open unlock. The
    ///      token transfers here re-enter the armed token, but its one-shot `_entered` guard is
    ///      set for the duration of this callback, so they cannot recurse.
    function _settleDeltas(PoolKey memory k, BalanceDelta d) internal {
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 < 0) k.currency0.settle(manager, address(this), uint256(uint128(-a0)), false);
        if (a1 < 0) k.currency1.settle(manager, address(this), uint256(uint128(-a1)), false);
        if (a0 > 0) k.currency0.take(manager, address(this), uint256(uint128(a0)), false);
        if (a1 > 0) k.currency1.take(manager, address(this), uint256(uint128(a1)), false);
    }
}
