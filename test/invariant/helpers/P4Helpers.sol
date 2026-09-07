// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Phase-4a shared helpers: multi-event log collectors for the SimHook event stream plus
///         two tiny adversarial fixtures. Local to test/invariant/ (phase4a-stateful-core owns it).
library P4Ev {
    bytes32 internal constant BEFORE_SWAP_SIG =
        keccak256("BeforeSwap(bytes32,uint160,uint160,uint256,int256,uint24,uint24)");
    bytes32 internal constant AFTER_SWAP_SIG = keccak256("AfterSwap(bytes32,uint160,uint256,int256)");
    bytes32 internal constant FEE_TAKEN_SIG = keccak256("ProtocolFeeTaken(bytes32,address,uint128,uint128)");
    bytes32 internal constant FEE_TAKEN_AS_CLAIMS_SIG =
        keccak256("ProtocolFeeTakenAsClaims(bytes32,address,uint128,uint128)");

    struct BeforeSwapEv {
        bytes32 poolId;
        uint160 sqrtBefore;
        uint160 sqrtAfterSim;
        uint256 priceImpact;
        int256 decayedCum;
        uint24 effMinFee;
        uint24 dynFee;
    }

    struct AfterSwapEv {
        bytes32 poolId;
        uint160 sqrtPrice;
        uint256 priceImpact;
        int256 cum;
    }

    struct FeeTakenEv {
        bytes32 poolId;
        address treasury;
        uint128 amount0;
        uint128 amount1;
    }

    /// @notice Collect ALL BeforeSwap events (in emission order) — the Phase-0 helpers return only
    ///         the first, which is not enough for batched-unlock tests.
    function beforeSwaps(Vm.Log[] memory logs) internal pure returns (BeforeSwapEv[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BEFORE_SWAP_SIG) n++;
        }
        out = new BeforeSwapEv[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != BEFORE_SWAP_SIG) continue;
            BeforeSwapEv memory e;
            e.poolId = logs[i].topics[1];
            (e.sqrtBefore, e.sqrtAfterSim, e.priceImpact, e.decayedCum, e.effMinFee, e.dynFee) =
                abi.decode(logs[i].data, (uint160, uint160, uint256, int256, uint24, uint24));
            out[j++] = e;
        }
    }

    /// @notice Collect ALL AfterSwap events in emission order.
    function afterSwaps(Vm.Log[] memory logs) internal pure returns (AfterSwapEv[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == AFTER_SWAP_SIG) n++;
        }
        out = new AfterSwapEv[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != AFTER_SWAP_SIG) continue;
            AfterSwapEv memory e;
            e.poolId = logs[i].topics[1];
            (e.sqrtPrice, e.priceImpact, e.cum) = abi.decode(logs[i].data, (uint160, uint256, int256));
            out[j++] = e;
        }
    }

    /// @notice Collect ALL ProtocolFeeTaken events in emission order.
    function feeTakes(Vm.Log[] memory logs) internal pure returns (FeeTakenEv[] memory out) {
        return _collect(logs, FEE_TAKEN_SIG);
    }

    /// @notice Collect ALL ProtocolFeeTakenAsClaims events in emission order — the claims
    ///         fallback path (direct treasury transfer reverted, slice minted as ERC-6909
    ///         claims). Same payload shape as ProtocolFeeTaken.
    function feeTakesAsClaims(Vm.Log[] memory logs) internal pure returns (FeeTakenEv[] memory out) {
        return _collect(logs, FEE_TAKEN_AS_CLAIMS_SIG);
    }

    function _collect(Vm.Log[] memory logs, bytes32 sig) private pure returns (FeeTakenEv[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) n++;
        }
        out = new FeeTakenEv[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            FeeTakenEv memory e;
            e.poolId = logs[i].topics[1];
            e.treasury = address(uint160(uint256(logs[i].topics[2])));
            (e.amount0, e.amount1) = abi.decode(logs[i].data, (uint128, uint128));
            out[j++] = e;
        }
    }

    /// @notice True if `sel` appears anywhere in `data`. v4-core wraps hook reverts in
    ///         `CustomRevert.WrappedError`, so the inner custom-error selector is embedded in the
    ///         bubbled revert bytes rather than sitting at offset 0.
    function containsSelector(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (
                bytes4(
                        uint32(
                            uint32(uint8(data[i])) << 24 | uint32(uint8(data[i + 1])) << 16 | uint32(uint8(data[i + 2]))
                                << 8 | uint32(uint8(data[i + 3]))
                        )
                    ) == sel
            ) {
                return true;
            }
        }
        return false;
    }
}

/// @notice Fallback-reverts contract; arm `ReentrantERC20` at it (bubbleRevert=true) to force the
///         treasury transfer inside `_takeProtocolFeeOnAfterSwap` to revert (ACC-8 / LIFE-13).
contract P4Reverter {
    fallback() external payable {
        revert("P4Reverter: always reverts");
    }
}

/// @notice Contract with no receive/fallback: native-ETH transfers to it always fail. Used as a
///         treasury to exercise the native-side claims fallback (XSUB-6): post-Fix-A the direct
///         `poolManager.take` of native ETH reverts here and the slice degrades to ERC-6909 claims
///         (`ProtocolFeeTakenAsClaims`) instead of bricking the swap. It CAN still hold ERC-20, so
///         the non-native quadrants keep settling real tokens to it.
contract P4NonPayableTreasury {
    // deliberately empty: cannot receive native ETH

    }
