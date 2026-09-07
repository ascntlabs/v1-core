// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {Phase3HookTestBase} from "./Phase3HookTestBase.sol";
import {ImpactOracle} from "../utils/ImpactOracle.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @notice phase3-differential — XSUB-4: protocolFeeBps alters the cumPriceImpact
///         trajectory (governance parameter x fee-state-machine coupling).
///
/// beforeSwap returns lpFee = dynamicFee - hookFee as the ACTUAL v4 fee override, so at a
/// higher protocolFeeBps the real swap is charged LESS in-swap, moves the price MORE, and
/// afterSwap records a LARGER realized impact for the identical input. Two identical pools
/// fed identical swap streams therefore accumulate DIFFERENT cumPriceImpact purely because
/// of the governance fee rate.
///
/// Method: one pool, two runs from a byte-identical pre-state (vm.snapshotState /
/// revertToState + explicit re-warp), bps=0 vs bps=2000 (cap). Realized impact per swap is
/// recomputed INDEPENDENTLY from test-captured slot0 prices (ImpactOracle, per XSUB-8) so
/// the divergence is attributed to the realized price move itself, not to the hook's
/// bookkeeping. This documents/quantifies an intended-but-undocumented coupling — it is
/// not a bug demonstration.
contract Phase3_Xsub4_BpsCouplingTest is Phase3HookTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant N = 4;
    // Large swaps so the dynamic fee saturates at maxFee (1%) from swap 2 on: the lpFee
    // difference between runs is then a full 20% of 10_000 pips = 2_000 pips of in-swap
    // fee, making the realized-impact divergence far exceed integer-pip rounding.
    uint256 internal constant AMT = 1e11;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        // wider range than the other suites so the 4 x 1e11 one-directional stream stays
        // inside range (capacity ~1e12 per side)
        addLiquidity(-3000, 3000, 1e12, initSqrtP, false);
        governance.setTreasury(address(0xBEEF));
    }

    function _runStream() internal returns (int256[] memory cums, uint256[] memory realized) {
        cums = new int256[](N);
        realized = new uint256[](N);
        // Explicit timeline rather than `vm.warp(block.timestamp + 60)`: on the via-IR optimized
        // profile `TIMESTAMP` is transaction-invariant to the optimizer, so a read inside a loop
        // that warps gets hoisted out — and `vm.warp` mutates it where the optimizer cannot see.
        // The stale read collapses every iteration onto one timestamp and silently removes the
        // decay this stream depends on. `vm.getBlockTimestamp()` is an external staticcall and
        // cannot be folded.
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i = 0; i < N; i++) {
            (uint160 sqrtBefore,,,) = manager.getSlot0(poolId);
            swap(true, -int256(AMT), false);
            realized[i] = ImpactOracle.realizedImpactPips(manager, poolId, sqrtBefore);
            (,,, int256 c) = hook.poolData(poolId);
            cums[i] = c;
            t += 60;
            vm.warp(t);
        }
    }

    function test_xsub4_cumTrajectoryDivergesWithBps() public {
        // vm.getBlockTimestamp(): opaque read — the via-IR optimizer would otherwise sink the
        // TIMESTAMP read past _runStream's vm.warp, so vm.warp(t0) below must restore the real t0.
        uint256 t0 = vm.getBlockTimestamp();
        uint256 snap = vm.snapshotState();

        // run A: bps = 0 (constructor default; nothing set)
        (int256[] memory cumLo, uint256[] memory realizedLo) = _runStream();

        // byte-identical restart (snapshotState does not cover block env, hence the warp)
        vm.revertToState(snap);
        vm.warp(t0);
        governance.setProtocolFeeBps(2000); // 20% cap
        (int256[] memory cumHi, uint256[] memory realizedHi) = _runStream();

        for (uint256 i = 0; i < N; i++) {
            // divergence direction: higher bps -> smaller lpFee -> larger realized move.
            // (Non-strict per swap: swap 1 prices near the floor where the lpFee gap is
            // small and can floor-round away; from swap 2 the gap is 2_000 pips.)
            assertGe(realizedHi[i], realizedLo[i], "XSUB-4: higher bps must never shrink the realized impact");
            // zeroForOne stream: cum is negative and must be at least as negative under
            // the higher fee rate at every step of the trajectory
            assertLe(cumHi[i], cumLo[i], "XSUB-4: cum trajectory direction");
        }

        // the coupling itself: identical swap streams, different accumulators — strictly
        assertLt(cumHi[N - 1], cumLo[N - 1], "XSUB-4: cumPriceImpact must diverge under a different protocolFeeBps");

        // quantification for the audit notes
        uint256 divergencePips = SignedMath.abs(cumHi[N - 1] - cumLo[N - 1]);
        console.log("XSUB-4 |cum(bps=2000)| - |cum(bps=0)| after 4 swaps (pips):", divergencePips);
        console.log("XSUB-4 |cum(bps=0)| (pips):", SignedMath.abs(cumLo[N - 1]));
    }
}
