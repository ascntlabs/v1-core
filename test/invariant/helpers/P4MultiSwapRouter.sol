// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @notice Batches multiple swaps — possibly on different pools — inside ONE PoolManager.unlock,
///         which PoolSwapTest cannot do. This is the exploit surface SETTLE-10/SETTLE-11/ACC-5
///         name: transient storage is NOT cleared between swaps of the same unlock, so a stale
///         hookFee stash or a cross-pool stash collision would only be observable here.
///
///         Per swap it records the pre/post slot0 price seen by THIS bracket and the hook's open
///         PoolManager currency deltas immediately after the swap (SETTLE-5: they must be zero —
///         the returned afterSwap delta must have netted the `.take` exactly, mid-unlock).
///         The router must be funded with both tokens; it settles all currencies at the end of
///         the unlock (ERC-20 pools only — no native plumbing).
contract P4MultiSwapRouter is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    address public immutable hookAddr;

    struct Step {
        PoolKey key;
        SwapParams params;
    }

    struct Obs {
        uint160 sqrtBefore; // slot0 read by THIS bracket immediately before manager.swap
        uint160 sqrtAfter; // slot0 immediately after manager.swap
        int128 amount0; // swapper-side delta returned by manager.swap (post-hook-delta)
        int128 amount1;
        int256 hookDelta0; // hook's open currency deltas right after this swap (must be 0)
        int256 hookDelta1;
    }

    error NotManager();

    constructor(IPoolManager _manager, address _hookAddr) {
        manager = _manager;
        hookAddr = _hookAddr;
    }

    function batchSwap(Step[] memory steps) external returns (Obs[] memory obs) {
        bytes memory result = manager.unlock(abi.encode(steps));
        obs = abi.decode(result, (Obs[]));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        Step[] memory steps = abi.decode(raw, (Step[]));
        Obs[] memory obs = new Obs[](steps.length);

        for (uint256 i = 0; i < steps.length; i++) {
            PoolId id = steps[i].key.toId();
            (uint160 sb,,,) = manager.getSlot0(id);
            BalanceDelta d = manager.swap(steps[i].key, steps[i].params, "");
            (uint160 sa,,,) = manager.getSlot0(id);
            obs[i] = Obs({
                sqrtBefore: sb,
                sqrtAfter: sa,
                amount0: d.amount0(),
                amount1: d.amount1(),
                hookDelta0: manager.currencyDelta(hookAddr, steps[i].key.currency0),
                hookDelta1: manager.currencyDelta(hookAddr, steps[i].key.currency1)
            });
        }

        // Settle every currency this router has an open delta on. Looping over all step
        // currencies is repeat-safe: after the first settle the delta is zero.
        for (uint256 i = 0; i < steps.length; i++) {
            _settle(steps[i].key.currency0);
            _settle(steps[i].key.currency1);
        }
        return abi.encode(obs);
    }

    function _settle(Currency c) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d < 0) {
            c.settle(manager, address(this), uint256(-d), false);
        } else if (d > 0) {
            c.take(manager, address(this), uint256(d), false);
        }
    }
}
