// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {HookMath} from "../../src/lib/HookMath.sol";

/// @notice KI-16 (Vulsight appendix): `swapDelta - hookDelta` recomposition headroom.
///
///         The reviewers' point was that `_takeProtocolFeeOnAfterSwap` proves the treasury take
///         fits `int128` on its own, but not that v4's later recomposition still has headroom at
///         the extreme. This contract pins the arithmetic that closes it, so a future change to
///         the take's basis or cap fails here rather than in production:
///
///           - the take is levied on the UNSPECIFIED currency, so the recomposition's worst case
///             is an exact-output swap carrying `-in - take`;
///           - `hookFee <= MAX_PROTOCOL_FEE_BPS (20%) x dynamicFee <= 20% x MAX_LP_FEE`, so
///             `take <= mag / 5` for any magnitude the hook can ever see;
///           - therefore `mag + take <= 1.2 x mag`, and overflow needs `mag > 2^127 / 1.2`.
///
///         That threshold is ~1.4e38 raw units — beyond any plausible token supply, which is why
///         KI-16 records this as unreachable rather than fixing anything. Were it ever reached,
///         v4's `toBalanceDelta` uses checked casts, so the failure is a clean revert of the
///         swap, not a corrupted delta.
///
///         Scope: this pins the BOUND, not a live settlement at 2^127 — minting a token to that
///         supply to exercise a path the bound already excludes buys nothing. If the settlement
///         path is ever revised, replace this with the end-to-end version KI-16 calls for.
contract SettlementBoundaryTest is Test {
    /// @dev mirrors `AscntGovernance.MAX_PROTOCOL_FEE_BPS`
    uint16 internal constant MAX_PROTOCOL_FEE_BPS = 2_000;

    /// @dev the largest take the hook can compute on a magnitude, over the whole reachable
    ///      (dynamicFee, bps) lattice
    function _maxTake(uint256 mag) internal pure returns (uint256) {
        uint24 maxDynamicFee = LPFeeLibrary.MAX_LP_FEE - 1; // v4's own ceiling; the hook's 50% maxFee cap is tighter still
        uint24 hookFee = uint24(uint256(maxDynamicFee) * MAX_PROTOCOL_FEE_BPS / 10_000);
        return FullMath.mulDiv(mag, hookFee, HookMath.PIPS_SCALE);
    }

    /// @notice The 20% cap holds as a hard ratio at every magnitude, so the recomposition can
    ///         never carry more than 1.2x the swap side it is built from.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_ki16_takeNeverExceedsAFifthOfTheMagnitude(uint256 magSeed) public pure {
        uint256 mag = bound(magSeed, 0, uint256(uint128(type(int128).max)));
        uint256 take = _maxTake(mag);

        assertLe(take * 5, mag + 5, "KI-16: the take must stay within a fifth of the magnitude");
    }

    /// @notice Every magnitude below the documented threshold recomposes inside `int128`; the
    ///         threshold itself is the first point that can overflow.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_ki16_recompositionFitsBelowTheDocumentedThreshold(uint256 magSeed) public pure {
        uint256 ceiling = uint256(uint128(type(int128).max)) * 10 / 12; // 2^127 / 1.2
        uint256 mag = bound(magSeed, 0, ceiling);

        uint256 recomposed = mag + _maxTake(mag);

        assertLe(recomposed, uint256(uint128(type(int128).max)), "KI-16: recomposition must fit int128");
    }

    /// @notice The documented threshold, stated as a number so a change to the cap moves it.
    function test_ki16_thresholdIsBeyondAnyPlausibleSupply() public pure {
        uint256 ceiling = uint256(uint128(type(int128).max)) * 10 / 12;

        // ~1.4e38 raw units: more than 1e20 whole tokens even at 18 decimals
        assertGt(ceiling, 1e38, "KI-16: the overflow threshold must exceed 1e38 raw units");
        assertGt(ceiling / 1e18, 1e20, "KI-16: and 1e20 whole tokens at 18 decimals");
    }
}
