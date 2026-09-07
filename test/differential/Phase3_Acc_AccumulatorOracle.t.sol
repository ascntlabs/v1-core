// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Phase3HookTestBase} from "./Phase3HookTestBase.sol";
import {Phase3ShadowMath} from "./Phase3ShadowMath.sol";
import {ImpactOracle} from "../utils/ImpactOracle.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";

/// @notice phase3-differential — ACC-1 (CRITICAL): the core accumulator recurrence.
///
/// After every committed swap N:
///     cum_N == addSat( decay(cum_{N-1}, now - lastSwapTimestamp_{N-1}, L),
///                      directional(realizedImpact_N) )
///
/// The shadow oracle is INDEPENDENT on both axes the XSUB-8 enabler demands:
///   - realizedImpact_N is recomputed by ImpactOracle from a slot0 sqrtPrice the TEST
///     captured immediately before the swap and the live slot0 after it — never from the
///     hook's emitted priceImpact or its stored sqrtPriceX96Before snapshot;
///   - decay/addSat come from Phase3ShadowMath, a spec transcription that does not import
///     HookMath.
/// So a corruption anywhere in the pipeline (wrong snapshot, wrong decay write in
/// beforeSwap, wrong add in afterSwap, wrong emitted impact) breaks the equality.
contract Phase3_Acc1_RecurrenceTest is Phase3HookTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal decayLen;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    uint256 internal constant N_SWAPS = 8;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        decayLen = cfg.timeDecayLength();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(TICK_LOWER, TICK_UPPER, 1e12, initSqrtP, false);
    }

    /// @dev Streams N_SWAPS fuzz-derived swaps (mixed direction / exactness / size / time
    ///      gap, including dt == 0 same-timestamp and dt >= L full-decay edges) and checks
    ///      the recurrence after EVERY swap. `feeOn` also runs the whole stream with the
    ///      protocol take active — the recurrence must be unaffected by the treasury take.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_acc1_recurrence(bytes32 seed, bool feeOn) public {
        if (feeOn) {
            governance.setTreasury(address(0xBEEF));
            governance.setProtocolFeeBps(1000); // 10%
        }

        int256 shadowCum = 0;
        uint48 prevTs = 0;

        for (uint256 i = 0; i < N_SWAPS; i++) {
            bytes32 r = keccak256(abi.encode(seed, i));
            bool zeroForOne = uint8(r[0]) & 1 == 1;
            bool exactIn = uint8(r[1]) & 1 == 1;
            // caps keep the 8-swap worst-case one-directional stream well inside the
            // [-600,600] range's ~5e11 per-side capacity so no swap reverts
            uint256 amount = 1e7 + (uint256(r) % (exactIn ? 3e10 : 1e10));
            uint256 dt = uint256(keccak256(abi.encode(r, "dt"))) % (decayLen + decayLen / 2);
            // vm.getBlockTimestamp(): opaque read — the via-IR optimizer folds the TIMESTAMP opcode,
            // so accumulating a fuzzed dt off bare block.timestamp in this loop is unreliable (TIMESTAMP-fold).
            vm.warp(vm.getBlockTimestamp() + dt);

            // test-captured pre-swap price — the independent realized-impact anchor
            (uint160 sqrtBefore,,,) = manager.getSlot0(poolId);

            // shadow decay: the first swap decays a zero accumulator (decay(0, dt, L) == 0),
            // so the uniform recurrence applies from swap one
            // vm.getBlockTimestamp(): opaque read the via-IR optimizer can't fold across the vm.warp
            // above; prevTs is a contract read, so both operands stay opaque (TIMESTAMP-fold hazard).
            int256 decayed = i == 0
                ? int256(0)
                : Phase3ShadowMath.decay(shadowCum, vm.getBlockTimestamp() - uint256(prevTs), decayLen);

            (, Vm.Log[] memory logs) = swap(zeroForOne, exactIn ? -int256(amount) : int256(amount), false);

            uint256 realized = ImpactOracle.realizedImpactPips(manager, poolId, sqrtBefore);
            shadowCum = Phase3ShadowMath.addSat(ImpactOracle.directional(zeroForOne, realized), decayed);

            (, uint48 ts,, int256 cumOnChain) = hook.poolData(poolId);
            assertEq(cumOnChain, shadowCum, "ACC-1: on-chain cum != shadow recurrence");
            // opaque timestamp read (TIMESTAMP-fold hazard); ts is a contract read
            assertEq(uint256(ts), vm.getBlockTimestamp(), "ACC-1: lastSwapTimestamp must stamp the swap block");

            // the emitted realized impact must equal the slot0-recomputed one — this is the
            // non-circular check the doc flags: a hook emitting a wrong realized impact
            // while storing a matching cum would fool an event-fed oracle but not this one
            AfterSwapEventData memory a = getAfterSwapEventData(logs);
            assertEq(a.priceImpact, realized, "ACC-1: emitted realized impact != independent slot0 recomputation");
            assertEq(a.cumPriceImpact, shadowCum, "ACC-1: emitted cum != shadow recurrence");

            prevTs = ts;
        }
    }
}

/// @notice phase3-differential — ACC-9: no systematic under-charge from sim-vs-real
///         divergence, checked at the live-hook level.
///
/// The fee is computed from the fee=0 simulation but the accumulator stores the realized
/// (LP-fee-reduced) move, so for a single isolated swap on the simulate path:
///   - exact-input:  simulated priceImpact (BeforeSwap) >= realized priceImpact (AfterSwap).
///     Exactness of the bound: the simulator moves sqrtPrice at least as far (fee=0 uses
///     the gross input), and the geometric-mean impact reading |r-1|/sqrt(r) is monotone in
///     the move ratio r from the shared pre-swap price — so the inequality is exact, no
///     tolerance is needed.
///   - exact-output: equality. The exact-output price path is fee-independent (fees load
///     the input side only), so the fee=0 simulation is byte-exact (SIM-1 at hook level).
contract Phase3_Acc9_SimVsRealizedTest is Phase3HookTestBase {
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(TICK_LOWER, TICK_UPPER, 1e12, initSqrtP, false);
        // warmup swap stamps the swap clock before the measured stream
        swap(true, -1e8, false);
        vm.warp(block.timestamp + 60);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_acc9_exactIn_simNeverBelowRealized(uint256 amount, bool zeroForOne) public {
        amount = bound(amount, 1e7, 3e10);
        (, Vm.Log[] memory logs) = swap(zeroForOne, -int256(amount), false);

        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);
        AfterSwapEventData memory a = getAfterSwapEventData(logs);

        assertGe(
            b.priceImpact, a.priceImpact, "ACC-9: fee=0 simulated impact must never understate the realized impact"
        );
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_acc9_exactOut_simEqualsRealized(uint256 amount, bool zeroForOne) public {
        amount = bound(amount, 1e7, 1e10);
        (, Vm.Log[] memory logs) = swap(zeroForOne, int256(amount), false);

        BeforeSwapEventData memory b = getBeforeSwapEventData(logs);
        AfterSwapEventData memory a = getAfterSwapEventData(logs);

        assertEq(
            b.priceImpact,
            a.priceImpact,
            "ACC-9: exact-output simulated impact must equal realized (fee-independent path)"
        );
    }
}
