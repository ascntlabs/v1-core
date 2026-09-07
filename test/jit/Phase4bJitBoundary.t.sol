// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {TestUtils} from "../utils/TestUtils.sol";
import {SimHook} from "../../src/SimHook.sol";

/// @notice Phase 4b (JIT block-lock) — stateless / differential fuzz over the lock-window
///         boundary, the jitLockBlocks config bound, the unstamped-key short-circuit, the
///         poke path, and the uint48 block-height cast.
///
///         Covers: JIT-1, JIT-2 (+JIT-3 support), JIT-5, JIT-6, JIT-8, JIT-14.
///
///         The pool is deployed but NOT configured in setUp, so every fuzz run can write its
///         own one-time `jitLockBlocks` (configurePool is immutable per pool; Foundry restores
///         the post-setUp snapshot between runs, so each run sees an unconfigured pool).
///
///         NOTE on block numbers: `vm.getBlockNumber()` is used instead of `block.number`
///         everywhere a frame also calls `vm.roll` — the via-IR optimizer treats the NUMBER
///         opcode as a frame constant (see test/feature/JitLock.t.sol).
contract Phase4bJitBoundaryFuzzTest is TestUtils {
    SimHook internal simHook;
    uint160 internal initSqrtP;

    int24 internal constant TL = -600;
    int24 internal constant TU = 600;
    uint48 internal constant MAX_JIT = 50_400;

    function setUp() public {
        address hookAddress = deployCoreAndHookCustomDecimals("SimHook.sol", "USDC", "USDT", 6, 6, false);
        simHook = SimHook(hookAddress);
        (, initSqrtP) = deployPool(IHooks(hookAddress), 0, 1, false);
        // deliberately NOT configured here — each test/fuzz run picks its own jitLockBlocks
    }

    function _configure(uint48 jit) internal {
        simHook.configurePool(poolId, 10, 10, 10_000, 3600, jit, 2e6, 1e6);
    }

    function _victimKey() internal view returns (bytes32) {
        return Position.calculatePositionKey(address(modifyLiquidityRouter), TL, TU, bytes32(0));
    }

    /// @dev Minimum liquidity for a successful removal probe: PoolModifyLiquidityTest
    ///      `assert`s that a remove produces a nonzero delta, and at this pool's price scale
    ///      (tick 0, +/-600 range) removing < ~34 liquidity rounds both amounts to 0. 1e6
    ///      keeps the probe well clear of that router-harness artifact.
    int256 internal constant REMOVE_PROBE = 1e6;

    /// @dev Attempts a removal on the salt-0 router position; returns success + raw revert bytes.
    function _tryRemove(int256 liq) internal returns (bool ok, bytes memory err) {
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: -liq, salt: bytes32(0)});
        try modifyLiquidityRouter.modifyLiquidity(key, p, ZERO_BYTES) returns (BalanceDelta) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    /// @dev Splits ABI-encoded revert data into its 4-byte selector and the remaining payload.
    function _split(bytes memory data) internal pure returns (bytes4 sel, bytes memory rest) {
        require(data.length >= 4, "revert data too short");
        sel = bytes4(data[0]) | (bytes4(data[1]) >> 8) | (bytes4(data[2]) >> 16) | (bytes4(data[3]) >> 24);
        rest = new bytes(data.length - 4);
        for (uint256 i = 0; i < rest.length; i++) {
            rest[i] = data[i + 4];
        }
    }

    /// @dev Decodes the ACTUAL revert bytes v4-core bubbled up (CustomRevert.WrappedError
    ///      around the hook's beforeRemoveLiquidity failure) and extracts JitLockActive's
    ///      blocksRemaining. Returns isJit=false for any other shape, so callers assert on the
    ///      contract's real payload rather than on bytes the test built itself.
    function _decodeJitLock(bytes memory err) internal view returns (bool isJit, uint48 remaining) {
        (bytes4 wsel, bytes memory body) = _split(err);
        if (wsel != CustomRevert.WrappedError.selector) return (false, 0);
        (address target, bytes4 hookSel, bytes memory reason, bytes memory details) =
            abi.decode(body, (address, bytes4, bytes, bytes));
        if (target != address(simHook)) return (false, 0);
        if (hookSel != IHooks.beforeRemoveLiquidity.selector) return (false, 0);
        if (keccak256(details) != keccak256(abi.encodeWithSelector(Hooks.HookCallFailed.selector))) return (false, 0);
        (bytes4 rsel, bytes memory rbody) = _split(reason);
        if (rsel != SimHook.JitLockActive.selector) return (false, 0);
        remaining = abi.decode(rbody, (uint48));
        isJit = true;
    }

    // ------------------------------------------------------------------
    // JIT-1 + JIT-8 — lock-window boundary, fuzzed over lockBlocks [1, MAX_JIT]
    // ------------------------------------------------------------------

    /// @dev JIT-1: removal reverts JitLockActive iff elapsed < lockBlocks; the boundary
    ///      H = B + lockBlocks is REMOVABLE. JIT-8: the thrown blocksRemaining equals
    ///      lockBlocks - elapsed and is always in [1, lockBlocks] (decoded from the actual
    ///      revert bytes, not rebuilt by the test).
    /// forge-config: default.fuzz.runs = 128
    /// forge-config: dev.fuzz.runs = 128
    function testFuzz_jit1_jit8_lockWindowBoundaryExact(uint48 lockSeed, uint256 elapsedSeed, uint256 postSeed) public {
        uint48 lockBlocks = uint48(bound(uint256(lockSeed), 1, MAX_JIT));
        _configure(lockBlocks);

        uint256 b0 = vm.getBlockNumber();
        addLiquidity(TL, TU, 1e10, initSqrtP, false);
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, _victimKey())), b0, "stamp == add block");

        // inside the window: revert with the exact remaining count
        uint256 elapsed = bound(elapsedSeed, 0, uint256(lockBlocks) - 1);
        vm.roll(b0 + elapsed);
        (bool ok, bytes memory err) = _tryRemove(REMOVE_PROBE);
        assertFalse(ok, "remove inside window must revert (JIT-1)");
        (bool isJit, uint48 remaining) = _decodeJitLock(err);
        assertTrue(isJit, "revert inside window must be JitLockActive (JIT-1)");
        assertEq(uint256(remaining), uint256(lockBlocks) - elapsed, "blocksRemaining == lockBlocks - elapsed");
        assertGe(remaining, 1, "blocksRemaining never 0 while locked (JIT-8)");
        assertLe(remaining, lockBlocks, "blocksRemaining never exceeds lockBlocks (JIT-8)");

        // the exact boundary H = B + lockBlocks is removable
        vm.roll(b0 + uint256(lockBlocks));
        (ok, err) = _tryRemove(REMOVE_PROBE);
        assertTrue(ok, "remove at exactly B + lockBlocks must succeed (JIT-1 boundary)");

        // and stays removable at any later height (no further add re-stamped the key)
        uint256 post = bound(postSeed, 1, 100_000);
        vm.roll(b0 + uint256(lockBlocks) + post);
        (ok, err) = _tryRemove(REMOVE_PROBE);
        assertTrue(ok, "remove beyond the boundary must keep succeeding");
    }

    // ------------------------------------------------------------------
    // JIT-6 — configurePool jitLockBlocks bound
    // ------------------------------------------------------------------

    /// @dev JIT-6: configurePool reverts JitLockBlocksTooHigh for any jitLockBlocks > MAX_JIT
    ///      (and leaves the pool unconfigured); otherwise it stores exactly the supplied value.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: dev.fuzz.runs = 256
    function testFuzz_jit6_configureJitLockBound(uint48 jitSeed, bool highRegion) public {
        if (highRegion) {
            uint48 jit = uint48(bound(uint256(jitSeed), uint256(MAX_JIT) + 1, type(uint48).max));
            vm.expectRevert(SimHook.JitLockBlocksTooHigh.selector);
            simHook.configurePool(poolId, 10, 10, 10_000, 3600, jit, 2e6, 1e6);
            (bool configured,,,,,,,) = simHook.poolConfig(poolId);
            assertFalse(configured, "rejected config must not mark the pool configured");
        } else {
            uint48 jit = uint48(bound(uint256(jitSeed), 0, uint256(MAX_JIT)));
            simHook.configurePool(poolId, 10, 10, 10_000, 3600, jit, 2e6, 1e6);
            (bool configured,,,,, uint48 storedJit,,) = simHook.poolConfig(poolId);
            assertTrue(configured, "valid config must mark the pool configured");
            assertEq(storedJit, jit, "stored jitLockBlocks must equal the supplied value exactly");
        }
    }

    /// @dev JIT-6 corners from the invariant spec: MAX_JIT accepted + stored, MAX_JIT+1 and
    ///      uint48.max rejected with the named revert.
    function test_jit6_corners() public {
        vm.expectRevert(SimHook.JitLockBlocksTooHigh.selector);
        simHook.configurePool(poolId, 10, 10, 10_000, 3600, type(uint48).max, 2e6, 1e6);

        vm.expectRevert(SimHook.JitLockBlocksTooHigh.selector);
        simHook.configurePool(poolId, 10, 10, 10_000, 3600, MAX_JIT + 1, 2e6, 1e6);

        simHook.configurePool(poolId, 10, 10, 10_000, 3600, MAX_JIT, 2e6, 1e6);
        (bool configured,,,,, uint48 storedJit,,) = simHook.poolConfig(poolId);
        assertTrue(configured);
        assertEq(storedJit, MAX_JIT, "MAX_JIT_LOCK_BLOCKS itself must be accepted and stored exactly");
    }

    // ------------------------------------------------------------------
    // JIT-5 — unstamped position keys are never blocked
    // ------------------------------------------------------------------

    /// @dev JIT-5: for any (owner, ticks, salt) tuple whose key was never stamped
    ///      (lastAddedLiquidityBlock == 0), _beforeRemoveLiquidity's `added != 0`
    ///      short-circuit skips the lock entirely — the callback returns its selector even
    ///      though the lock is armed for a sibling key in the same pool. Called directly on
    ///      the hook (pranked as PoolManager) so arbitrary tuples can be exercised without
    ///      needing core liquidity under them. The contrast leg proves the very same call on
    ///      the STAMPED tuple does revert, so the pass is not vacuous.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: dev.fuzz.runs = 256
    function testFuzz_jit5_unstampedKeyNeverBlocked(
        address fuzzOwner,
        int24 tickASeed,
        int24 tickBSeed,
        bytes32 fuzzSalt,
        uint96 liqSeed
    ) public {
        _configure(50);
        addLiquidity(TL, TU, 1e10, initSqrtP, false); // stamps (router, TL, TU, 0) this block

        int24 tl = int24(bound(int256(tickASeed), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        int24 tu = int24(bound(int256(tickBSeed), int256(tl) + 1, TickMath.MAX_TICK));
        bytes32 k = Position.calculatePositionKey(fuzzOwner, tl, tu, fuzzSalt);
        vm.assume(simHook.lastAddedLiquidityBlock(poolId, k) == 0); // tuple never stamped

        int256 delta = -int256(uint256(bound(uint256(liqSeed), 1, type(uint96).max)));
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: delta, salt: fuzzSalt});
        address mgr = address(manager);

        vm.prank(mgr);
        bytes4 sel = simHook.beforeRemoveLiquidity(fuzzOwner, key, p, ZERO_BYTES);
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector, "unstamped key must never be lock-blocked (JIT-5)");

        // contrast: the stamped tuple IS blocked by the very same entry point (full window)
        ModifyLiquidityParams memory pStamped =
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: -1, salt: bytes32(0)});
        address stampedOwner = address(modifyLiquidityRouter);
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(SimHook.JitLockActive.selector, uint48(50)));
        simHook.beforeRemoveLiquidity(stampedOwner, key, pStamped, ZERO_BYTES);
    }

    // ------------------------------------------------------------------
    // JIT-2 (+JIT-3 support) — fee-only pokes are never blocked and never restamp
    // ------------------------------------------------------------------

    /// @dev JIT-2: a liquidityDelta == 0 poke succeeds at EVERY point inside an active lock
    ///      window, including while the add-liquidity pause is active (delta==0 routes the
    ///      remove path, which the pause does not gate). JIT-3: the poke leaves the stamp
    ///      unchanged, and the lock still enforces with the un-shifted remaining count after.
    /// forge-config: default.fuzz.runs = 128
    /// forge-config: dev.fuzz.runs = 128
    function testFuzz_jit2_pokeNeverBlockedInsideWindow(uint256 elapsedSeed) public {
        _configure(50);
        uint256 b0 = vm.getBlockNumber();
        addLiquidity(TL, TU, 1e10, initSqrtP, false);
        uint48 stampBefore = simHook.lastAddedLiquidityBlock(poolId, _victimKey());
        assertEq(uint256(stampBefore), b0);

        uint256 elapsed = bound(elapsedSeed, 0, 49); // strictly inside the window
        vm.roll(b0 + elapsed);

        ModifyLiquidityParams memory poke =
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: 0, salt: bytes32(0)});

        // poke while locked — must not revert (JIT-2)
        modifyLiquidityRouter.modifyLiquidity(key, poke, ZERO_BYTES);
        assertEq(simHook.lastAddedLiquidityBlock(poolId, _victimKey()), stampBefore, "poke must not restamp (JIT-3)");

        // poke while locked AND paused — pause gates only the add path
        governance.setAddLiquidityPaused(true);
        modifyLiquidityRouter.modifyLiquidity(key, poke, ZERO_BYTES);
        governance.setAddLiquidityPaused(false);
        assertEq(
            simHook.lastAddedLiquidityBlock(poolId, _victimKey()), stampBefore, "paused poke must not restamp (JIT-3)"
        );

        // pokes neither cleared nor extended the lock
        (bool ok, bytes memory err) = _tryRemove(REMOVE_PROBE);
        assertFalse(ok, "lock must still enforce after pokes");
        (bool isJit, uint48 remaining) = _decodeJitLock(err);
        assertTrue(isJit);
        assertEq(uint256(remaining), 50 - elapsed, "pokes must not shift the unlock deadline");
    }

    /// @dev KI-18 / LeftClaw #2: the poke is not a loophole, and this pins why. A fee-only poke
    ///      inside the lock DOES pay out accrued fees — it is not a no-op — while the position's
    ///      PRINCIPAL stays locked for the full remaining window. That is the whole argument for
    ///      leaving `liquidityDelta == 0` ungated: the lock deters JIT deposits through inventory
    ///      risk on principal, and collecting fees early removes nothing from that risk. (Contrast
    ///      fee-withholding designs, where a poke escapes a penalty and must be gated.)
    function test_jit2_pokeSettlesFeesWhilePrincipalStaysLocked() public {
        _configure(50);
        uint256 b0 = vm.getBlockNumber();
        addLiquidity(TL, TU, 1e12, initSqrtP, false);

        // generate fees for the position to collect
        swap(true, -1e9, false);
        swap(false, -1e9, false);

        vm.roll(b0 + 10); // strictly inside the 50-block lock

        BalanceDelta pokeDelta = modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: 0, salt: bytes32(0)}), ZERO_BYTES
        );

        // the poke realizes value: fees accrued on both sides of the round trip above
        assertTrue(
            pokeDelta.amount0() > 0 || pokeDelta.amount1() > 0,
            "KI-18: a poke inside the lock must settle accrued fees, not no-op"
        );

        // and principal is still locked for the remainder of the window
        (bool ok, bytes memory err) = _tryRemove(REMOVE_PROBE);
        assertFalse(ok, "KI-18: principal must stay locked after the poke");
        (bool isJit, uint48 remaining) = _decodeJitLock(err);
        assertTrue(isJit, "KI-18: the removal must fail with JitLockActive");
        assertEq(uint256(remaining), 40, "KI-18: the poke must not shorten the lock");
    }

    // ------------------------------------------------------------------
    // JIT-14 — uint48(block.number) cast exact / elapsed math non-wrapping
    // ------------------------------------------------------------------

    /// @dev JIT-14 (bounded static assertion): for any stamp height B < 2^48, the stored
    ///      uint48 cast is the identity, and the lock decision at H = B + elapsed matches
    ///      wide-integer math — no truncation wrap can brick removal or unlock early. Exercised
    ///      up close to the uint48 horizon.
    /// forge-config: default.fuzz.runs = 128
    /// forge-config: dev.fuzz.runs = 128
    function testFuzz_jit14_uint48CastExactAtHighHeights(uint256 bSeed, uint256 eSeed) public {
        uint48 lockBlocks = MAX_JIT;
        _configure(lockBlocks);

        // stamp height anywhere in [1, 2^48 - 2*lock - 1] — keeps H < 2^48 (chain-height domain)
        uint256 b = bound(bSeed, 1, uint256(type(uint48).max) - 2 * uint256(lockBlocks) - 1);
        vm.roll(b);
        addLiquidity(TL, TU, 1e10, initSqrtP, false);

        uint48 stamp = simHook.lastAddedLiquidityBlock(poolId, _victimKey());
        assertEq(uint256(stamp), b, "uint48(block.number) must be the identity below 2^48 (JIT-14)");

        uint256 elapsed = bound(eSeed, 0, 2 * uint256(lockBlocks));
        vm.roll(b + elapsed);
        (bool ok, bytes memory err) = _tryRemove(REMOVE_PROBE);

        bool lockedWide = elapsed < uint256(lockBlocks); // wide-integer reference model
        assertEq(ok, !lockedWide, "lock decision must match wide-integer math (no wrap)");
        if (!ok) {
            (bool isJit, uint48 remaining) = _decodeJitLock(err);
            assertTrue(isJit);
            assertEq(uint256(remaining), uint256(lockBlocks) - elapsed, "remaining must match wide-integer math");
        }
    }
}
