// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "./SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

library HookMath {
    /// @notice 1e6 = 100%. The unit for fees and price impact throughout the hook.
    uint256 internal constant PIPS_SCALE = 1e6;

    /// @notice Price impact between two sqrtPriceX96 values, in pips, capped at 100%.
    /// @dev Measured against the geometric mean of the two prices, not the starting price, so
    ///      the reading is direction-symmetric
    function calculatePriceImpactCapped(
        uint160 sqrtPriceX96Before,
        uint160 sqrtPriceX96After
    ) internal pure returns (uint256 priceImpactPips) {
        // defensive: call sites source both from slot0 of an initialized pool
        if (sqrtPriceX96Before == 0 || sqrtPriceX96After == 0) return 0;

        // divide by Q96 during squaring to prevent overflow for extreme prices
        uint256 priceX96Before = FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, FixedPoint96.Q96);
        uint256 priceX96After = FullMath.mulDiv(sqrtPriceX96After, sqrtPriceX96After, FixedPoint96.Q96);

        // sqrt(priceBefore * priceAfter), same X96 scale
        uint256 priceX96Geo = FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96After, FixedPoint96.Q96);

        uint256 priceChangeX96 =
            priceX96After >= priceX96Before ? priceX96After - priceX96Before : priceX96Before - priceX96After;

        // Assumes both prices >= MIN_USABLE_SQRT_PRICE (enforced at init); below it this
        // branch swallows every pair — KI-14. Also guards the division against a zero mean.
        if (priceChangeX96 >= priceX96Geo) {
            return PIPS_SCALE;
        }

        priceImpactPips = FullMath.mulDiv(priceChangeX96, PIPS_SCALE, priceX96Geo);
    }

    /// @notice Saturating addition for int256. Clamps to [int256.min+1, int256.max] (abs-safe).
    function addSaturating(int256 a, int256 b) internal pure returns (int256) {
        int256 c;
        unchecked {
            c = a + b;
        }
        if (a > 0 && b > 0 && c <= 0) return type(int256).max;
        if (a < 0 && b < 0 && c >= 0) return type(int256).min + 1;
        if (c < type(int256).min + 1) return type(int256).min + 1;
        return c;
    }

    /// @notice Saturating addition for uint256. Clamps to type(uint256).max.
    function addSaturatingUint(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > type(uint256).max - b) return type(uint256).max;
        return a + b;
    }

    /// @notice Linearly decay a cumulative signed impact toward 0 over `timeDecayLength` seconds.
    /// @dev Applied once per swap against the inter-swap gap, so decay is credited for IDLE
    ///      time and does not compose over a span. Intended — KI-7.
    function decayCumByTime(
        int256 cumValue,
        uint256 timeSinceLastSwap,
        uint256 timeDecayLength
    ) internal pure returns (int256 decayedValue) {
        if (cumValue == 0 || timeDecayLength == 0) return 0;
        if (timeSinceLastSwap >= timeDecayLength) return 0;

        uint256 timeLeft = timeDecayLength - timeSinceLastSwap;
        uint256 decayFactor = FullMath.mulDiv(timeLeft, PIPS_SCALE, timeDecayLength);

        // sign handled separately: FullMath.mulDiv is uint256-only
        uint256 absCumValue = SignedMath.abs(cumValue);
        uint256 decayedAbs = FullMath.mulDiv(absCumValue, decayFactor, PIPS_SCALE);

        // decayFactor <= PIPS_SCALE, so the cast can never clamp
        return cumValue < 0 ? -(SafeCast.toInt256Capped(decayedAbs)) : SafeCast.toInt256Capped(decayedAbs);
    }

    /// @notice Linear ramp from minMinFee → maxMinFee keyed off inter-swap time.
    /// @dev Driven off `rampAnchor`, not the raw last-swap gap, and shares `timeDecayLength`
    ///      with the accumulator decay — floor and decay run on one clock.
    function calculateEffectiveMinFee(
        uint24 minMinFee,
        uint24 maxMinFee,
        uint256 timeSinceLastSwap,
        uint256 timeDecayLength
    ) internal pure returns (uint24 effectiveMinFee) {
        if (minMinFee == maxMinFee) return minMinFee;
        if (timeSinceLastSwap == 0) return minMinFee;
        if (timeSinceLastSwap >= timeDecayLength) return maxMinFee;

        uint24 spread = maxMinFee - minMinFee;
        uint256 delta = FullMath.mulDiv(uint256(spread), timeSinceLastSwap, timeDecayLength);
        return minMinFee + SafeCast.toUint24Capped(delta);
    }
}
