// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolDeploymentBaseSim} from "../PoolDeploymentBaseSim.sol";
import {BasePoolConfig} from "../../lib/BasePoolConfig.sol";
import {HighLowDecimalsPoolConfig} from "../../lib/PoolConfigs.sol";

/// @notice Pre-deployment validation for SimHook on a high/low-decimal asymmetric
/// pair (WETH 18 / USDC 6 at parity tick 0). Verifies that decimals math and fee
/// bounds behave on a pool where token0_raw and token1_raw have very different magnitudes.
contract Deploy_SimHook_HighLowDecimalsPool is PoolDeploymentBaseSim {
    function _poolConfig() internal override returns (BasePoolConfig) {
        return new HighLowDecimalsPoolConfig();
    }

    function _setupLiquidity(uint160 sqrtPriceX96) internal override {
        addLiquidity(-500, 500, 1_000_000e6, sqrtPriceX96, false);
        addLiquidity(-5000, 5000, 10_000_000e6, sqrtPriceX96, false);
    }

    /// @dev token0 = WETH (18 dec) but the pool is at parity (price 1 raw/raw).
    /// At parity 1 wei WETH consumes 1 raw USDC, so zeroForOne amounts in wei
    /// must stay well below the pool's USDC reserves (~1.1e13 raw).
    function _smokeZeroForOneAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        small = -1e6; // ~1 USDC equivalent drained
        medium = -1e9; // ~1k USDC equivalent drained
        large = -1e11; // ~100k USDC equivalent drained (1% of pool)
    }

    function _smokeOneForZeroAmounts() internal pure override returns (int256 small, int256 medium, int256 large) {
        small = -1e6; // 1 USDC
        medium = -1_000e6; // 1k USDC
        large = -100_000e6; // 100k USDC
    }

    function _jitLockTicks() internal pure override returns (int24, int24) {
        return (-500, 500);
    }
}
