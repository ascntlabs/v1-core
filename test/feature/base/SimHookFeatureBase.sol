// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {TestUtils} from "../../utils/TestUtils.sol";
import {IAscntFeeHook} from "../../utils/IAscntFeeHook.sol";
import {NativeEthPoolConfig} from "../../lib/PoolConfigs.sol";
import {SimHook} from "../../../src/SimHook.sol";

/// @notice Shared scaffolding for the SimHook feature suites (ProtocolFee, JitLock, EmergencyPause).
///         Deploys a SimHook on a fresh native-ETH pool and writes its one-time config; each suite
///         seeds its own liquidity in `setUp` afterward. Replaces the per-suite abstract
///         `_hookName`/`_configurePool` indirection — only a single SimHook variant exists.
abstract contract SimHookFeatureBase is TestUtils {
    NativeEthPoolConfig internal nativeEthPoolConfig;
    IAscntFeeHook internal hook;
    uint160 internal initialSqrtPriceX96;

    /// @dev Deploy SimHook on a fresh NativeEth pool and write its config. Sets
    ///      `nativeEthPoolConfig`, `hook`, and `initialSqrtPriceX96`. Callers seed liquidity.
    function _deployConfigurePool() internal {
        nativeEthPoolConfig = new NativeEthPoolConfig();
        address hookAddress = deployCoreAndHookCustomDecimals(
            "SimHook.sol",
            nativeEthPoolConfig.symbol0(),
            nativeEthPoolConfig.symbol1(),
            nativeEthPoolConfig.decimals0(),
            nativeEthPoolConfig.decimals1(),
            nativeEthPoolConfig.nativeEth()
        );
        hook = IAscntFeeHook(hookAddress);

        (, initialSqrtPriceX96) =
            deployPool(IHooks(hookAddress), nativeEthPoolConfig.targetTick(), nativeEthPoolConfig.tickSpacing(), false);

        _configurePool(
            hookAddress,
            nativeEthPoolConfig.minMinFee(),
            nativeEthPoolConfig.maxFee(),
            nativeEthPoolConfig.timeDecayLength(),
            nativeEthPoolConfig.jitLockBlocks(),
            nativeEthPoolConfig.kPips(),
            nativeEthPoolConfig.cPips()
        );
    }

    /// @dev One-time configure for a SimHook pool. Collapses the min-fee ramp to a degenerate
    ///      floor (minMinFee == maxMinFee == minF), matching the feature suites' setup. Reusable
    ///      for additional pools within a suite (e.g. JitLock's second pool).
    function _configurePool(
        address hookAddr,
        uint24 minF,
        uint24 maxF,
        uint256 decay,
        uint48 jit,
        uint32 k,
        uint32 c
    ) internal {
        SimHook(hookAddr).configurePool(poolId, minF, minF, maxF, decay, jit, k, c);
    }
}
