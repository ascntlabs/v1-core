// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal stand-in for the OZ `TimelockController` in the phase-5 reentrancy suites.
///
///         `AscntGovernance` duck-types its timelock (`code.length > 0` + non-zero `getMinDelay()`),
///         so this contract satisfies the check while letting tests drive the slow lane. It exposes
///         two DELIBERATELY different lanes:
///
///           - `exec` — permissionless and immediate, with NO delay. This is the reentrancy
///             delivery vehicle and fixture bring-up path: the vectors need a governance entry
///             point an armed ERC-20 can call synchronously from inside `PoolManager.take` to
///             mutate `protocolFeeBps` / `treasury` mid-settlement, and `setUp` needs one-line
///             slow-lane calls. Nothing that goes through `exec` says anything about timelock
///             SECURITY — only about what the timelock ROLE can reach.
///
///           - `schedule` / `execute` — the delay-ENFORCING pair. `execute` reverts until
///             `MIN_DELAY` has elapsed since the matching `schedule`. The SETTLE-17 recovery
///             vectors run through this pair, so "recovery costs the full delay window" is
///             asserted by the proxy's own clock, not narrated. (Full OZ TimelockController
///             semantics — roles, predecessors, cancellation — are exercised end-to-end in
///             `test/timelock/Timelock.t.sol`; this proxy enforces only the delay dimension.)
///
///         Two reasons the suites need a *separate* timelock address rather than the usual
///         "test contract is both owner and timelock" shortcut:
///
///           1. SETTLE-17 asserts that the fast lane (owner / pauser) genuinely CANNOT clear a
///              settlement DoS — that assertion is vacuous if `owner == timelock`.
///           2. The reentrancy vectors need the mid-settlement mutation path described above.
contract Phase5TimelockProxy {
    uint256 public constant MIN_DELAY = 1 days;

    error Phase5NotScheduled(bytes32 id);
    error Phase5DelayNotElapsed(bytes32 id, uint256 readyAt);

    /// @dev operation id (keccak of target+data) => earliest executable timestamp.
    mapping(bytes32 => uint256) public readyAt;

    /// @dev Non-zero delay so `AscntGovernance._requireValidTimelock` accepts this address.
    function getMinDelay() external pure returns (uint256) {
        return MIN_DELAY;
    }

    /// @notice Forward an arbitrary call as the timelock IMMEDIATELY, bubbling any revert reason
    ///         verbatim. Permissionless and delay-free by design — see the header for what this
    ///         lane may and may not be used to demonstrate.
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        return _call(target, data);
    }

    /// @notice Register an operation; it becomes executable `MIN_DELAY` from now.
    function schedule(address target, bytes calldata data) external returns (bytes32 id) {
        id = keccak256(abi.encode(target, data));
        readyAt[id] = block.timestamp + MIN_DELAY;
    }

    /// @notice Execute a previously scheduled operation. Reverts if it was never scheduled or the
    ///         delay has not fully elapsed — this is the enforced clock the recovery vectors
    ///         assert against.
    function execute(address target, bytes calldata data) external returns (bytes memory) {
        bytes32 id = keccak256(abi.encode(target, data));
        uint256 eta = readyAt[id];
        if (eta == 0) revert Phase5NotScheduled(id);
        if (block.timestamp < eta) revert Phase5DelayNotElapsed(id, eta);
        delete readyAt[id];
        return _call(target, data);
    }

    function _call(address target, bytes calldata data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
