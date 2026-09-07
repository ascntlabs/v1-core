// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BasePoolConfig} from "../lib/BasePoolConfig.sol";

/// @title PoolDeploymentBase
/// @notice Hook-AGNOSTIC root of the per-pool pre-deployment validation harness.
///
/// Currently a thin shell — illiq-scale calibration was removed when SimHook moved
/// to in-loop simulation. Subclasses (e.g. `PoolDeploymentBaseSim`) layer hook-specific
/// smoke tests on top.
abstract contract PoolDeploymentBase is Test {
    BasePoolConfig internal poolCfg;
}
