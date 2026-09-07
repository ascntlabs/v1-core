// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ParseBytes} from "@uniswap/v4-core/src/libraries/ParseBytes.sol";

/// @title  SwapQuoter (test infra)
/// @notice Adapted from Uniswap v4-periphery (MIT licence, Copyright (c) Uniswap Labs):
///         `src/libraries/QuoterRevert.sol` and `src/base/BaseV4Quoter.sol`. The revert-with-
///         encoded-result mechanism and the `selfOnly` self-call pattern are theirs; the
///         adaptation carries the post-swap `sqrtPriceX96` alongside the amount deltas, which
///         the upstream quoter does not return.
///
///         Used as an INDEPENDENT ORACLE in the fuzz tests for `SwapSimulator`: run
///         `poolManager.swap()` for real, read post-swap slot0, then revert with the encoded
///         result. The revert rolls back the swap so no state mutates net. Because it drives
///         the live engine rather than replicating it, drift between the two is a genuine
///         signal that `SwapSimulator` has diverged from `Pool.swap`.
///
/// @dev    MUST be called from inside an unlock context (the harness handles that).
library QuoterRevertPrice {
    using ParseBytes for bytes;

    error UnexpectedRevertBytes(bytes revertData);
    error QuoteSwapResult(int256 amount0, int256 amount1, uint160 sqrtPriceX96);

    function revertSwapQuote(int256 amount0, int256 amount1, uint160 sqrtPriceX96) internal pure {
        revert QuoteSwapResult(amount0, amount1, sqrtPriceX96);
    }

    function parseSwapQuote(bytes memory reason)
        internal
        pure
        returns (int256 amount0, int256 amount1, uint160 sqrtPriceX96)
    {
        if (reason.parseSelector() != QuoteSwapResult.selector) {
            revert UnexpectedRevertBytes(reason);
        }
        assembly ("memory-safe") {
            amount0 := mload(add(reason, 0x24))
            amount1 := mload(add(reason, 0x44))
            sqrtPriceX96 := mload(add(reason, 0x64))
        }
    }
}

abstract contract SwapQuoter {
    using QuoterRevertPrice for *;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NotSelf();

    struct SwapQuote {
        int256 amount0;
        int256 amount1;
        uint160 finalSqrtPriceX96;
    }

    IPoolManager internal immutable quoterPoolManager;

    constructor(IPoolManager _poolManager) {
        quoterPoolManager = _poolManager;
    }

    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @notice Simulate a swap and return signed deltas + resulting price.
    function quoteSwapReturnPrice(
        PoolKey memory key,
        SwapParams memory params,
        bytes memory hookData
    ) public returns (SwapQuote memory quote) {
        try this._quoteSwapReturnPrice(key, params, hookData) {}
        catch (bytes memory reason) {
            (quote.amount0, quote.amount1, quote.finalSqrtPriceX96) = QuoterRevertPrice.parseSwapQuote(reason);
        }
    }

    function _quoteSwapReturnPrice(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external selfOnly returns (bytes memory) {
        BalanceDelta swapDelta = quoterPoolManager.swap(key, params, hookData);
        (uint160 finalSqrtPriceX96,,,) = quoterPoolManager.getSlot0(key.toId());
        QuoterRevertPrice.revertSwapQuote(int256(swapDelta.amount0()), int256(swapDelta.amount1()), finalSqrtPriceX96);
    }
}
