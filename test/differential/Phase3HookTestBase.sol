// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {SimHookUtils} from "../utils/SimHookUtils.sol";

/// @notice Shared helpers for the phase3-differential hook-level suites. Lives inside
///         test/differential/ so no shared scaffolding is modified.
abstract contract Phase3HookTestBase is SimHookUtils {
    bytes32 internal constant PROTOCOL_FEE_TAKEN_SIG = keccak256("ProtocolFeeTaken(bytes32,address,uint128,uint128)");

    struct ProtocolFeeTakenData {
        bool found;
        bytes32 poolId;
        address treasury;
        uint128 amount0;
        uint128 amount1;
    }

    /// @dev Scans recorded logs for the (single) ProtocolFeeTaken emission of a swap.
    function _parseProtocolFeeTaken(Vm.Log[] memory logs) internal pure returns (ProtocolFeeTakenData memory data) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PROTOCOL_FEE_TAKEN_SIG) {
                data.found = true;
                data.poolId = logs[i].topics[1];
                data.treasury = address(uint160(uint256(logs[i].topics[2])));
                (data.amount0, data.amount1) = abi.decode(logs[i].data, (uint128, uint128));
                return data;
            }
        }
    }
}
