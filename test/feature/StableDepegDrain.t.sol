// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {SimHook} from "../../src/SimHook.sol";

/// @dev ECONOMIC CHARACTERIZATION (not a defense proof) of SimHook under a stable-pair depeg:
///      token1 (USDT) depegs and an attacker dumps it for the pool's token0 (USDC). No AMM fee
///      prevents a depegged asset being sold into a pool — the curve quotes a price and the pool
///      is a willing buyer at it — so the dynamic fee is a compensation mechanism here, not a peg
///      guard. These tests measure what it actually retains for LPs across one-shot vs chunked
///      drains and fast vs slow decay. NOTE: exact-input drain fees accrue in the INPUT token
///      (the depegging USDT); the good token (USDC) leaves the pool regardless of fee level.
contract StableDepegDrainTest is SimHookUtils {
    using StateLibrary for IPoolManager;

    uint160 internal _sp;
    int24 internal constant EDGE = 20000; // single wide position [-EDGE, EDGE]

    struct DrainResult {
        uint256 maxUSDC; // USDC in the pool at the depeg moment (max drainable)
        uint256 attUSDC; // USDC the drainer walked away with
        uint256 attUSDT; // USDT the drainer paid in (incl. fees)
        uint256 lpFeesUSDT; // fees accrued to the wide LP position (input token = USDT)
        uint256 chunks; // swaps executed
    }

    function _t0() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency0));
    }

    function _t1() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency1));
    }

    function _mkTrader(string memory name) internal returns (address a) {
        a = makeAddr(name);
        vm.deal(a, 1_000 ether);
        _t0().mint(a, 100_000_000e6);
        _t1().mint(a, 100_000_000e6);
        vm.startPrank(a);
        _t0().approve(address(swapRouter), type(uint256).max);
        _t1().approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Fresh USDC/USDT pool (peg tick 0), one wide 1M-USDC-scale position, warmed up.
    ///      jitLockBlocks = 0 — the lock is not the subject here.
    function _buildDrainPool(uint24 maxFee, uint256 decayLen) internal returns (uint256 lpLiq) {
        address hookAddr = deployCoreAndHookCustomDecimals("SimHook.sol", "USDC", "USDT", 6, 6, false);
        hook = SimHook(hookAddr);
        (, _sp) = deployPool(IHooks(hookAddr), 0, 1, false);
        hook.configurePool(poolId, 10, 10, maxFee, decayLen, 0, 2e6, 1e6);
        LiquidityValues memory lv = addLiquidity(-EDGE, EDGE, 1_000_000e6, _sp, false);
        lpLiq = uint256(lv.liquidityDelta);
        swap(false, -100e6, false); // warmup swap (normal pre-depeg flow)
    }

    /// @param maxFee    per-pool fee ceiling (pips)
    /// @param decayLen  timeDecayLength for the pool (seconds)
    /// @param oneShot   drain in a single price-limited swap vs 40k chunks
    /// @param waitSecs  time warped between chunks (iterative only; 0 = fast successive)
    function _runDepegDrain(
        uint24 maxFee,
        uint256 decayLen,
        bool oneShot,
        uint256 waitSecs
    ) internal returns (DrainResult memory r) {
        uint256 lpLiq = _buildDrainPool(maxFee, decayLen);
        address att = _mkTrader("drainer");

        r.maxUSDC = _t0().balanceOf(address(manager));
        uint256 usdcBefore = _t0().balanceOf(att);
        uint256 usdtBefore = _t1().balanceOf(att);
        (, uint256 fg1Before) = StateLibrary.getFeeGrowthGlobals(manager, poolId);

        uint160 edge = TickMath.getSqrtPriceAtTick(EDGE); // drain toward the top of the liquidity
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        if (oneShot) {
            vm.startPrank(att);
            swapRouter.swap(
                key,
                SwapParams({zeroForOne: false, amountSpecified: -100_000_000e6, sqrtPriceLimitX96: edge}),
                ts,
                ZERO_BYTES
            );
            vm.stopPrank();
            r.chunks = 1;
        } else {
            for (uint256 i = 0; i < 300; i++) {
                if (_t0().balanceOf(address(manager)) <= r.maxUSDC / 100) break; // <=1% USDC left
                vm.startPrank(att);
                swapRouter.swap(
                    key,
                    SwapParams({zeroForOne: false, amountSpecified: -40_000e6, sqrtPriceLimitX96: edge}),
                    ts,
                    ZERO_BYTES
                );
                vm.stopPrank();
                r.chunks++;
                if (waitSecs > 0) vm.warp(block.timestamp + waitSecs);
            }
        }

        r.attUSDC = _t0().balanceOf(att) - usdcBefore;
        r.attUSDT = usdtBefore - _t1().balanceOf(att);
        (, uint256 fg1After) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
        r.lpFeesUSDT = FullMath.mulDiv(fg1After - fg1Before, lpLiq, 1 << 128); // fees to the single wide position
    }

    function _logDrain(string memory label, DrainResult memory r) internal {
        emit log(label);
        emit log_named_uint("  max drainable USDC (6dp)", r.maxUSDC);
        emit log_named_uint("  drainer keeps USDC", r.attUSDC);
        emit log_named_uint("  drainer keeps (bps of max)", r.maxUSDC == 0 ? 0 : r.attUSDC * 10_000 / r.maxUSDC);
        emit log_named_uint("  drainer paid USDT (incl. fees)", r.attUSDT);
        emit log_named_uint("  LP fees retained (USDT, 6dp)", r.lpFeesUSDT);
        emit log_named_uint("  LP fees (bps of drained USDC)", r.maxUSDC == 0 ? 0 : r.lpFeesUSDT * 10_000 / r.maxUSDC);
        emit log_named_uint("  chunks", r.chunks);
    }

    // ------ arm (i): high maxFee (50%) isolation — how do drain strategies rank on fees paid? ------
    function test_depegDrain_strategies_highMaxFee() public {
        // Array (single memory pointer) keeps this function inside the Yul stack budget.
        DrainResult[4] memory rs;
        // S0: one-shot reference — the whole drain priced at its full cumulative impact.
        rs[0] = _runDepegDrain(500_000, 15 minutes, true, 0);
        // S1: chunks + wait out the 15min decay — each chunk reprices as fresh (games the decay).
        rs[1] = _runDepegDrain(500_000, 15 minutes, false, 15 minutes);
        // S2: chunks, same timestamp — cum builds, no decay gaming.
        rs[2] = _runDepegDrain(500_000, 15 minutes, false, 0);
        // S3: chunks + 15min waits against a 1-day decay (the config ceiling) — too slow to game.
        rs[3] = _runDepegDrain(500_000, 1 days, false, 15 minutes);

        _logDrain("[S0] one-shot, decay=15min", rs[0]);
        _logDrain("[S1] chunks, decay=15min, wait 15min (games decay)", rs[1]);
        _logDrain("[S2] chunks, decay=15min, no wait (fast successive)", rs[2]);
        _logDrain("[S3] chunks, decay=1d, wait 15min (slow decay)", rs[3]);

        // (a) waiting out a fast decay lets the drainer reprice each chunk as fresh — he pays
        //     materially less in fees than one-shot or fast-successive chunking.
        assertLt(rs[1].lpFeesUSDT, rs[0].lpFeesUSDT, "decay-gamed chunks pay less than one-shot");
        assertLt(rs[1].lpFeesUSDT, rs[2].lpFeesUSDT, "decay-gamed chunks pay less than fast-successive chunks");
        // (b) a slow (1d) decay closes the gaming window: LPs retain far more fee than fast (15min) decay.
        assertGt(rs[3].lpFeesUSDT, rs[1].lpFeesUSDT, "slow decay retains more LP fees than gamed fast decay");
        // Characterization: the fee never stops the good token from leaving — drainer keeps ~all USDC.
        assertGt(rs[1].attUSDC * 10_000 / rs[1].maxUSDC, 9_500, "fee does not retain the good token itself");
    }

    // ------ arm (ii): a 1% fee ceiling (the StablePairPoolConfig shape) ------
    function test_depegDrain_onePercentCeiling_retentionBounded() public {
        // StablePairPoolConfig shape: maxFee 10_000 (1%), decay 1h. Drainer games the decay (1h waits).
        DrainResult memory p0 = _runDepegDrain(10_000, 1 hours, true, 0);
        DrainResult memory p1 = _runDepegDrain(10_000, 1 hours, false, 1 hours);

        _logDrain("[P0] production 1% ceiling, one-shot", p0);
        _logDrain("[P1] production 1% ceiling, chunks + 1h waits", p1);

        // With a 1% ceiling the drainer keeps ~all the pool's USDC and LP fee retention is bounded
        // by that ceiling — as it is for any capped fee schedule. Decay speed shifts only the size
        // of the (capped) take, not whether the good token leaves.
        assertGt(p0.attUSDC * 10_000 / p0.maxUSDC, 9_500, "one-shot drainer keeps >95% of the pool's USDC");
        assertGt(p1.attUSDC * 10_000 / p1.maxUSDC, 9_500, "chunked drainer keeps >95% of the pool's USDC");
        // Ceiling binds: fees paid are <= ~1% of the USDT notional pushed through the pool.
        assertLe(p0.lpFeesUSDT, p0.attUSDT / 90, "1% ceiling caps one-shot fee retention near 1% of notional");
        assertLe(p1.lpFeesUSDT, p1.attUSDT / 90, "1% ceiling caps chunked fee retention near 1% of notional");
    }
}
