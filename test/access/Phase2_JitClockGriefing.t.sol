// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------------------------
// Phase 2 (access-gov): JIT-12 — no cross-user JIT-clock griefing.
//
// The JIT clock is keyed by positionKey = keccak256(sender, tickLower, tickUpper, salt), where
// `sender` is the PoolManager caller (the router/position contract). An attacker driving a
// DIFFERENT contract (their own unlock callback, or any other router) therefore writes a
// DIFFERENT key and can never bump a victim's stamp. Under PositionManager the salt is the
// tokenId, which is mint/ownership-gated, so key collision is impossible there too.
//
// The second test DOCUMENTS the boundary condition: two users going through the SAME naive
// router with the same (ticks, salt) share one v4 position AND one JIT clock — inherent to
// v4's sender-keyed positions, not a SimHook defect (such routers already commingle the
// position itself, which is the larger problem). Documented here so LPs integrating via shared
// routers know to use per-user salts.
// ---------------------------------------------------------------------------------------------

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SimHook} from "../../src/SimHook.sol";

contract Phase2JitClockGriefingTest is SimHookUtils {
    PoolModifyLiquidityTest internal attackRouter;
    address internal constant ATTACKER = address(0xA77AC2);

    uint48 internal JIT; // StablePair config: 50 blocks

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(-600, 600, 1e12, initSqrtP, false); // depth; key (routerA, -600, 600, 0)
        (,,,,, JIT,,) = hook.poolConfig(poolId);
        assertGt(JIT, 0, "fixture must have a live JIT lock");

        // A second, attacker-controlled PoolManager caller. Same trust level as any contract
        // an attacker can deploy: from the hook's perspective its address IS the sender.
        attackRouter = new PoolModifyLiquidityTest(manager);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(attackRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(attackRouter), type(uint256).max);
    }

    function _mlp(int24 lo, int24 up, int256 delta, bytes32 salt) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: lo, tickUpper: up, liquidityDelta: delta, salt: salt});
    }

    function _expectJitLocked(uint48 blocksRemaining) internal {
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

    /// JIT-12: an attacker using their own PoolManager caller (different sender) with the
    /// victim's exact (ticks, salt) produces a DIFFERENT position key — the victim's stamp is
    /// untouched and their lock expires on the original schedule.
    function test_jit12_differentSender_cannotBumpVictimClock() public {
        int24 lo = -120;
        int24 up = 120;
        bytes32 salt = bytes32(uint256(0x56));

        // Victim (through the canonical router) opens a position; the hook stamps the clock.
        modifyLiquidityRouter.modifyLiquidity(key, _mlp(lo, up, 1e9, salt), ZERO_BYTES);
        bytes32 victimKey = Position.calculatePositionKey(address(modifyLiquidityRouter), lo, up, salt);
        // Anchor ALL block math on the stamp read back from the hook, never on `block.number`.
        // Under the via-IR optimizer `block.number` (the NUMBER opcode) is value-numbered as an
        // invariant and folded to a single representative across the whole function — it does not
        // model vm.roll mutating the block env, so BOTH a pre-roll snapshot AND a fresh read of
        // block.number can silently yield a pre- or post-roll value after a roll. A uint48 returned
        // from the hook is opaque and cannot be folded, so it is a safe absolute-block anchor.
        uint48 victimStamp = hook.lastAddedLiquidityBlock(poolId, victimKey);
        assertGt(victimStamp, 0, "victim clock is live");

        // Attacker copies ticks + salt exactly, but through their own contract, 10 blocks later.
        vm.roll(uint256(victimStamp) + 10);
        attackRouter.modifyLiquidity(key, _mlp(lo, up, 1e9, salt), ZERO_BYTES);
        bytes32 attackerKey = Position.calculatePositionKey(address(attackRouter), lo, up, salt);

        // Different sender => different key => the victim's clock did not move.
        assertTrue(attackerKey != victimKey, "sender is hashed into the position key");
        assertEq(
            hook.lastAddedLiquidityBlock(poolId, victimKey), victimStamp, "victim stamp unchanged by the attacker's add"
        );
        assertEq(
            hook.lastAddedLiquidityBlock(poolId, attackerKey),
            victimStamp + 10,
            "attacker only stamped their own key, 10 blocks later"
        );

        // Victim exits exactly on the original schedule — no extension happened.
        // Original deadline = victimStamp + JIT (an absolute block derived from the opaque stamp).
        vm.roll(uint256(victimStamp) + JIT);
        modifyLiquidityRouter.modifyLiquidity(key, _mlp(lo, up, -1e9, salt), ZERO_BYTES);
    }

    /// JIT-12 (boundary, documents current behaviour): two users behind
    /// the SAME naive router with the same (ticks, salt) share one position key, so a later add
    /// by anyone through that router re-stamps the shared clock and extends the earlier LP's
    /// wait. This is v4's sender-keyed position model, not a SimHook write path — the hook only
    /// ever stamps the key of the sender that actually added. PositionManager (salt = owned
    /// tokenId) is immune; shared routers must give each user a unique salt.
    function test_jit12_sharedRouterSharedSalt_clockIsShared_documented() public {
        int24 lo = -240;
        int24 up = 240;
        bytes32 salt = bytes32(uint256(0x77));

        // Victim opens the position through the shared router; the hook stamps the shared clock.
        modifyLiquidityRouter.modifyLiquidity(key, _mlp(lo, up, 1e9, salt), ZERO_BYTES);
        bytes32 sharedKey = Position.calculatePositionKey(address(modifyLiquidityRouter), lo, up, salt);
        // Anchor ALL block math on the stamp read back from the hook, never on `block.number`.
        // Under the via-IR optimizer `block.number` (the NUMBER opcode) is value-numbered as an
        // invariant and folded to a single representative across the whole function — it does not
        // model vm.roll mutating the block env, so BOTH a pre-roll snapshot AND a fresh read of
        // block.number can silently yield a pre- or post-roll value after a roll. A uint48 returned
        // from the hook is opaque and cannot be folded, so it is a safe absolute-block anchor.
        uint48 victimStamp = hook.lastAddedLiquidityBlock(poolId, sharedKey);
        assertGt(victimStamp, 0, "victim clock is live");

        // A different EOA adds dust through the SAME router with the SAME (ticks, salt), 10 blocks later.
        vm.roll(uint256(victimStamp) + 10);
        MockERC20 t0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(key.currency1));
        t0.mint(ATTACKER, 1e12);
        t1.mint(ATTACKER, 1e12);
        vm.startPrank(ATTACKER);
        t0.approve(address(modifyLiquidityRouter), type(uint256).max);
        t1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(key, _mlp(lo, up, 1e6, salt), ZERO_BYTES);
        vm.stopPrank();

        // Documented: the shared clock was re-stamped to the later add (victim's stamp + 10).
        uint48 restamp = hook.lastAddedLiquidityBlock(poolId, sharedKey);
        assertEq(restamp, victimStamp + 10, "documented: same sender contract + same salt = shared, re-stampable clock");

        // At the victim's ORIGINAL deadline (victimStamp + JIT) the shared position is still locked:
        // the current stamp is `restamp` (victimStamp + 10), elapsed = JIT - 10, so 10 blocks remain.
        vm.roll(uint256(victimStamp) + JIT);
        _expectJitLocked(10);
        modifyLiquidityRouter.modifyLiquidity(key, _mlp(lo, up, -1e9, salt), ZERO_BYTES);

        // It unlocks on the re-stamped schedule (restamp + JIT).
        vm.roll(uint256(restamp) + JIT);
        modifyLiquidityRouter.modifyLiquidity(key, _mlp(lo, up, -1e9, salt), ZERO_BYTES);
    }
}
