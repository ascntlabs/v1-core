// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice EVENT-independent — but deliberately NOT algorithm-independent — transcription of the
///         cumulative-impact time decay, the saturating add and the dynamic min-fee ramp, used by
///         the XSUB-1 composition oracle.
///
///         What "independent" means here, precisely:
///           - it does not import `src/lib/HookMath` and never reads the hook's events or storage,
///             so composition/ramp assertions cannot be satisfied by feeding the hook's own
///             OUTPUTS back to it (the circularity XSUB-8 names);
///           - `decay()` is, however, a line-for-line re-transcription of
///             `HookMath.decayCumByTime` — same early returns, same two-step mulDiv truncation
///             points, same sign handling. The two-step pips form (factor first, then apply) is
///             kept ON PURPOSE: a closed-form `cum * (L - dt) / L` differs by up to one pip of
///             truncation, which would force tolerance bands onto every exact-equality composition
///             assertion in the phase.
///
///         LIMITATION (stated so nobody over-reads the oracle): because the algorithm is shared,
///         a divergence between the DOCUMENTED decay spec and the implementation would be
///         invisible to every assertion built on this library. What these oracles do falsify:
///         lost/duplicated/mis-signed legs, a skipped or double-applied decay step, wrong-pool or
///         stale-snapshot composition, and wrapping past the saturation clamp (verified: feeding
///         a wrong `timeDecayLength` fails the suite). Spec-vs-implementation conformance of the
///         decay FORMULA itself is phase 1's job (`test/fuzz/Phase1HookMathLib.t.sol`, the
///         `testFuzz_decay_*` family), not this file's.
library Phase5Decay {
    uint256 internal constant PIPS = 1e6;

    /// @notice Linear decay of the signed accumulator toward 0 over `timeDecayLength` seconds.
    function decay(int256 cumValue, uint256 timeSinceLastSwap, uint256 timeDecayLength) internal pure returns (int256) {
        if (cumValue == 0 || timeDecayLength == 0) return 0;
        if (timeSinceLastSwap >= timeDecayLength) return 0;

        uint256 factor = FullMath.mulDiv(timeDecayLength - timeSinceLastSwap, PIPS, timeDecayLength);
        uint256 abs = cumValue < 0 ? uint256(-cumValue) : uint256(cumValue);
        uint256 decayed = FullMath.mulDiv(abs, factor, PIPS);
        return cumValue < 0 ? -int256(decayed) : int256(decayed);
    }

    /// @notice Event-independent transcription of the SATURATING add specified for the
    ///         accumulator: clamps to `[int256.min + 1, int256.max]` instead of wrapping.
    /// @dev `b` here is always a directional pips value, i.e. `|b| <= 1e6`, so the bound
    ///      arithmetic below cannot itself overflow.
    function addSat(int256 a, int256 b) internal pure returns (int256) {
        if (b > 0 && a > type(int256).max - b) return type(int256).max;
        if (b < 0 && a < type(int256).min + 1 - b) return type(int256).min + 1;
        return a + b;
    }

    /// @notice Event-independent transcription of the min-fee ramp: linear from `minMinFee` at
    ///         `timeSinceLastSwap == 0` to `maxMinFee` at `timeSinceLastSwap >= timeDecayLength`
    ///         (same truncation points as the implementation — see the header limitation).
    function effectiveMinFee(
        uint24 minMinFee,
        uint24 maxMinFee,
        uint256 timeSinceLastSwap,
        uint256 timeDecayLength
    ) internal pure returns (uint24) {
        if (minMinFee == maxMinFee) return minMinFee;
        if (timeSinceLastSwap == 0) return minMinFee;
        if (timeSinceLastSwap >= timeDecayLength) return maxMinFee;

        uint256 delta = FullMath.mulDiv(uint256(maxMinFee - minMinFee), timeSinceLastSwap, timeDecayLength);
        return minMinFee + uint24(delta); // delta < spread < 2^24, cast cannot truncate
    }
}
