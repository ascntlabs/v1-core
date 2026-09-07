// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Vm} from "forge-std/Vm.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @dev Exact ACCOUNTING for the afterSwap protocol-fee take: the take is sized off the
///      *realized* unspecified-currency fill (not `amountSpecified`), lands on the correct currency,
///      and the emitted event == treasury balance delta. The partial-fill case is the direct proof
///      of the exact-output/limit undercharge fix — the old code sized off `|amountSpecified|`.
contract ProtocolFeeAccountingTest is SimHookUtils {
    using StateLibrary for IPoolManager;

    StablePairPoolConfig internal cfg;
    address internal constant TREASURY = address(0xFEE);
    uint16 internal constant BPS = 500; // 5%

    bytes32 constant PROTOCOL_FEE_TAKEN_SIG = keccak256("ProtocolFeeTaken(bytes32,address,uint128,uint128)");

    function setUp() public {
        cfg = new StablePairPoolConfig();
        (, uint160 initialSqrtPriceX96) = setupSimHookAndPool(cfg, false);
        addLiquidity(-2000, 2000, 1_000_000e6, initialSqrtPriceX96, false);
        // Test contract is owner+timelock (see TestUtils.deployCoreAndHookCustomDecimals).
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(BPS);
    }

    // ------ helpers ------

    function _decodeTaken(Vm.Log[] memory logs) internal pure returns (uint128 amount0, uint128 amount1, bool found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PROTOCOL_FEE_TAKEN_SIG) {
                (amount0, amount1) = abi.decode(logs[i].data, (uint128, uint128));
                return (amount0, amount1, true);
            }
        }
    }

    /// @dev mirror `_computeProtocolFeeSplit`: hookFee (pips) = dynamicFee * bps / 10000, uint24-capped.
    function _hookFeePipsAt(uint24 dynamicFeePips, uint16 bps) internal pure returns (uint256) {
        return FullMath.mulDiv(dynamicFeePips, bps, 10_000);
    }

    function _hookFeePips(uint24 dynamicFeePips) internal pure returns (uint256) {
        return _hookFeePipsAt(dynamicFeePips, BPS);
    }

    /// @dev The contract sizes the take off the RAW swap delta seen in `_afterSwap`; the router
    ///      returns the swapper's NET delta (raw ∓ take). Reconstruct the exact take independently
    ///      from the net magnitude + the fee rate by solving take = hookFee·raw with raw = net ± take.
    ///      exact-in: the take is subtracted from the output ⇒ raw = net + take. exact-out: it is
    ///      added to the input ⇒ raw = net − take.
    function _expectedTakeAt(
        uint256 netMag,
        uint24 dynamicFeePips,
        bool exactInput,
        uint16 bps
    ) internal pure returns (uint256) {
        uint256 hf = _hookFeePipsAt(dynamicFeePips, bps);
        uint256 denom = exactInput ? (1e6 - hf) : (1e6 + hf);
        return FullMath.mulDiv(netMag, hf, denom);
    }

    function _expectedTake(uint256 netMag, uint24 dynamicFeePips, bool exactInput) internal pure returns (uint256) {
        return _expectedTakeAt(netMag, dynamicFeePips, exactInput, BPS);
    }

    /// @dev Swap with an explicit price limit (TestUtils.swap hard-codes the extreme). Records logs.
    function _swapWithLimit(
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit
    ) internal returns (BalanceDelta delta, Vm.Log[] memory logs) {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory p =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit});
        vm.recordLogs();
        delta = swapRouter.swap(key, p, ts, ZERO_BYTES);
        logs = vm.getRecordedLogs();
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.balanceOf(who);
    }

    // ------ exact-INPUT, full fill: take == hookFee × realized OUTPUT (currency1), event == treasury delta ------
    function test_exactInput_takeEqualsRealizedUnspecified_andTreasuryDelta() public {
        swap(true, -20_000e6, false); // warmup swap

        uint256 tBefore = _bal(key.currency1, TREASURY);
        (SwapValues memory sv, Vm.Log[] memory logs) = swap(true, -40_000e6, false);
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);

        // exactIn zeroForOne ⇒ unspecified = currency1 (the output). realized (net) output magnitude:
        uint256 mag = SignedMath.abs(int256(sv.amount1));
        uint256 expected = _expectedTake(mag, b.dynamicFeePips, true);

        (uint128 a0, uint128 a1, bool found) = _decodeTaken(logs);
        assertTrue(found, "ProtocolFeeTaken must fire");
        assertEq(a0, 0, "no take on currency0");
        assertEq(a1, expected, "take == hookFee x realized output");
        assertEq(_bal(key.currency1, TREASURY) - tBefore, expected, "treasury delta == emitted take");
    }

    // ------ exact-OUTPUT, full fill: take on the INPUT (unspecified) currency, sized off realized input ------
    function test_exactOutput_takeSizedOffRealizedInput_notAmountSpecified() public {
        swap(true, -20_000e6, false); // warmup

        uint256 tBefore0 = _bal(key.currency0, TREASURY);
        // exact-output zeroForOne: positive amountSpecified = requested currency1 OUT. Unspecified =
        // currency0 (the input). But the take is on the UNSPECIFIED currency = currency0? For exactOut
        // zeroForOne, exactInput=false, zeroForOne=true ⇒ unspecifiedIsCurrency0 = (false != true) = true.
        (SwapValues memory sv, Vm.Log[] memory logs) = swap(true, int256(30_000e6), false);
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);

        // unspecified = currency0 = the realized INPUT. Old code would have sized off |amountSpecified|
        // (the currency1 output). Prove the take tracks the realized currency0 input.
        uint256 magInput = SignedMath.abs(int256(sv.amount0));
        uint256 expected = _expectedTake(magInput, b.dynamicFeePips, false);

        (uint128 a0, uint128 a1, bool found) = _decodeTaken(logs);
        assertTrue(found, "ProtocolFeeTaken must fire");
        assertEq(a1, 0, "no take on currency1 (the specified/output side)");
        assertEq(a0, expected, "take == hookFee x realized input");
        assertEq(_bal(key.currency0, TREASURY) - tBefore0, expected, "treasury currency0 delta == emitted take");
    }

    // ------ PARTIAL FILL (the undercharge-fix proof): realized fill < amountSpecified ------
    // A price-limited exact-input swap stops early. The take must track the *realized* output, i.e.
    // be strictly smaller than a take sized off the full |amountSpecified|. The old beforeSwap code
    // sized off |amountSpecified| and would have over/mis-charged relative to the actual fill.
    function test_partialFill_takeTracksRealizedFill_notAmountSpecified() public {
        swap(true, -20_000e6, false); // warmup

        (uint160 curSqrt,,,) = manager.getSlot0(poolId);
        // zeroForOne pushes price DOWN — set a limit ~0.15% below current so a large swap partial-fills.
        uint160 limit = uint160(uint256(curSqrt) * 9985 / 10000);

        int256 requested = -500_000e6; // large exact input; the limit will cut it short
        uint256 tBefore = _bal(key.currency1, TREASURY);
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapWithLimit(true, requested, limit);
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);

        uint256 realizedInput = SignedMath.abs(int256(delta.amount0()));
        uint256 realizedOutput = SignedMath.abs(int256(delta.amount1()));
        assertLt(realizedInput, SignedMath.abs(requested), "must PARTIAL-fill (realized < requested)");

        // New take is sized off the realized (net) output (unspecified). Assert exact + treasury delta.
        uint256 expected = _expectedTake(realizedOutput, b.dynamicFeePips, true);
        (, uint128 a1, bool found) = _decodeTaken(logs);
        assertTrue(found, "ProtocolFeeTaken must fire");
        assertEq(a1, expected, "take tracks realized output, not amountSpecified");
        assertEq(_bal(key.currency1, TREASURY) - tBefore, expected, "treasury delta == emitted take");

        // And it is strictly less than a take sized off the full requested magnitude would be — the
        // concrete signature of the fix (old code keyed off |amountSpecified|).
        uint256 oldStyle = FullMath.mulDiv(SignedMath.abs(requested), _hookFeePips(b.dynamicFeePips), 1e6);
        assertLt(expected, oldStyle, "realized-fill take must be below the amountSpecified-sized take");
    }

    // ------ LP-side split: feeGrowthGlobal must accrue ONLY the lpFee slice ------
    // The treasury-side take is asserted to the wei above; this closes the LP side. If
    // _computeProtocolFeeSplit regressed to returning the full dynamicFee (double-charging: LPs
    // get 100% AND the treasury takes its slice), the growth delta would land on the full-fee
    // value instead of the 95% lpFee slice and both asserts fail.
    function test_lpFeeGrowth_excludesProtocolSlice() public {
        swap(true, -20_000e6, false); // warmup swap

        uint128 liq = manager.getLiquidity(poolId);
        (uint256 g0Before,) = manager.getFeeGrowthGlobals(poolId);

        uint256 amtIn = 40_000e6;
        (, Vm.Log[] memory logs) = swap(true, -int256(amtIn), false);
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);

        (uint256 g0After,) = manager.getFeeGrowthGlobals(poolId);
        uint256 lpFeeAmount = FullMath.mulDiv(g0After - g0Before, liq, FixedPoint128.Q128);

        uint256 lpPips = uint256(b.dynamicFeePips) - _hookFeePips(b.dynamicFeePips);
        uint256 expectedLp = FullMath.mulDiv(amtIn, lpPips, 1e6);
        uint256 fullFee = FullMath.mulDiv(amtIn, b.dynamicFeePips, 1e6);

        assertGt(lpFeeAmount, 0, "LPs accrued nothing");
        assertApproxEqRel(lpFeeAmount, expectedLp, 0.01e18, "LP growth != lpFee slice of the dynamic fee");
        assertLt(lpFeeAmount, fullFee, "LP growth must exclude the protocol slice (no double-charge)");
    }

    // ------ transient stash isolation: sequential swaps at DIFFERENT rates ------
    // The rate is stashed in beforeSwap and consumed in afterSwap; two sequential swaps at different
    // directions AND bps must each take exactly for their OWN rate. If swap 2 read swap 1's stashed
    // hookFee its exact-amount check would fail. Also proves the hook's local bps cache picks up a
    // governance push mid-sequence.
    function test_stashIsolation_sequentialSwapsDifferentRates() public {
        swap(true, -20_000e6, false); // warmup swap

        // swap 1 @ bps = 2000, exact-in zeroForOne ⇒ take on currency1 (the output/unspecified side)
        governance.setProtocolFeeBps(2000);
        uint256 t1Before = _bal(key.currency1, TREASURY);
        (SwapValues memory sv1, Vm.Log[] memory logs1) = swap(true, -40_000e6, false);
        BeforeSwapEventData memory b1 = getBeforeSwapEventData(logs1);
        uint256 take1 = _bal(key.currency1, TREASURY) - t1Before;
        assertGt(take1, 0, "swap 1 take must be non-zero");
        assertEq(
            take1,
            _expectedTakeAt(SignedMath.abs(int256(sv1.amount1)), b1.dynamicFeePips, true, 2000),
            "swap 1 take must be exact for bps=2000"
        );

        // push the lower rate; the hook's local cache must reflect it before swap 2
        governance.setProtocolFeeBps(500);
        assertEq(hook.protocolFeeBps(), 500, "cache picked up the new bps");

        // swap 2 @ bps = 500, exact-in oneForZero ⇒ take on currency0 (the output/unspecified side)
        uint256 t0Before = _bal(key.currency0, TREASURY);
        (SwapValues memory sv2, Vm.Log[] memory logs2) = swap(false, -40_000e6, false);
        BeforeSwapEventData memory b2 = getBeforeSwapEventData(logs2);
        uint256 take2 = _bal(key.currency0, TREASURY) - t0Before;
        assertGt(take2, 0, "swap 2 take must be non-zero");
        assertEq(
            take2,
            _expectedTakeAt(SignedMath.abs(int256(sv2.amount0)), b2.dynamicFeePips, true, 500),
            "swap 2 take must be exact for bps=500 (no bleed from swap 1's stash)"
        );
    }
}
