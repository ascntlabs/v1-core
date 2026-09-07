// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {TestUtils} from "../utils/TestUtils.sol";
import {SimHook} from "../../src/SimHook.sol";
import {Phase4bJitHandler} from "./handlers/Phase4bJitHandler.sol";

/// @notice Phase 4b (JIT block-lock) — stateful invariant campaign. A handler drives a
///         victim position through arbitrary sequences of adds / third-party adds / pokes /
///         swaps / block rolls / pause toggles / removal attempts, checking lock semantics
///         in-line against a ghost model (see Phase4bJitHandler for the per-check ID map).
///
///         Covers (stateful): JIT-7 (no permanent lock — removal always permitted from
///         B+lockBlocks on), JIT-9 (deadline only ever moves forward, gated by the most
///         recent add), JIT-2/JIT-3 (pokes never blocked / never restamp under any
///         interleaving), JIT-10 (third-party adds never touch the victim), JIT-13 (only
///         add>0 ever writes the clock — asserted via ghost-stamp equality after every
///         action), and XSUB-7 (pause x lock composition: paused adds don't re-arm, and the
///         afterInvariant probe forces the pause ON at the deadline and requires full exit).
contract Phase4bJitInvariantTest is TestUtils {
    SimHook internal simHook;
    Phase4bJitHandler internal handler;
    uint160 internal initSqrtP;

    uint48 internal constant LOCK = 50;

    function setUp() public {
        address hookAddress = deployCoreAndHookCustomDecimals("SimHook.sol", "USDC", "USDT", 6, 6, false);
        simHook = SimHook(hookAddress);
        (, initSqrtP) = deployPool(IHooks(hookAddress), 0, 1, false);
        simHook.configurePool(poolId, 10, 10, 10_000, 3600, LOCK, 2e6, 1e6);

        // seed depth so swaps mostly succeed (unrelated wide position, salt 0)
        addLiquidity(-6000, 6000, 1e12, initSqrtP, false);

        handler =
            new Phase4bJitHandler(manager, swapRouter, modifyLiquidityRouter, simHook, governance, key, poolId, LOCK);

        // fund the handler with both tokens
        MockERC20(Currency.unwrap(key.currency0)).transfer(address(handler), 1e24);
        MockERC20(Currency.unwrap(key.currency1)).transfer(address(handler), 1e24);

        // the handler doubles as the pauser so sequences can flip the pause mid-flight
        governance.setPauser(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = Phase4bJitHandler.addVictim.selector;
        selectors[1] = Phase4bJitHandler.addOther.selector;
        selectors[2] = Phase4bJitHandler.pokeVictim.selector;
        selectors[3] = Phase4bJitHandler.swapSome.selector;
        selectors[4] = Phase4bJitHandler.advanceBlocks.selector;
        selectors[5] = Phase4bJitHandler.togglePause.selector;
        selectors[6] = Phase4bJitHandler.tryRemoveVictim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice No in-line lock-semantics violation was recorded (JIT-7/9/2/3/10/13, XSUB-7 —
    ///         see the handler), and the on-chain stamp always equals the ghost stamp: only a
    ///         successful add>0 to the victim key ever wrote the clock (JIT-13 / JIT-3).
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 45
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 24
    /// forge-config: dev.invariant.depth = 45
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 3000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_jit_lockSemanticsHold() public view {
        assertEq(handler.violations(), 0, handler.firstViolation());
        assertEq(
            uint256(simHook.lastAddedLiquidityBlock(poolId, handler.victimKey())),
            handler.ghostStamp(),
            "stamp diverged from ghost: something other than add>0 wrote the lock clock"
        );
    }

    /// @notice Post-sequence checks: (1) the campaign made progress (not vacuous); (2) joint
    ///         liveness probe — force the pause ON, jump to the victim's unlock deadline, and
    ///         require the ENTIRE remaining position to exit (JIT-7 + XSUB-7: no reachable
    ///         state, pause included, leaves LP funds trapped past stamp + jitLockBlocks).
    function afterInvariant() public {
        assertGt(handler.totalCalls(), 0, "handler made no calls");

        governance.setAddLiquidityPaused(true);
        uint256 deadline = handler.ghostStamp() + LOCK;
        if (vm.getBlockNumber() < deadline) vm.roll(deadline);
        assertTrue(
            handler.forceRemoveAllVictim(),
            "victim position not fully recoverable at its deadline with the pause active"
        );
        assertEq(handler.violations(), 0, handler.firstViolation());
    }
}
