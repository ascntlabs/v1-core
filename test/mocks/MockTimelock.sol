// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal stand-in for an OZ `TimelockController`. `AscntGovernance` duck-types the
///      timelock slot via `getMinDelay()`, so unit tests can install a "valid" timelock without
///      scaffolding a full controller. Returns a non-zero delay to pass
///      `AscntGovernance._requireValidTimelock`.
contract MockTimelock {
    function getMinDelay() external pure returns (uint256) {
        return 1 days;
    }
}

/// @dev Timelock-shaped contract with a zero delay — rejected by `_requireValidTimelock`
///      because a no-delay controller offers no slow-lane protection.
contract MockZeroDelayTimelock {
    function getMinDelay() external pure returns (uint256) {
        return 0;
    }
}

/// @dev Timelock-shaped contract sitting one second under `MIN_TIMELOCK_DELAY` (24h) — rejected
///      by `_requireValidTimelock`, pinning the boundary of the minimum-delay floor.
contract MockShortDelayTimelock {
    function getMinDelay() external pure returns (uint256) {
        return 24 hours - 1;
    }
}

/// @dev Timelock-shaped contract whose delay can move, mirroring a real `TimelockController`
///      (whose `updateDelay` may be re-run any number of times, to any value including zero).
///      Used to exercise the re-validation `acceptTimelock` performs: a nominee valid at
///      nomination time may have drifted below the floor by the time it accepts.
contract MockMutableDelayTimelock {
    uint256 private _minDelay;

    constructor(uint256 initialDelay) {
        _minDelay = initialDelay;
    }

    function setMinDelay(uint256 newDelay) external {
        _minDelay = newDelay;
    }

    function getMinDelay() external view returns (uint256) {
        return _minDelay;
    }
}
