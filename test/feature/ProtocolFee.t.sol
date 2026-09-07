// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Vm} from "forge-std/Vm.sol";

import {SimHookFeatureBase} from "./base/SimHookFeatureBase.sol";

/// @dev Tests the per-swap protocol-fee take. Treasury receives real ERC-20/native on every
///      swap (no LP-event poke needed). LP-event hooks return ZERO_DELTA — PositionManager
///      sees clean LP-only deltas, so out-of-range burns + adds-with-large-fees both pass
///      cleanly. The take is settled in afterSwap via `AscntBaseHook._takeProtocolFeeOnAfterSwap`,
///      from the realized *unspecified* currency (output on exact-in, input on exact-out).
contract ProtocolFeeTest is SimHookFeatureBase {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    address constant TREASURY = address(0xDEAF);

    /// @dev Event emitted by AscntBaseHook._takeProtocolFeeOnAfterSwap when the take is non-zero.
    bytes32 constant PROTOCOL_FEE_TAKEN_SIG = keccak256("ProtocolFeeTaken(bytes32,address,uint128,uint128)");

    function setUp() public {
        _deployConfigurePool();

        // seed liquidity
        addLiquidity(76080, 90000, 10 ether, initialSqrtPriceX96, false);
        addLiquidity(-80000, 887000, 0.2 ether, initialSqrtPriceX96, false);
    }

    /// @dev Helper: configures the active governance with a given protocol bps + treasury.
    function _setProtocolFee(uint16 bps, address treasury) internal {
        governance.setTreasury(treasury);
        governance.setProtocolFeeBps(bps);
    }

    function _hasProtocolFeeTaken(Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PROTOCOL_FEE_TAKEN_SIG) return true;
        }
        return false;
    }

    /// @dev protocolFeeBps = 0 (default) — swap charges full dynamicFee to LP; no take, no event.
    function test_zeroBps_noTakeOnSwap() public {
        assertEq(governance.protocolFeeBps(), 0);

        // `swap()` records its own logs and returns them — using its return value here, not
        // a fresh `vm.recordLogs` (which would be cleared by the swap helper's own call).
        (, Vm.Log[] memory logs) = swap(true, -0.1 ether, false);

        assertFalse(_hasProtocolFeeTaken(logs), "should not emit ProtocolFeeTaken when bps is 0");
        assertEq(key.currency0.balanceOf(TREASURY), 0);
        assertEq(key.currency1.balanceOf(TREASURY), 0);
    }

    /// @dev Full disable flow: enable (take fires) -> bps back to 0 (no take, LPs get the full
    ///      fee again) -> treasury can then be unset (governance permits 0 only when bps == 0).
    function test_disableFlow_bpsToZero_thenTreasuryUnset() public {
        _setProtocolFee(500, TREASURY);
        swap(true, -0.05 ether, false); // warmup swap

        (, Vm.Log[] memory logsOn) = swap(true, -0.1 ether, false);
        assertTrue(_hasProtocolFeeTaken(logsOn), "take must fire while enabled");
        uint256 balAfterEnable = key.currency1.balanceOf(TREASURY);

        governance.setProtocolFeeBps(0);
        assertEq(hook.protocolFeeBps(), 0, "hook cache picked up the disable push");

        (, Vm.Log[] memory logsOff) = swap(true, -0.1 ether, false);
        assertFalse(_hasProtocolFeeTaken(logsOff), "no take after disable");
        assertEq(key.currency1.balanceOf(TREASURY), balAfterEnable, "treasury stops growing");

        governance.setTreasury(address(0)); // must succeed now that bps == 0
        assertEq(governance.treasury(), address(0));
    }

    /// @dev protocolFeeBps = 5% — treasury receives a slice of the *unspecified* currency on
    ///      every swap (output on exact-input, input on exact-output), as real ERC-20/native
    ///      (claims=false). Warmup first so the dynamicFee is
    ///      large enough that the 5% slice rounds to a non-zero take.
    function test_fivePercent_takeOnSwap() public {
        _setProtocolFee(500, TREASURY);

        // Warmup swap — a first swap doesn't always produce
        // an emit-large-enough take by itself.
        swap(true, -0.05 ether, false);

        uint256 bal0Before = key.currency0.balanceOf(TREASURY);
        uint256 bal1Before = key.currency1.balanceOf(TREASURY);

        (, Vm.Log[] memory logs) = swap(true, -0.1 ether, false);

        assertTrue(_hasProtocolFeeTaken(logs), "should emit ProtocolFeeTaken");
        // Exact-input zeroForOne ⇒ unspecified = currency1 (output) ⇒ take from currency1.
        assertEq(key.currency0.balanceOf(TREASURY), bal0Before, "currency0 untouched");
        assertGt(key.currency1.balanceOf(TREASURY), bal1Before, "currency1 grew");
    }

    /// @dev Reverse-direction swap takes from the other side.
    function test_oneForZeroSwap_takesFromCurrency0() public {
        _setProtocolFee(500, TREASURY);

        // Warmup swap.
        swap(true, -0.1 ether, false);

        uint256 bal0Before = key.currency0.balanceOf(TREASURY);
        uint256 bal1Before = key.currency1.balanceOf(TREASURY);

        swap(false, -500e18, false);

        // Exact-input oneForZero ⇒ unspecified = currency0 (output) ⇒ take from currency0.
        assertGt(key.currency0.balanceOf(TREASURY), bal0Before, "currency0 grew");
        assertEq(key.currency1.balanceOf(TREASURY), bal1Before, "currency1 untouched");
    }

    /// @dev protocolFeeBps = 2000 (cap) — works correctly at the cap.
    function test_maxBps_takeOnSwap() public {
        _setProtocolFee(governance.MAX_PROTOCOL_FEE_BPS(), TREASURY);

        // Warmup — a small first swap may produce too-small a take to clear the floor.
        swap(true, -0.05 ether, false);

        uint256 bal1Before = key.currency1.balanceOf(TREASURY);
        swap(true, -0.1 ether, false);
        // Exact-input zeroForOne ⇒ unspecified = currency1 (output) ⇒ take from currency1.
        assertGt(key.currency1.balanceOf(TREASURY), bal1Before, "cap-bps take should fire");
    }

    /// @dev Exact-output zeroForOne (caller fixes the **output** of currency1). Unspecified
    ///      currency = currency0 (the input), so the take comes from currency0.
    function test_exactOutputZeroForOne_takesFromCurrency0() public {
        _setProtocolFee(500, TREASURY);

        // Warmup swap.
        swap(true, -0.05 ether, false);

        uint256 bal0Before = key.currency0.balanceOf(TREASURY);
        uint256 bal1Before = key.currency1.balanceOf(TREASURY);

        // Exact-output zeroForOne: positive amountSpecified means "give me this much currency1".
        swap(true, int256(200e18), false);

        assertGt(key.currency0.balanceOf(TREASURY), bal0Before, "currency0 grew (unspecified/input side)");
        assertEq(key.currency1.balanceOf(TREASURY), bal1Before, "currency1 untouched (specified/output side)");
    }

    /// @dev Exact-output oneForZero (caller fixes the **output** of currency0). Unspecified
    ///      currency = currency1 (the input), so the take comes from currency1.
    function test_exactOutputOneForZero_takesFromCurrency1() public {
        _setProtocolFee(500, TREASURY);

        // Warmup swap.
        swap(true, -0.05 ether, false);

        uint256 bal0Before = key.currency0.balanceOf(TREASURY);
        uint256 bal1Before = key.currency1.balanceOf(TREASURY);

        // Exact-output oneForZero: positive amountSpecified means "give me this much currency0".
        swap(false, int256(0.01 ether), false);

        assertEq(key.currency0.balanceOf(TREASURY), bal0Before, "currency0 untouched (specified/output side)");
        assertGt(key.currency1.balanceOf(TREASURY), bal1Before, "currency1 grew (unspecified/input side)");
    }

    /// @dev Tiny swap × high bps may produce `hookFee == 0` or `slice == 0`. The take helper
    ///      must short-circuit and emit nothing in that case (no zero-amount transfer).
    function test_tinySwap_roundsToZero_noTake() public {
        _setProtocolFee(governance.MAX_PROTOCOL_FEE_BPS(), TREASURY);

        // Warm.
        swap(true, -0.05 ether, false);

        uint256 bal0Before = key.currency0.balanceOf(TREASURY);
        uint256 bal1Before = key.currency1.balanceOf(TREASURY);

        // A 1-wei exact-input swap. Whatever the dynamic fee resolves to, the take on the
        // ~0 realized output rounds to zero. The helper's `if (take == 0)` early-return must fire.
        (, Vm.Log[] memory logs) = swap(true, -1, false);

        assertFalse(_hasProtocolFeeTaken(logs), "no event when slice rounds to zero");
        assertEq(key.currency0.balanceOf(TREASURY), bal0Before, "treasury currency0 unchanged");
        assertEq(key.currency1.balanceOf(TREASURY), bal1Before, "treasury currency1 unchanged");
    }

    /// @dev `setProtocolFeeBps` on governance pushes the new value into every subscribed hook's
    ///      cache in the same tx. Asserts the cache lands at the new bps and the per-swap take
    ///      scales accordingly. Uses `vm.snapshotState` so both swaps run from identical pool
    ///      state — otherwise differing dynamic-fee curves would muddle the bps comparison.
    function test_governancePush_updatesHookCache() public {
        _setProtocolFee(500, TREASURY); // global = 5%; push reaches hook in same tx

        // Sanity: cached bps reflects the push.
        assertEq(hook.protocolFeeBps(), 500, "hook cache picked up the 5% push");

        // Warmup so the first measured swap starts from a stamped swap clock.
        swap(true, -0.05 ether, false);

        // Snapshot post-warmup. Both branches will resume from here.
        uint256 snap = vm.snapshotState();

        // Branch A — keep 5% bps. Exact-input zeroForOne ⇒ take from currency1 (output).
        uint256 bal1Before = key.currency1.balanceOf(TREASURY);
        swap(true, -0.1 ether, false);
        uint256 takeAt500 = key.currency1.balanceOf(TREASURY) - bal1Before;

        // Branch B — bump global to 15%; push reaches hook; run identical swap.
        vm.revertToState(snap);
        governance.setProtocolFeeBps(1500);
        assertEq(hook.protocolFeeBps(), 1500, "hook cache picked up the 15% push");
        bal1Before = key.currency1.balanceOf(TREASURY);
        swap(true, -0.1 ether, false);
        uint256 takeAt1500 = key.currency1.balanceOf(TREASURY) - bal1Before;

        // 15% ÷ 5% = 3× the per-swap take, modulo integer-rounding drift. Loose floor (2×).
        assertGt(takeAt1500, takeAt500 * 2, "higher bps must take materially more");
    }

    /// @dev LP events never emit ProtocolFeeTaken (take happens at swap time only) and never
    ///      return a non-zero hookDelta — PositionManager sees clean LP-only deltas on add/burn.
    function test_noTakeOnAddOrRemove() public {
        _setProtocolFee(500, TREASURY);

        int24 tickLower = 78000;
        int24 tickUpper = 81000;

        // No event on add.
        vm.recordLogs();
        addLiquidity(tickLower, tickUpper, 0.5 ether, initialSqrtPriceX96, false);
        Vm.Log[] memory addLogs = vm.getRecordedLogs();
        assertFalse(_hasProtocolFeeTaken(addLogs), "add must not emit ProtocolFeeTaken");

        // Accumulate fees via swaps; THESE swaps each emit ProtocolFeeTaken.
        swap(true, -0.1 ether, false);
        swap(false, -500e18, false);

        // Advance past JIT window.
        vm.roll(block.number + 51);

        // No event on remove either.
        vm.recordLogs();
        removeLiquidity(tickLower, tickUpper, 1);
        Vm.Log[] memory removeLogs = vm.getRecordedLogs();
        assertFalse(_hasProtocolFeeTaken(removeLogs), "remove must not emit ProtocolFeeTaken");
    }

    // NOT COVERED HERE: the out-of-range burn regression lives in
    // ProtocolFee_PositionManager.t.sol, because only the PositionManager path (validateMinOut)
    // can catch that bug class — this file's router bypasses it. For reference, the case is an
    // out-of-range burn after a directional swap: the principal-side delta on one currency is
    // zero (the position holds no token of that side), while historic fees accrued on both sides
    // in range. The hook enables no `afterRemoveLiquidity` callback, so validateMinOut sees a
    // clean positive delta and the burn succeeds. A hook returning a negative principal-side
    // delta there — e.g. taking a cut at LP-event time — would hit `SafeCastOverflow`.
}

