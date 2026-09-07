// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Always-reverting re-entry target. Armed into `ReentrantERC20` with `bubble = true` it
///         turns the unspecified currency into a revert-on-transfer token, which is the SETTLE-17
///         failure mode ("token paused / adversarial revert-on-transfer").
contract Phase5RevertSink {
    error Phase5SinkBoom();

    function boom() external pure {
        revert Phase5SinkBoom();
    }
}
