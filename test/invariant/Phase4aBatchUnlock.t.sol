// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {TestUtils} from "../utils/TestUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";
import {SimHookHarness} from "../harness/SimHookHarness.sol";
import {ImpactOracle} from "../utils/ImpactOracle.sol";
import {P4Ev} from "./helpers/P4Helpers.sol";
import {P4MultiSwapRouter} from "./helpers/P4MultiSwapRouter.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Phase-4a: multiple swaps batched inside ONE PoolManager.unlock — the surface where a
///         stale transient stash (SETTLE-10), a cross-pool stash collision (SETTLE-11), an
///         interleaved before/after price bracket (ACC-5), or a hook delta that fails to net
///         against the take (SETTLE-5) would actually show up. PoolSwapTest can't batch, so this
///         drives the local P4MultiSwapRouter.
contract Phase4aBatchUnlockTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;

    P4MultiSwapRouter internal router;

    PoolKey internal keyB;
    PoolId internal poolIdB;

    address internal constant TREASURY = address(0xBEEF);
    uint16 internal constant BPS = 2000;
    uint24 internal constant MAX_FEE_A = 10_000; // StablePairPoolConfig.maxFee
    uint24 internal constant MAX_FEE_B = 500_000;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(-600, 600, 1e12, initSqrtP, false);

        // pool B: same currencies/hook, different tickSpacing + config (different fee rates)
        (keyB, poolIdB) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, initSqrtP);
        hook.configurePool(poolIdB, 50, 50, MAX_FEE_B, 3600, 0, 2e6, 1e6);
        modifyLiquidityRouter.modifyLiquidity(
            keyB, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 3e13, salt: bytes32(0)}), ""
        );

        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(BPS);

        router = new P4MultiSwapRouter(manager, address(hook));
        MockERC20(Currency.unwrap(currency0)).transfer(address(router), 1e24);
        MockERC20(Currency.unwrap(currency1)).transfer(address(router), 1e24);
    }

    /// @dev First-swap fee from a zero accumulator: k x midpoint of the 0 -> P leg =
    ///      mulDiv(P, kPips, 2e6) == P at the canonical k = 2e6, clamped into
    ///      [effectiveMinFee, maxFee].
    function _freshSwapFee(P4Ev.BeforeSwapEv memory b, uint24 maxFee) internal pure returns (uint24) {
        uint256 raw = b.priceImpact;
        if (raw < b.effMinFee) return b.effMinFee;
        if (raw > maxFee) return maxFee;
        return uint24(raw);
    }

    function _step(
        PoolKey memory k,
        bool zeroForOne,
        bool exactOut,
        uint256 amount
    ) internal pure returns (P4MultiSwapRouter.Step memory) {
        return P4MultiSwapRouter.Step({
            key: k,
            params: SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactOut ? int256(amount) : -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        });
    }

    /// @dev Shared batch verifier. For every swap i in the batch:
    ///       - the hook's open currency deltas were ZERO immediately after the swap (SETTLE-5:
    ///         the returned int128 nets the take exactly, observed mid-unlock);
    ///       - the ProtocolFeeTaken amount equals floor(mag_i * hookFee_i / 1e6) where hookFee_i
    ///         is derived from swap i's OWN BeforeSwap dynamicFee (SETTLE-10/11: never a stale or
    ///         other-pool rate);
    ///       - the take sits in the unspecified currency's event slot (SETTLE-19 slice).
    function _checkBatch(
        P4MultiSwapRouter.Step[] memory steps,
        P4MultiSwapRouter.Obs[] memory obs,
        Vm.Log[] memory logs
    ) internal pure returns (P4Ev.BeforeSwapEv[] memory bevs, P4Ev.AfterSwapEv[] memory aevs) {
        bevs = P4Ev.beforeSwaps(logs);
        aevs = P4Ev.afterSwaps(logs);
        P4Ev.FeeTakenEv[] memory takes = P4Ev.feeTakes(logs);
        assertEq(bevs.length, steps.length, "one BeforeSwap per batched swap");
        assertEq(aevs.length, steps.length, "one AfterSwap per batched swap");
        assertEq(takes.length, steps.length, "every batched swap must take (amounts sized so)");

        for (uint256 i = 0; i < steps.length; i++) {
            bytes32 pid = PoolId.unwrap(steps[i].key.toId());
            assertEq(bevs[i].poolId, pid, "BeforeSwap order/pool mismatch");
            assertEq(aevs[i].poolId, pid, "AfterSwap order/pool mismatch");
            assertEq(takes[i].poolId, pid, "ProtocolFeeTaken order/pool mismatch");

            // SETTLE-5: no dangling hook delta mid-unlock
            assertEq(obs[i].hookDelta0, 0, "hook currency0 delta dangling after swap");
            assertEq(obs[i].hookDelta1, 0, "hook currency1 delta dangling after swap");

            bool exactInput = steps[i].params.amountSpecified < 0;
            bool unspecIs0 = (exactInput != steps[i].params.zeroForOne);
            uint256 take = unspecIs0 ? uint256(takes[i].amount0) : uint256(takes[i].amount1);
            uint256 otherSlot = unspecIs0 ? uint256(takes[i].amount1) : uint256(takes[i].amount0);
            assertGt(take, 0, "batched swap produced a zero take");
            assertEq(otherSlot, 0, "take recorded in the specified currency slot");

            int128 unspec = unspecIs0 ? obs[i].amount0 : obs[i].amount1;
            uint256 unspecAbs = unspec >= 0 ? uint256(uint128(unspec)) : uint256(uint128(-unspec));
            uint256 hookFee = (uint256(bevs[i].dynFee) * uint256(BPS)) / 10_000;
            // The router delta is POST-hook-delta. v4 does swapDelta -= (+take) on the unspecified
            // currency, so the hook's own pre-take magnitude is:
            //   exact-input  (unspecified = output, +delta reduced by take): mag = |delta| + take
            //   exact-output (unspecified = input,  -delta grown   by take): mag = |delta| - take
            uint256 mag = exactInput ? unspecAbs + take : unspecAbs - take;
            // SETTLE-10/11: settled at THIS swap's own split rate
            assertEq(take, (mag * hookFee) / 1e6, "take != own-swap split rate");
            assertLt(take, mag, "take >= unspecified magnitude");
        }
    }

    /// @notice SETTLE-5 + SETTLE-10: a fresh-pool first swap then dynamic swaps of differing
    ///         size/direction/exactness on ONE pool inside ONE unlock. Each afterSwap must settle
    ///         its own beforeSwap's split; each swap must leave the hook with zero open deltas.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_settle5_settle10_batchedSwapsSettleOwnSplit(uint256 seed) public {
        P4MultiSwapRouter.Step[] memory steps = new P4MultiSwapRouter.Step[](4);
        steps[0] = _step(key, true, false, _bound(seed, 1e9, 1e10)); // FIRST swap prices off cum = 0
        // Corrective sized >= 4x the first swap. The crossing-zero fee equals the fresh fee P0
        // exactly when the corrective's impact is (3 + sqrt(3)) / 2 ~ 2.37 x P0 (the fuzzer found
        // that root: 1128 == 1128), and grows monotonically past it; oneForZero impact is
        // super-linear in amount while zeroForOne is sub-linear, so a 4x amount ratio keeps the
        // impact ratio above the root.
        steps[1] = _step(key, false, false, _bound(seed >> 32, 4e10, 6e10)); // large corrective => different rate
        steps[2] = _step(key, true, true, _bound(seed >> 64, 1e9, 5e9)); // exact-out quadrant
        steps[3] = _step(key, false, false, _bound(seed >> 96, 1e9, 4e10));

        vm.recordLogs();
        P4MultiSwapRouter.Obs[] memory obs = router.batchSwap(steps);
        (P4Ev.BeforeSwapEv[] memory bevs,) = _checkBatch(steps, obs, vm.getRecordedLogs());

        // the batch really did mix differing fee rates — otherwise the "own split, not the
        // prior one's" check has no discriminating power
        assertEq(bevs[0].decayedCum, 0, "swap #1 must price off a zero accumulator");
        assertEq(bevs[0].dynFee, _freshSwapFee(bevs[0], MAX_FEE_A), "swap #1 fee != fresh-push recompute");
        assertNotEq(bevs[1].dynFee, bevs[0].dynFee, "batch must contain differing fee rates");
    }

    /// @notice SETTLE-11: swaps on two pools with different fee configs interleaved in one unlock.
    ///         Each afterSwap must settle at its OWN pool's stashed rate (B's first swap is sized
    ///         an order of magnitude above A's so the two rates provably differ — a cross-pool
    ///         stash bleed shifts the take).
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_settle11_interleavedPoolsSettleOwnPoolRate(uint256 seed) public {
        P4MultiSwapRouter.Step[] memory steps = new P4MultiSwapRouter.Step[](4);
        steps[0] = _step(key, true, false, _bound(seed, 1e9, 1e10)); // A first swap (cum = 0)
        steps[1] = _step(keyB, true, false, _bound(seed >> 32, 2e10, 4e10)); // B first swap, far larger impact
        steps[2] = _step(key, false, false, _bound(seed >> 64, 2e9, 2e10)); // A dynamic
        steps[3] = _step(keyB, false, true, _bound(seed >> 96, 1e9, 5e9)); // B dynamic exact-out

        vm.recordLogs();
        P4MultiSwapRouter.Obs[] memory obs = router.batchSwap(steps);
        (P4Ev.BeforeSwapEv[] memory bevs,) = _checkBatch(steps, obs, vm.getRecordedLogs());

        assertEq(bevs[0].dynFee, _freshSwapFee(bevs[0], MAX_FEE_A), "A's first swap must price off A's own state");
        assertEq(bevs[1].dynFee, _freshSwapFee(bevs[1], MAX_FEE_B), "B's first swap must price off B's own state");
        assertNotEq(bevs[0].dynFee, bevs[1].dynFee, "the two pools' rates must differ to discriminate");
    }

    /// @notice ACC-5: several swaps on one pool inside one unlock — every afterSwap's realized
    ///         impact must be computed against ITS OWN bracket's before-price (recorded by the
    ///         router immediately before each manager.swap), recomputed with the independent
    ///         ImpactOracle rather than the hook's math.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_acc5_bracketsUseOwnBeforePrice(uint256 seed) public {
        P4MultiSwapRouter.Step[] memory steps = new P4MultiSwapRouter.Step[](4);
        steps[0] = _step(key, true, false, _bound(seed, 1e9, 2e10));
        steps[1] = _step(key, seed % 2 == 0, false, _bound(seed >> 32, 1e9, 2e10));
        steps[2] = _step(key, false, false, _bound(seed >> 64, 1e9, 2e10));
        steps[3] = _step(key, seed % 3 == 0, true, _bound(seed >> 96, 1e9, 5e9));

        vm.recordLogs();
        P4MultiSwapRouter.Obs[] memory obs = router.batchSwap(steps);
        (P4Ev.BeforeSwapEv[] memory bevs, P4Ev.AfterSwapEv[] memory aevs) =
            _checkBatch(steps, obs, vm.getRecordedLogs());

        for (uint256 i = 0; i < steps.length; i++) {
            // the hook's bracket price == the price this bracket actually started from
            assertEq(uint256(bevs[i].sqrtBefore), uint256(obs[i].sqrtBefore), "bracket before-price mismatch");
            assertEq(uint256(aevs[i].sqrtPrice), uint256(obs[i].sqrtAfter), "bracket after-price mismatch");
            // realized impact measured over exactly THIS bracket (independent oracle recompute)
            assertEq(
                aevs[i].priceImpact,
                ImpactOracle.priceImpactPips(obs[i].sqrtBefore, obs[i].sqrtAfter),
                "realized impact not measured over own bracket"
            );
            if (i > 0) {
                // brackets never interleave: each starts where the previous one ended
                assertEq(uint256(obs[i].sqrtBefore), uint256(obs[i - 1].sqrtAfter), "brackets interleaved");
            }
        }
    }
}

/// @notice SETTLE-11 (direct slot check): the transient hookFee stash is keyed by poolId — a
///         write for pool B must never touch pool A's stashed value. Uses the harness's readStash
///         inside a single test tx (transient storage persists across calls within one tx).
contract Phase4aStashIsolationTest is TestUtils {
    SimHookHarness internal harness;

    address internal constant STASH_TREASURY = address(0xBEEF);

    function setUp() public {
        address hookAddress = deployCoreAndHookCustomDecimals("SimHookHarness.sol", "USDC", "USDT", 6, 6, false);
        harness = SimHookHarness(hookAddress);
        // The split carves only while the LIVE `governance.treasury()` is set; with no treasury it
        // stashes 0 for every pool and this test would compare two empty slots. Wire one up (the
        // test contract is the timelock) so both pools stash a genuinely nonzero rate.
        governance.setTreasury(STASH_TREASURY);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_settle11_stashSlotsArePerPool(
        bytes32 rawA,
        bytes32 rawB,
        uint24 feeA,
        uint24 feeB,
        uint16 bps
    ) public {
        vm.assume(rawA != rawB);
        PoolId pidA = PoolId.wrap(rawA);
        PoolId pidB = PoolId.wrap(rawB);
        feeA = uint24(_bound(feeA, 0, 1_000_000));
        feeB = uint24(_bound(feeB, 0, 1_000_000));
        bps = uint16(_bound(bps, 1, 2000));
        harness.harnessSetProtocolFeeBps(bps);

        uint24 lpA = harness.exposedComputeProtocolFeeSplit(pidA, feeA);
        uint24 stashA = harness.readStash(pidA);

        uint24 lpB = harness.exposedComputeProtocolFeeSplit(pidB, feeB);

        // B's stash write must not have moved A's slot
        assertEq(harness.readStash(pidA), stashA, "pool B's stash write clobbered pool A's slot");
        assertEq(
            uint256(harness.readStash(pidB)), (uint256(feeB) * uint256(bps)) / 10_000, "pool B stash != its own split"
        );
        // split conservation on both pools
        assertEq(uint256(lpA) + uint256(stashA), uint256(feeA), "A split does not conserve fee");
        assertEq(uint256(lpB) + uint256(harness.readStash(pidB)), uint256(feeB), "B split does not conserve fee");
    }
}
