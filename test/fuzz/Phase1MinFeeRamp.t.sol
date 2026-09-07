// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookMath} from "../../src/lib/HookMath.sol";

/// @notice RAMP-1/RAMP-4 stateless legs: the deferred once-per-block anchor-settle rule
///         `anchor' = lastTs - (lastTs - anchor) / 2` (SimHook._beforeSwap), pinned as pure
///         arithmetic over its full admissible domain. End-to-end coverage (event floors, real
///         swaps, revert atomicity) lives in test/feature/MinFeeRampAnchor.t.sol and
///         Phase4aAccLifecycle; this file proves the settle rule itself cannot misbehave:
///         bounded, monotone, exactly credit-halving, and fixed at zero credit.
contract Phase1MinFeeRampTest is Test {
    /// @dev Mirror of the in-contract settle expression, in the uint256 width the contract's
    ///      uint48/uint40 operands promote to. Domain: anchor <= lastTs (contract invariant —
    ///      the anchor starts at the first swap's timestamp and only moves toward later
    ///      lastSwapTimestamp values).
    function _settle(uint256 anchor, uint256 lastTs) internal pure returns (uint256) {
        return lastTs - (lastTs - anchor) / 2;
    }

    /// @notice Settled anchor stays inside [anchor, lastTs]; the credit measured at lastTs
    ///         halves exactly (floor division); zero credit is a fixed point; and the uint40
    ///         store cast cannot truncate for any in-range timestamp.
    function testFuzz_settle_boundsAndExactHalving(uint40 anchorRaw, uint40 lastTsRaw) public pure {
        uint256 anchor = uint256(anchorRaw);
        uint256 lastTs = uint256(lastTsRaw);
        if (anchor > lastTs) (anchor, lastTs) = (lastTs, anchor);

        uint256 credit = lastTs - anchor;
        uint256 settled = _settle(anchor, lastTs);

        assertGe(settled, anchor, "settle moved the anchor backward");
        assertLe(settled, lastTs, "settle moved the anchor past lastTs");
        assertEq(lastTs - settled, credit / 2, "credit at lastTs must halve exactly");
        if (credit == 0) assertEq(settled, anchor, "zero credit must be a fixed point");
        assertLe(settled, type(uint40).max, "settled anchor must fit uint40");
    }

    /// @notice Monotonicity in both operands: a later anchor or a later lastTs never settles
    ///         to an earlier anchor — so repeated settles can only walk the anchor forward
    ///         (RAMP-4's monotone non-decreasing leg).
    function testFuzz_settle_monotone(uint40 anchorRaw, uint40 lastTsRaw, uint16 bump) public pure {
        uint256 anchor = uint256(anchorRaw);
        uint256 lastTs = uint256(lastTsRaw);
        if (anchor > lastTs) (anchor, lastTs) = (lastTs, anchor);

        uint256 base = _settle(anchor, lastTs);
        // later lastTs (same anchor)
        assertGe(_settle(anchor, lastTs + uint256(bump)), base, "later lastTs must not settle earlier");
        // later anchor (same lastTs), staying in-domain
        uint256 anchorBumped = anchor + uint256(bump);
        if (anchorBumped <= lastTs) {
            assertGe(_settle(anchorBumped, lastTs), base, "later anchor must not settle earlier");
        }
    }

    /// @notice Geometric relaxation: iterating settle against a FIXED lastTs drives the credit
    ///         to zero in at most ~40 rounds (log2 of the uint40 range) — the "several
    ///         consecutive blocks in the open" bound the deferred design relies on; combined
    ///         with the ramp being exact at the endpoints, an idle-banked floor always bleeds
    ///         to minMinFee under sustained per-block trading and never earlier than log2 steps.
    function testFuzz_settle_iterationDrivesCreditToZero(uint40 anchorRaw, uint40 lastTsRaw) public pure {
        uint256 anchor = uint256(anchorRaw);
        uint256 lastTs = uint256(lastTsRaw);
        if (anchor > lastTs) (anchor, lastTs) = (lastTs, anchor);

        uint256 a = anchor;
        for (uint256 i = 0; i < 41 && a != lastTs; i++) {
            uint256 next = _settle(a, lastTs);
            assertGe(next, a, "iteration must be monotone");
            a = next;
        }
        assertEq(a, lastTs, "credit must reach zero within log2(range) settles");
    }

    /// @notice The floor read composes exactly: for any settled anchor and any `now >= lastTs`,
    ///         the effective floor equals the library ramp of `now - anchor'` — and because
    ///         settle never moves the anchor past lastTs, the floor after a settle is never
    ///         below the floor a raw `now - lastTs` clock would give (deferred halving only
    ///         ever RAISES the floor relative to an instant reset).
    function testFuzz_settledFloor_neverBelowInstantResetFloor(
        uint40 anchorRaw,
        uint40 lastTsRaw,
        uint16 sinceLast,
        uint24 minMin,
        uint24 maxMin,
        uint32 lenRaw
    ) public pure {
        uint256 anchor = uint256(anchorRaw);
        uint256 lastTs = uint256(lastTsRaw);
        if (anchor > lastTs) (anchor, lastTs) = (lastTs, anchor);
        if (minMin > maxMin) (minMin, maxMin) = (maxMin, minMin);
        uint256 len = uint256(lenRaw) + 1; // ZeroDecay is config-unreachable
        uint256 nowTs = lastTs + uint256(sinceLast);

        uint256 settled = _settle(anchor, lastTs);
        uint24 floorSettled = HookMath.calculateEffectiveMinFee(minMin, maxMin, nowTs - settled, len);
        uint24 floorInstantReset = HookMath.calculateEffectiveMinFee(minMin, maxMin, nowTs - lastTs, len);
        assertGe(floorSettled, floorInstantReset, "deferred halving never undercuts the instant-reset floor");
    }
}
