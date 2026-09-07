// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {BasePoolConfig} from "../lib/BasePoolConfig.sol";
import {PoolDeploymentBase} from "./PoolDeploymentBase.sol";

abstract contract PoolDeploymentBaseSim is PoolDeploymentBase, SimHookUtils {
    uint160 internal initialSqrtPriceX96;

    struct SmokeSwap {
        bool zeroForOne;
        int256 amount;
    }

    function _poolConfig() internal virtual returns (BasePoolConfig);
    function _setupLiquidity(uint160 sqrtPriceX96) internal virtual;

    function _smokeZeroForOneAmounts() internal pure virtual returns (int256 small, int256 medium, int256 large);
    function _smokeOneForZeroAmounts() internal pure virtual returns (int256 small, int256 medium, int256 large);

    function _jitLockTicks() internal pure virtual returns (int24 tickLower, int24 tickUpper);

    function _firstSwapAmount() internal pure virtual returns (int256) {
        (int256 small,,) = _smokeZeroForOneAmounts();
        return small;
    }

    function setUp() public virtual {
        poolCfg = _poolConfig();
        (, initialSqrtPriceX96) = setupSimHookAndPool(poolCfg, false);
        _setupLiquidity(initialSqrtPriceX96);
    }

    function test_firstSwap_pricesOffZeroCum() public {
        (, uint48 lastSwapTimestamp,,) = hook.poolData(poolId);
        assertEq(uint256(lastSwapTimestamp), 0, "fresh pool must start unswapped");

        int256 amt = _firstSwapAmount();
        (, Vm.Log[] memory logs) = swap(true, amt, false);

        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);
        assertEq(b.decayedCumPriceImpact, 0, "first swap must price off a zero accumulator");
        uint256 expected = FullMath.mulDiv(b.priceImpact, poolCfg.kPips(), 2e6);
        if (expected < b.effectiveMinFee) expected = b.effectiveMinFee;
        if (expected > poolCfg.maxFee()) expected = poolCfg.maxFee();
        assertEq(b.dynamicFeePips, expected, "first swap fee != fresh-push recompute");
    }

    function test_smokeSwapBattery_smallMediumLarge() public {
        (int256 zSmall, int256 zMed, int256 zLarge) = _smokeZeroForOneAmounts();
        (int256 oSmall, int256 oMed, int256 oLarge) = _smokeOneForZeroAmounts();
        int256[3] memory zsizes = [zSmall, zMed, zLarge];
        int256[3] memory osizes = [oSmall, oMed, oLarge];

        swap(true, zSmall, false);

        for (uint256 i = 0; i < zsizes.length; i++) {
            (, Vm.Log[] memory zlogs) = swap(true, zsizes[i], false);
            BeforeSwapEventData memory zb = getBeforeSwapEventData(zlogs);
            assertGe(zb.dynamicFeePips, poolCfg.minMinFee(), "z2o fee below minMinFee");
            assertLe(zb.dynamicFeePips, poolCfg.maxFee(), "z2o fee above maxFee");

            (, Vm.Log[] memory ologs) = swap(false, osizes[i], false);
            BeforeSwapEventData memory ob = getBeforeSwapEventData(ologs);
            assertGe(ob.dynamicFeePips, poolCfg.minMinFee(), "o2z fee below minMinFee");
            assertLe(ob.dynamicFeePips, poolCfg.maxFee(), "o2z fee above maxFee");
        }
    }

    /// @dev Asserts the dormant-pool floor for whichever shape this config has: flat when
    ///      minMinFee == maxMinFee, ramped to maxMinFee otherwise. Every config in
    ///      `test/lib/PoolConfigs.sol` is currently flat, so the ramped branch is exercised by
    ///      the dedicated ramp suites (`feature/MinFeeRampAnchor`, `fuzz/Phase1MinFeeRamp`)
    ///      rather than here.
    function test_dynamicFloor_flatOrDormant() public {
        (int256 small,,) = _smokeZeroForOneAmounts();
        swap(true, small, false);
        skip(poolCfg.timeDecayLength() + 1);

        (, Vm.Log[] memory logs) = swap(true, small, false);
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);

        if (poolCfg.maxMinFee() == poolCfg.minMinFee()) {
            assertEq(b.effectiveMinFee, poolCfg.minMinFee(), "flat-floor: eff == minMin == maxMin");
        } else {
            assertEq(b.effectiveMinFee, poolCfg.maxMinFee(), "dormant pool: eff == maxMinFee");
        }
    }

    function test_jitLock_blocksImmediateRemoval() public {
        if (poolCfg.jitLockBlocks() == 0) return;

        (int24 tl, int24 tu) = _jitLockTicks();
        vm.expectRevert();
        removeLiquidity(tl, tu, 1);
    }
}
