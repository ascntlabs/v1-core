// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @dev Test-only ABI shim over the slice of `SimHook`'s public surface the parameterised
///      feature suites actually call. `configurePool` / `poolConfig` are handled in
///      per-suite `_configurePool` helpers, not here.
interface IAscntFeeHook is IHooks {
    function protocolFeeBps() external view returns (uint16);
    function lastAddedLiquidityBlock(PoolId, bytes32) external view returns (uint48);
    function MAX_JIT_LOCK_BLOCKS() external view returns (uint48);
    function MAX_K_PIPS() external view returns (uint32);
    function MAX_C_PIPS() external view returns (uint32);
}
