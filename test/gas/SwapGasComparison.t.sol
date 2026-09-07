// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookFlags} from "../../script/utils/HookFlags.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";
import {SimHook} from "../../src/SimHook.sol";
import {HookMath} from "../../src/lib/HookMath.sol";

/**
 * @notice Head-to-head gas comparison: vanilla v4 swap vs SimHook swap.
 *
 *         Two pools share the same currencies, same initial price, same liquidity range.
 *         Only the hook + fee mode differs. Same swap is executed against each pool and
 *         per-swap gas is captured via vm.snapshotGasLastCall.
 *
 *         Both routers are measured:
 *           - swapRouterNoChecks: matches v4-core's "simple swap" baseline (~123k gas)
 *           - swapRouter (PoolSwapTest): the heavier router with delta checks
 *
 *         Both code paths are measured:
 *           - first swap: cold storage slots, pricing off a zero accumulator
 *           - steady-state swap: warm slots, full dynamic-fee logic
 */
contract SwapGasComparison is Test, ArtifactDeployers {
    using PoolIdLibrary for PoolKey;

    // shared currencies (18-decimal MockERC20s minted by Deployers)
    Currency token0;
    Currency token1;

    // vanilla pool: no hook, static 3000 fee tier
    PoolKey vanillaKey;
    PoolId vanillaId;

    // SimHook pool: dynamic fee via SimHook
    PoolKey simKey;
    PoolId simId;
    SimHook simHook;

    AscntGovernance governance;

    // swap params: small exact-input zeroForOne so we don't cross many ticks
    int256 constant SWAP_AMOUNT = -0.01 ether; // 0.01 token0
    int24 constant TARGET_TICK = 0; // 1:1 price
    int24 constant TICK_SPACING = 60;
    int24 constant LIQ_LOWER = -6000;
    int24 constant LIQ_UPPER = 6000;
    uint256 constant LIQ_AMOUNT0 = 100 ether;

    // pool config (15-min decay — the configuration we concluded was sane for stables)
    uint24 constant MIN_MIN_FEE = 500;
    uint24 constant MAX_MIN_FEE = 5_000;
    uint24 constant MAX_FEE = 200_000;
    uint256 constant TIME_DECAY_LENGTH = 900;
    uint48 constant JIT_LOCK_BLOCKS = 0;
    uint32 constant K_PIPS = uint32(2 * HookMath.PIPS_SCALE); // 2.0x midpoint
    uint32 constant C_PIPS = uint32(HookMath.PIPS_SCALE); // 1.0x midpoint

    function setUp() public {
        deployArtifactManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = currency0;
        token1 = currency1;

        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TARGET_TICK);

        // 1) vanilla pool — no hook, static 3000-pip fee
        (vanillaKey, vanillaId) =
            initPool(token0, token1, IHooks(address(0)), uint24(3000), TICK_SPACING, initialSqrtPriceX96);

        // 2) Deploy shared governance for the hook
        governance = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance",
                abi.encode(address(this), address(new MockTimelock()), address(0), address(0))
            )
        );

        // Shared with TestUtils via HookFlags so the mask can't drift; must mirror
        // SimHook.getHookPermissions(). NB: this gas suite deliberately does NOT register the
        // hook as a governance subscriber (lean baseline) — isVerified() is false here.
        uint160 hookFlagsMask = HookFlags.simHookMask();

        // 3) SimHook pool
        address simHookAddr = address(hookFlagsMask | uint160(0x10000)); // off vanilla path
        deployCodeTo("SimHook.sol", abi.encode(manager, governance), simHookAddr);
        simHook = SimHook(simHookAddr);

        (simKey, simId) = initPool(
            token0, token1, IHooks(simHookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, initialSqrtPriceX96
        );

        simHook.configurePool(
            simId, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, TIME_DECAY_LENGTH, JIT_LOCK_BLOCKS, K_PIPS, C_PIPS
        );

        // 4) Add identical liquidity to both pools
        _addLiquidity(vanillaKey, initialSqrtPriceX96);
        _addLiquidity(simKey, initialSqrtPriceX96);
    }

    function _addLiquidity(PoolKey memory key, uint160 initialSqrtPriceX96) internal {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(LIQ_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(LIQ_UPPER);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, LIQ_AMOUNT0);
        modifyLiquidityRouter.modifyLiquidity{value: 1}(
            key,
            ModifyLiquidityParams({
                tickLower: LIQ_LOWER,
                tickUpper: LIQ_UPPER,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // unused but silences "initialSqrtPriceX96 unused" warning if we trim later
        initialSqrtPriceX96;
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return
            SwapParams({zeroForOne: true, amountSpecified: SWAP_AMOUNT, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
    }

    function _swapNoChecks(PoolKey memory key) internal {
        swapRouterNoChecks.swap(key, _swapParams());
    }

    function _swapPoolSwapTest(PoolKey memory key) internal {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(key, _swapParams(), ts, ZERO_BYTES);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  GAS SNAPSHOTS — swapRouterNoChecks (matches v4-core's "simple swap" reference)
    // ─────────────────────────────────────────────────────────────────────────

    // NOTE on pairing: the STEADY rows below are the like-for-like comparison — each pool is
    // pre-warmed with one swap, then the NEXT swap is measured. The FIRST/cold rows are only
    // comparable to each other. Mixing them (cold vanilla vs steady simhook) understates the
    // hook's true overhead by the cold-SLOAD delta and must not be quoted.

    function test_gas_swapNoChecks_vanillaFirst() public {
        _swapNoChecks(vanillaKey);
        vm.snapshotGasLastCall("swap_noChecks: vanilla v4 FIRST (cold-slot swap, no hook)");
    }

    function test_gas_swapNoChecks_vanillaSteady() public {
        _swapNoChecks(vanillaKey); // warm-up: same treatment as the simhook STEADY row
        _swapNoChecks(vanillaKey); // measured
        vm.snapshotGasLastCall("swap_noChecks: vanilla v4 STEADY (static fee, no hook)");
    }

    function test_gas_swapNoChecks_simHookFirst() public {
        _swapNoChecks(simKey);
        vm.snapshotGasLastCall("swap_noChecks: simhook FIRST (cold-slot swap)");
    }

    function test_gas_swapNoChecks_simHookSteady() public {
        _swapNoChecks(simKey); // warm-up: stamps poolData, warms the slots
        _swapNoChecks(simKey); // measured: full dynamic-fee path
        vm.snapshotGasLastCall("swap_noChecks: simhook STEADY (full dyn-fee path)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  GAS SNAPSHOTS — swapRouter (PoolSwapTest, heavier router with delta checks)
    // ─────────────────────────────────────────────────────────────────────────

    function test_gas_swapRouter_vanillaFirst() public {
        _swapPoolSwapTest(vanillaKey);
        vm.snapshotGasLastCall("swap_full: vanilla v4 FIRST (cold-slot swap, no hook)");
    }

    function test_gas_swapRouter_vanillaSteady() public {
        _swapPoolSwapTest(vanillaKey); // warm-up: same treatment as the simhook STEADY row
        _swapPoolSwapTest(vanillaKey); // measured
        vm.snapshotGasLastCall("swap_full: vanilla v4 STEADY (static fee, no hook)");
    }

    function test_gas_swapRouter_simHookSteady() public {
        _swapPoolSwapTest(simKey);
        _swapPoolSwapTest(simKey);
        vm.snapshotGasLastCall("swap_full: simhook STEADY (full dyn-fee path)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  SUMMARY — prints two tables:
    //    A. cold-pool first swap (apples-to-apples: each pool's first-ever swap)
    //    B. warm-state steady swap (each pool pre-warmed with one swap, then measured)
    //
    //  Comparing cold vs warm across pools would mislead — cold storage SLOADs
    //  (2100 gas each) dominate the first-ever swap, so all pools' first swaps
    //  are compared to each other, and all pools' warm swaps are compared to
    //  each other.
    // ─────────────────────────────────────────────────────────────────────────

    function _measureNoChecks(PoolKey memory key) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        _swapNoChecks(key);
        used = g0 - gasleft();
    }

    function _measureFull(PoolKey memory key) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        _swapPoolSwapTest(key);
        used = g0 - gasleft();
    }

    function test_gas_summary() public {
        // ============ TABLE A — COLD: each pool's first swap ============
        uint256 vanillaFirstNC = _measureNoChecks(vanillaKey);
        uint256 simFirstNC = _measureNoChecks(simKey);

        // ============ TABLE B — WARM: each pool's next swap after warmup ============
        uint256 vanillaSteadyNC = _measureNoChecks(vanillaKey);
        uint256 simSteadyNC = _measureNoChecks(simKey);

        // Full PoolSwapTest router — measure warm-state only (the realistic case)
        uint256 vanillaSteadyFull = _measureFull(vanillaKey);
        uint256 simSteadyFull = _measureFull(simKey);

        console.log("");
        console.log("====================================================================");
        console.log(" SWAP GAS COMPARISON  (FOUNDRY_PROFILE=default, optimizer_runs=200)");
        console.log("====================================================================");
        console.log("");
        console.log("TABLE A: first swap on a fresh pool (cold storage)");
        console.log("  router=swapRouterNoChecks");
        console.log("  vanilla v4 (no hook):              ", vanillaFirstNC);
        console.log("  simhook  (first swap, cold slots): ", simFirstNC);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simFirstNC, vanillaFirstNC));
        console.log("");
        console.log("TABLE B: warm-state swap (each pool pre-warmed)");
        console.log("  router=swapRouterNoChecks");
        console.log("  vanilla v4 (no hook):              ", vanillaSteadyNC);
        console.log("  simhook  (full dyn-fee logic):     ", simSteadyNC);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simSteadyNC, vanillaSteadyNC));
        console.log("");
        console.log("  router=swapRouter (PoolSwapTest, heavier)");
        console.log("  vanilla v4 (no hook):              ", vanillaSteadyFull);
        console.log("  simhook  (full dyn-fee logic):     ", simSteadyFull);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simSteadyFull, vanillaSteadyFull));
        console.log("====================================================================");
    }

    function _delta(uint256 a, uint256 b) internal pure returns (int256) {
        return int256(a) - int256(b);
    }
}
