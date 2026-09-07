// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookMath} from "../../src/lib/HookMath.sol";

/// @dev Pure-math tests for HookMath helpers. No hook / pool infrastructure needed.
contract SaturationTest is Test {
    // ------ addSaturating (int256) ------

    function test_addSaturating_positiveOverflow_returnsIntMax() public pure {
        int256 result = HookMath.addSaturating(type(int256).max, 1);
        assertEq(result, type(int256).max);
    }

    function test_addSaturating_negativeOverflow_returnsIntMinPlusOne() public pure {
        int256 result = HookMath.addSaturating(type(int256).min + 1, -1);
        assertEq(result, type(int256).min + 1);
    }

    function test_addSaturating_noOverflow_identity() public pure {
        assertEq(HookMath.addSaturating(100, 200), 300);
        assertEq(HookMath.addSaturating(-100, -200), -300);
        assertEq(HookMath.addSaturating(100, -200), -100);
        assertEq(HookMath.addSaturating(0, 0), 0);
    }

    function test_addSaturating_neverReturnsIntMin() public pure {
        int256 result = HookMath.addSaturating(type(int256).min, -1);
        assertEq(result, type(int256).min + 1, "must not return int256.min (SignedMath.abs unsafe there)");
    }

    function testFuzz_addSaturating_neverReverts(int256 a, int256 b) public pure {
        // Must never revert, for any input.
        HookMath.addSaturating(a, b);
    }

    function testFuzz_addSaturating_resultIsValidForAbs(int256 a, int256 b) public pure {
        int256 result = HookMath.addSaturating(a, b);
        // Invariant: result must never equal type(int256).min because SignedMath.abs is unsafe there.
        assertNotEq(result, type(int256).min);
    }

    // ------ decayCumByTime ------

    function test_decayCumByTime_zeroCumValue_returnsZero() public pure {
        assertEq(HookMath.decayCumByTime(0, 100, 1000), 0);
    }

    function test_decayCumByTime_zeroDecayLength_returnsZero() public pure {
        assertEq(HookMath.decayCumByTime(1000, 100, 0), 0);
    }

    function test_decayCumByTime_elapsedEqualsDecayLength_returnsZero() public pure {
        assertEq(HookMath.decayCumByTime(1000, 1000, 1000), 0);
    }

    function test_decayCumByTime_elapsedExceedsDecayLength_returnsZero() public pure {
        assertEq(HookMath.decayCumByTime(1000, 2000, 1000), 0);
    }

    function test_decayCumByTime_halfTime_halfValue() public pure {
        int256 result = HookMath.decayCumByTime(1000, 500, 1000);
        assertEq(result, 500);
    }

    function test_decayCumByTime_preservesSign_positive() public pure {
        int256 result = HookMath.decayCumByTime(1000, 500, 1000);
        assertGt(result, 0);
    }

    function test_decayCumByTime_preservesSign_negative() public pure {
        int256 result = HookMath.decayCumByTime(-1000, 500, 1000);
        assertLt(result, 0);
        assertEq(result, -500);
    }

    /// @dev |result| must never exceed |cumValue| — decay can only shrink magnitude.
    function testFuzz_decayCumByTime_magnitudeBounded(
        int256 cumValue,
        uint256 elapsed,
        uint256 decayLength
    ) public pure {
        // avoid int256.min where abs is unsafe
        vm.assume(cumValue != type(int256).min);

        int256 result = HookMath.decayCumByTime(cumValue, elapsed, decayLength);

        uint256 absInput = cumValue >= 0 ? uint256(cumValue) : uint256(-cumValue);
        uint256 absResult = result >= 0 ? uint256(result) : uint256(-result);

        assertLe(absResult, absInput);
    }

    /// @dev decay result has same sign as input when non-zero; or is zero.
    function testFuzz_decayCumByTime_signInvariant(int256 cumValue, uint256 elapsed, uint256 decayLength) public pure {
        vm.assume(cumValue != type(int256).min);

        int256 result = HookMath.decayCumByTime(cumValue, elapsed, decayLength);

        if (result == 0) return;
        if (cumValue > 0) assertGt(result, 0);
        if (cumValue < 0) assertLt(result, 0);
    }
}
