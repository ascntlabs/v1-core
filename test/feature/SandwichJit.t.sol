// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {SimHook} from "../../src/SimHook.sol";

/// @dev Adversarial sandwich / JIT-liquidity coverage. Two defensive properties are exercised on a
///      concentrated stable pool (deep band + shallow tail, ~the "10k in [0.99,1.01], thin beyond"
///      shape): the simulator prices *each* swap for the impact it actually causes, so a frontrun
///      earns no discount from going first; and `jitLockBlocks` gates the add-before/remove-after
///      liquidity cycle.
///
///      Depth asymmetry is built from two STRADDLING positions (the `addLiquidity` helper requires
///      both token amounts > 0, i.e. in-range): a deep NARROW band + a thin WIDE band. Beyond ±100
///      only the thin band is active ⇒ shallow "tail". Swaps are oneForZero (price up) into it.
contract SandwichJitTest is SimHookUtils {
    uint160 internal _sp;

    int24 internal constant NARROW = 100; // deep band [-100,100] ≈ [0.99,1.01]
    int24 internal constant WIDE = 2000; // thin band [-2000,2000]
    int24 internal constant JIT = 500; // attacker's straddling JIT position [-500,500]

    /// @dev Build a fresh concentrated USDC/USDT pool (price≈1) with the given JIT lock. maxFee=50%
    ///      and a 10-pip floor so impact fees are visible and not clamped for moderate swaps.
    function _buildPool(uint48 jitBlocks) internal {
        address hookAddr = deployCoreAndHookCustomDecimals("SimHook.sol", "USDC", "USDT", 6, 6, false);
        hook = SimHook(hookAddr);
        (, _sp) = deployPool(IHooks(hookAddr), 0, 1, false);
        //             minMinFee, maxMinFee, maxFee, decay, jitBlocks
        hook.configurePool(poolId, 10, 10, 500_000, 1 hours, jitBlocks, 2e6, 1e6);
        addLiquidity(-NARROW, NARROW, 2_000_000e6, _sp, false); // deep narrow band
        addLiquidity(-WIDE, WIDE, 40_000e6, _sp, false); // thin wide band → shallow beyond ±100
    }

    function _feeUp(int256 amt) internal returns (uint24) {
        (, Vm.Log[] memory logs) = swap(false, amt, false); // oneForZero, price up
        return getBeforeSwapEventData(logs).dynamicFeePips;
    }

    // 1) A large frontrun that pushes price through liquidity is charged the FULL fee in the same
    //    swap — the old "cheap frontrun off stale illiq" is gone (the simulator prices live state).
    function test_frontrun_chargedFullFee_notCheap() public {
        _buildPool(0);
        swap(false, -100e6, false); // warmup swap (cum ≈ 0)
        uint24 fee = _feeUp(-1_500_000e6); // large frontrun through the band into the tail
        // Scenario 1 (increasing from ~0): fee = k×midpoint of the 0→P leg ≈ estPI itself, so a
        // large own impact ⇒ very high fee, not cheap.
        assertGt(fee, 50_000, "large frontrun must be charged a high fee");
    }

    // 2) Edge variant: a frontrun that moves within the deep band is cheap; a same-direction victim
    //    continuing into the thin tail pays far more — because the simulator charges each swap for
    //    the impact IT causes plus the standing imbalance. The victim's high fee is correct pricing;
    //    the attacker can't get the frontrun cheap AND leave the victim mispriced.
    function test_edgeVariant_victimPaysMoreThanFrontrun() public {
        _buildPool(0);
        swap(false, -100e6, false); // warmup
        uint24 frontrunFee = _feeUp(-60_000e6); // moves toward the band edge (deep liquidity)
        uint24 victimFee = _feeUp(-60_000e6); // same direction, thinner liquidity + higher cum
        assertLt(frontrunFee, victimFee, "victim (thin liquidity + built-up imbalance) pays more than frontrun");
    }

    // 3) The lock's scope: with `jitLockBlocks` on, a position added this block cannot be removed
    //    in the backrun window, so the same-block hit-and-run does not complete. Note the bound of
    //    what this proves — the lock gates TIMING, not profitability: a holder willing to wait out
    //    `jitLockBlocks` is not blocked, and on a pegged pair that wait carries little price risk.
    function test_jitLock_blocksSameBlockRemoval() public {
        _buildPool(50); // lock on
        addLiquidity(-JIT, JIT, 100_000e6, _sp, false); // attacker JIT-adds spanning the victim's path
        swap(false, -200_000e6, false); // victim swaps into the tail (price up)
        vm.expectRevert(); // JitLockActive — attacker can't unwind the JIT this block
        removeLiquidity(-JIT, JIT, 1);
    }

    // 4) The same sequence with the lock OFF completes — removal is not blocked. Pins the
    //    behavioural difference the parameter makes; contrast with test 3.
    function test_sandwich_lockOff_removalNotBlocked() public {
        _buildPool(0); // lock off
        addLiquidity(-JIT, JIT, 100_000e6, _sp, false); // attacker JIT-adds
        swap(false, -200_000e6, false); // victim
        removeLiquidity(-JIT, JIT, 1); // succeeds — no lock to stop the unwind
    }
}
