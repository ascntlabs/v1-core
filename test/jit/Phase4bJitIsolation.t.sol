// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast as CoreSafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {TestUtils} from "../utils/TestUtils.sol";
import {SimHook} from "../../src/SimHook.sol";

/// @notice Phase 4b (JIT block-lock) — isolation of the lock across position keys (salt /
///         owner / pool dimensions), key-derivation parity between the hook and v4-core, and
///         single-unlock batching that tries to reset the lock clock mid-transaction.
///
///         Covers: JIT-10 (cross-position/cross-pool isolation), JIT-11 (hook key == core
///         key, no add-path-A/remove-path-B dodge), JIT-13 (only add>0 mutates the clock;
///         batched swap/poke/remove in one unlock cannot reset it).
///
///         Tick-range isolation for the same owner/salt is already covered by
///         test/feature/JitLock.t.sol::test_lockIsolatedPerPositionKey and is not repeated.
contract Phase4bJitIsolationTest is TestUtils {
    SimHook internal simHook;
    uint160 internal initSqrtP;

    PoolKey internal key2;
    PoolId internal poolId2;
    PoolModifyLiquidityTest internal router2;
    Phase4bJitBatcher internal batcher;

    uint48 internal constant LOCK = 50;
    int24 internal constant TL = -600;
    int24 internal constant TU = 600;
    int256 internal constant LIQ = 1e10;
    bytes32 internal constant SALT_A = bytes32(uint256(0xAA));
    bytes32 internal constant SALT_B = bytes32(uint256(0xBB));

    function setUp() public {
        address hookAddress = deployCoreAndHookCustomDecimals("SimHook.sol", "USDC", "USDT", 6, 6, false);
        simHook = SimHook(hookAddress);
        (, initSqrtP) = deployPool(IHooks(hookAddress), 0, 1, false);
        simHook.configurePool(poolId, 10, 10, 10_000, 3600, LOCK, 2e6, 1e6);

        // second pool: same currencies + hook, different tickSpacing => distinct poolId
        (key2, poolId2) = initPool(
            currency0, currency1, IHooks(hookAddress), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, TickMath.getSqrtPriceAtTick(0)
        );
        simHook.configurePool(poolId2, 10, 10, 10_000, 3600, LOCK, 2e6, 1e6);

        // an independent second router = a different position owner at the PoolManager level
        router2 = new PoolModifyLiquidityTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(router2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router2), type(uint256).max);

        // seed depth in pool1 (unrelated wide position, salt 0, distinct tick range)
        addLiquidity(-6000, 6000, 1e12, initSqrtP, false);

        batcher = new Phase4bJitBatcher(manager, simHook);
        MockERC20(Currency.unwrap(currency0)).transfer(address(batcher), 1e15);
        MockERC20(Currency.unwrap(currency1)).transfer(address(batcher), 1e15);
    }

    // ------ helpers ------

    function _modify(
        PoolModifyLiquidityTest r,
        PoolKey memory k,
        int256 delta,
        bytes32 salt
    ) internal returns (BalanceDelta) {
        return r.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: delta, salt: salt}), ZERO_BYTES
        );
    }

    function _keyOf(address owner, bytes32 salt) internal pure returns (bytes32) {
        return Position.calculatePositionKey(owner, TL, TU, salt);
    }

    /// @dev Exact wrapped JitLockActive expectation (see test/feature/JitLock.t.sol for the
    ///      CustomRevert.WrappedError shape v4-core bubbles hook reverts in).
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

    // ------------------------------------------------------------------
    // JIT-10 — cross-position isolation (salt / owner / pool dimensions)
    // ------------------------------------------------------------------

    /// @dev Same owner + same ticks, differing only in salt: B's fresh lock must not restamp
    ///      or re-lock A, and A's expired lock must not free B.
    function test_jit10_saltIsolation() public {
        uint256 b0 = vm.getBlockNumber();
        _modify(modifyLiquidityRouter, key, LIQ, SALT_A);
        bytes32 kA = _keyOf(address(modifyLiquidityRouter), SALT_A);
        bytes32 kB = _keyOf(address(modifyLiquidityRouter), SALT_B);
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, kA)), b0);

        vm.roll(b0 + LOCK); // A's window elapses
        uint256 b1 = vm.getBlockNumber();
        _modify(modifyLiquidityRouter, key, LIQ, SALT_B); // B freshly locked

        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, kA)), b0, "sibling-salt add must not restamp A");
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, kB)), b1);

        _modify(modifyLiquidityRouter, key, -LIQ, SALT_A); // A unlocked — must succeed

        _expectJitLockRevert(LOCK); // B locked, full window remaining
        _modify(modifyLiquidityRouter, key, -1, SALT_B);
    }

    /// @dev Same ticks + same salt, differing only in owner (two routers): each owner's lock
    ///      is independent.
    function test_jit10_ownerIsolation() public {
        uint256 b0 = vm.getBlockNumber();
        _modify(modifyLiquidityRouter, key, LIQ, bytes32(0));
        bytes32 k1 = _keyOf(address(modifyLiquidityRouter), bytes32(0));
        bytes32 k2 = _keyOf(address(router2), bytes32(0));

        vm.roll(b0 + LOCK); // router1's window elapses
        uint256 b1 = vm.getBlockNumber();
        _modify(router2, key, LIQ, bytes32(0)); // router2's key freshly locked

        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, k1)), b0, "other owner's add must not restamp k1");
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, k2)), b1);

        _modify(modifyLiquidityRouter, key, -LIQ, bytes32(0)); // router1 unlocked — must succeed

        _expectJitLockRevert(LOCK);
        _modify(router2, key, -1, bytes32(0));
    }

    /// @dev Cross-POOL isolation: an add of the byte-identical (owner, ticks, salt) tuple in
    ///      pool2 must not restamp or re-lock the same positionKey in pool1 (the mapping is
    ///      poolId-keyed).
    function test_jit10_crossPoolIsolation() public {
        uint256 b0 = vm.getBlockNumber();
        _modify(modifyLiquidityRouter, key, LIQ, bytes32(0)); // pool1, stamped b0
        bytes32 k = _keyOf(address(modifyLiquidityRouter), bytes32(0)); // same bytes in both pools

        vm.roll(b0 + LOCK); // pool1 position unlocked
        uint256 b1 = vm.getBlockNumber();
        _modify(modifyLiquidityRouter, key2, LIQ, bytes32(0)); // SAME tuple in pool2, stamped b1

        assertEq(
            uint256(simHook.lastAddedLiquidityBlock(poolId, k)), b0, "pool2 add must not restamp pool1's identical key"
        );
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId2, k)), b1);

        _modify(modifyLiquidityRouter, key, -LIQ, bytes32(0)); // pool1 unlocked — must succeed

        _expectJitLockRevert(LOCK); // pool2 locked, full window
        _modify(modifyLiquidityRouter, key2, -1, bytes32(0));
    }

    // ------------------------------------------------------------------
    // JIT-11 — hook lock key == v4-core position key (no path-mismatch dodge)
    // ------------------------------------------------------------------

    /// @dev The hook stamps exactly the (msg.sender-to-PoolManager, ticks, salt) tuple v4-core
    ///      indexes the position on. Removing "through the other path" (a different router =
    ///      different owner) finds no liquidity at all (CannotUpdateEmptyPosition), while the
    ///      only path that CAN remove is exactly the stamped, locked one — the lock cannot be
    ///      dodged by presenting a different key on the way out.
    function test_jit11_lockKeyMatchesCorePositionKey() public {
        _modify(modifyLiquidityRouter, key, LIQ, bytes32(0));
        bytes32 k1 = _keyOf(address(modifyLiquidityRouter), bytes32(0));
        bytes32 k2 = _keyOf(address(router2), bytes32(0));

        // core indexes the liquidity under the exact tuple the hook stamped
        (uint128 liq1,,) =
            StateLibrary.getPositionInfo(manager, poolId, address(modifyLiquidityRouter), TL, TU, bytes32(0));
        assertEq(uint256(liq1), uint256(LIQ), "core position lives under the stamped tuple");
        assertGt(simHook.lastAddedLiquidityBlock(poolId, k1), 0, "hook stamped the same tuple");

        // the alternate path holds nothing and was never stamped
        (uint128 liq2,,) = StateLibrary.getPositionInfo(manager, poolId, address(router2), TL, TU, bytes32(0));
        assertEq(uint256(liq2), 0, "no liquidity under the other path's key");
        assertEq(simHook.lastAddedLiquidityBlock(poolId, k2), 0, "other path's key never stamped");

        // remove via the other path: nothing to remove — core, not the hook, rejects it
        // (liquidity underflow on the empty position: SafeCastOverflow; the hook's
        // beforeRemoveLiquidity passed because router2's key was never stamped)
        vm.expectRevert(CoreSafeCast.SafeCastOverflow.selector);
        _modify(router2, key, -1, bytes32(0));

        // remove via the stamped path: exactly the locked key
        _expectJitLockRevert(LOCK);
        _modify(modifyLiquidityRouter, key, -1, bytes32(0));
    }

    // ------------------------------------------------------------------
    // JIT-13 — single-unlock batching cannot reset the lock clock
    // ------------------------------------------------------------------

    /// @dev Batches add -> swap -> poke(delta==0) -> remove in ONE unlock callback, ordered to
    ///      try to clear/reset the lock before the remove. Asserts: the stamp is written only
    ///      by the add and is untouched by the swap and the poke (JIT-13, JIT-3); the in-unlock
    ///      poke is not blocked (JIT-2); and the batched remove still reverts JitLockActive
    ///      with the FULL window (JIT-13) — same-transaction escape is impossible.
    function test_jit13_singleUnlockBatchCannotResetLock() public {
        uint256 b0 = vm.getBlockNumber();
        batcher.runAddSwapPokeRemove(key, poolId, LIQ, 1e6);

        bytes32 kB = Position.calculatePositionKey(address(batcher), batcher.BTL(), batcher.BTU(), batcher.BSALT());

        assertEq(uint256(batcher.stampAfterAdd()), b0, "in-unlock add stamps the current block");
        assertEq(uint256(batcher.stampAfterSwap()), b0, "in-unlock swap must not touch the stamp");
        assertEq(uint256(batcher.stampAfterPoke()), b0, "in-unlock poke must not touch the stamp");
        assertEq(uint256(simHook.lastAddedLiquidityBlock(poolId, kB)), b0, "stamp persists after the unlock closes");

        assertTrue(batcher.pokeSucceeded(), "in-unlock fee poke must not be lock-blocked (JIT-2)");
        assertFalse(batcher.removeSucceeded(), "in-unlock remove must not escape the lock");

        bytes memory expected = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(simHook),
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(SimHook.JitLockActive.selector, LOCK),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        assertEq(
            keccak256(batcher.removeRevertData()),
            keccak256(expected),
            "batched remove must revert JitLockActive with the full window"
        );

        // liveness: the batched position exits normally once the window elapses
        vm.roll(b0 + LOCK);
        batcher.runRemoveAll();
        (uint128 liqLeft,,) = StateLibrary.getPositionInfo(
            manager, poolId, address(batcher), batcher.BTL(), batcher.BTU(), batcher.BSALT()
        );
        assertEq(uint256(liqLeft), 0, "batcher position fully recoverable at the boundary");
    }
}

/// @dev Local Phase-4b helper (NOT shared scaffolding): an IUnlockCallback contract that
///      batches liquidity ops and swaps against the PoolManager inside a single unlock, so
///      the test can order actions add -> swap -> poke -> remove within one transaction.
///      The batcher itself is the position owner (msg.sender to the PoolManager).
contract Phase4bJitBatcher is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    SimHook internal immutable hook;

    int24 public constant BTL = -600;
    int24 public constant BTU = 600;
    bytes32 public constant BSALT = bytes32(uint256(0xBA7C4));

    enum Mode {
        AddSwapPokeRemove,
        RemoveAll
    }

    Mode internal mode;
    PoolKey internal k;
    PoolId internal pid;
    int256 internal liqAdded;
    uint256 internal swapAmount;

    // results readable by the test
    uint48 public stampAfterAdd;
    uint48 public stampAfterSwap;
    uint48 public stampAfterPoke;
    bool public pokeSucceeded;
    bool public removeSucceeded;
    bytes public removeRevertData;

    constructor(IPoolManager _manager, SimHook _hook) {
        manager = _manager;
        hook = _hook;
    }

    function runAddSwapPokeRemove(PoolKey calldata _key, PoolId _pid, int256 liq, uint256 swapAmt) external {
        k = _key;
        pid = _pid;
        liqAdded = liq;
        swapAmount = swapAmt;
        mode = Mode.AddSwapPokeRemove;
        manager.unlock("");
    }

    function runRemoveAll() external {
        mode = Mode.RemoveAll;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        bytes32 posKey = Position.calculatePositionKey(address(this), BTL, BTU, BSALT);

        if (mode == Mode.AddSwapPokeRemove) {
            // 1. add — the only action allowed to write the clock
            manager.modifyLiquidity(
                k, ModifyLiquidityParams({tickLower: BTL, tickUpper: BTU, liquidityDelta: liqAdded, salt: BSALT}), ""
            );
            stampAfterAdd = hook.lastAddedLiquidityBlock(pid, posKey);

            // 2. swap — must not touch the clock
            manager.swap(
                k,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(swapAmount),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            stampAfterSwap = hook.lastAddedLiquidityBlock(pid, posKey);

            // 3. fee-only poke — must succeed and must not touch the clock
            try manager.modifyLiquidity(
                k, ModifyLiquidityParams({tickLower: BTL, tickUpper: BTU, liquidityDelta: 0, salt: BSALT}), ""
            ) returns (
                BalanceDelta, BalanceDelta
            ) {
                pokeSucceeded = true;
            } catch {
                pokeSucceeded = false;
            }
            stampAfterPoke = hook.lastAddedLiquidityBlock(pid, posKey);

            // 4. remove — must revert JitLockActive despite the interleaving above
            try manager.modifyLiquidity(
                k, ModifyLiquidityParams({tickLower: BTL, tickUpper: BTU, liquidityDelta: -liqAdded, salt: BSALT}), ""
            ) returns (
                BalanceDelta, BalanceDelta
            ) {
                removeSucceeded = true;
            } catch (bytes memory err) {
                removeRevertData = err;
            }
        } else {
            manager.modifyLiquidity(
                k, ModifyLiquidityParams({tickLower: BTL, tickUpper: BTU, liquidityDelta: -liqAdded, salt: BSALT}), ""
            );
        }

        _close(k.currency0);
        _close(k.currency1);
        return "";
    }

    function _close(Currency c) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d < 0) {
            c.settle(manager, address(this), uint256(-d), false);
        } else if (d > 0) {
            c.take(manager, address(this), uint256(d), false);
        }
    }
}
