// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {SimHook} from "../../src/SimHook.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";

/// @notice Test-only subclass exposing `SimHook` / `AscntBaseHook` internals for the stateless-fuzz
///         invariants (FEE-*, SETTLE-1/2/18). Adds NO callbacks, so `getHookPermissions` — and
///         therefore the required hook-address bits — are identical to `SimHook`; deploy it at the
///         same mined address via `deployCodeTo("SimHookHarness.sol", ...)`.
contract SimHookHarness is SimHook {
    /// @dev MUST equal `AscntBaseHook._HOOK_FEE_STASH` (which is private). `readStash` below relies
    ///      on it; if the src constant ever changes, this read diverges and the stash tests break
    ///      loudly — an intentional tripwire.
    bytes32 private constant HOOK_FEE_STASH = keccak256("ascnt.protocolfee.hookfee.v1");

    constructor(IPoolManager _manager, AscntGovernance _governance) SimHook(_manager, _governance) {}

    /// @notice Direct call into the internal pure fee calculator.
    function exposedCalculateDynamicFee(
        uint256 estimatedPriceImpact,
        int256 cumPriceImpact,
        bool zeroForOne,
        uint24 effectiveMinFee,
        uint24 maxFee,
        uint32 kPips,
        uint32 cPips
    ) external pure returns (uint24) {
        return calculateDynamicFee(
            estimatedPriceImpact, cumPriceImpact, zeroForOne, effectiveMinFee, maxFee, kPips, cPips
        );
    }

    /// @notice Runs the real LP/protocol split (writes the transient hookFee stash); returns lpFee.
    ///         Pair with `readStash` (same transaction) to inspect the stashed protocol slice.
    function exposedComputeProtocolFeeSplit(PoolId poolId, uint24 dynamicFee) external returns (uint24 lpFee) {
        return _computeProtocolFeeSplit(poolId, dynamicFee);
    }

    /// @notice Read the per-pool transient hookFee stash written by the split (same-tx only).
    function readStash(PoolId poolId) external view returns (uint24 hookFee) {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(poolId), HOOK_FEE_STASH));
        assembly ("memory-safe") {
            hookFee := tload(slot)
        }
    }

    /// @notice Set the local `protocolFeeBps` cache directly, bypassing governance, so fuzzers can
    ///         drive `protBps` beyond the 2000-bps governance cap to probe the SETTLE-1 boundary.
    function harnessSetProtocolFeeBps(uint16 bps) external {
        protocolFeeBps = bps;
    }
}
