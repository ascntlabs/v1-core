// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SwapQuoter} from "./SwapQuoter.sol";

/// @notice Concrete subclass of `SwapQuoter` for use in tests. Bridges from an external
///         test call into an unlock context: the quoter requires the PoolManager to already
///         be unlocked, which holds inside a hook callback but NOT inside a plain test
///         function.
contract TestSwapQuoter is SwapQuoter, IUnlockCallback {
    constructor(IPoolManager _pm) SwapQuoter(_pm) {}

    /// @notice External entry. Calls `manager.unlock(...)` which calls back into us
    ///         with the pool unlocked; we then run the quoter from inside.
    function quote(
        PoolKey memory key,
        SwapParams memory params,
        bytes memory hookData
    ) external returns (SwapQuote memory) {
        bytes memory data = abi.encode(key, params, hookData);
        bytes memory result = quoterPoolManager.unlock(data);
        return abi.decode(result, (SwapQuote));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(quoterPoolManager), "only manager");
        (PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(data, (PoolKey, SwapParams, bytes));

        // Now inside an unlocked context — run the quoter.
        SwapQuote memory q = quoteSwapReturnPrice(key, params, hookData);
        return abi.encode(q);
    }
}
