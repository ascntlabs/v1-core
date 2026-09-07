// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Independent price-impact oracle for the accumulator/fee invariants. Deliberately does
///         NOT import `src/lib/HookMath` — it is a separate transcription of the spec formula so
///         that:
///           - FEE-4 can differentially cross-check `HookMath.calculatePriceImpactCapped` against
///             it across the input domain (they must agree; divergence = a HookMath regression), and
///           - ACC-1 / XSUB-4 can recompute REALIZED impact from a `sqrtBefore` the TEST captured
///             from `slot0` itself (not the hook's emitted `priceImpact` or its stored snapshot),
///             so the `cum == decay(prev) + directional(realized)` recurrence cannot be satisfied
///             by construction.
///
///         Formula (matches the spec): price = (sqrtP^2)/Q96; impact = |Δprice| / geoMean, where
///         geoMean = (sqrtBefore * sqrtAfter)/Q96 = sqrt(priceBefore * priceAfter), in pips,
///         capped at 100% (1e6). The `>=` branch returns the cap, mirroring HookMath.
library ImpactOracle {
    using StateLibrary for IPoolManager;

    uint256 internal constant PIPS = 1e6;

    /// @notice Price impact in pips between two sqrtPriceX96 values, capped at 100%.
    function priceImpactPips(uint160 sqrtBefore, uint160 sqrtAfter) internal pure returns (uint256) {
        if (sqrtBefore == 0 || sqrtAfter == 0) return 0;
        uint256 pBefore = FullMath.mulDiv(sqrtBefore, sqrtBefore, FixedPoint96.Q96);
        uint256 pAfter = FullMath.mulDiv(sqrtAfter, sqrtAfter, FixedPoint96.Q96);
        uint256 pGeo = FullMath.mulDiv(sqrtBefore, sqrtAfter, FixedPoint96.Q96);
        uint256 change = pAfter >= pBefore ? pAfter - pBefore : pBefore - pAfter;
        if (change >= pGeo) return PIPS;
        return FullMath.mulDiv(change, PIPS, pGeo);
    }

    /// @notice Signed directional impact: negative for zeroForOne (price falls), positive otherwise.
    ///         Mirrors SimHook's directional convention.
    function directional(bool zeroForOne, uint256 pips) internal pure returns (int256) {
        return zeroForOne ? -int256(pips) : int256(pips);
    }

    /// @notice Realized impact between a test-captured `sqrtBefore` and the live `slot0` price.
    function realizedImpactPips(
        IPoolManager manager,
        PoolId poolId,
        uint160 sqrtBefore
    ) internal view returns (uint256) {
        (uint160 sqrtAfter,,,) = manager.getSlot0(poolId);
        return priceImpactPips(sqrtBefore, sqrtAfter);
    }
}
