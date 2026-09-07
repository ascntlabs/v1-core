// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SimHook} from "../../../src/SimHook.sol";
import {AscntGovernance} from "../../../src/AscntGovernance.sol";

/// @notice Phase-4b stateful handler for the JIT block-lock. Tracks a "victim" position
///         (fixed salt, fixed range) through arbitrary interleavings of adds, third-party
///         adds, fee pokes, swaps, block rolls, pause toggles, and removal attempts, and
///         verifies the lock's semantics IN-LINE against ghost bookkeeping. Violations are
///         recorded (not asserted) because the campaign runs with fail-on-revert = false;
///         the invariant contract asserts violations == 0.
///
///         In-line checks map to: JIT-7 (removal succeeds whenever eligible), JIT-9 (stamp
///         monotonic; deadline gated by the MOST RECENT add), JIT-2 (poke never blocked),
///         JIT-3 (poke never restamps), JIT-10 (third-party adds never touch the victim's
///         stamp), JIT-13 (swaps never touch the stamp), XSUB-7 (paused adds revert without
///         re-arming; removals unaffected by pause), and the exact JitLockActive payload on
///         every in-window removal attempt (JIT-1/JIT-8 stateful slice).
contract Phase4bJitHandler is Test {
    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable liqRouter;
    SimHook public immutable hook;
    AscntGovernance public immutable governance;
    uint48 public immutable lockBlocks;

    PoolKey internal key;
    PoolId internal poolId;

    int24 public constant TICK_LOWER = -600;
    int24 public constant TICK_UPPER = 600;
    bytes32 public constant VICTIM_SALT = bytes32(uint256(0xF1C71));
    bytes32 public constant OTHER_SALT = bytes32(uint256(0x07EA));
    int24 public constant OTHER_TL = -1200;
    int24 public constant OTHER_TU = 1200;

    /// @dev Minimum removal size: PoolModifyLiquidityTest `assert`s that a remove produces a
    ///      nonzero delta, and dust removals round both amounts to 0 at this pool's price
    ///      scale (a router-harness artifact, not hook behavior). Removals are kept >= this,
    ///      and remainders below it are swept in full, so the ghost position is always either
    ///      0 or >= MIN_REMOVE.
    uint256 public constant MIN_REMOVE = 1e6;

    bytes32 public victimKey;

    // ---- ghost state ----
    uint256 public ghostStamp; // block of the victim's most recent successful add (0 = never)
    uint256 public ghostVictimLiq; // victim position liquidity per our bookkeeping
    uint256 public ghostOtherLiq;

    // ---- progress counters ----
    uint256 public totalCalls;
    uint256 public addOkCount;
    uint256 public pausedAddCount;
    uint256 public otherAddCount;
    uint256 public pokeCount;
    uint256 public swapCount;
    uint256 public swapRevertCount;
    uint256 public rollCount;
    uint256 public pauseToggleCount;
    uint256 public removeOkCount;
    uint256 public lockRevertCount;

    // ---- violation recording ----
    uint256 public violations;
    string public firstViolation;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _liqRouter,
        SimHook _hook,
        AscntGovernance _governance,
        PoolKey memory _key,
        PoolId _poolId,
        uint48 _lockBlocks
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        liqRouter = _liqRouter;
        hook = _hook;
        governance = _governance;
        key = _key;
        poolId = _poolId;
        lockBlocks = _lockBlocks;
        victimKey = Position.calculatePositionKey(address(_liqRouter), TICK_LOWER, TICK_UPPER, VICTIM_SALT);

        _approve(_key.currency0);
        _approve(_key.currency1);
    }

    function _approve(Currency c) internal {
        address t = Currency.unwrap(c);
        if (t == address(0)) return;
        MockERC20(t).approve(address(swapRouter), type(uint256).max);
        MockERC20(t).approve(address(liqRouter), type(uint256).max);
    }

    function _flag(string memory what) internal {
        violations++;
        if (bytes(firstViolation).length == 0) firstViolation = what;
    }

    function _stamp() internal view returns (uint48) {
        return hook.lastAddedLiquidityBlock(poolId, victimKey);
    }

    function _params(
        int24 tl,
        int24 tu,
        int256 delta,
        bytes32 salt
    ) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: delta, salt: salt});
    }

    // ------------------------------------------------------------------
    // actions
    // ------------------------------------------------------------------

    /// @dev Add to the victim position. Success must stamp the current block, monotonically
    ///      (JIT-9); failure is legitimate ONLY under the pause and must not restamp (XSUB-7).
    function addVictim(uint256 seed) external {
        totalCalls++;
        uint256 liq = _bound(seed, 1e8, 1e11);
        uint48 stampBefore = _stamp();
        bool paused = governance.addLiquidityPaused();

        // Collect accrued fees first so the add nets exactly its cost and the checked router's
        // add asserts hold; skipped on an empty position (v4 reverts a zero-delta update of one).
        if (ghostVictimLiq != 0) {
            try liqRouter.modifyLiquidity(key, _params(TICK_LOWER, TICK_UPPER, 0, VICTIM_SALT), "") returns (
                BalanceDelta
            ) {}
            catch {
                _flag("pre-add fee poke on the victim reverted (JIT-2)");
            }
        }
        try liqRouter.modifyLiquidity(key, _params(TICK_LOWER, TICK_UPPER, int256(liq), VICTIM_SALT), "") returns (
            BalanceDelta
        ) {
            if (paused) _flag("add succeeded while paused");
            uint256 nb = vm.getBlockNumber();
            uint48 st = _stamp();
            if (uint256(st) != nb) _flag("stamp != block.number after add");
            if (st < stampBefore) _flag("stamp moved backwards on re-add (JIT-9)");
            ghostStamp = nb;
            ghostVictimLiq += liq;
            addOkCount++;
        } catch {
            if (!paused) _flag("unpaused victim add reverted unexpectedly");
            if (_stamp() != stampBefore) _flag("failed add changed the stamp (XSUB-7)");
            pausedAddCount++;
        }
    }

    /// @dev Add to a DIFFERENT position key (same pool, other salt + range). Must never touch
    ///      the victim's stamp (JIT-10).
    function addOther(uint256 seed) external {
        totalCalls++;
        uint256 liq = _bound(seed, 1e8, 1e11);
        uint48 stampBefore = _stamp();
        bool paused = governance.addLiquidityPaused();

        // Same pre-add fee poke as addVictim, on the other position.
        if (ghostOtherLiq != 0) {
            try liqRouter.modifyLiquidity(key, _params(OTHER_TL, OTHER_TU, 0, OTHER_SALT), "") returns (BalanceDelta) {}
            catch {
                _flag("pre-add fee poke on the other position reverted");
            }
        }
        try liqRouter.modifyLiquidity(key, _params(OTHER_TL, OTHER_TU, int256(liq), OTHER_SALT), "") returns (
            BalanceDelta
        ) {
            if (paused) _flag("other add succeeded while paused");
            ghostOtherLiq += liq;
            otherAddCount++;
        } catch {
            if (!paused) _flag("unpaused other add reverted unexpectedly");
        }
        if (_stamp() != stampBefore) _flag("third-party add changed the victim stamp (JIT-10)");
    }

    /// @dev Fee-only poke on the victim. Must ALWAYS succeed — the lock only gates delta < 0
    ///      and the pause only gates the add path (JIT-2) — and must never restamp (JIT-3).
    function pokeVictim(uint256) external {
        totalCalls++;
        if (ghostVictimLiq == 0) return;
        uint48 stampBefore = _stamp();

        try liqRouter.modifyLiquidity(key, _params(TICK_LOWER, TICK_UPPER, 0, VICTIM_SALT), "") returns (BalanceDelta) {
            pokeCount++;
        } catch {
            _flag("fee-only poke was blocked (JIT-2)");
        }
        if (_stamp() != stampBefore) _flag("poke changed the stamp (JIT-3)");
    }

    /// @dev Swap. Must never touch the lock clock (JIT-13: no swap path writes it).
    function swapSome(uint256 seed, bool zeroForOne) external {
        totalCalls++;
        uint48 stampBefore = _stamp();
        uint256 amount = _bound(seed, 1e3, 1e9);
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        try swapRouter.swap(key, p, s, "") {
            swapCount++;
        } catch {
            swapRevertCount++;
        }
        if (_stamp() != stampBefore) _flag("swap changed the victim stamp (JIT-13)");
    }

    function advanceBlocks(uint256 seed) external {
        totalCalls++;
        vm.roll(vm.getBlockNumber() + _bound(seed, 1, 97));
        vm.warp(block.timestamp + _bound(seed, 1, 3600));
        rollCount++;
    }

    /// @dev Handler is wired as the governance pauser, so it can flip the pause mid-sequence.
    function togglePause(uint256 seed) external {
        totalCalls++;
        governance.setAddLiquidityPaused(seed % 2 == 0);
        pauseToggleCount++;
    }

    /// @dev Attempt a victim removal and check the outcome against the ghost model:
    ///      eligible (block.number >= ghostStamp + lockBlocks) => MUST succeed (JIT-7, and
    ///      pause-independence per XSUB-7); ineligible => MUST revert with the exact wrapped
    ///      JitLockActive(ghostStamp + lockBlocks - now) (JIT-1/JIT-8/JIT-9 stateful slice).
    function tryRemoveVictim(uint256 seed) external {
        totalCalls++;
        if (ghostVictimLiq == 0) return;
        uint256 amt;
        if (ghostVictimLiq <= MIN_REMOVE) {
            amt = ghostVictimLiq;
        } else {
            amt = _bound(seed, MIN_REMOVE, ghostVictimLiq);
            if (ghostVictimLiq - amt < MIN_REMOVE) amt = ghostVictimLiq; // sweep the remainder
        }
        uint256 nb = vm.getBlockNumber();
        bool eligible = nb >= ghostStamp + uint256(lockBlocks);

        try liqRouter.modifyLiquidity(key, _params(TICK_LOWER, TICK_UPPER, -int256(amt), VICTIM_SALT), "") returns (
            BalanceDelta
        ) {
            if (!eligible) _flag("remove succeeded INSIDE the lock window (lock bypass)");
            ghostVictimLiq -= amt;
            removeOkCount++;
        } catch (bytes memory err) {
            if (eligible) {
                _flag("remove blocked at/after the deadline (JIT-7 liveness violation)");
            } else {
                uint48 expectRemaining = uint48(ghostStamp + uint256(lockBlocks) - nb);
                bytes memory expected = abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeRemoveLiquidity.selector,
                    abi.encodeWithSelector(SimHook.JitLockActive.selector, expectRemaining),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                );
                if (keccak256(err) != keccak256(expected)) {
                    _flag("in-window remove reverted with the wrong reason/remaining");
                }
                lockRevertCount++;
            }
        }
    }

    // ------------------------------------------------------------------
    // liveness probe (called from afterInvariant, not fuzzed)
    // ------------------------------------------------------------------

    /// @dev Remove the ENTIRE remaining victim position; returns whether it succeeded.
    ///      Called at ghostStamp + lockBlocks with the pause forced ON to prove the joint
    ///      pause x lock composition never traps funds (JIT-7 + XSUB-7).
    function forceRemoveAllVictim() external returns (bool ok) {
        if (ghostVictimLiq == 0) return true;
        try liqRouter.modifyLiquidity(
            key, _params(TICK_LOWER, TICK_UPPER, -int256(ghostVictimLiq), VICTIM_SALT), ""
        ) returns (
            BalanceDelta
        ) {
            ghostVictimLiq = 0;
            removeOkCount++;
            ok = true;
        } catch {
            ok = false;
        }
    }
}
