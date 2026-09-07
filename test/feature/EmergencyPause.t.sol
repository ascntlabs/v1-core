// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SimHookFeatureBase} from "./base/SimHookFeatureBase.sol";

/// @dev Verifies the emergency add-liquidity pause flag (now on `AscntGovernance`):
///      - pause blocks add, but does NOT block remove or swap
///      - unpause restores add
///      - owner OR pauser can toggle the flag
///      - only timelock can rotate the pauser slot
///      - event emits on every transition
///      Pause logic on the hook side lives in `AscntBaseHook._beforeAddLiquidity`, which reads
///      `governance.addLiquidityPaused()`.
contract EmergencyPauseTest is SimHookFeatureBase {
    address constant ALICE = address(0xA11CE);

    function setUp() public {
        _deployConfigurePool();

        addLiquidity(76080, 90000, 1 ether, initialSqrtPriceX96, false);
    }

    // ------ pause blocks adds ------

    function test_pausedBlocksAdd() public {
        governance.setAddLiquidityPaused(true);
        assertTrue(governance.addLiquidityPaused());

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: 78000, tickUpper: 81000, liquidityDelta: int256(1e18), salt: bytes32(0)});

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(key, params, ZERO_BYTES);
    }

    function test_unpausedAllowsAdd() public {
        governance.setAddLiquidityPaused(true);
        governance.setAddLiquidityPaused(false);
        assertFalse(governance.addLiquidityPaused());

        addLiquidity(78000, 81000, 0.1 ether, initialSqrtPriceX96, false);
    }

    // ------ pause does not block exits ------

    function test_pausedDoesNotBlockRemove() public {
        addLiquidity(78000, 81000, 0.1 ether, initialSqrtPriceX96, false);
        vm.roll(block.number + 51);

        governance.setAddLiquidityPaused(true);

        removeLiquidity(78000, 81000, 1);
    }

    function test_pausedDoesNotBlockSwap() public {
        governance.setAddLiquidityPaused(true);

        swap(true, -0.05 ether, false);
        swap(false, -100e18, false);
    }

    // Direct governance-setter unit tests (pauser can pause/unpause, revertsIfNotPauserOrOwner,
    // revertsAfterPauserCleared, setPauser_revertsForNonOwner, event emission) live in
    // `test/governance/AscntGovernance.t.sol` — this suite only covers paths with the hook in the loop.
}

