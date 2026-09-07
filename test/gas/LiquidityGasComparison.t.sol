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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";
import {SimHook} from "../../src/SimHook.sol";
import {HookMath} from "../../src/lib/HookMath.sol";

/**
 * @notice Head-to-head gas comparison: vanilla v4 liquidity ops vs SimHook liquidity ops.
 *
 *         Companion to SwapGasComparison. Three pools share the same currencies, initial price
 *         and seed liquidity; only the hook and its JIT-lock config differ:
 *           - vanilla:    no hook, static 3000 fee tier
 *           - simhook:    SimHook, jitLockBlocks = 0
 *           - simhookJit: SimHook, jitLockBlocks > 0 (its own pool — configurePool is one-shot)
 *
 *         Each row is one router call captured via vm.snapshotGasLastCall:
 *           - add:    FIRST (fresh position on an uninitialised tick range) and STEADY (second add
 *                     to that position). The hook adds beforeAddLiquidity (one governance pause
 *                     read) and afterAddLiquidity (config read; JIT stamp when jitLockBlocks > 0).
 *           - remove: STEADY partial remove. The hook adds beforeRemoveLiquidity: a no-op at
 *                     jitLockBlocks = 0, a lock-window check otherwise (measured outside the
 *                     window, i.e. the success path).
 *           - poke:   zero-delta modify that collects fees. Routes through beforeRemoveLiquidity,
 *                     which exempts it from the JIT lock, so it is measured inside the window.
 *
 *         Both routers are measured, as in SwapGasComparison:
 *           - modifyLiquidityNoChecks: bare settle/take, closest to the raw pool cost
 *           - modifyLiquidityRouter (PoolModifyLiquidityTest): adds position and delta checks
 */
contract LiquidityGasComparison is Test, ArtifactDeployers {
    using PoolIdLibrary for PoolKey;

    Currency token0;
    Currency token1;

    // vanilla pool: no hook, static 3000 fee tier
    PoolKey vanillaKey;
    PoolId vanillaId;

    // SimHook pool, jitLockBlocks = 0
    PoolKey simKey;
    PoolId simId;

    // SimHook pool, jitLockBlocks = JIT_LOCK_BLOCKS (distinct tick spacing => distinct PoolId)
    PoolKey simJitKey;
    PoolId simJitId;

    SimHook simHook;
    AscntGovernance governance;

    int24 constant TARGET_TICK = 0; // 1:1 price
    int24 constant TICK_SPACING = 60;
    int24 constant JIT_TICK_SPACING = 30;
    int24 constant SEED_LOWER = -6000;
    int24 constant SEED_UPPER = 6000;
    uint256 constant SEED_AMOUNT0 = 100 ether;

    // measured position: its own tick range (both ticks uninitialised) so FIRST includes tick init
    int24 constant POS_LOWER = -1200;
    int24 constant POS_UPPER = 1200;
    bytes32 constant POS_SALT = bytes32(uint256(1));
    int256 constant ADD_LIQ = 1e18;
    int256 constant REMOVE_LIQ = 1e17;

    // pool config — same as SwapGasComparison; the JIT lock is the only per-pool difference
    uint24 constant MIN_MIN_FEE = 500;
    uint24 constant MAX_MIN_FEE = 5_000;
    uint24 constant MAX_FEE = 200_000;
    uint256 constant TIME_DECAY_LENGTH = 900;
    uint48 constant JIT_LOCK_BLOCKS = 10;
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

        // 2) Shared governance for the hook (not registered as a subscriber — lean baseline,
        //    same as SwapGasComparison)
        governance = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance",
                abi.encode(address(this), address(new MockTimelock()), address(0), address(0))
            )
        );

        uint160 hookFlagsMask = HookFlags.simHookMask();
        address simHookAddr = address(hookFlagsMask | uint160(0x10000));
        deployCodeTo("SimHook.sol", abi.encode(manager, governance), simHookAddr);
        simHook = SimHook(simHookAddr);

        // 3) SimHook pool, no JIT lock
        (simKey, simId) = initPool(
            token0, token1, IHooks(simHookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, initialSqrtPriceX96
        );
        simHook.configurePool(simId, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, TIME_DECAY_LENGTH, 0, K_PIPS, C_PIPS);

        // 4) SimHook pool, JIT lock configured
        (simJitKey, simJitId) = initPool(
            token0, token1, IHooks(simHookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, JIT_TICK_SPACING, initialSqrtPriceX96
        );
        simHook.configurePool(
            simJitId, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, TIME_DECAY_LENGTH, JIT_LOCK_BLOCKS, K_PIPS, C_PIPS
        );

        // 5) Identical seed liquidity in all three pools
        _seedLiquidity(vanillaKey);
        _seedLiquidity(simKey);
        _seedLiquidity(simJitKey);
    }

    function _seedLiquidity(PoolKey memory key) internal {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(SEED_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(SEED_UPPER);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, SEED_AMOUNT0);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: SEED_LOWER,
                tickUpper: SEED_UPPER,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _params(int256 liquidityDelta) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: POS_LOWER,
            tickUpper: POS_UPPER,
            liquidityDelta: liquidityDelta,
            salt: POS_SALT
        });
    }

    function _modNoChecks(PoolKey memory key, int256 liquidityDelta) internal {
        modifyLiquidityNoChecks.modifyLiquidity(key, _params(liquidityDelta), ZERO_BYTES);
    }

    function _modFull(PoolKey memory key, int256 liquidityDelta) internal {
        modifyLiquidityRouter.modifyLiquidity(key, _params(liquidityDelta), ZERO_BYTES);
    }

    function _rollPastJitLock() internal {
        vm.roll(vm.getBlockNumber() + JIT_LOCK_BLOCKS);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  GAS SNAPSHOTS — modifyLiquidityNoChecks (bare settle/take)
    // ─────────────────────────────────────────────────────────────────────────

    // NOTE on pairing: FIRST rows are only comparable to each other (cold slots + tick init),
    // STEADY rows only to each other. Every STEADY row gets the same warm-up on every pool.

    // --- add ---

    function test_gas_addNoChecks_vanillaFirst() public {
        _modNoChecks(vanillaKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_noChecks: vanilla v4 FIRST (fresh position, no hook)");
    }

    function test_gas_addNoChecks_vanillaSteady() public {
        _modNoChecks(vanillaKey, ADD_LIQ); // warm-up: creates the position
        _modNoChecks(vanillaKey, ADD_LIQ); // measured
        vm.snapshotGasLastCall("add_noChecks: vanilla v4 STEADY (existing position, no hook)");
    }

    function test_gas_addNoChecks_simHookFirst() public {
        _modNoChecks(simKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_noChecks: simhook FIRST (fresh position, jitLock=0)");
    }

    function test_gas_addNoChecks_simHookSteady() public {
        _modNoChecks(simKey, ADD_LIQ);
        _modNoChecks(simKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_noChecks: simhook STEADY (existing position, jitLock=0)");
    }

    function test_gas_addNoChecks_simHookJitFirst() public {
        _modNoChecks(simJitKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_noChecks: simhook FIRST (fresh position, jitLock configured)");
    }

    function test_gas_addNoChecks_simHookJitSteady() public {
        _modNoChecks(simJitKey, ADD_LIQ);
        _modNoChecks(simJitKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_noChecks: simhook STEADY (existing position, jitLock configured)");
    }

    // --- remove ---

    function test_gas_removeNoChecks_vanillaSteady() public {
        _modNoChecks(vanillaKey, ADD_LIQ);
        _modNoChecks(vanillaKey, -REMOVE_LIQ); // warm-up
        _modNoChecks(vanillaKey, -REMOVE_LIQ); // measured
        vm.snapshotGasLastCall("remove_noChecks: vanilla v4 STEADY (partial remove, no hook)");
    }

    function test_gas_removeNoChecks_simHookSteady() public {
        _modNoChecks(simKey, ADD_LIQ);
        _modNoChecks(simKey, -REMOVE_LIQ);
        _modNoChecks(simKey, -REMOVE_LIQ);
        vm.snapshotGasLastCall("remove_noChecks: simhook STEADY (partial remove, jitLock=0)");
    }

    function test_gas_removeNoChecks_simHookJitSteady() public {
        _modNoChecks(simJitKey, ADD_LIQ);
        _rollPastJitLock(); // success path of the lock check
        _modNoChecks(simJitKey, -REMOVE_LIQ);
        _modNoChecks(simJitKey, -REMOVE_LIQ);
        vm.snapshotGasLastCall("remove_noChecks: simhook STEADY (partial remove, jitLock configured, outside window)");
    }

    // --- zero-delta fee poke ---

    function test_gas_pokeNoChecks_vanillaSteady() public {
        _modNoChecks(vanillaKey, ADD_LIQ);
        _modNoChecks(vanillaKey, 0); // warm-up
        _modNoChecks(vanillaKey, 0); // measured
        vm.snapshotGasLastCall("poke_noChecks: vanilla v4 STEADY (zero-delta fee poke, no hook)");
    }

    function test_gas_pokeNoChecks_simHookJitSteady() public {
        _modNoChecks(simJitKey, ADD_LIQ);
        // no roll: the poke is measured INSIDE the lock window to pin the JIT exemption
        _modNoChecks(simJitKey, 0);
        _modNoChecks(simJitKey, 0);
        vm.snapshotGasLastCall("poke_noChecks: simhook STEADY (zero-delta fee poke, inside JIT window)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  GAS SNAPSHOTS — modifyLiquidityRouter (PoolModifyLiquidityTest, with checks)
    // ─────────────────────────────────────────────────────────────────────────

    function test_gas_addRouter_vanillaFirst() public {
        _modFull(vanillaKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_full: vanilla v4 FIRST (fresh position, no hook)");
    }

    function test_gas_addRouter_vanillaSteady() public {
        _modFull(vanillaKey, ADD_LIQ);
        _modFull(vanillaKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_full: vanilla v4 STEADY (existing position, no hook)");
    }

    function test_gas_addRouter_simHookFirst() public {
        _modFull(simKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_full: simhook FIRST (fresh position, jitLock=0)");
    }

    function test_gas_addRouter_simHookSteady() public {
        _modFull(simKey, ADD_LIQ);
        _modFull(simKey, ADD_LIQ);
        vm.snapshotGasLastCall("add_full: simhook STEADY (existing position, jitLock=0)");
    }

    function test_gas_removeRouter_vanillaSteady() public {
        _modFull(vanillaKey, ADD_LIQ);
        _modFull(vanillaKey, -REMOVE_LIQ);
        _modFull(vanillaKey, -REMOVE_LIQ);
        vm.snapshotGasLastCall("remove_full: vanilla v4 STEADY (partial remove, no hook)");
    }

    function test_gas_removeRouter_simHookSteady() public {
        _modFull(simKey, ADD_LIQ);
        _modFull(simKey, -REMOVE_LIQ);
        _modFull(simKey, -REMOVE_LIQ);
        vm.snapshotGasLastCall("remove_full: simhook STEADY (partial remove, jitLock=0)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  SUMMARY — prints four tables (cold add, warm add, warm remove, poke), each comparing
    //  like with like across pools, as SwapGasComparison does for swaps.
    // ─────────────────────────────────────────────────────────────────────────

    function _measureNoChecks(PoolKey memory key, int256 liquidityDelta) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        _modNoChecks(key, liquidityDelta);
        used = g0 - gasleft();
    }

    function _measureFull(PoolKey memory key, int256 liquidityDelta) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        _modFull(key, liquidityDelta);
        used = g0 - gasleft();
    }

    function test_gas_summary() public {
        // ============ TABLE A — COLD: first add, fresh position ============
        uint256 vanillaAddFirst = _measureNoChecks(vanillaKey, ADD_LIQ);
        uint256 simAddFirst = _measureNoChecks(simKey, ADD_LIQ);
        uint256 simJitAddFirst = _measureNoChecks(simJitKey, ADD_LIQ);

        // ============ TABLE B — WARM: second add to the same position ============
        uint256 vanillaAddSteady = _measureNoChecks(vanillaKey, ADD_LIQ);
        uint256 simAddSteady = _measureNoChecks(simKey, ADD_LIQ);
        uint256 simJitAddSteady = _measureNoChecks(simJitKey, ADD_LIQ);

        // ============ TABLE C — WARM: partial remove after one warm-up remove ============
        _rollPastJitLock();
        _measureNoChecks(vanillaKey, -REMOVE_LIQ);
        _measureNoChecks(simKey, -REMOVE_LIQ);
        _measureNoChecks(simJitKey, -REMOVE_LIQ);
        uint256 vanillaRemove = _measureNoChecks(vanillaKey, -REMOVE_LIQ);
        uint256 simRemove = _measureNoChecks(simKey, -REMOVE_LIQ);
        uint256 simJitRemove = _measureNoChecks(simJitKey, -REMOVE_LIQ);

        // ============ TABLE D — zero-delta fee poke after one warm-up poke ============
        _measureNoChecks(vanillaKey, 0);
        _measureNoChecks(simJitKey, 0);
        uint256 vanillaPoke = _measureNoChecks(vanillaKey, 0);
        uint256 simJitPoke = _measureNoChecks(simJitKey, 0);

        // Full router — warm add and warm remove only (the realistic case)
        _measureFull(vanillaKey, ADD_LIQ);
        _measureFull(simKey, ADD_LIQ);
        uint256 vanillaAddFull = _measureFull(vanillaKey, ADD_LIQ);
        uint256 simAddFull = _measureFull(simKey, ADD_LIQ);
        _measureFull(vanillaKey, -REMOVE_LIQ);
        _measureFull(simKey, -REMOVE_LIQ);
        uint256 vanillaRemoveFull = _measureFull(vanillaKey, -REMOVE_LIQ);
        uint256 simRemoveFull = _measureFull(simKey, -REMOVE_LIQ);

        console.log("");
        console.log("====================================================================");
        console.log(" LIQUIDITY GAS COMPARISON  (FOUNDRY_PROFILE=default, optimizer_runs=200)");
        console.log("====================================================================");
        console.log("");
        console.log("TABLE A: first add, fresh position (cold slots + tick init)");
        console.log("  router=modifyLiquidityNoChecks");
        console.log("  vanilla v4 (no hook):              ", vanillaAddFirst);
        console.log("  simhook  (jitLock=0):              ", simAddFirst);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simAddFirst, vanillaAddFirst));
        console.log("  simhook  (jitLock configured):     ", simJitAddFirst);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simJitAddFirst, vanillaAddFirst));
        console.log("");
        console.log("TABLE B: warm add, existing position");
        console.log("  router=modifyLiquidityNoChecks");
        console.log("  vanilla v4 (no hook):              ", vanillaAddSteady);
        console.log("  simhook  (jitLock=0):              ", simAddSteady);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simAddSteady, vanillaAddSteady));
        console.log("  simhook  (jitLock configured):     ", simJitAddSteady);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simJitAddSteady, vanillaAddSteady));
        console.log("");
        console.log("  router=modifyLiquidityRouter (PoolModifyLiquidityTest, heavier)");
        console.log("  vanilla v4 (no hook):              ", vanillaAddFull);
        console.log("  simhook  (jitLock=0):              ", simAddFull);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simAddFull, vanillaAddFull));
        console.log("");
        console.log("TABLE C: warm partial remove");
        console.log("  router=modifyLiquidityNoChecks");
        console.log("  vanilla v4 (no hook):              ", vanillaRemove);
        console.log("  simhook  (jitLock=0):              ", simRemove);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simRemove, vanillaRemove));
        console.log("  simhook  (jitLock, outside window):", simJitRemove);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simJitRemove, vanillaRemove));
        console.log("");
        console.log("  router=modifyLiquidityRouter (PoolModifyLiquidityTest, heavier)");
        console.log("  vanilla v4 (no hook):              ", vanillaRemoveFull);
        console.log("  simhook  (jitLock=0):              ", simRemoveFull);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simRemoveFull, vanillaRemoveFull));
        console.log("");
        console.log("TABLE D: zero-delta fee poke (inside the JIT window on the simhook pool)");
        console.log("  router=modifyLiquidityNoChecks");
        console.log("  vanilla v4 (no hook):              ", vanillaPoke);
        console.log("  simhook  (jitLock configured):     ", simJitPoke);
        console.log("  simhook  overhead vs vanilla:      ", _delta(simJitPoke, vanillaPoke));
        console.log("====================================================================");
    }

    function _delta(uint256 a, uint256 b) internal pure returns (int256) {
        return int256(a) - int256(b);
    }
}
