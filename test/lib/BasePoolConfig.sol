// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

abstract contract BasePoolConfig {
    string public symbol0;
    string public symbol1;
    uint8 public decimals0;
    uint8 public decimals1;
    bool public nativeEth;
    int24 public targetTick;
    int24 public tickSpacing;
    uint24 public minMinFee;
    uint24 public maxMinFee;
    uint24 public maxFee;
    uint256 public timeDecayLength;
    uint48 public jitLockBlocks;
    uint32 public kPips;
    uint32 public cPips;
}
