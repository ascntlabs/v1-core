// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ImpactOracle} from "../utils/ImpactOracle.sol";
import {HookMath} from "../../src/lib/HookMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Phase-0 smoke test for the independent price-impact oracle. Confirms the spec
///         properties (zero impact for no move, cap at 100%, in-range) and that it agrees with
///         `HookMath.calculatePriceImpactCapped` across the domain — the differential relationship
///         FEE-4 will lean on. The oracle is a separate code path, so agreement here is a real
///         cross-check (and a tripwire if either transcription drifts).
contract ImpactOracleSmokeTest is Test {
    uint160 constant MIN_USABLE = uint160(1) << 58; // SimHook.MIN_USABLE_SQRT_PRICE

    function test_noMove_isZero() public pure {
        uint160 p = TickMath.getSqrtPriceAtTick(0);
        assertEq(ImpactOracle.priceImpactPips(p, p), 0);
    }

    function test_zeroBefore_isZero() public pure {
        assertEq(ImpactOracle.priceImpactPips(0, TickMath.getSqrtPriceAtTick(0)), 0);
    }

    function test_zeroAfter_isZero() public pure {
        assertEq(ImpactOracle.priceImpactPips(TickMath.getSqrtPriceAtTick(0), 0), 0);
    }

    function test_hugeJump_capsAt100pct() public pure {
        // from a tiny price to a huge one => change >= geometric mean => cap
        uint160 lo = MIN_USABLE;
        uint160 hi = TickMath.MAX_SQRT_PRICE - 1;
        assertEq(ImpactOracle.priceImpactPips(lo, hi), 1e6);
    }

    function test_directionalSign() public pure {
        assertEq(ImpactOracle.directional(true, 500), int256(-500));
        assertEq(ImpactOracle.directional(false, 500), int256(500));
    }

    /// @notice Oracle == HookMath across the usable sqrt-price domain.
    function testFuzz_agreesWithHookMath(uint160 a, uint160 b) public pure {
        a = uint160(bound(uint256(a), MIN_USABLE, uint256(TickMath.MAX_SQRT_PRICE - 1)));
        b = uint160(bound(uint256(b), MIN_USABLE, uint256(TickMath.MAX_SQRT_PRICE - 1)));
        uint256 oracle = ImpactOracle.priceImpactPips(a, b);
        uint256 lib = HookMath.calculatePriceImpactCapped(a, b);
        assertEq(oracle, lib, "oracle vs HookMath divergence");
        assertLe(oracle, 1e6, "impact must be <= 100%");
    }
}
