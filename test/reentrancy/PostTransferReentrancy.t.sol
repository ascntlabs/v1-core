// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {Phase5ReentrancyBase} from "./base/Phase5ReentrancyBase.sol";
import {Phase5NestedSwapper} from "./helpers/Phase5NestedSwapper.sol";
import {Phase5PostTransferToken} from "./helpers/Phase5PostTransferToken.sol";
import {Phase5Decay} from "./helpers/Phase5Decay.sol";
import {ImpactOracle} from "../utils/ImpactOracle.sol";

/// @notice XSUB-1 / SETTLE-12 at the OTHER callback position.
///
///         The shared `test/mocks/ReentrantERC20` fires its callback BEFORE `super.transfer`, so
///         every "mid-take" observation in `NestedSwapDuringTake.t.sol` is taken at a moment when
///         the treasury has not yet been credited. A real callback token — ERC-777
///         `tokensReceived`, or any hook-on-transfer token — fires AFTER the balances move, which
///         is a different point in the PoolManager's reserve accounting. This suite re-runs the two
///         flagship vectors through `Phase5PostTransferToken` so both positions are covered.
///
///         The callback position is not assumed, it is PROVEN per test: the adversary samples
///         `token1.balanceOf(TREASURY)` at re-entry, and it already includes the take.
contract Phase5PostTransferReentrancyTest is Phase5ReentrancyBase {
    using StateLibrary for IPoolManager;

    Phase5PostTransferToken internal token0;
    Phase5PostTransferToken internal token1;
    Phase5NestedSwapper internal attacker;

    uint24 internal constant MIN_MIN_FEE = 100;
    uint24 internal constant MAX_MIN_FEE = 500;
    uint24 internal constant MAX_FEE = 200_000;
    uint256 internal constant DECAY = 1 hours;
    uint16 internal constant BPS = 1_000; // 10%

    int256 internal constant WARMUP = 2e19;
    int256 internal constant OUTER = 5e19;
    int256 internal constant NESTED = 3e19;

    function setUp() public {
        _deployProtocol();

        Phase5PostTransferToken a = new Phase5PostTransferToken("Phase5PtA", "P5PA", 18);
        Phase5PostTransferToken b = new Phase5PostTransferToken("Phase5PtB", "P5PB", 18);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        _useTokens(address(a), address(b));
        token0 = Phase5PostTransferToken(Currency.unwrap(currency0));
        token1 = Phase5PostTransferToken(Currency.unwrap(currency1));

        (key, poolId) = _initAndConfigure(1, 0, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, DECAY, 0);
        _addLiquidity(key, TICK_LOWER, TICK_UPPER, 1e21);
        _enableProtocolFee(BPS, TREASURY);

        attacker = new Phase5NestedSwapper(manager, hook, address(token1), key, poolId);
        token0.mint(address(attacker), 1e26);
        token1.mint(address(attacker), 1e26);
        attacker.setBalanceProbe(address(token1), TREASURY);

        _swap(key, true, -WARMUP); // warm-up swap
    }

    function _armNestedSwap(bool zeroForOne, int256 amount) internal {
        attacker.setNested(key, poolId, zeroForOne, amount);
        token1.arm(address(attacker), abi.encodeCall(Phase5NestedSwapper.onTakeSwap, ()), true, false, true);
    }

    // =====================================================================================

    /// @notice XSUB-1 with the callback fired AFTER the treasury credit: the accumulator still
    ///         composes as `decay(prev) + dir(outer) + dir(nested)`, each swap recorded once. The
    ///         balance probe proves the re-entry really is post-credit — which is what distinguishes
    ///         this from the pre-transfer suite.
    function test_XSUB1_postTransferCallback_accumulatorComposesExactlyOnce() public {
        vm.warp(block.timestamp + 600);

        (, uint48 lastTsBefore,, int256 cumBefore) = hook.poolData(poolId);
        // vm.getBlockTimestamp(): opaque read the via-IR optimizer can't fold across vm.warp
        // (TIMESTAMP-fold hazard); lastTsBefore is a contract read.
        uint256 dt = vm.getBlockTimestamp() - lastTsBefore;
        (uint160 p0,,,) = manager.getSlot0(poolId);
        uint256 treasuryBefore = token1.balanceOf(TREASURY);

        _armNestedSwap(true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 1, "exactly one re-entry");
        assertEq(token1.reenterCount(), 1);

        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 2, "nested take, then the outer take");
        uint128 outerTake = takes[1].amount1;
        assertGt(outerTake, 0);

        // --- callback position: the treasury was ALREADY credited when the adversary ran ---
        assertEq(
            attacker.balanceAtReentry(),
            treasuryBefore + outerTake,
            "re-entry observed the post-credit treasury balance"
        );

        AfterSwapEvent[] memory as_ = _afterSwapEvents(logs);
        assertEq(as_.length, 2, "each swap recorded exactly once");

        uint160 p1 = attacker.sqrtAtReentry();
        uint160 p2 = attacker.sqrtAfterNested();
        int256 decayed = Phase5Decay.decay(cumBefore, dt, DECAY);
        assertTrue(decayed != cumBefore, "the decay term is live");

        int256 c1 = decayed + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p0, p1));
        int256 c2 = c1 + ImpactOracle.directional(true, ImpactOracle.priceImpactPips(p1, p2));

        assertEq(as_[0].cumPriceImpact, c1, "outer leg");
        assertEq(as_[1].cumPriceImpact, c2, "nested leg composes on the written state");

        (uint160 storedSqrtBefore, uint48 storedTs,, int256 storedCum) = hook.poolData(poolId);
        assertEq(storedCum, c2, "stored accumulator == composition");
        assertEq(storedSqrtBefore, p1, "the nested swap owns the final snapshot");
        // opaque timestamp read (TIMESTAMP-fold hazard); storedTs is a contract read
        assertEq(storedTs, uint48(vm.getBlockTimestamp()));
    }

    /// @notice SETTLE-12 with the post-credit callback: the nested swap still clobbers the pool's
    ///         transient stash, and the outer take is still byte-identical to its no-re-entry
    ///         control — and the treasury ends up with exactly the two takes.
    function test_SETTLE12_postTransferCallback_outerTakeUnchanged() public {
        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        TakeEvent[] memory ctrlTakes = _takeEvents(ctrlLogs);
        assertEq(ctrlTakes.length, 1);
        uint128 controlTake = ctrlTakes[0].amount1;
        assertGt(controlTake, 0, "control take must be non-zero or the comparison is vacuous");
        vm.revertToState(snap);

        uint256 treasuryBefore = token1.balanceOf(TREASURY);
        _armNestedSwap(true, -NESTED);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 2);

        assertGt(attacker.stashAtReentry(), 0, "outer rate stashed");
        assertTrue(
            attacker.stashAfterNested() != attacker.stashAtReentry(),
            "nested swap must overwrite the stash, else this proves nothing"
        );

        assertEq(takes[1].amount1, controlTake, "outer take immune to a post-credit re-entry");
        assertEq(
            token1.balanceOf(TREASURY) - treasuryBefore,
            uint256(takes[0].amount1) + uint256(takes[1].amount1),
            "treasury received exactly both takes"
        );
    }

    /// @notice SETTLE-12 fuzzed at the post-credit callback position, over the nested trade, the
    ///         elapsed time and the protocol rate (`1 <= bps <= 2000` — the full band up to and
    ///         including the governance cap; no rounding band is silently excluded). Mirrors the
    ///         two-regime structure of `testFuzz_SETTLE12_outerTakeInvariantToNestedSwap`:
    ///         when the outer split is non-zero the re-entry lands inside `unspecified.take` and
    ///         the last `ProtocolFeeTaken` on this pool is unambiguously the outer swap's; when it
    ///         truncates to zero (low bps) there is no in-take window and the callback fires on
    ///         the router's own output transfer — asserted explicitly, not skipped.
    function testFuzz_SETTLE12_postTransferCallback_outerTakeInvariant(
        uint256 amountSeed,
        bool nestedZeroForOne,
        uint256 dtSeed,
        uint16 bpsSeed
    ) public {
        int256 nested = -int256(bound(amountSeed, 1e16, 1e20));
        uint16 bps = uint16(bound(uint256(bpsSeed), 1, 2_000));
        vm.warp(block.timestamp + bound(dtSeed, 0, 2 * DECAY));
        _setProtocolFeeBps(bps);

        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory ctrlLogs) = _swap(key, true, -OUTER);
        uint256 controlTake = _takeAmountOrZero(ctrlLogs, poolId);
        vm.revertToState(snap);

        _armNestedSwap(nestedZeroForOne, nested);
        (, Vm.Log[] memory logs) = _swap(key, true, -OUTER);

        assertEq(attacker.fired(), 1, "the re-entry ran (in-take, or on the router transfer)");
        assertEq(_afterSwapEvents(logs).length, 2, "and the nested swap really executed");

        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        uint24 outerSplit = uint24((uint256(bs[0].dynamicFeePips) * bps) / 10_000);
        uint24 nestedSplit = uint24((uint256(bs[1].dynamicFeePips) * bps) / 10_000);

        if (controlTake > 0) {
            // in-take regime: with split >= 1 pip and a ~5e19 unspecified leg the take is >= ~5e13
            // wei, so this branch is the bulk of the domain by construction, not by luck.
            assertEq(_takeAmountOrZero(logs, poolId), controlTake, "outer take invariant to the nested swap");
            assertGt(outerSplit, 0, "a settling take implies a non-zero stashed rate");
            assertEq(attacker.stashAtReentry(), outerSplit, "the OUTER split sat in the stash mid-take");
            assertEq(attacker.stashAfterNested(), nestedSplit, "the NESTED split overwrote it");
            // Anti-vacuity: a run where both legs split to the same uint24 cannot distinguish
            // clobber from no-write — discard it rather than pass it silently (rare; low-bps only).
            vm.assume(attacker.stashAfterNested() != attacker.stashAtReentry());
        } else {
            // rounding-band regime: the outer split
            // truncated to zero, the hook transferred nothing, no in-take window existed.
            assertEq(outerSplit, 0, "a zero control take must come from the split rounding to zero");
            assertEq(_takeEvents(ctrlLogs).length, 0, "control: no settlement at all");
            assertEq(attacker.stashAtReentry(), 0, "the zero rate really was stashed for the outer swap");
            assertEq(
                _takeEvents(logs).length,
                nestedSplit > 0 ? 1 : 0,
                "only the nested swap may settle when the outer split is zero"
            );
        }
    }
}
