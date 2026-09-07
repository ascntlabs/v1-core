// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolDeploymentBaseSim} from "../PoolDeploymentBaseSim.sol";
import {BasePoolConfig} from "../../lib/BasePoolConfig.sol";
import {ERC20PoolConfig} from "../../lib/PoolConfigs.sol";

/// @notice Pre-deployment validation for SimHook on the EURC/MORPHO pool
/// (6/18 decimals, volatile pair, 1-day decay window).
contract Deploy_SimHook_ERC20Pool is PoolDeploymentBaseSim {
    function _poolConfig() internal override returns (BasePoolConfig) {
        return new ERC20PoolConfig();
    }

    function _setupLiquidity(uint160 sqrtPriceX96) internal override {
        // ERC20 pair: narrow in-range band + wide band.
        addLiquidity(275270, 278150, 10_000e6, sqrtPriceX96, false);
        addLiquidity(75_000, 400_000, 1_000_000e6, sqrtPriceX96, false);
    }

    /// @dev token0 = EURC (6 dec), token1 = MORPHO (18 dec). Pool at tick 276716,
    ///      so token1 has very different real-world scale than token0.
    function _smokeZeroForOneAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        small = -0.1e6; // 0.1 EURC
        medium = -100e6; // 100 EURC
        large = -5_000e6; // 5k EURC (50% of narrow-range depth)
    }

    function _smokeOneForZeroAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        small = -0.1e18; // 0.1 MORPHO
        medium = -100e18; // 100 MORPHO
        large = -5_000e18; // 5k MORPHO
    }

    function _jitLockTicks() internal pure override returns (int24, int24) {
        return (275270, 278150); // narrow position added in _setupLiquidity
    }
}
