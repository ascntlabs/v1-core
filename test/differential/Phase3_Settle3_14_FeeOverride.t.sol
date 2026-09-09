// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {Phase3HookTestBase} from "./Phase3HookTestBase.sol";
import {SimHook} from "../../src/SimHook.sol";
import {SimHookHarness} from "../harness/SimHookHarness.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @notice phase3-differential — SETTLE-3: the lpFee the hook feeds v4-core as
///         `lpFee | OVERRIDE_FEE_FLAG` is ALWAYS a valid override, differentialed against
///         v4's own `LPFeeLibrary.removeOverrideFlagAndValidate`, including the worst case
///         maxFee == HOOK_MAX_FEE (the largest configurePool admits, 50%) with protocolFeeBps
///         at the 20% cap.
contract Phase3_Settle3_FeeOverrideTest is Phase3HookTestBase {
    SimHookHarness internal harness;

    address internal constant TREASURY = address(0xBEEF);

    function setUp() public {
        // harness hook (identical permissions/address as SimHook) so protocolFeeBps can be
        // driven directly and the internal split called with fuzzed inputs
        address hookAddress = deployCoreAndHookCustomDecimals("SimHookHarness.sol", "USDC", "USDT", 6, 6, false);
        harness = SimHookHarness(hookAddress);
        hook = SimHook(hookAddress);

        (, uint160 initSqrtP) = deployPool(IHooks(hookAddress), 0, 1, false);
        // the worst-case shape: maxFee at the hook-wide ceiling
        harness.configurePool(poolId, 1, 10, HOOK_MAX_FEE, 900, 0, 2e6, 1e6);
        addLiquidity(-600, 600, 1e12, initSqrtP, false);
        // The split carves only while the LIVE `governance.treasury()` is set; with none, every
        // bps degrades to "full dynamic fee to LPs" and the differential below would only ever
        // see lpFee == dynamicFee. Wire one up so the protocol-cut arm is the one under test.
        governance.setTreasury(TREASURY);
    }

    /// @dev Differential vs v4's own validator across the ENTIRE reachable input lattice:
    ///      every dynamicFee calculateDynamicFee can emit on a configurePool-admitted pool
    ///      (<= maxFee <= HOOK_MAX_FEE; fuzzed up to v4's own cap, a superset) x every
    ///      governance-reachable bps (<= 2000). Every _beforeSwap invocation routes through
    ///      this exact split, so the property covers the return site.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_settle3_splitAlwaysValidOverride(uint24 dynamicFee, uint16 bps) public {
        dynamicFee = uint24(bound(dynamicFee, 0, LPFeeLibrary.MAX_LP_FEE - 1));
        bps = uint16(bound(bps, 0, 2000));
        harness.harnessSetProtocolFeeBps(bps);

        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(poolId, dynamicFee);

        assertLe(lpFee, dynamicFee, "SETTLE-3: split may never grow the fee");
        assertLt(lpFee, LPFeeLibrary.MAX_LP_FEE, "SETTLE-3: lpFee at or above the v4 cap");
        assertEq(lpFee & LPFeeLibrary.OVERRIDE_FEE_FLAG, 0, "SETTLE-3: lpFee collides with OVERRIDE_FEE_FLAG");
        assertEq(lpFee & LPFeeLibrary.DYNAMIC_FEE_FLAG, 0, "SETTLE-3: lpFee collides with DYNAMIC_FEE_FLAG");

        // v4's own check: reverts LPFeeTooLarge on any invalid override
        uint24 overridden = lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(
            LPFeeLibrary.removeOverrideFlagAndValidate(overridden),
            lpFee,
            "SETTLE-3: override round-trip through v4's validator"
        );
    }

    /// @dev End-to-end at the extreme: a liquidity-exhausting swap saturates the simulated
    ///      impact at 100% so dynamicFee clamps to maxFee == HOOK_MAX_FEE; with bps at the
    ///      cap the engine receives lpFee = 400_000 — the LARGEST lpFee an admissible config can
    ///      produce with a protocol cut — and must accept it (the swap succeeding IS the
    ///      differential: an invalid override reverts inside v4-core).
    function test_settle3_maxFee_maxBps_endToEnd() public {
        harness.harnessSetProtocolFeeBps(2000);

        swap(true, -1e8, false); // warmup swap
        vm.warp(block.timestamp + 1);

        (, Vm.Log[] memory logs) = swap(true, -3e12, false); // >> pool capacity: impact caps at 1e6
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);

        assertEq(b.dynamicFeePips, HOOK_MAX_FEE, "must clamp to dynamicFee == maxFee == HOOK_MAX_FEE");
        uint24 expectedLpFee = 400_000; // 500_000 - floor(500_000 * 2000 / 10_000)
        assertEq(
            LPFeeLibrary.removeOverrideFlagAndValidate(expectedLpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG),
            expectedLpFee,
            "SETTLE-3: max lpFee override must validate"
        );
        // the protocol slice settled (20% of the realized unspecified magnitude)
        assertTrue(_parseProtocolFeeTaken(logs).found, "protocol take must settle at the extreme");
    }

    /// @dev bps == 0 pushes the other endpoint: lpFee == HOOK_MAX_FEE, the largest LP fee
    ///      v4 can ever see from this hook. Half the input still trades, so the price moves —
    ///      the 100%-fee "price frozen" edge is unreachable under the hook-wide cap.
    function test_settle3_maxFee_zeroBps_lpFeeAtHookCap() public {
        harness.harnessSetProtocolFeeBps(0);

        swap(true, -1e8, false);
        vm.warp(block.timestamp + 1);

        (SwapValues memory v, Vm.Log[] memory logs) = swap(true, -3e12, false);
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);

        uint24 cap = HOOK_MAX_FEE;
        assertEq(b.dynamicFeePips, cap, "must clamp to dynamicFee == HOOK_MAX_FEE");
        assertEq(
            LPFeeLibrary.removeOverrideFlagAndValidate(cap | LPFeeLibrary.OVERRIDE_FEE_FLAG),
            cap,
            "SETTLE-3: HOOK_MAX_FEE override must validate"
        );
        assertLt(v.sqrtPriceX96After, v.sqrtPriceX96Before, "half the input must still move the price");
    }
}

/// @notice phase3-differential — SETTLE-14: no double charge. A swapper's total cost for
///         the SAME swap from the SAME pre-state is (to second order) independent of
///         protocolFeeBps: the treasury take replaces the LP slice removed from the
///         in-swap fee, it is never additive on top of the full dynamicFee.
///
/// Method: one pool, byte-identical pre-states via snapshot/revert (+ re-warp), the same
/// exact-input swap under bps=0 and bps=2000. The specified side is identical by
/// construction; the unspecified (output) side must differ only by second-order terms.
contract Phase3_Settle14_NoDoubleChargeTest is Phase3HookTestBase {
    address internal constant TREASURY = address(0x7E5714);

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(-600, 600, 1e12, initSqrtP, false);
        governance.setTreasury(TREASURY);
        swap(true, -1e8, false); // warmup swap
        vm.warp(block.timestamp + 60);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_settle14_noDoubleCharge(uint256 amount, bool zeroForOne) public {
        amount = bound(amount, 1e8, 3e10);
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();

        // ---- run A: bps = 0, the whole dynamicFee is LP fee ----
        (SwapValues memory v0, Vm.Log[] memory logs0) = swap(zeroForOne, -int256(amount), false);
        uint256 paid0 = SignedMath.abs(int256(zeroForOne ? v0.amount0 : v0.amount1));
        uint256 recv0 = uint256(int256(zeroForOne ? v0.amount1 : v0.amount0));
        uint24 fee0 = getBeforeSwapEventData(logs0).dynamicFeePips;

        // ---- run B: identical pre-state, bps = 2000 ----
        vm.revertToState(snap);
        vm.warp(t0);
        governance.setProtocolFeeBps(2000);
        (SwapValues memory v1, Vm.Log[] memory logs1) = swap(zeroForOne, -int256(amount), false);
        uint256 paid1 = SignedMath.abs(int256(zeroForOne ? v1.amount0 : v1.amount1));
        uint256 recv1 = uint256(int256(zeroForOne ? v1.amount1 : v1.amount0));
        BeforeSwapEventData memory b1 = getBeforeSwapEventData(logs1);

        // identical pre-state -> identical dynamic fee; the bps only moves the SPLIT
        assertEq(b1.dynamicFeePips, fee0, "identical pre-state must produce identical dynamicFee");
        assertEq(paid1, paid0, "exact-input: specified side must be identical");

        ProtocolFeeTakenData memory fee = _parseProtocolFeeTaken(logs1);
        assertTrue(fee.found, "take must be live in run B");
        uint256 take = uint256(zeroForOne ? fee.amount1 : fee.amount0);
        assertGt(take, 0, "take must be non-zero for the comparison to bite");

        // ---- the invariant ----
        // Double charging would give recv1 ~= recv0 - take. Correct replace-not-add
        // settlement gives recv1 ~= recv0 up to second-order terms:
        //   +take*lpFee/1e6        (the take is measured on the LARGER pre-take output the
        //                           reduced in-swap fee produced), and
        //   -take*O(priceImpact)   (marginal output per input < average along the curve).
        // Bound: |recv1 - recv0| <= take*(dynamicFee + 2*impact)/1e6 + 2 wei of floor dust
        // — derived, not tuned; with stable-pool fees (<=1%) and these sizes it is ~1-2%
        // of take, i.e. two orders below the double-charge failure mode.
        uint256 diffAbs = recv1 >= recv0 ? recv1 - recv0 : recv0 - recv1;
        uint256 bound_ = FullMath.mulDiv(take, uint256(fee0) + 2 * b1.priceImpact, 1e6) + 2;
        assertLe(diffAbs, bound_, "SETTLE-14: swapper cost moved by more than second-order terms");
        assertLt(diffAbs, take / 2, "SETTLE-14: double-charge sentinel (cost shift comparable to the take)");

        // replace-not-add direction: the pre-take output of run B covers run A's output
        assertGe(recv1 + take + 2, recv0, "SETTLE-14: pre-take output must cover the bps=0 output");
    }
}
