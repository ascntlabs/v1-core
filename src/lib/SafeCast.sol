// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SafeCast
/// @dev Clamps instead of reverting: these run inside swap-path callbacks, where a revert
///      bricks the pool. Every call site bounds its input below the target max, so the clamps
///      are unreachable backstops.
library SafeCast {
    /// @notice Caps at int256 max instead of reverting. Use at trusted call sites.
    function toInt256Capped(uint256 value) internal pure returns (int256) {
        if (value > uint256(type(int256).max)) {
            return type(int256).max;
        } else {
            return int256(value);
        }
    }

    /// @notice Caps at uint24 max instead of reverting. Use at trusted call sites.
    function toUint24Capped(uint256 value) internal pure returns (uint24) {
        if (value > type(uint24).max) {
            return type(uint24).max;
        } else {
            return uint24(value);
        }
    }

    /// @notice Caps at uint128 max instead of reverting. Use at trusted call sites.
    function toUint128Capped(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) {
            return type(uint128).max;
        } else {
            return uint128(value);
        }
    }
}
