// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

/// @notice Phase-3 (differential) shadow transcription of the accumulator recurrence spec:
///         decay-toward-zero over `timeDecayLength` plus abs-safe saturating signed addition.
///
///         Deliberately does NOT import `src/lib/HookMath.sol` — this is an independent
///         re-derivation from the spec (two floor divisions for the decay: factor then
///         magnitude, matching the documented rounding-toward-zero behavior), so the ACC-1
///         recurrence check `cum' == decay(cum, dt) + directional(realized)` cannot be
///         satisfied by construction. Realized impact comes from `test/utils/ImpactOracle.sol`
///         (slot0-based, also HookMath-free), per the XSUB-8 enabler.
library Phase3ShadowMath {
    uint256 internal constant PIPS = 1e6;

    /// @notice Linear decay of `cum` toward zero: zero at/after the horizon `L`, identity at
    ///         t==0, magnitude floor-rounded toward zero (factor and magnitude each floored,
    ///         mirroring the spec's two-step fixed-point evaluation).
    function decay(int256 cum, uint256 t, uint256 L) internal pure returns (int256) {
        if (cum == 0 || L == 0) return 0;
        if (t >= L) return 0;

        uint256 factor = FullMath.mulDiv(L - t, PIPS, L);
        uint256 decayedAbs = FullMath.mulDiv(SignedMath.abs(cum), factor, PIPS);

        // Spec caps the magnitude at int256.max instead of reverting (unreachable for
        // pip-scale values; kept for domain completeness).
        if (decayedAbs > uint256(type(int256).max)) decayedAbs = uint256(type(int256).max);
        return cum < 0 ? -int256(decayedAbs) : int256(decayedAbs);
    }

    /// @notice Saturating signed addition clamped to [int256.min + 1, int256.max] so every
    ///         result has a representable absolute value.
    function addSat(int256 a, int256 b) internal pure returns (int256) {
        int256 c;
        unchecked {
            c = a + b;
        }
        if (a > 0 && b > 0 && c <= 0) return type(int256).max;
        if (a < 0 && b < 0 && c >= 0) return type(int256).min + 1;
        if (c < type(int256).min + 1) return type(int256).min + 1;
        return c;
    }
}
