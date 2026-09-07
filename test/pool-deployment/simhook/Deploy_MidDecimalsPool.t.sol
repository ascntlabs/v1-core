// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolDeploymentBaseSim} from "../PoolDeploymentBaseSim.sol";
import {BasePoolConfig} from "../../lib/BasePoolConfig.sol";
import {MidDecimalsPoolConfig} from "../../lib/PoolConfigs.sol";

/// @notice Pre-deployment validation for SimHook on a mid-decimals asymmetric pair
/// (WBTC 8 / WETH 18 at parity tick 0).
contract Deploy_SimHook_MidDecimalsPool is PoolDeploymentBaseSim {
    function _poolConfig() internal override returns (BasePoolConfig) {
        return new MidDecimalsPoolConfig();
    }

    function _setupLiquidity(uint160 sqrtPriceX96) internal override {
        addLiquidity(-500, 500, 10_000e8, sqrtPriceX96, false);
        addLiquidity(-5000, 5000, 100_000e8, sqrtPriceX96, false);
    }

    /// @dev token0 = WBTC (8 dec), token1 = WETH (18 dec) at parity. At parity 1
    /// sat consumes 1 wei. WETH side is bounded by ~1e13 wei in the pool reserves.
    function _smokeZeroForOneAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        small = -1e4;
        medium = -1e6;
        large = -1e8;
    }

    function _smokeOneForZeroAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        small = -1e10;
        medium = -1e11;
        large = -1e12;
    }

    function _jitLockTicks() internal pure override returns (int24, int24) {
        return (-500, 500);
    }
}
