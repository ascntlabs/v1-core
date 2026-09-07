// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolDeploymentBaseSim} from "../PoolDeploymentBaseSim.sol";
import {BasePoolConfig} from "../../lib/BasePoolConfig.sol";
import {StablePairPoolConfig} from "../../lib/PoolConfigs.sol";

/// @notice Pre-deployment validation for SimHook on a USDC/USDT-style stable pair
/// (6/6 decimals, parity tick 0, deep concentrated band).
contract Deploy_SimHook_StablePool is PoolDeploymentBaseSim {
    function _poolConfig() internal override returns (BasePoolConfig) {
        return new StablePairPoolConfig();
    }

    function _setupLiquidity(uint160 sqrtPriceX96) internal override {
        // Deep concentrated band around parity + shallow wide tail.
        addLiquidity(-5, 5, 1_000_000e6, sqrtPriceX96, false);
        addLiquidity(-5000, 5000, 1_000e6, sqrtPriceX96, false);
    }

    function _smokeZeroForOneAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        small = -1e6;
        medium = -1_000e6;
        large = -100_000e6;
    }

    function _smokeOneForZeroAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        small = -1e6;
        medium = -1_000e6;
        large = -100_000e6;
    }

    function _jitLockTicks() internal pure override returns (int24, int24) {
        return (-5, 5);
    }
}
