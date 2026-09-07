// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BasePoolConfig} from "./BasePoolConfig.sol";

contract NativeEthPoolConfig is BasePoolConfig {
    constructor() {
        symbol0 = "ETH";
        symbol1 = "DAI";
        decimals0 = 18;
        decimals1 = 18;
        nativeEth = true;
        targetTick = 79500;
        tickSpacing = 1;
        minMinFee = 100;
        maxMinFee = 100;
        maxFee = 200000;
        timeDecayLength = 1 hours;
        jitLockBlocks = 50;
        kPips = 2_000_000; // 2.0x midpoint weight on increasing legs (fresh push pays its endpoint)
        cPips = 1_000_000; // 1.0x midpoint weight on decreasing legs
    }
}

contract ERC20PoolConfig is BasePoolConfig {
    constructor() {
        symbol0 = "EURC";
        symbol1 = "MORPHO";
        decimals0 = 6;
        decimals1 = 18;
        nativeEth = false;
        targetTick = 276716;
        tickSpacing = 10;
        minMinFee = 100;
        maxMinFee = 100;
        maxFee = 500000;
        timeDecayLength = 1 days;
        jitLockBlocks = 50;
        kPips = 2_000_000; // 2.0x midpoint weight on increasing legs (fresh push pays its endpoint)
        cPips = 1_000_000; // 1.0x midpoint weight on decreasing legs
    }
}

// ------ T2: same-low-decimal stable pair (USDC/USDT style) ------
// Target tick 0 places current price at 1 (after SortTokens reorder).
contract StablePairPoolConfig is BasePoolConfig {
    constructor() {
        symbol0 = "USDC";
        symbol1 = "USDT";
        decimals0 = 6;
        decimals1 = 6;
        nativeEth = false;
        targetTick = 0;
        tickSpacing = 1;
        minMinFee = 10;
        maxMinFee = 10;
        maxFee = 10_000;
        timeDecayLength = 1 hours;
        jitLockBlocks = 50;
        kPips = 2_000_000; // 2.0x midpoint weight on increasing legs (fresh push pays its endpoint)
        cPips = 1_000_000; // 1.0x midpoint weight on decreasing legs
    }
}

// ------ T3: high/low decimals (ETH/USDC style, token0=18, token1=6) ------
// Simplified targetTick = 0 (price = 1 raw/raw) for easier liquidity placement;
// the decimals-interaction is what we exercise, not any specific real-world price.
contract HighLowDecimalsPoolConfig is BasePoolConfig {
    constructor() {
        symbol0 = "WETH";
        symbol1 = "USDC";
        decimals0 = 18;
        decimals1 = 6;
        nativeEth = false;
        targetTick = 0;
        tickSpacing = 10;
        minMinFee = 100;
        maxMinFee = 100;
        maxFee = 200_000;
        timeDecayLength = 1 hours;
        jitLockBlocks = 50;
        kPips = 2_000_000; // 2.0x midpoint weight on increasing legs (fresh push pays its endpoint)
        cPips = 1_000_000; // 1.0x midpoint weight on decreasing legs
    }
}

// ------ T4: mid decimals asymmetric (WBTC/WETH style, token0=8, token1=18) ------
contract MidDecimalsPoolConfig is BasePoolConfig {
    constructor() {
        symbol0 = "WBTC";
        symbol1 = "WETH";
        decimals0 = 8;
        decimals1 = 18;
        nativeEth = false;
        targetTick = 0;
        tickSpacing = 10;
        minMinFee = 100;
        maxMinFee = 100;
        maxFee = 200_000;
        timeDecayLength = 1 hours;
        jitLockBlocks = 50;
        kPips = 2_000_000; // 2.0x midpoint weight on increasing legs (fresh push pays its endpoint)
        cPips = 1_000_000; // 1.0x midpoint weight on decreasing legs
    }
}
