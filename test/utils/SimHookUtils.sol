// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestUtils} from "./TestUtils.sol";
import {SimHook} from "../../src/SimHook.sol";
import {BasePoolConfig} from "../lib/BasePoolConfig.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract SimHookUtils is TestUtils {
    struct BeforeSwapEventData {
        bytes32 poolId;
        uint160 sqrtPriceX96Before;
        uint160 sqrtPriceX96AfterSim;
        uint256 priceImpact;
        int256 decayedCumPriceImpact;
        uint24 effectiveMinFee;
        uint24 dynamicFeePips;
    }

    struct AfterSwapEventData {
        bytes32 poolId;
        uint160 sqrtPriceX96;
        uint256 priceImpact;
        int256 cumPriceImpact;
    }

    struct PoolConfiguredEventData {
        bytes32 poolId;
        bool configured;
        uint24 minMinFee;
        uint24 maxMinFee;
        uint24 maxFee;
        uint256 timeDecayLength;
        uint48 jitLockBlocks;
        uint32 kPips;
        uint32 cPips;
        uint256 timestamp;
    }

    SimHook public hook;

    bytes32 constant BEFORE_SWAP_SIG = keccak256("BeforeSwap(bytes32,uint160,uint160,uint256,int256,uint24,uint24)");
    bytes32 constant AFTER_SWAP_SIG = keccak256("AfterSwap(bytes32,uint160,uint256,int256)");
    bytes32 constant POOL_CONFIGURED_SIG =
        keccak256("PoolConfigured(bytes32,bool,uint24,uint24,uint24,uint256,uint48,uint32,uint32,uint256)");

    function setupSimHookAndPool(
        BasePoolConfig poolConfig,
        bool logging
    ) public returns (int24 initialTick, uint160 initialSqrtPriceX96) {
        address hookAddress = deployCoreAndHookCustomDecimals(
            "SimHook.sol",
            poolConfig.symbol0(),
            poolConfig.symbol1(),
            poolConfig.decimals0(),
            poolConfig.decimals1(),
            poolConfig.nativeEth()
        );
        hook = SimHook(hookAddress);

        (initialTick, initialSqrtPriceX96) =
            deployPool(hook, poolConfig.targetTick(), poolConfig.tickSpacing(), logging);

        vm.recordLogs();

        hook.configurePool(
            poolId,
            poolConfig.minMinFee(),
            poolConfig.maxMinFee(),
            poolConfig.maxFee(),
            poolConfig.timeDecayLength(),
            poolConfig.jitLockBlocks(),
            poolConfig.kPips(),
            poolConfig.cPips()
        );

        if (logging) {
            console.log("Configuring pool...");
            console.log("minMinFee:", poolConfig.minMinFee());
            console.log("maxMinFee:", poolConfig.maxMinFee());
            console.log("maxFee:", poolConfig.maxFee());
            console.log("timeDecayLength:", poolConfig.timeDecayLength());
            console.log("\n");
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        PoolConfiguredEventData memory poolConfiguredEventData = getPoolConfiguredEventData(logs);

        assertEq(poolConfiguredEventData.poolId, PoolId.unwrap(poolId));
        assertEq(poolConfiguredEventData.configured, true);
        assertEq(poolConfiguredEventData.minMinFee, poolConfig.minMinFee());
        assertEq(poolConfiguredEventData.maxMinFee, poolConfig.maxMinFee());
        assertEq(poolConfiguredEventData.maxFee, poolConfig.maxFee());
        assertEq(poolConfiguredEventData.timeDecayLength, poolConfig.timeDecayLength());
        assertEq(poolConfiguredEventData.jitLockBlocks, poolConfig.jitLockBlocks());
        assertEq(poolConfiguredEventData.kPips, poolConfig.kPips());
        assertEq(poolConfiguredEventData.cPips, poolConfig.cPips());
    }

    /* ------ EVENT PARSING HELPERS ------ */

    function getBeforeSwapEventData(Vm.Log[] memory logs) internal pure returns (BeforeSwapEventData memory data) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BEFORE_SWAP_SIG) {
                data.poolId = logs[i].topics[1];
                (
                    data.sqrtPriceX96Before,
                    data.sqrtPriceX96AfterSim,
                    data.priceImpact,
                    data.decayedCumPriceImpact,
                    data.effectiveMinFee,
                    data.dynamicFeePips
                ) = abi.decode(logs[i].data, (uint160, uint160, uint256, int256, uint24, uint24));
                return data;
            }
        }
        revert("BeforeSwap event not found");
    }

    function getAfterSwapEventData(Vm.Log[] memory logs) internal pure returns (AfterSwapEventData memory data) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == AFTER_SWAP_SIG) {
                data.poolId = logs[i].topics[1];
                (data.sqrtPriceX96, data.priceImpact, data.cumPriceImpact) =
                    abi.decode(logs[i].data, (uint160, uint256, int256));
                return data;
            }
        }
        revert("AfterSwap event not found");
    }

    /// @dev The event's non-indexed body, in emit order (poolId is indexed). Decoding into a
    ///      struct keeps ONE memory pointer live instead of a 10-way stack destructure — the
    ///      tuple form pushed optimized via-IR frames in derived test units over the stack limit.
    struct PoolConfiguredEventBody {
        bool configured;
        uint24 minMinFee;
        uint24 maxMinFee;
        uint24 maxFee;
        uint256 timeDecayLength;
        uint48 jitLockBlocks;
        uint32 kPips;
        uint32 cPips;
        uint256 timestamp;
    }

    function getPoolConfiguredEventData(Vm
                .Log[] memory logs) internal pure returns (PoolConfiguredEventData memory data) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == POOL_CONFIGURED_SIG) {
                data.poolId = logs[i].topics[1];
                PoolConfiguredEventBody memory body = abi.decode(logs[i].data, (PoolConfiguredEventBody));
                data.configured = body.configured;
                data.minMinFee = body.minMinFee;
                data.maxMinFee = body.maxMinFee;
                data.maxFee = body.maxFee;
                data.timeDecayLength = body.timeDecayLength;
                data.jitLockBlocks = body.jitLockBlocks;
                data.kPips = body.kPips;
                data.cPips = body.cPips;
                data.timestamp = body.timestamp;
                return data;
            }
        }
        revert("PoolConfigured event not found");
    }
}
