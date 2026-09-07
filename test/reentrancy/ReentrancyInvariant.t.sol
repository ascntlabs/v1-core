// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {Phase5ReentrancyBase} from "./base/Phase5ReentrancyBase.sol";
import {Phase5NestedSwapper} from "./helpers/Phase5NestedSwapper.sol";
import {Phase5ReentrancyHandler} from "./handlers/Phase5ReentrancyHandler.sol";
import {ReentrantERC20} from "../mocks/ReentrantERC20.sol";

/// @notice XSUB-1 / SETTLE-12 as a STATEFUL invariant run, complementing the deterministic vectors
///         and bounded fuzzes in the other phase-5 files.
///
///         The catalog tags both IDs `stateful-fuzz`. The deterministic suites pin exact values at
///         exact landmarks that a random-action handler cannot hand back (mid-take stash samples,
///         the observer's view of the accumulator during the transfer); this suite covers the other
///         half: long, randomly-ordered histories of armed and unarmed swaps across all four
///         quadrants, interleaved with time jumps, protocol-rate changes and liquidity adds.
///
///         The flagship invariant here is NOT weaker than the deterministic vectors: the handler
///         recomputes the FULL accumulator chain for every committed transaction (outer leg plus
///         every nested leg that re-entered inside its take) from an event-independent decay/impact
///         transcription and compares it to the hook's stored value. Verified falsifiable — feeding
///         the oracle a wrong `timeDecayLength` makes it fail.
///
///         Campaign size is deliberately NOT pinned inline (inline `invariant.runs`/`invariant.depth`
///         cannot be overridden from the CLI or env, which un-deepens the campaign forever): the
///         suite inherits foundry.toml / CLI / `FOUNDRY_INVARIANT_RUNS` / `FOUNDRY_INVARIANT_DEPTH`,
///         so CI can drive it as deep as it likes. Only `fail-on-revert = false` is pinned — the
///         handler's fault-tolerance (see its header) makes that a semantic requirement, not a size
///         choice. `afterInvariant` guards progress by RATIO (see below), so it stays meaningful at
///         any depth.
contract Phase5ReentrancyInvariantTest is Phase5ReentrancyBase {
    using StateLibrary for IPoolManager;

    Phase5ReentrancyHandler internal handler;
    ReentrantERC20 internal token0;
    ReentrantERC20 internal token1;

    uint24 internal constant MIN_MIN_FEE = 100;
    uint24 internal constant MAX_MIN_FEE = 500;
    uint24 internal constant MAX_FEE = 200_000;
    uint256 internal constant DECAY = 1 hours;

    uint256 internal constant PIPS = 1e6;

    function setUp() public {
        _deployProtocol();

        ReentrantERC20 a = new ReentrantERC20("Phase5InvA", "P5IA", 18);
        ReentrantERC20 b = new ReentrantERC20("Phase5InvB", "P5IB", 18);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        _useTokens(address(a), address(b));
        token0 = ReentrantERC20(Currency.unwrap(currency0));
        token1 = ReentrantERC20(Currency.unwrap(currency1));

        (key, poolId) = _initAndConfigure(1, 0, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, DECAY, 0);
        _addLiquidity(key, TICK_LOWER, TICK_UPPER, 1e22);
        _enableProtocolFee(1_000, TREASURY);

        Phase5NestedSwapper attacker1 = new Phase5NestedSwapper(manager, hook, address(token1), key, poolId);
        Phase5NestedSwapper attacker0 = new Phase5NestedSwapper(manager, hook, address(token0), key, poolId);
        token0.mint(address(attacker0), 1e26);
        token1.mint(address(attacker0), 1e26);
        token0.mint(address(attacker1), 1e26);
        token1.mint(address(attacker1), 1e26);

        handler = new Phase5ReentrancyHandler(
            manager,
            swapRouter,
            modifyLiquidityRouter,
            hook,
            governance,
            timelockProxy,
            token0,
            token1,
            attacker0,
            attacker1,
            TREASURY,
            key,
            poolId,
            DECAY
        );
        token0.mint(address(handler), 1e28);
        token1.mint(address(handler), 1e28);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = Phase5ReentrancyHandler.swapMaybeArmed.selector;
        selectors[1] = Phase5ReentrancyHandler.advanceTime.selector;
        selectors[2] = Phase5ReentrancyHandler.setProtocolFeeBps.selector;
        selectors[3] = Phase5ReentrancyHandler.addLiquidity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice XSUB-1, the SHARP form: after every committed swap in the sequence, the handler
    ///         recomputes the whole accumulator chain for that transaction — the outer leg plus
    ///         every nested leg that re-entered inside its take — from an event-independent decay
    ///         transcription and price impacts derived from `slot0`/`AfterSwap` prices, with each
    ///         leg's direction inferred from the price movement. Any divergence latches
    ///         `chainMismatch`. This is the per-swap equality of the deterministic vectors, applied
    ///         across randomly-ordered histories instead of one frozen fixture.
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_XSUB1_accumulatorChainMatchesIndependentOracle() public view {
        assertFalse(handler.chainMismatch(), "accumulator diverged from the independent chain oracle");
        assertFalse(handler.impactMismatch(), "an emitted realized impact diverged from the oracle");
    }

    /// @notice XSUB-1 as a global bound: every accumulator write moves `|cumPriceImpact|` by at
    ///         most `PIPS_SCALE` (the impact cap) and the decay step can only shrink it, so after
    ///         `w` writes `|cum| <= 1e6 * w`. A nested swap double-counted into the outer's write,
    ///         a lost decay step, or a wrap past the saturating add all break this bound. The
    ///         ceiling counts one write per committed outer swap plus one per adversary callback,
    ///         so it is tight enough to falsify (it is NOT `type(int256).max`).
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_XSUB1_accumulatorMagnitudeBoundedByWriteCount() public view {
        (,,, int256 cum) = hook.poolData(poolId);
        uint256 abs = cum < 0 ? uint256(-cum) : uint256(cum);
        assertLe(abs, PIPS * handler.accumulatorWriteCeiling(), "accumulator grew faster than its cap allows");
    }

    /// @notice XSUB-1 coherence: `lastSwapTimestamp` can never run ahead of the clock, and the
    ///         `sqrtPriceX96Before` snapshot must be populated exactly once the pool has swapped —
    ///         a re-entry that wrote the wrong pool's slot, or that left the snapshot cleared, is
    ///         visible here.
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_XSUB1_poolDataStaysCoherent() public view {
        (uint160 sqrtBefore, uint48 lastTs,,) = hook.poolData(poolId);
        assertLe(uint256(lastTs), block.timestamp, "lastSwapTimestamp cannot be in the future");
        assertEq(lastTs > 0, handler.swapCount() > 0, "lastSwapTimestamp tracks the swap history");
        if (lastTs > 0) {
            assertGt(sqrtBefore, 0, "a swapped pool must carry a price snapshot");
        }
    }

    /// @notice SETTLE-12 / settlement hygiene: the take is `claims = false` and pays the treasury
    ///         directly, so across ANY history the hook must end every transaction holding neither
    ///         real tokens nor ERC-6909 claims. A settlement that credited the hook instead of the
    ///         treasury (or a claim minted and never swept) shows up here immediately.
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_SETTLE12_hookNeverHoldsValue() public view {
        assertEq(token0.balanceOf(address(hook)), 0, "hook holds currency0");
        assertEq(token1.balanceOf(address(hook)), 0, "hook holds currency1");
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(currency0)))),
            0,
            "hook holds currency0 claims"
        );
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(currency1)))),
            0,
            "hook holds currency1 claims"
        );
    }

    /// @notice SETTLE-12: settlement only ever moves value TOWARD the treasury. No action sequence
    ///         — including one where a nested swap re-enters mid-take — may claw a take back.
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_SETTLE12_treasuryBalancesAreMonotone() public view {
        assertFalse(handler.treasuryEverDecreased(), "a settled take was reversed");
    }

    /// @notice Progress guard, stated as RATIOS so it scales with whatever depth the campaign is
    ///         run at (absolute floors would be meaningless at depth 500 and flaky at depth 30).
    ///         The handler's try/catch makes forge's `reverts: 0` summary uninformative, so
    ///         degeneracy is judged from the handler's own ghosts:
    ///
    ///           - every committed swap must have been chain-checked (exact equality — the oracle
    ///             consumes the recorded logs of each committed swap, so any gap is a harness bug);
    ///           - at least 1 in 4 attempted swaps must commit (observed commit rate is >90%; a
    ///             sequence in which most swaps degenerate into the catch fails here instead of
    ///             passing on a handful of survivors);
    ///           - re-entries and settled takes must track the committed swaps (~7/8 of swaps run
    ///             armed and, with bps > 0 all but ~0.05% of the time, nearly every committed swap
    ///             settles a take; 1-in-4 / 1-in-8 floors leave wide statistical margin while still
    ///             failing any systematically dead settlement path).
    ///
    ///         Below 8 attempts (a deliberately shallow CLI/env-driven smoke run) ratio judgements
    ///         have no statistical meaning, so the guard self-disables rather than mislabelling
    ///         the property as failed.
    function afterInvariant() public view {
        uint256 committed = handler.swapCount();
        uint256 attempts = committed + handler.failedSwapCount();
        if (attempts < 8) return;

        assertEq(handler.chainChecks(), committed, "a committed swap escaped the chain oracle");
        assertGe(committed * 4, attempts, "most attempted swaps degenerated into the catch");
        assertGe(handler.reentryCount() * 4, committed, "the armed-swap re-entry path went dead");
        assertGe(handler.takeCount() * 8, committed, "the settlement path went dead");
    }
}
