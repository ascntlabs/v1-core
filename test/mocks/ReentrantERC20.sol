// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice ERC20 whose `transfer` / `transferFrom` can be ARMED to re-enter an arbitrary target
///         exactly once. Scaffolding for the settlement-reentrancy invariants (SETTLE-12/13/17,
///         XSUB-1).
///
///         The protocol-fee take runs `currency.take` -> `PoolManager.take` ->
///         `ERC20.transfer(treasury, amount)`, so arming `reenterOnTransfer` fires the callback
///         mid-settlement — letting a test drive a nested `PoolManager.swap` while the outer
///         `SimHook._afterSwap` is still on the stack. A one-shot guard prevents the token from
///         recursing into its own reentry.
///
///         Disarmed (the default), it is a plain `MockERC20` — a drop-in for the honest token side.
contract ReentrantERC20 is MockERC20 {
    address public reenterTarget;
    bytes public reenterData;
    bool public armed;
    bool public reenterOnTransfer;
    bool public reenterOnTransferFrom;
    /// @dev When true, a failed reentrant call bubbles up and reverts the transfer (attack must
    ///      land); when false, the reentry failure is swallowed and the transfer proceeds.
    bool public bubbleRevert;

    uint256 public reenterCount;
    bool private _entered; // one-shot reentrancy guard for our OWN callback

    constructor(string memory _name, string memory _symbol, uint8 _decimals) MockERC20(_name, _symbol, _decimals) {}

    /// @notice Arm the token to call `target` with `data` once, on the selected path(s).
    function arm(address target, bytes calldata data, bool onTransfer, bool onTransferFrom, bool bubble) external {
        reenterTarget = target;
        reenterData = data;
        reenterOnTransfer = onTransfer;
        reenterOnTransferFrom = onTransferFrom;
        bubbleRevert = bubble;
        armed = true;
    }

    function disarm() external {
        armed = false;
        reenterOnTransfer = false;
        reenterOnTransferFrom = false;
    }

    function _maybeReenter() internal {
        if (!armed || _entered || reenterTarget == address(0)) return;
        _entered = true;
        reenterCount++;
        (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
        _entered = false;
        if (bubbleRevert && !ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (reenterOnTransfer) _maybeReenter();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (reenterOnTransferFrom) _maybeReenter();
        return super.transferFrom(from, to, amount);
    }
}
