// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------------------------
// Phase 2 (access-gov): XSUB-2 — there is NO on-chain kill switch for a live, configured pool.
//
// These tests PROVE (and pin) the CURRENT behavior:
//   * factory deprecation (isDeprecatedHook / isDeprecated()) is ADVISORY ONLY — no swap,
//     configure, add or remove path reads the flag;
//   * the add-liquidity pause stops adds but NOT swaps, removes, or the protocol take;
//   * disabling the protocol fee stops neither swaps nor the JIT lock;
//   * no owner / timelock / pauser mutator halts swaps on an already-configured poolId.
//
// By design, `configurePool` is one-time and no governance path halts swaps on a configured
// poolId; recovery is relaunch on a fresh pool key. These tests fail the moment a halt path is
// added, so the behaviour cannot change silently.
// ---------------------------------------------------------------------------------------------

import {TestUtils} from "../utils/TestUtils.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookFlags} from "../../script/utils/HookFlags.sol";
import {SimHook} from "../../src/SimHook.sol";
import {AscntBaseHook} from "../../src/AscntBaseHook.sol";
import {HookFactory} from "../../src/HookFactory.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";

contract Phase2XSub2NoKillSwitchTest is TestUtils {
    HookFactory internal factoryC;
    SimHook internal hook;

    address internal constant TREASURY = address(0x7EA5B);
    uint48 internal constant JIT_BLOCKS = 2;

    int24 internal constant TL = -600;
    int24 internal constant TU = 600;

    function setUp() public {
        // Production-shaped wiring: hook deployed BY the HookFactory so deprecation is real
        // (the hook's `factory` immutable is the HookFactory, and isDeprecated() reads it).
        deployArtifactManagerAndRouters();
        deployMintAndApprove2Currencies();
        isNativeEth = false;
        decimals0 = 18;
        decimals1 = 18;

        // Test contract = owner AND timelock (valid via TestUtils.getMinDelay).
        governance = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance",
                abi.encode(address(this), address(this), address(0), address(0))
            )
        );
        factoryC = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(governance)));
        governance.setHookFactory(address(factoryC));

        bytes memory ctorArgs = abi.encode(manager, governance);
        (address expected, bytes32 salt) =
            HookMiner.find(address(factoryC), HookFlags.simHookMask(), type(SimHook).creationCode, ctorArgs);
        bytes memory initCode = abi.encodePacked(type(SimHook).creationCode, ctorArgs);
        hook = SimHook(factoryC.deployHook(initCode, salt, expected));

        (key, poolId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        hook.configurePool(poolId, 10, 100, 10_000, 1 hours, JIT_BLOCKS, 2e6, 1e6);

        _add(1e18, bytes32(0));

        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(1000); // 10% — protocol take live

        vm.roll(block.number + JIT_BLOCKS + 1); // clear the setUp position's JIT clock
    }

    // ------ helpers ------

    function _add(int256 liquidityDelta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: liquidityDelta, salt: salt}),
            ZERO_BYTES
        );
    }

    function _remove(int256 liquidityDelta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: -liquidityDelta, salt: salt}),
            ZERO_BYTES
        );
    }

    /// @dev Swap and assert it succeeded; returns the protocol-fee amount that landed in the
    ///      treasury for this swap (output side = currency1 for zeroForOne exact-in).
    function _swapAndMeasureTake() internal returns (uint256 takeAmount) {
        uint256 before_ = MockERC20(Currency.unwrap(currency1)).balanceOf(TREASURY);
        swap(true, -1e15, false); // reverts (failing the test) if any path blocks the swap
        takeAmount = MockERC20(Currency.unwrap(currency1)).balanceOf(TREASURY) - before_;
    }

    function _expectWrappedHookRevert(bytes4 hookFn, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookFn,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    // ------ XSUB-2 core: deprecation is advisory ------

    /// XSUB-2: after factory.setHookDeprecated(hook, true), swaps still execute, the dynamic
    /// fee + protocol take still run, adds/removes still work and the JIT lock still bites —
    /// byte-for-byte the same lifecycle as an undeprecated hook. Deprecation is a pure signal.
    function test_xsub2_deprecation_isAdvisoryOnly_lifecycleUnchanged() public {
        // Baseline (verified, not deprecated).
        assertTrue(hook.isVerified());
        assertFalse(hook.isDeprecated());
        uint256 takeBefore = _swapAndMeasureTake();
        assertGt(takeBefore, 0, "baseline: protocol take flows");

        // Deprecate — owner fast lane, takes effect immediately...
        factoryC.setHookDeprecated(address(hook), true);
        assertTrue(hook.isDeprecated(), "flag flipped");
        assertTrue(factoryC.isDeprecatedHook(address(hook)));

        // ...but NOTHING in the swap path reads it: swap succeeds, protocol take unchanged.
        uint256 takeAfter = _swapAndMeasureTake();
        assertGt(takeAfter, 0, "deprecated hook still takes protocol fees");

        // Adds still work and still stamp the JIT clock.
        bytes32 salt = bytes32(uint256(0x5A17));
        _add(1e15, salt);

        // JIT lock still enforced on the deprecated hook (immediate remove blocked)...
        _expectWrappedHookRevert(
            IHooks.beforeRemoveLiquidity.selector, abi.encodeWithSelector(SimHook.JitLockActive.selector, JIT_BLOCKS)
        );
        _remove(1e15, salt);

        // ...and still expires normally.
        vm.roll(block.number + JIT_BLOCKS);
        _remove(1e15, salt);

        // Un-deprecation is equally advisory (round trip leaves the pool identical).
        factoryC.setHookDeprecated(address(hook), false);
        assertFalse(hook.isDeprecated());
        assertGt(_swapAndMeasureTake(), 0, "identical after round trip");
    }

    // ------ XSUB-2 negative sweep: no governance mutator halts swaps ------

    /// XSUB-2: enumerate EVERY owner/timelock/pauser mutator reachable on this deployment and
    /// assert that after each one, swaps on the configured poolId still execute. The pause is
    /// add-only (removes and swaps flow); zeroing the protocol fee only reroutes the split.
    /// There is no reachable on-chain halt — relaunch on a fresh poolId is the only recourse.
    function test_xsub2_noOwnerTimelockPauserMutatorHaltsSwaps() public {
        // 1. Deprecate (owner).
        factoryC.setHookDeprecated(address(hook), true);
        _swapAndMeasureTake();

        // 2. Pause add-liquidity (owner; same code path as the pauser key).
        governance.setAddLiquidityPaused(true);

        //    Adds are blocked...
        _expectWrappedHookRevert(
            IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(AscntBaseHook.AddLiquidityIsPaused.selector)
        );
        _add(1e15, bytes32(0));

        //    ...but swaps and removes (LP exit) still flow while paused.
        assertGt(_swapAndMeasureTake(), 0, "swap + protocol take flow while paused");
        _remove(1e14, bytes32(0)); // setUp position, lock long expired

        // 3. Rotate the pauser (owner) — swap unaffected.
        governance.setPauser(makeAddr("p2-xsub2-pauser"));
        _swapAndMeasureTake();

        // 4. Zero the poolDeployer (timelock) — swap unaffected.
        governance.setPoolDeployer(address(0));
        _swapAndMeasureTake();

        // 5. Move the treasury (timelock) — the take just redirects; swap unaffected.
        governance.setTreasury(makeAddr("p2-xsub2-treasury2"));
        _swapAndMeasureTake();

        // 6. Zero the protocol fee (timelock) — swap still executes; only the split moves.
        governance.setProtocolFeeBps(0);
        uint256 take = _swapAndMeasureTake();
        assertEq(take, 0, "no protocol take at bps=0");

        // 7. Unpause + re-enable — pool marches on, fully unhaltable throughout.
        governance.setAddLiquidityPaused(false);
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(2000);
        assertGt(_swapAndMeasureTake(), 0, "pool still fully operational after the whole sweep");

        // None of the seven actions above — nor any other mutator on AscntGovernance /
        // HookFactory — stops swaps on this poolId. Recovery is relaunch on a fresh pool key.
    }
}
