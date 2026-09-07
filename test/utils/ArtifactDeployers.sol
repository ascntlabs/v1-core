// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapRouterNoChecks} from "@uniswap/v4-core/src/test/SwapRouterNoChecks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolTakeTest} from "@uniswap/v4-core/src/test/PoolTakeTest.sol";
import {PoolClaimsTest} from "@uniswap/v4-core/src/test/PoolClaimsTest.sol";
import {PoolNestedActionsTest} from "@uniswap/v4-core/src/test/PoolNestedActionsTest.sol";
import {ActionsRouter} from "@uniswap/v4-core/src/test/ActionsRouter.sol";

/// @dev v4-core's Deployers with the manager and routers deployed from compiled artifacts
///      (`deployCode`) instead of `new`. `new X()` inlines X's creation code into every test
///      contract and via-IR re-optimises it per contract; loading the artifact deploys the same
///      bytecode without that compile cost. Same deployments, order and constructor arguments
///      as the originals, so nonce-derived addresses do not move.
abstract contract ArtifactDeployers is Deployers {
    string internal constant V4_CORE = "lib/uniswap-hooks/lib/v4-core/src/";

    function deployFreshManager() internal virtual override {
        manager =
            IPoolManager(deployCode(string.concat(V4_CORE, "PoolManager.sol:PoolManager"), abi.encode(address(this))));
    }

    /// @dev Mirrors Deployers.deployFreshManagerAndRouters, which is not virtual.
    function deployArtifactManagerAndRouters() internal {
        deployFreshManager();
        swapRouter = PoolSwapTest(_router("PoolSwapTest"));
        swapRouterNoChecks = SwapRouterNoChecks(_router("SwapRouterNoChecks"));
        modifyLiquidityRouter = PoolModifyLiquidityTest(_router("PoolModifyLiquidityTest"));
        modifyLiquidityNoChecks = PoolModifyLiquidityTestNoChecks(_router("PoolModifyLiquidityTestNoChecks"));
        donateRouter = PoolDonateTest(_router("PoolDonateTest"));
        takeRouter = PoolTakeTest(_router("PoolTakeTest"));
        claimsRouter = PoolClaimsTest(_router("PoolClaimsTest"));
        nestedActionRouter = PoolNestedActionsTest(_router("PoolNestedActionsTest"));
        feeController = makeAddr("feeController");
        actionsRouter = ActionsRouter(_router("ActionsRouter"));

        manager.setProtocolFeeController(feeController);
    }

    function _router(string memory name) private returns (address) {
        return deployCode(string.concat(V4_CORE, "test/", name, ".sol:", name), abi.encode(manager));
    }
}
