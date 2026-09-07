// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";
import {SimHookHandler} from "./handlers/SimHookHandler.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Phase-0 invariant scaffolding. Stands up a configured SimHook pool with protocol fees
///         on, seeds liquidity, and wires a funded handler as the fuzz target. The single smoke
///         invariant proves the harness actually drives the pool; the real accumulator / solvency
///         / isolation invariants (Phase 4) extend this same base.
contract SimHookInvariantTest is SimHookUtils {
    SimHookHandler internal handler;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    // config snapshot for the immutability smoke invariant
    uint24 internal cfgMaxFee;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);

        // seed depth so swaps mostly succeed
        addLiquidity(TICK_LOWER, TICK_UPPER, 1e12, initSqrtP, false);

        // turn the protocol-fee settlement path on
        governance.setTreasury(address(0xBEEF));
        governance.setProtocolFeeBps(1000); // 10%

        handler = new SimHookHandler(manager, swapRouter, modifyLiquidityRouter, key, poolId, TICK_LOWER, TICK_UPPER);
        vm.deal(address(handler), 10 ether);

        // fund the handler with both tokens so it can swap either direction
        MockERC20(Currency.unwrap(key.currency0)).transfer(address(handler), 1e24);
        MockERC20(Currency.unwrap(key.currency1)).transfer(address(handler), 1e24);

        // restrict the fuzzer to the handler's action selectors
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = SimHookHandler.swap.selector;
        selectors[1] = SimHookHandler.advanceTime.selector;
        selectors[2] = SimHookHandler.addLiquidity.selector;
        selectors[3] = SimHookHandler.removeLiquidity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        (,,, cfgMaxFee,,,,) = hook.poolConfig(poolId);
    }

    /// @notice Smoke invariant: the one-time pool config never changes and the pool stays
    ///         configured across any action sequence (a real slice of LIFE-1). Its purpose in
    ///         Phase 0 is to confirm the whole handler pipeline runs and holds an obvious truth.
    /// forge-config: default.invariant.runs = 4
    /// forge-config: default.invariant.depth = 20
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_poolConfigImmutable() public view {
        (bool configured,,, uint24 maxFee,,,,) = hook.poolConfig(poolId);
        assertTrue(configured, "pool must remain configured");
        assertEq(maxFee, cfgMaxFee, "maxFee must be immutable");
    }

    /// @notice Confirms the fuzzer actually exercised the pool (not a no-op run) so the smoke
    ///         invariant above is meaningful. Runs once after the whole sequence.
    function afterInvariant() public view {
        assertGt(handler.swapCount() + handler.addCount() + handler.removeCount(), 0, "handler made no progress");
    }
}
