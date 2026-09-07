// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolDeploymentBaseSim} from "../PoolDeploymentBaseSim.sol";
import {BasePoolConfig} from "../../lib/BasePoolConfig.sol";
import {NativeEthPoolConfig} from "../../lib/PoolConfigs.sol";

/// @notice Pre-deployment validation for SimHook on the ETH/DAI native-ETH pool
/// (18/18 decimals, 1-hour decay window).
contract Deploy_SimHook_NativeEthPool is PoolDeploymentBaseSim {
    function _poolConfig() internal override returns (BasePoolConfig) {
        return new NativeEthPoolConfig();
    }

    function _setupLiquidity(uint160 sqrtPriceX96) internal override {
        // Native-ETH pair: one in-range band + one wide band.
        addLiquidity(76080, 90000, 10 ether, sqrtPriceX96, false);
        addLiquidity(-80000, 887000, 0.2 ether, sqrtPriceX96, false);
    }

    function _smokeZeroForOneAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        // Sell ETH → DAI: 0.01 / 0.5 / 2 ETH.
        small = -0.01 ether;
        medium = -0.5 ether;
        large = -2 ether;
    }

    function _smokeOneForZeroAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        // Sell DAI → ETH. Pool initial price ~2820 DAI/ETH, so DAI amounts much
        // larger than the ETH amounts above.
        small = -25e18; // 25 DAI ≈ 0.01 ETH
        medium = -1_400e18; // 1.4k DAI ≈ 0.5 ETH
        large = -5_500e18; // 5.5k DAI ≈ 2 ETH
    }

    function _jitLockTicks() internal pure override returns (int24, int24) {
        return (76080, 90000); // narrow position added in _setupLiquidity
    }
}
