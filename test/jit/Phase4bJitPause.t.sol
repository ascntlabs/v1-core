// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {TestUtils} from "../utils/TestUtils.sol";
import {SimHook} from "../../src/SimHook.sol";
import {AscntBaseHook} from "../../src/AscntBaseHook.sol";

/// @notice Phase 4b (JIT block-lock) — XSUB-7: add-liquidity pause x JIT lock joint liveness.
///         Holds BOTH gates active on the same position at once (pause blocks adds, lock
///         blocks removes) and asserts the composition can never permanently trap LP funds:
///         the in-window remove fails on the JIT gate specifically (not the pause), the
///         boundary remove succeeds with the pause still active, and pause transitions never
///         extend or re-arm a lock.
contract Phase4bJitPauseTest is TestUtils {
    SimHook internal simHook;
    uint160 internal initSqrtP;

    uint48 internal constant LOCK = 50;
    int24 internal constant TL = -600;
    int24 internal constant TU = 600;

    /// @dev Minimum liquidity for a successful removal probe: PoolModifyLiquidityTest
    ///      `assert`s a remove produces a nonzero delta; dust removals round to (0,0) at this
    ///      pool's price scale (router-harness artifact, not hook behavior).
    int256 internal constant REMOVE_PROBE = 1e6;

    function setUp() public {
        address hookAddress = deployCoreAndHookCustomDecimals("SimHook.sol", "USDC", "USDT", 6, 6, false);
        simHook = SimHook(hookAddress);
        (, initSqrtP) = deployPool(IHooks(hookAddress), 0, 1, false);
        simHook.configurePool(poolId, 10, 10, 10_000, 3600, LOCK, 2e6, 1e6);

        // unrelated depth so the victim position is not the only liquidity
        addLiquidity(-6000, 6000, 1e12, initSqrtP, false);
    }

    function _victimKey() internal view returns (bytes32) {
        return Position.calculatePositionKey(address(modifyLiquidityRouter), TL, TU, bytes32(0));
    }

    function _expectJitLockRevert(uint48 blocksRemaining) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(simHook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(SimHook.JitLockActive.selector, blocksRemaining),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _expectPausedAddRevert() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(simHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(AscntBaseHook.AddLiquidityIsPaused.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev XSUB-7 core: with the pause AND the lock simultaneously active on the same
    ///      position, the LP can neither add nor remove — yet a remove succeeds the moment
    ///      block.number >= stamp + jitLockBlocks, with the pause STILL active. No pause x
    ///      lock combination traps funds past the lock horizon.
    function test_xsub7_jointPauseAndLockNeverTrapFunds() public {
        uint256 b0 = vm.getBlockNumber();
        LiquidityValues memory lv = addLiquidity(TL, TU, 1e10, initSqrtP, false); // victim stamped at b0
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, _victimKey())), b0);

        governance.setAddLiquidityPaused(true);
        vm.roll(b0 + 10); // strictly inside the lock window

        // (a) both gates verified active on the SAME position at the SAME time:
        // add blocked by the pause...
        ModifyLiquidityParams memory addP =
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: int256(1e9), salt: bytes32(0)});
        _expectPausedAddRevert();
        modifyLiquidityRouter.modifyLiquidity(key, addP, ZERO_BYTES);
        // ...and the failed paused add must NOT have re-armed / restamped the lock
        assertEq(
            uint256(simHook.lastAddedLiquidityBlock(poolId, _victimKey())),
            b0,
            "reverted paused add must not restamp the lock"
        );

        // (b) remove blocked by the JIT gate specifically (exact JitLockActive, not the pause)
        _expectJitLockRevert(LOCK - 10);
        removeLiquidity(TL, TU, REMOVE_PROBE);

        // (c) fee-only poke stays live under pause + lock (delta==0 routes the remove path)
        ModifyLiquidityParams memory poke =
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: 0, salt: bytes32(0)});
        modifyLiquidityRouter.modifyLiquidity(key, poke, ZERO_BYTES);
        assertEq(
            uint256(simHook.lastAddedLiquidityBlock(poolId, _victimKey())), b0, "poke under pause must not restamp"
        );

        // (d) at exactly stamp + jitLockBlocks, with the pause STILL on, full exit succeeds
        vm.roll(b0 + LOCK);
        assertTrue(governance.addLiquidityPaused(), "pause still active at the boundary");
        removeLiquidity(TL, TU, lv.liquidityDelta);
        (uint128 liqLeft,,) =
            StateLibrary.getPositionInfo(manager, poolId, address(modifyLiquidityRouter), TL, TU, bytes32(0));
        assertEq(uint256(liqLeft), 0, "victim position fully recoverable under pause");
    }

    /// @dev XSUB-7 complement: pause transitions themselves never extend, re-arm, or clear a
    ///      lock — the stamp moves ONLY on a successful add (which requires the pause to be
    ///      lifted first).
    function test_xsub7_pauseTogglesNeverMoveTheLockClock() public {
        uint256 b0 = vm.getBlockNumber();
        addLiquidity(TL, TU, 1e10, initSqrtP, false); // stamped at b0
        bytes32 vKey = _victimKey();

        // toggle the pause repeatedly across the window; stamp must never move
        governance.setAddLiquidityPaused(true);
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, vKey)), b0, "pause-on must not move the stamp");
        vm.roll(b0 + 20);
        governance.setAddLiquidityPaused(false);
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, vKey)), b0, "pause-off must not move the stamp");
        governance.setAddLiquidityPaused(true);

        // deadline is untouched: still locked with the original remaining count...
        _expectJitLockRevert(LOCK - 20);
        removeLiquidity(TL, TU, REMOVE_PROBE);

        // ...and unlocks exactly at the ORIGINAL deadline despite all the toggling
        vm.roll(b0 + LOCK);
        removeLiquidity(TL, TU, REMOVE_PROBE);

        // re-arming requires a real add: blocked while paused, effective once unpaused
        ModifyLiquidityParams memory addP =
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: int256(1e9), salt: bytes32(0)});
        _expectPausedAddRevert();
        modifyLiquidityRouter.modifyLiquidity(key, addP, ZERO_BYTES);
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, vKey)), b0, "blocked add must not re-arm");

        governance.setAddLiquidityPaused(false);
        uint256 b1 = vm.getBlockNumber();
        modifyLiquidityRouter.modifyLiquidity(key, addP, ZERO_BYTES);
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, vKey)), b1, "unpaused add re-arms at current block");
    }
}
