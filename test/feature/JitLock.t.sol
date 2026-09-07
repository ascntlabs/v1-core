// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IAscntFeeHook} from "../utils/IAscntFeeHook.sol";
import {SimHookFeatureBase} from "./base/SimHookFeatureBase.sol";
import {SimHook} from "../../src/SimHook.sol";

/// @dev Tests the JIT block-lock. Pool configured with `jitLockBlocks = 50` (from
///      NativeEthPoolConfig).
contract JitLockTest is SimHookFeatureBase {
    using StateLibrary for IPoolManager;

    int24 constant TICK_LOWER = 78000;
    int24 constant TICK_UPPER = 81000;

    function setUp() public {
        _deployConfigurePool();

        // seed unrelated liquidity so swaps work
        addLiquidity(76080, 90000, 10 ether, initialSqrtPriceX96, false);
        addLiquidity(-80000, 887000, 0.2 ether, initialSqrtPriceX96, false);
    }

    /// @dev lastAddedLiquidityBlock is set on add and bumped on a subsequent add.
    function test_clockSetOnAdd_andBumpedOnRepeat() public {
        // vm.getBlockNumber() instead of block.number: the via-IR optimizer treats the NUMBER
        // opcode as a frame constant and freely moves its reads across vm.roll, so direct
        // block.number arithmetic in a rolled test frame is unreliable.
        uint256 startBlock = vm.getBlockNumber();
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.5 ether, initialSqrtPriceX96, false);
        bytes32 positionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
        uint48 first = hook.lastAddedLiquidityBlock(poolId, positionKey);
        assertEq(first, startBlock, "clock set to current block on add");

        vm.roll(startBlock + 10);
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.3 ether, initialSqrtPriceX96, false);
        uint48 second = hook.lastAddedLiquidityBlock(poolId, positionKey);
        assertEq(second, startBlock + 10, "clock bumped on repeat add");
        assertGt(second, first);
    }

    /// @dev Re-encodes the CustomRevert.WrappedError v4-core wraps hook reverts in, so the test
    /// asserts JitLockActive with the EXACT blocksRemaining — an off-by-one or a wrong-reason
    /// revert fails instead of passing.
    function _expectJitLockRevert(uint48 blocksRemaining) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(SimHook.JitLockActive.selector, blocksRemaining),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev Removing inside the lock window reverts JitLockActive with the exact remaining
    /// blocks — same-block (full window) and mid-window in one sequence.
    function test_removeInsideWindow_reverts() public {
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.5 ether, initialSqrtPriceX96, false);

        _expectJitLockRevert(50); // same block: elapsed 0 of 50
        removeLiquidity(TICK_LOWER, TICK_UPPER, 1);

        vm.roll(vm.getBlockNumber() + 10); // still inside the 50-block window
        _expectJitLockRevert(40); // 50 - 10 elapsed
        removeLiquidity(TICK_LOWER, TICK_UPPER, 1);
    }

    /// @dev Removing exactly at the window boundary succeeds.
    function test_removeAtBoundary_succeeds() public {
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.5 ether, initialSqrtPriceX96, false);

        vm.roll(block.number + 50); // elapsed == lockBlocks, no longer < lockBlocks
        removeLiquidity(TICK_LOWER, TICK_UPPER, 1);
    }

    /// @dev Removing after the window succeeds.
    function test_removeAfterWindow_succeeds() public {
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.5 ether, initialSqrtPriceX96, false);

        vm.roll(block.number + 100);
        removeLiquidity(TICK_LOWER, TICK_UPPER, 1);
    }

    /// @dev jitLockBlocks = 0 disables the lock entirely — remove always works.
    function test_lockDisabled_removeAlwaysAllowed() public {
        // fresh pool with lock disabled
        address hookAddress2 = deployCoreAndHookCustomDecimals("SimHook.sol", "ETH", "DAI", 18, 18, true);
        IAscntFeeHook hook2 = IAscntFeeHook(hookAddress2);
        // address(this) is owner+timelock from TestUtils.deployCoreAndHookCustomDecimals
        deployPool(IHooks(hookAddress2), 79500, 1, false);
        _configurePool(hookAddress2, 100, 200000, 1 hours, 0, 2_000_000, 1_000_000);

        addLiquidity(TICK_LOWER, TICK_UPPER, 0.5 ether, initialSqrtPriceX96, false);

        // with lock disabled, clock is never written
        bytes32 positionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
        assertEq(hook2.lastAddedLiquidityBlock(poolId, positionKey), 0, "clock not written when lock disabled");

        // remove in the same block — no revert
        removeLiquidity(TICK_LOWER, TICK_UPPER, 1);
    }

    /// @dev A fee-only poke (liquidityDelta == 0) routes through afterAddLiquidity
    /// but must NOT reset the lock clock.
    function test_poke_doesNotResetClock() public {
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.5 ether, initialSqrtPriceX96, false);

        bytes32 positionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
        uint48 firstBlock = hook.lastAddedLiquidityBlock(poolId, positionKey);

        // generate some fees then advance so we can observe a would-be clock reset
        swap(true, -0.05 ether, false);
        vm.roll(block.number + 20);

        // poke with liquidityDelta = 0
        ModifyLiquidityParams memory pokeParams =
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 0, salt: bytes32(0)});
        modifyLiquidityRouter.modifyLiquidity(key, pokeParams, ZERO_BYTES);

        uint48 afterPoke = hook.lastAddedLiquidityBlock(poolId, positionKey);
        assertEq(afterPoke, firstBlock, "poke must not bump the lock clock");
    }

    /// @dev The lock is keyed per position (owner, ticks, salt): a fresh lock on position B
    /// must not block removal of an already-unlocked position A.
    function test_lockIsolatedPerPositionKey() public {
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.5 ether, initialSqrtPriceX96, false); // position A
        vm.roll(block.number + 50); // A's window elapses

        addLiquidity(76080, 90000, 0.5 ether, initialSqrtPriceX96, false); // position B, locked now

        removeLiquidity(TICK_LOWER, TICK_UPPER, 1); // A unlocked — must succeed

        _expectJitLockRevert(50); // B still locked, full window remaining
        removeLiquidity(76080, 90000, 1);
    }

    /// @dev Clock is bumped on the later of interleaved adds; remove is blocked until the
    /// most-recent add's window elapses. vm.getBlockNumber() everywhere — see the NUMBER-opcode
    /// note on test_clockSetOnAdd_andBumpedOnRepeat.
    function test_clockTracksMostRecentAdd() public {
        uint256 startBlock = vm.getBlockNumber();
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.01 ether, initialSqrtPriceX96, false);
        vm.roll(startBlock + 30);
        swap(true, -0.02 ether, false);

        // second add bumps clock to this block
        addLiquidity(TICK_LOWER, TICK_UPPER, 0.01 ether, initialSqrtPriceX96, false);
        bytes32 positionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
        assertEq(hook.lastAddedLiquidityBlock(poolId, positionKey), startBlock + 30);

        // advance only 30 blocks after the most-recent add — still < 50, should revert
        vm.roll(startBlock + 60);
        _expectJitLockRevert(20); // 50 - 30 elapsed since the MOST RECENT add
        removeLiquidity(TICK_LOWER, TICK_UPPER, 1);
    }
}

