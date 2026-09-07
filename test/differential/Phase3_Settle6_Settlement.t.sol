// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Phase3HookTestBase} from "./Phase3HookTestBase.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @notice phase3-differential — SETTLE-6 (CRITICAL) + SIM-6.
///
/// SETTLE-6: the hook's unspecified-currency selection
///     `unspecifiedIsCurrency0 = (exactInput != zeroForOne)`   (AscntBaseHook.sol:174)
/// must pick the SAME currency v4-core assigns the returned afterSwap hook delta to.
/// v4's rule (transcribed from v4-core Hooks.sol:307-309, the ONLY authority this test
/// trusts): the SPECIFIED currency is currency0 iff `(amountSpecified < 0) == zeroForOne`,
/// so the UNSPECIFIED currency is currency0 iff `(amountSpecified < 0) != zeroForOne`.
///
/// Verification is end-to-end through real PoolManager swaps in all four
/// (direction x exactness) quadrants:
///   1. the swap succeeds — if the hook took currency X while v4 booked the returned
///      int128 against currency Y, the two deltas could not net and the unlock would
///      revert (CurrencyNotSettled), so success itself is load-bearing;
///   2. the treasury receives real tokens ONLY in the v4-rule unspecified currency, and
///      the amount equals the ProtocolFeeTaken event amount in that currency's slot;
///   3. the take equals floor(|pre-hook unspecified swap delta| * hookFee / 1e6), where the
///      pre-hook delta is reconstructed from the router's post-hook delta + the take
///      (v4: callerDelta = swapDelta - hookDelta), pinning the magnitude to the correct SIDE.
contract Phase3_Settle6_SettlementTest is Phase3HookTestBase {
    address internal constant TREASURY = address(0x7E5717);

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(TICK_LOWER, TICK_UPPER, 1e12, initSqrtP, false);

        // protocol take ON at the governance cap (test contract is owner+timelock)
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(2000); // 20%

        // warmup swap stamps the swap clock before the quadrant swaps
        swap(true, -1e8, false);
        vm.warp(block.timestamp + 60);
    }

    function _quadrant(bool zeroForOne, bool exactInput, uint256 amount) internal {
        uint256 t0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(TREASURY);
        uint256 t1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(TREASURY);

        int256 amountSpecified = exactInput ? -int256(amount) : int256(amount);
        (SwapValues memory sv, Vm.Log[] memory logs) = swap(zeroForOne, amountSpecified, false);

        // --- independent expectation: v4-core Hooks.sol:307-309 transcription ---
        bool v4SpecifiedIs0 = (amountSpecified < 0) == zeroForOne;
        bool expectUnspecifiedIs0 = !v4SpecifiedIs0;

        ProtocolFeeTakenData memory fee = _parseProtocolFeeTaken(logs);
        assertTrue(fee.found, "SETTLE-6: ProtocolFeeTaken must be emitted (take > 0 by construction)");
        assertEq(fee.treasury, TREASURY, "SETTLE-6: event treasury");

        uint256 t0After = MockERC20(Currency.unwrap(key.currency0)).balanceOf(TREASURY);
        uint256 t1After = MockERC20(Currency.unwrap(key.currency1)).balanceOf(TREASURY);

        uint128 take;
        if (expectUnspecifiedIs0) {
            take = fee.amount0;
            assertGt(fee.amount0, 0, "SETTLE-6: take must land in currency0 (v4 unspecified)");
            assertEq(fee.amount1, 0, "SETTLE-6: nothing may be taken from currency1");
            assertEq(t0After - t0Before, fee.amount0, "SETTLE-6: treasury currency0 delta != event");
            assertEq(t1After, t1Before, "SETTLE-6: treasury currency1 must be untouched");
        } else {
            take = fee.amount1;
            assertGt(fee.amount1, 0, "SETTLE-6: take must land in currency1 (v4 unspecified)");
            assertEq(fee.amount0, 0, "SETTLE-6: nothing may be taken from currency0");
            assertEq(t1After - t1Before, fee.amount1, "SETTLE-6: treasury currency1 delta != event");
            assertEq(t0After, t0Before, "SETTLE-6: treasury currency0 must be untouched");
        }

        // --- magnitude cross-check on the correct SIDE ---
        // The router's returned delta is post-hook: callerDelta = swapDelta - hookDelta,
        // hookDelta = +take on the unspecified currency; so preHookUnspecified = final + take.
        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);
        uint24 hookFeePips = uint24(FullMath.mulDiv(uint256(b.dynamicFeePips), 2000, 10_000));
        int256 finalUnspec = int256(expectUnspecifiedIs0 ? sv.amount0 : sv.amount1);
        uint256 magPre = SignedMath.abs(finalUnspec + int256(uint256(take)));
        assertEq(
            uint256(take),
            FullMath.mulDiv(magPre, hookFeePips, 1e6),
            "SETTLE-6: take != hookFee share of the unspecified-side magnitude"
        );
    }

    // ---- the four (exactness x direction) quadrants, fuzzed over amount ----

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_settle6_exactIn_zeroForOne(uint256 amount) public {
        _quadrant(true, true, bound(amount, 1e8, 3e10));
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_settle6_exactIn_oneForZero(uint256 amount) public {
        _quadrant(false, true, bound(amount, 1e8, 3e10));
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_settle6_exactOut_zeroForOne(uint256 amount) public {
        _quadrant(true, false, bound(amount, 1e8, 1e10));
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_settle6_exactOut_oneForZero(uint256 amount) public {
        _quadrant(false, false, bound(amount, 1e8, 1e10));
    }

    // ---- SIM-6: invalid price limit -> engine validation reverts the whole tx, ----
    // ---- so the simulator's garbage output on such input is never fee-priced.  ----

    function _rawSwap(bool zeroForOne, int256 amountSpecified, uint160 limit) internal {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            ts,
            ZERO_BYTES
        );
    }

    function test_sim6_wrongSideLimit_zeroForOne_reverts() public {
        uint256 t0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(TREASURY);
        uint256 t1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(TREASURY);

        // zeroForOne with a limit ABOVE the current price: beforeSwap (and the simulator)
        // runs first, then Pool.swap's own validation must reject the whole tx.
        vm.expectPartialRevert(Pool.PriceLimitAlreadyExceeded.selector);
        _rawSwap(true, -1e9, TickMath.getSqrtPriceAtTick(100));

        assertEq(MockERC20(Currency.unwrap(key.currency0)).balanceOf(TREASURY), t0Before, "no fee may be realized");
        assertEq(MockERC20(Currency.unwrap(key.currency1)).balanceOf(TREASURY), t1Before, "no fee may be realized");
    }

    function test_sim6_wrongSideLimit_oneForZero_reverts() public {
        uint256 t0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(TREASURY);

        vm.expectPartialRevert(Pool.PriceLimitAlreadyExceeded.selector);
        _rawSwap(false, -1e9, TickMath.getSqrtPriceAtTick(-100));

        assertEq(MockERC20(Currency.unwrap(key.currency0)).balanceOf(TREASURY), t0Before, "no fee may be realized");
    }

    function test_sim6_outOfBoundsLimit_reverts() public {
        // zeroForOne with limit <= MIN_SQRT_PRICE: passes the already-exceeded check
        // (limit < current) and must die on PriceLimitOutOfBounds.
        vm.expectPartialRevert(Pool.PriceLimitOutOfBounds.selector);
        _rawSwap(true, -1e9, TickMath.MIN_SQRT_PRICE);
    }
}
