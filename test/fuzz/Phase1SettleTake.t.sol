// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Phase1FuzzBase, Phase1MockManager} from "./Phase1Helpers.sol";

/// @notice Phase-1 stateless fuzz over `AscntBaseHook._takeProtocolFeeOnAfterSwap` — the REAL
///         settle code, called directly through a subclass, with a mock manager recording the
///         single external `take` call.
///
/// Covers: SETTLE-7 (critical — take128 <= int128.max on all reachable inputs, so the int128
///         cast never wraps negative), SETTLE-4 (take < mag strictly), SETTLE-8 (returned hook
///         delta always >= 0, including every no-op trigger), FEE-5 (the take rounds DOWN).
///
/// Rounding direction: `take = floor(mag * hookFee / 1e6)` (FullMath.mulDiv floors). Rounding
/// DOWN is required — treasury may only be under-paid by < 1 wei per swap (bias toward the
/// swapper); rounding up could push take to/above the swapper's realized credit.
///
/// Reachable envelope (production): hookFee <= 200_000 pips (dynamicFee <= MAX_LP_FEE = 1e6 and
/// governance cache cap 2000 bps => floor(1e6 * 2000/10000) = 2e5), mag = |int128 delta| <= 2^127.
contract Phase1SettleTakeFuzz is Phase1FuzzBase {
    /// @dev Independent oracle for |int128| that is exact at int128.min (2^127).
    function _abs128(int128 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(uint128(x)) : uint256(-(int256(x)));
    }

    /// @dev Spec rule (SETTLE-6): the unspecified
    ///      currency is currency0 iff (exactInput != zeroForOne), exactInput = amountSpecified < 0.
    function _unspecifiedIsCurrency0(SwapParams memory p) internal pure returns (bool) {
        return (p.amountSpecified < 0) != p.zeroForOne;
    }

    // ------------------------------------------------------------------
    // SETTLE-7 + SETTLE-8 + SETTLE-4 + FEE-5 — reachable envelope fuzz
    // ------------------------------------------------------------------

    /// @notice SETTLE-7/8/4: over the full reachable input domain — hookFee in [0, 2e5],
    ///         swap delta components over the FULL int128 range (incl. int128.min, |.| = 2^127),
    ///         all four direction x exactness quadrants — the settle path:
    ///         (1) returns a delta that is never negative (SETTLE-8);
    ///         (2) returns exactly the amount passed to `manager.take` (single take128 local);
    ///         (3) takes strictly less than the realized magnitude when it takes at all (SETTLE-4);
    ///         (4) takes exactly floor(mag * hookFee / 1e6) — round-down (FEE-5);
    ///         (5) never reaches the uint128 cap nor the int128 sign bit (SETTLE-7).
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: dev.fuzz.runs = 1000
    function testFuzz_take_reachableEnvelope(
        uint24 hookFee,
        int128 amount0,
        int128 amount1,
        bool zeroForOne,
        bool exactInput
    ) public {
        hookFee = uint24(bound(hookFee, 0, MAX_REACHABLE_HOOK_FEE));
        _stashExactHookFee(PID_A, hookFee);

        SwapParams memory params = _swapParams(zeroForOne, exactInput ? int256(-1) : int256(1));
        BalanceDelta delta = toBalanceDelta(amount0, amount1);

        int128 hookDelta = harness.exposedTakeProtocolFeeOnAfterSwap(_key(), params, delta, PID_A);

        // (1) SETTLE-8: the afterSwap hook delta is never negative.
        assertGe(hookDelta, 0, "hook delta must never be negative");

        int128 unspecComponent = _unspecifiedIsCurrency0(params) ? amount0 : amount1;
        uint256 mag = _abs128(unspecComponent);
        uint256 expectedTake = (mag * uint256(hookFee)) / PIPS_SCALE; // fits: 2^127 * 2^24 << 2^256

        if (expectedTake == 0) {
            // No-op path: nothing taken, exactly zero returned.
            assertEq(hookDelta, 0, "no-op returns exactly 0");
            assertEq(p1Manager.takeCount(), 0, "no manager.take on the no-op path");
        } else {
            // (2) returned delta == amount actually taken to treasury.
            Phase1MockManager.TakeCall memory t = p1Manager.lastTake();
            assertEq(p1Manager.takeCount(), 1, "exactly one take");
            assertEq(t.to, TREASURY, "take goes to treasury");
            assertEq(uint256(uint128(hookDelta)), t.amount, "returned delta == taken amount");

            // (4) FEE-5: exact floor, never rounds up.
            assertEq(t.amount, expectedTake, "take == floor(mag*hookFee/1e6)");

            // (3) SETTLE-4: strict under-take vs realized magnitude.
            assertLt(t.amount, mag, "take strictly < unspecified magnitude");
            assertLe(t.amount, mag / 5 + 1, "take within the 20% envelope");

            // (5) SETTLE-7: far below the int128 sign bit — cast is exact and non-negative.
            assertLe(t.amount, uint256(uint128(type(int128).max)), "take128 <= int128.max");
            assertEq(int256(hookDelta), int256(expectedTake), "int128 cast lossless");

            // Currency selection matches the spec rule for the quadrant.
            assertEq(
                Currency.unwrap(t.currency),
                _unspecifiedIsCurrency0(params) ? address(0xC0) : address(0xC1),
                "took from the unspecified currency"
            );
        }
    }

    /// @notice SETTLE-7 worst reachable corner, pinned: hookFee at its reachable max (200_000)
    ///         and mag at its absolute max (|int128.min| = 2^127). take = floor(2^127 / 5) —
    ///         comfortably below int128.max (~5x margin). The delta returned is positive.
    function test_take_worstReachableCorner_noWrap() public {
        _stashExactHookFee(PID_A, MAX_REACHABLE_HOOK_FEE);
        BalanceDelta delta = toBalanceDelta(type(int128).min, 0);
        // exactInput=true, zeroForOne=false => unspecified is currency0 (the int128.min side).
        int128 hookDelta = harness.exposedTakeProtocolFeeOnAfterSwap(_key(), _swapParams(false, -1), delta, PID_A);

        uint256 expected = ((uint256(1) << 127) * uint256(MAX_REACHABLE_HOOK_FEE)) / PIPS_SCALE;
        assertGt(hookDelta, 0, "worst-corner delta positive");
        assertEq(uint256(uint128(hookDelta)), expected, "worst-corner take exact");
        assertLt(expected, uint256(uint128(type(int128).max)), "worst-corner take < int128.max");
    }

    // ------------------------------------------------------------------
    // SETTLE-7 — beyond the envelope: demonstrate the cliff the caps guard
    // ------------------------------------------------------------------

    /// @notice SETTLE-7 cliff demonstration (documentation, NOT a reachable bug): if the stashed
    ///         hookFee could ever reach PIPS_SCALE (1e6 = 100%) while mag = 2^127, then
    ///         take = 2^127 fits uint128 (no cap) but int128(take128) wraps to int128.min — a
    ///         NEGATIVE hook delta that would CREDIT the swapper the whole unspecified side while
    ///         treasury is simultaneously handed 2^127 tokens (pool drain). The production guard
    ///         is purely numeric: hookFee <= 2e5 << 1e6, enforced by the 2000-bps governance
    ///         cache cap + dynamicFee <= MAX_LP_FEE. 5x margin, no in-code backstop.
    function test_take_beyondEnvelope_hookFee100pct_wrapsNegative() public {
        _stashExactHookFee(PID_A, uint24(PIPS_SCALE)); // 100% — unreachable in production
        BalanceDelta delta = toBalanceDelta(type(int128).min, 0);
        int128 hookDelta = harness.exposedTakeProtocolFeeOnAfterSwap(_key(), _swapParams(false, -1), delta, PID_A);

        // The wrap: returned delta is int128.min while the manager was told to pay out 2^127.
        assertEq(hookDelta, type(int128).min, "documented wrap: delta goes negative at 100% hookFee");
        assertEq(p1Manager.lastTake().amount, uint256(1) << 127, "treasury was handed the full magnitude");
    }

    /// @notice SETTLE-7 companion (documentation): at the absolute stash ceiling (uint24.max ~
    ///         1677%) with mag = 2^127, the raw product exceeds uint128 and `toUint128Capped`
    ///         fires, so take128 = uint128.max and int128(take128) = -1. Proves BOTH the capped
    ///         cast and the sign flip are live failure modes above the envelope — the invariant's
    ///         safety is entirely the reachable bound on hookFee.
    function test_take_beyondEnvelope_uint24MaxHookFee_capFires() public {
        _stashExactHookFee(PID_A, type(uint24).max);
        BalanceDelta delta = toBalanceDelta(type(int128).min, 0);
        int128 hookDelta = harness.exposedTakeProtocolFeeOnAfterSwap(_key(), _swapParams(false, -1), delta, PID_A);

        assertEq(hookDelta, -1, "documented: uint128 cap then int128 cast yields -1");
        assertEq(p1Manager.lastTake().amount, type(uint128).max, "cap fired at uint128.max");
    }

    // ------------------------------------------------------------------
    // SETTLE-8 — every no-op trigger returns exactly 0 with no take
    // ------------------------------------------------------------------

    /// @notice SETTLE-8 no-op trigger 1: stashed hookFee == 0 (protocol fee disabled) — returns 0,
    ///         no manager call, regardless of delta size or quadrant.
    function testFuzz_take_noop_zeroHookFee(int128 amount0, int128 amount1, bool zeroForOne, bool exactIn) public {
        _stashExactHookFee(PID_A, 0);
        int128 hookDelta = harness.exposedTakeProtocolFeeOnAfterSwap(
            _key(), _swapParams(zeroForOne, exactIn ? int256(-1) : int256(1)), toBalanceDelta(amount0, amount1), PID_A
        );
        assertEq(hookDelta, 0, "zero hookFee => zero delta");
        assertEq(p1Manager.takeCount(), 0, "zero hookFee => no take");
    }

    /// @notice SETTLE-8 no-op trigger 2: treasury unset — returns 0, no manager call, even with a
    ///         positive stashed rate and a huge realized delta.
    /// @dev Ordering is load-bearing. `_computeProtocolFeeSplit` (the only real writer of the
    ///      stash) reads the LIVE treasury and carves nothing when it is unset, so the stash must
    ///      be primed while the treasury is still live and the treasury cleared afterwards. That
    ///      is also the only shape in which this no-op is reachable at all: a stash written under
    ///      a live treasury, settled after governance cleared it mid-flight. Stashing after the
    ///      clear would leave hookFee == 0 and the test would pass through no-op trigger 1
    ///      instead — vacuous for the property under test. The pre-take assertion below pins that.
    function testFuzz_take_noop_treasuryUnset(uint24 hookFee, int128 amount0, int128 amount1) public {
        hookFee = uint24(bound(hookFee, 1, MAX_REACHABLE_HOOK_FEE));

        _stashExactHookFee(PID_A, hookFee); // treasury still TREASURY from setUp: the split carves

        // governance.protocolFeeBps is still 0, so zeroing the treasury is permitted.
        p1Governance.setTreasury(address(0));
        assertEq(harness.readStash(PID_A), hookFee, "sanity: a nonzero rate is still stashed");

        int128 hookDelta = harness.exposedTakeProtocolFeeOnAfterSwap(
            _key(), _swapParams(true, -1), toBalanceDelta(amount0, amount1), PID_A
        );
        assertEq(hookDelta, 0, "unset treasury => zero delta");
        assertEq(p1Manager.takeCount(), 0, "unset treasury => no take");
    }

    /// @notice The split-side companion to the trigger above: with the treasury unset the split
    ///         refuses to carve in the first place, so the stash is 0 and the settle path has
    ///         nothing to forfeit. Together the two tests close the shape where a slice is
    ///         deducted from LPs and then taken by nobody.
    function testFuzz_split_noTreasury_carvesNothing(uint24 dynamicFee, uint16 protBps) public {
        protBps = uint16(bound(protBps, 1, MAX_PROTOCOL_FEE_BPS));
        p1Governance.setTreasury(address(0));

        harness.harnessSetProtocolFeeBps(protBps);
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(PID_A, dynamicFee);

        assertEq(lpFee, dynamicFee, "unset treasury => full dynamic fee stays with LPs");
        assertEq(harness.readStash(PID_A), 0, "unset treasury => nothing stashed");
    }

    /// @notice SETTLE-8 no-op trigger 3: dust — mag * hookFee < 1e6 rounds the take to 0 (floor,
    ///         FEE-5); returns 0 and performs no take instead of taking a phantom wei.
    function testFuzz_take_noop_dustRoundsToZero(uint24 hookFee, uint8 magSeed, bool zeroForOne) public {
        hookFee = uint24(bound(hookFee, 1, MAX_REACHABLE_HOOK_FEE));
        // Pick mag so that mag * hookFee < 1e6 strictly => floor == 0.
        uint256 maxDustMag = (PIPS_SCALE - 1) / uint256(hookFee);
        vm.assume(maxDustMag > 0);
        int128 mag = int128(int256(bound(uint256(magSeed), 1, maxDustMag)));

        _stashExactHookFee(PID_A, hookFee);
        // exactInput, zeroForOne => unspecified is currency1; put the dust there, junk on 0.
        int128 hookDelta = harness.exposedTakeProtocolFeeOnAfterSwap(
            _key(),
            _swapParams(zeroForOne, -1),
            zeroForOne ? toBalanceDelta(type(int128).max, mag) : toBalanceDelta(mag, type(int128).max),
            PID_A
        );
        assertEq(hookDelta, 0, "dust take rounds down to zero delta");
        assertEq(p1Manager.takeCount(), 0, "dust => no take call");
    }
}
