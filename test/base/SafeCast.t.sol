// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SafeCast} from "../../src/lib/SafeCast.sol";

/// @title SafeCastTest
/// @notice Direct unit tests for the four SafeCast helpers. The hook contracts
/// exercise these indirectly through swap math, but the boundary cases (cap
/// activations) are easier to pin down here.
contract SafeCastTest is Test {
    // ------ toInt256Capped ------

    function test_toInt256Capped_zero() public pure {
        assertEq(SafeCast.toInt256Capped(0), 0);
    }

    function test_toInt256Capped_smallValue() public pure {
        assertEq(SafeCast.toInt256Capped(42), 42);
    }

    function test_toInt256Capped_atIntMax_unchanged() public pure {
        uint256 v = uint256(type(int256).max);
        assertEq(SafeCast.toInt256Capped(v), type(int256).max);
    }

    function test_toInt256Capped_aboveIntMax_capped() public pure {
        uint256 v = uint256(type(int256).max) + 1;
        assertEq(SafeCast.toInt256Capped(v), type(int256).max);
    }

    function test_toInt256Capped_uintMax_capped() public pure {
        assertEq(SafeCast.toInt256Capped(type(uint256).max), type(int256).max);
    }

    function testFuzz_toInt256Capped_belowIntMax_identity(uint256 value) public pure {
        vm.assume(value <= uint256(type(int256).max));
        assertEq(SafeCast.toInt256Capped(value), int256(value));
    }

    function testFuzz_toInt256Capped_aboveIntMax_capped(uint256 value) public pure {
        vm.assume(value > uint256(type(int256).max));
        assertEq(SafeCast.toInt256Capped(value), type(int256).max);
    }

    // ------ toUint24Capped ------

    function test_toUint24Capped_zero() public pure {
        assertEq(uint256(SafeCast.toUint24Capped(0)), 0);
    }

    function test_toUint24Capped_smallValue() public pure {
        assertEq(uint256(SafeCast.toUint24Capped(123_456)), 123_456);
    }

    function test_toUint24Capped_atUint24Max_unchanged() public pure {
        assertEq(uint256(SafeCast.toUint24Capped(type(uint24).max)), type(uint24).max);
    }

    function test_toUint24Capped_aboveUint24Max_capped() public pure {
        assertEq(uint256(SafeCast.toUint24Capped(uint256(type(uint24).max) + 1)), type(uint24).max);
    }

    function test_toUint24Capped_uintMax_capped() public pure {
        assertEq(uint256(SafeCast.toUint24Capped(type(uint256).max)), type(uint24).max);
    }

    function testFuzz_toUint24Capped_belowMax_identity(uint256 value) public pure {
        vm.assume(value <= type(uint24).max);
        assertEq(uint256(SafeCast.toUint24Capped(value)), value);
    }

    function testFuzz_toUint24Capped_aboveMax_capped(uint256 value) public pure {
        vm.assume(value > type(uint24).max);
        assertEq(uint256(SafeCast.toUint24Capped(value)), type(uint24).max);
    }

    // ------ toUint128Capped ------

    function test_toUint128Capped_zero() public pure {
        assertEq(uint256(SafeCast.toUint128Capped(0)), 0);
    }

    function test_toUint128Capped_smallValue() public pure {
        assertEq(uint256(SafeCast.toUint128Capped(1_000_000)), 1_000_000);
    }

    function test_toUint128Capped_atMax_unchanged() public pure {
        assertEq(uint256(SafeCast.toUint128Capped(type(uint128).max)), type(uint128).max);
    }

    function test_toUint128Capped_aboveMax_capped() public pure {
        assertEq(uint256(SafeCast.toUint128Capped(uint256(type(uint128).max) + 1)), type(uint128).max);
    }

    function test_toUint128Capped_uintMax_capped() public pure {
        assertEq(uint256(SafeCast.toUint128Capped(type(uint256).max)), type(uint128).max);
    }

    function testFuzz_toUint128Capped_belowMax_identity(uint256 value) public pure {
        vm.assume(value <= type(uint128).max);
        assertEq(uint256(SafeCast.toUint128Capped(value)), value);
    }

    function testFuzz_toUint128Capped_aboveMax_capped(uint256 value) public pure {
        vm.assume(value > type(uint128).max);
        assertEq(uint256(SafeCast.toUint128Capped(value)), type(uint128).max);
    }
}
