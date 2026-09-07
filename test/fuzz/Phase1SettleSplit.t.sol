// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Phase1FuzzBase} from "./Phase1Helpers.sol";

/// @notice Phase-1 stateless fuzz over `AscntBaseHook._computeProtocolFeeSplit` and the
///         per-pool transient hookFee stash.
///
/// Covers: SETTLE-1 (critical — lpFee = dynamicFee - hookFee never underflows for reachable
///         protBps), SETTLE-2 (split conserves fee exactly), SETTLE-18 (stash round-trips as a
///         clean uint24 word, per-pool isolated), FEE-5 (split rounds DOWN; remainder pip lands
///         in lpFee).
///
/// Rounding direction: `hookFee = floor(dynamicFee * protBps / 10000)` (FullMath.mulDiv floors).
/// Rounding DOWN is required here — it biases the indivisible remainder pip to the LP side
/// (lpFee = dynamicFee - floor(...)), never to treasury, and it is what makes hookFee <= dynamicFee
/// hold with no underflow for all protBps <= 10000.
contract Phase1SettleSplitFuzz is Phase1FuzzBase {
    // ------------------------------------------------------------------
    // SETTLE-1 + SETTLE-2 — reachable domain: protBps in [0, 2000]
    // ------------------------------------------------------------------

    /// @notice SETTLE-1/SETTLE-2: for every dynamicFee in [0, uint24.max] and every REACHABLE
    ///         protBps in [0, 2000] (governance cap), the split never reverts, hookFee <= 20% of
    ///         dynamicFee (so the uint24 subtraction cannot underflow), and
    ///         lpFee + stashedHookFee == dynamicFee exactly (conservation).
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: dev.fuzz.runs = 1000
    function testFuzz_split_reachableDomain_noUnderflow_conserves(uint24 dynamicFee, uint16 protBps) public {
        protBps = uint16(bound(protBps, 0, MAX_PROTOCOL_FEE_BPS));

        harness.harnessSetProtocolFeeBps(protBps);
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(PID_A, dynamicFee); // must not revert
        uint24 hookFee = harness.readStash(PID_A);

        // SETTLE-1: no underflow => hookFee <= dynamicFee, with the 20% envelope.
        assertLe(hookFee, dynamicFee, "hookFee must never exceed dynamicFee");
        assertLe(uint256(hookFee), uint256(dynamicFee) / 5, "hookFee bounded by 20% of dynamicFee");
        if (dynamicFee > 0 && protBps > 0) {
            assertLt(hookFee, dynamicFee, "hookFee strictly < dynamicFee when dynamicFee > 0");
        }

        // SETTLE-2: exact conservation — the split neither creates nor destroys fee.
        assertEq(uint256(lpFee) + uint256(hookFee), uint256(dynamicFee), "lpFee + hookFee == dynamicFee");

        // FEE-5 (split site): hookFee is the exact FLOOR of the proportional share; the
        // sub-1-pip remainder lands in lpFee (bias to LPs, never to treasury). Products fit
        // uint256 trivially (dynamicFee < 2^24, protBps < 2^16), so plain integer division is
        // an independent floor oracle.
        uint256 floorShare = (uint256(dynamicFee) * uint256(protBps)) / BPS_SCALE;
        assertEq(uint256(hookFee), floorShare, "hookFee == floor(dynamicFee*protBps/10000)");
        uint256 remainder = (uint256(dynamicFee) * uint256(protBps)) % BPS_SCALE;
        // floor error < 1 pip per split by construction; lpFee absorbs it.
        assertLt(remainder, BPS_SCALE, "floor error strictly under one pip-equivalent");
    }

    /// @notice SETTLE-2 boundary lattice: dynamicFee {0, 1, MAX_LP_FEE, uint24.max} x
    ///         protBps {0, 1, 2000} — exact conservation and floor at every corner.
    function test_split_boundaryLattice_conserves() public {
        uint24[4] memory fees = [uint24(0), uint24(1), MAX_LP_FEE, type(uint24).max];
        uint16[3] memory bpss = [uint16(0), uint16(1), MAX_PROTOCOL_FEE_BPS];

        for (uint256 i = 0; i < fees.length; i++) {
            for (uint256 j = 0; j < bpss.length; j++) {
                harness.harnessSetProtocolFeeBps(bpss[j]);
                uint24 lpFee = harness.exposedComputeProtocolFeeSplit(PID_A, fees[i]);
                uint24 hookFee = harness.readStash(PID_A);
                assertEq(uint256(lpFee) + uint256(hookFee), uint256(fees[i]), "conservation at boundary corner");
                assertEq(
                    uint256(hookFee), (uint256(fees[i]) * uint256(bpss[j])) / BPS_SCALE, "floor at boundary corner"
                );
            }
        }
    }

    // ------------------------------------------------------------------
    // SETTLE-1 — beyond the governance cap: where does the arithmetic ACTUALLY break?
    // ------------------------------------------------------------------

    /// @notice SETTLE-1 headroom: the split arithmetic itself tolerates protBps all the way to
    ///         10000 (100%) — floor(d*p/1e4) <= d for every p <= 1e4 — so the 2000-bps governance
    ///         cap has a 5x safety margin before the subtraction underflows. Documents that the
    ///         load-bearing guard is the cap, and exactly how much slack sits behind it.
    function testFuzz_split_beyondCapUpTo100pct_stillNoUnderflow(uint24 dynamicFee, uint16 protBps) public {
        protBps = uint16(bound(protBps, MAX_PROTOCOL_FEE_BPS + 1, uint16(BPS_SCALE)));

        harness.harnessSetProtocolFeeBps(protBps); // bypasses governance cap by design
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(PID_A, dynamicFee); // must not revert
        uint24 hookFee = harness.readStash(PID_A);

        assertLe(hookFee, dynamicFee, "no underflow up to 100% bps");
        assertEq(uint256(lpFee) + uint256(hookFee), uint256(dynamicFee), "conservation up to 100% bps");
    }

    /// @notice SETTLE-1 breaking point (documentation, NOT a reachable bug): at protBps = 10001
    ///         and dynamicFee = 1e6, hookFee = floor(1e6*10001/1e4) = 1_000_100 > dynamicFee and
    ///         the checked uint24 subtraction panics — i.e. EVERY swap on the pool would revert.
    ///         This is the total-DoS failure mode the 2000-bps cache cap protects against.
    function test_split_above100pct_underflowReverts() public {
        harness.harnessSetProtocolFeeBps(10_001);
        vm.expectRevert(stdError.arithmeticError);
        harness.exposedComputeProtocolFeeSplit(PID_A, MAX_LP_FEE);
    }

    /// @notice SETTLE-1 breaking point, fuzzed: for protBps in (10000, 65535] and dynamicFee
    ///         >= 1e4 (so floor(d*p/1e4) >= d+1) with dynamicFee < uint24.max (see the masking
    ///         edge below), the split ALWAYS underflow-panics. Confirms the revert region is
    ///         everything above 100%, not something the uint24 cap quietly absorbs.
    function testFuzz_split_above100pct_underflowReverts(uint24 dynamicFee, uint16 protBps) public {
        protBps = uint16(bound(protBps, uint16(BPS_SCALE) + 1, type(uint16).max));
        dynamicFee = uint24(bound(dynamicFee, BPS_SCALE, uint256(type(uint24).max) - 1));

        harness.harnessSetProtocolFeeBps(protBps);
        vm.expectRevert(stdError.arithmeticError);
        harness.exposedComputeProtocolFeeSplit(PID_A, dynamicFee);
    }

    /// @notice SETTLE-1 subtle edge (documentation): at dynamicFee == uint24.max exactly, the
    ///         `toUint24Capped` clamp on hookFeeRaw caps hookFee back down to uint24.max ==
    ///         dynamicFee, MASKING the underflow — the split "succeeds" with lpFee = 0 even at
    ///         protBps far above 100%. Unreachable (dynamicFee <= MAX_LP_FEE = 1e6 in production),
    ///         but shows the cap can convert an over-100% rate into a silent 100% take instead
    ///         of a revert at this single point.
    function test_split_uint24MaxFee_capMasksUnderflow() public {
        harness.harnessSetProtocolFeeBps(type(uint16).max); // 655.35%
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(PID_A, type(uint24).max);
        uint24 hookFee = harness.readStash(PID_A);
        assertEq(lpFee, 0, "lpFee zero: cap clamped hookFee to exactly dynamicFee");
        assertEq(hookFee, type(uint24).max, "hookFee capped at uint24.max == dynamicFee");
    }

    // ------------------------------------------------------------------
    // SETTLE-18 — transient stash: clean uint24 round-trip, per-pool isolation
    // ------------------------------------------------------------------

    /// @notice SETTLE-18: the real writer (`_stashHookFee` via the split) leaves the FULL 32-byte
    ///         transient word equal to the bare uint24 value — no dirty high bits — for every
    ///         hookFee value and any poolId, so `_loadHookFee` reads back exactly what was stashed.
    function testFuzz_stash_rawWordIsCleanUint24(uint24 hookFee, bytes32 rawPoolId) public {
        PoolId pid = PoolId.wrap(rawPoolId);
        _stashExactHookFee(pid, hookFee);

        bytes32 raw = harness.readRawStashWord(pid);
        assertEq(uint256(raw), uint256(hookFee), "full stash word == bare uint24 value (no high bits)");
        assertEq(harness.readStash(pid), hookFee, "narrow load returns the exact stashed rate");
    }

    /// @notice SETTLE-18: a maximally dirty pre-existing word at the stash slot (which no real
    ///         code path can produce — the split is the only writer) is FULLY overwritten by the
    ///         next real stash. tstore writes the whole word, so no residual high bits survive
    ///         into the value `_loadHookFee` returns. This mirrors production ordering: every
    ///         `_beforeSwap` branch re-stashes before `_afterSwap` loads.
    function testFuzz_stash_overwritesDirtyPriorWord(uint24 hookFee, bytes32 dirt) public {
        // Force high bits into the dirt pattern so the test cannot pass vacuously.
        bytes32 dirty = dirt | bytes32(uint256(1) << 255) | bytes32(uint256(0xdead) << 200);
        harness.writeRawStashWord(PID_A, dirty);
        assertEq(harness.readRawStashWord(PID_A), dirty, "sanity: dirty word landed");

        _stashExactHookFee(PID_A, hookFee);

        assertEq(uint256(harness.readRawStashWord(PID_A)), uint256(hookFee), "real stash purges all dirty bits");
        assertEq(harness.readStash(PID_A), hookFee, "load exact after dirty pre-state");
    }

    /// @notice SETTLE-18 (cross-pool slot isolation, stateless half): stashing to pool A leaves
    ///         pool B's word untouched and vice versa — the keccak(poolId, tag) slot derivation
    ///         cannot collide for distinct poolIds.
    function testFuzz_stash_perPoolIsolation(uint24 feeA, uint24 feeB, bytes32 pidRawA, bytes32 pidRawB) public {
        vm.assume(pidRawA != pidRawB);
        PoolId pidA = PoolId.wrap(pidRawA);
        PoolId pidB = PoolId.wrap(pidRawB);

        _stashExactHookFee(pidA, feeA);
        _stashExactHookFee(pidB, feeB);

        // B's write must not have disturbed A, and both read back exactly.
        assertEq(harness.readStash(pidA), feeA, "pool A stash intact after pool B write");
        assertEq(harness.readStash(pidB), feeB, "pool B stash exact");
        assertEq(uint256(harness.readRawStashWord(pidA)), uint256(feeA), "pool A raw word clean");
        assertEq(uint256(harness.readRawStashWord(pidB)), uint256(feeB), "pool B raw word clean");
    }
}
