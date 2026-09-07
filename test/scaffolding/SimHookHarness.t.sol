// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestUtils} from "../utils/TestUtils.sol";
import {SimHookHarness} from "../harness/SimHookHarness.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Phase-0 smoke test for the internals-exposing harness. Proves the harness deploys at
///         the same mined hook address as SimHook (identical permissions) and that the exposed
///         internal fee/split entry points behave, unblocking the Phase-1 stateless-fuzz suite.
contract SimHookHarnessSmokeTest is TestUtils {
    SimHookHarness internal harness;
    PoolId internal constant PID = PoolId.wrap(bytes32(uint256(1)));
    address internal constant TREASURY = address(0xBEEF);

    function setUp() public {
        address hookAddress = deployCoreAndHookCustomDecimals("SimHookHarness.sol", "USDC", "USDT", 6, 6, false);
        harness = SimHookHarness(hookAddress);
        // `_computeProtocolFeeSplit` carves only when the LIVE `governance.treasury()` is set —
        // without somewhere for the slice to go it degrades to "full dynamic fee to LPs". Wire a
        // treasury up (the test contract is the timelock) so the carve path below is genuinely
        // exercised rather than passing through the degraded branch.
        governance.setTreasury(TREASURY);
    }

    // ---- calculateDynamicFee clamp behavior ----

    function test_dynamicFee_withinBounds_returnsValue() public view {
        // cum==0 => increasing branch => fee = k x midpoint of the 0->500 leg = 500, in [100, 10000]
        uint24 fee = harness.exposedCalculateDynamicFee(500, 0, false, 100, 10_000, 2e6, 1e6);
        assertEq(fee, 500);
    }

    function test_dynamicFee_belowMin_clampsToMin() public view {
        uint24 fee = harness.exposedCalculateDynamicFee(50, 0, false, 100, 10_000, 2e6, 1e6);
        assertEq(fee, 100);
    }

    function test_dynamicFee_aboveMax_clampsToMax() public view {
        uint24 fee = harness.exposedCalculateDynamicFee(20_000, 0, false, 100, 10_000, 2e6, 1e6);
        assertEq(fee, 10_000);
    }

    // ---- protocol-fee split + transient stash round-trip ----

    function test_split_stashesAndConservesFee() public {
        harness.harnessSetProtocolFeeBps(1000); // 10%
        uint24 dynamicFee = 1000;
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(PID, dynamicFee);
        uint24 hookFee = harness.readStash(PID);

        assertEq(hookFee, 100, "hookFee = 10% of 1000");
        assertEq(lpFee, 900, "lpFee = remainder");
        assertEq(uint256(lpFee) + uint256(hookFee), uint256(dynamicFee), "split conserves fee");
    }

    function test_split_zeroBps_allToLp() public {
        harness.harnessSetProtocolFeeBps(0);
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(PID, 1234);
        assertEq(lpFee, 1234);
        assertEq(harness.readStash(PID), 0);
    }

    /// @dev The other zero-carve trigger: a nonzero cache with NO treasury. The split reads the
    ///      live treasury, so it takes nothing and hands the full dynamic fee to LPs — it must
    ///      never reduce lpFee for a slice that then has nowhere to settle.
    function test_split_noTreasury_allToLp() public {
        governance.setTreasury(address(0)); // permitted: governance.protocolFeeBps is still 0
        harness.harnessSetProtocolFeeBps(1000); // 10% cached, but stranded
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(PID, 1000);
        assertEq(lpFee, 1000, "unset treasury must leave the full dynamic fee with LPs");
        assertEq(harness.readStash(PID), 0, "nothing may be stashed with no treasury to settle to");
    }
}
