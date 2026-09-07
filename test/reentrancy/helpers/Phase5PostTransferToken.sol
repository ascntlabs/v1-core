// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Armable reentrant ERC-20 that fires its callback AFTER the balance movement — the
///         ERC-777 `tokensReceived` / hook-on-transfer shape — in contrast to the shared
///         `test/mocks/ReentrantERC20`, which fires BEFORE `super.transfer`.
///
///         The distinction matters for the settlement-reentrancy suites: with this token the
///         treasury has ALREADY been credited when the adversary runs, so the re-entry lands at a
///         different point in the manager's reserve accounting. XSUB-1 / SETTLE-12 must hold at
///         both callback positions; this mock covers the post-transfer one
///         (see `PostTransferReentrancy.t.sol`).
///
///         Local to test/reentrancy/ because shared scaffolding must not be modified mid-phase;
///         the arm/disarm surface mirrors `ReentrantERC20` so `Phase5NestedSwapper` can drive
///         either token through its `IPhase5Trigger` interface.
contract Phase5PostTransferToken is MockERC20 {
    address public reenterTarget;
    bytes public reenterData;
    bool public armed;
    bool public reenterOnTransfer;
    bool public reenterOnTransferFrom;
    /// @dev When true, a failed reentrant call bubbles up and reverts the transfer (attack must
    ///      land); when false, the reentry failure is swallowed and the transfer stands.
    bool public bubbleRevert;

    uint256 public reenterCount;
    bool private _entered; // one-shot reentrancy guard for our OWN callback

    constructor(string memory _name, string memory _symbol, uint8 _decimals) MockERC20(_name, _symbol, _decimals) {}

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
        bool ok = super.transfer(to, amount); // balances move FIRST
        if (reenterOnTransfer) _maybeReenter(); // then the callback fires
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (reenterOnTransferFrom) _maybeReenter();
        return ok;
    }
}
