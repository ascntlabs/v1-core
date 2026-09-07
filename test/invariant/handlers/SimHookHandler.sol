// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice StdInvariant handler driving bounded, sequence-safe actions against a configured
///         SimHook pool. Phase-0 scaffolding: the action surface + ghost variables live here so
///         the Phase-4 invariants bolt straight on. Every action try/catches expected reverts
///         (JIT lock, price limit, insufficient liquidity) so a single failed op never halts the
///         fuzz sequence. ERC-20 pool only (no native msg.value plumbing) for this phase.
contract SimHookHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable liqRouter;
    PoolKey internal key;
    PoolId internal poolId;

    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    // ---- ghost variables (read by invariants / afterInvariant) ----
    uint256 public swapCount;
    uint256 public swapZeroForOneCount;
    uint256 public warpCount;
    uint256 public addCount;
    uint256 public removeCount;
    uint256 public revertCount;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _liqRouter,
        PoolKey memory _key,
        PoolId _poolId,
        int24 _tickLower,
        int24 _tickUpper
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        liqRouter = _liqRouter;
        key = _key;
        poolId = _poolId;
        tickLower = _tickLower;
        tickUpper = _tickUpper;

        _approve(_key.currency0);
        _approve(_key.currency1);
    }

    function _approve(Currency c) internal {
        address t = Currency.unwrap(c);
        if (t == address(0)) return; // native side needs no approval
        MockERC20(t).approve(address(swapRouter), type(uint256).max);
        MockERC20(t).approve(address(liqRouter), type(uint256).max);
    }

    function swap(uint256 amountSeed, bool zeroForOne) external {
        uint256 amount = _bound(amountSeed, 1e3, 1e12);
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount), // exact input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        try swapRouter.swap(key, p, s, "") {
            swapCount++;
            if (zeroForOne) swapZeroForOneCount++;
        } catch {
            revertCount++;
        }
    }

    function advanceTime(uint256 secsSeed) external {
        uint256 secs = _bound(secsSeed, 1, 2 hours);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + _bound(secsSeed, 1, 10));
        warpCount++;
    }

    function addLiquidity(uint256 amountSeed) external {
        uint256 amount0 = _bound(amountSeed, 1e6, 1e15);
        uint160 sl = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 su = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sl, su, amount0);
        if (liq == 0) return;
        try liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        ) {
            addCount++;
        } catch {
            revertCount++;
        }
    }

    function removeLiquidity(uint256 amountSeed) external {
        (uint128 posLiq,,) = manager.getPositionInfo(poolId, address(liqRouter), tickLower, tickUpper, bytes32(0));
        if (posLiq == 0) return;
        uint256 toRemove = _bound(amountSeed, 1, posLiq);
        try liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(toRemove),
                salt: bytes32(0)
            }),
            ""
        ) {
            removeCount++;
        } catch {
            revertCount++;
        }
    }
}
