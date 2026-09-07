// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookFlags} from "../../script/utils/HookFlags.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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

/// @notice Head-to-head: vanilla v4 vs SimHook on identical laddered pools, across
///         a range of initialized-tick-crossing counts. Single test, prints a clean
///         table. Both pools use tickSpacing=10 and a position ladder that
///         initializes a tick every 10 below tick 0.
contract SimHookOverheadByCrossings is Test, ArtifactDeployers {
    using PoolIdLibrary for PoolKey;

    Currency token0;
    Currency token1;

    PoolKey vanillaKey;
    PoolId vanillaId;
    PoolKey simKey;
    PoolId simId;
    SimHook simHook;
    AscntGovernance governance;

    int24 constant TICK_SPACING = 10;
    int24 constant LADDER_LO = -500;
    int24 constant WIDE_LO = -10_000;
    int24 constant HI = 10_000;
    uint256 constant BASE_LIQ = 100 ether;
    uint256 constant SPIKE_LIQ = 0.1 ether;

    // SimHook config (matches SwapGasComparison defaults)
    uint24 constant MIN_MIN_FEE = 500;
    uint24 constant MAX_MIN_FEE = 5_000;
    uint24 constant MAX_FEE = 200_000;
    uint256 constant TIME_DECAY_LENGTH = 900;
    uint48 constant JIT_LOCK_BLOCKS = 0;
    uint32 constant K_PIPS = uint32(2 * HookMath.PIPS_SCALE);
    uint32 constant C_PIPS = uint32(HookMath.PIPS_SCALE);

    function setUp() public {
        deployArtifactManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = currency0;
        token1 = currency1;

        uint160 init = TickMath.getSqrtPriceAtTick(0);

        // 1) Vanilla v4 pool
        (vanillaKey, vanillaId) = initPool(token0, token1, IHooks(address(0)), uint24(100), TICK_SPACING, init);

        // 2) SimHook setup
        governance = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance",
                abi.encode(address(this), address(new MockTimelock()), address(0), address(0))
            )
        );
        // Shared with TestUtils via HookFlags so the mask can't drift; mirrors
        // SimHook.getHookPermissions(). Lean baseline: hook is not registered as a subscriber.
        uint160 mask = HookFlags.simHookMask();
        address simAddr = address(mask | uint160(0x10000));
        deployCodeTo("SimHook.sol", abi.encode(manager, governance), simAddr);
        simHook = SimHook(simAddr);

        (simKey, simId) = initPool(token0, token1, IHooks(simAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, init);
        simHook.configurePool(
            simId, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, TIME_DECAY_LENGTH, JIT_LOCK_BLOCKS, K_PIPS, C_PIPS
        );

        // 3) Identical laddered liquidity on both pools
        _ladder(vanillaKey);
        _ladder(simKey);
    }

    function _addPosition(PoolKey memory key, int24 lo, int24 hi, uint256 amount0) internal {
        uint160 sl = TickMath.getSqrtPriceAtTick(lo);
        uint160 su = TickMath.getSqrtPriceAtTick(hi);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sl, su, amount0);
        modifyLiquidityRouter.modifyLiquidity{value: 1}(
            key,
            ModifyLiquidityParams({
                tickLower: lo,
                tickUpper: hi,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _ladder(PoolKey memory key) internal {
        _addPosition(key, WIDE_LO, HI, BASE_LIQ);
        for (int24 t = -TICK_SPACING; t >= LADDER_LO; t -= TICK_SPACING) {
            _addPosition(key, t, HI, SPIKE_LIQ);
        }
    }

    function _swap(PoolKey memory key, int256 amt) internal returns (uint256 gas) {
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: amt, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        uint256 g0 = gasleft();
        swapRouter.swap(key, p, ts, "");
        gas = g0 - gasleft();
    }

    function _tick(PoolId id) internal view returns (int24 t) {
        (, t,,) = StateLibrary.getSlot0(manager, id);
    }

    function _abs(int24 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(uint24(x)) : uint256(uint24(-x));
    }

    function test_overheadByCrossings() public {
        // Warm up both pools so the measured swaps run on warm slots.
        // Same tiny swap on both.
        _swap(vanillaKey, int256(-100));
        _swap(simKey, int256(-100));

        int256[5] memory swapAmounts = [
            int256(-0.001 ether), // ~0 crossings
            int256(-0.05 ether), // ~0 crossings
            int256(-0.2 ether), // ~3 crossings
            int256(-1 ether), // ~18 crossings
            int256(-5 ether) // ~98 crossings
        ];

        console.log("");
        console.log("===========================================================================");
        console.log(" VANILLA v4 vs SimHook - SAME laddered pool, identical swap, side by side");
        console.log(" tickSpacing=10, initial tick=0, ladder positions every 10 ticks down to -500");
        console.log("===========================================================================");

        for (uint256 i = 0; i < swapAmounts.length; i++) {
            // Vanilla pool: measure
            int24 vTickBefore = _tick(vanillaId);
            uint256 vGas = _swap(vanillaKey, swapAmounts[i]);
            int24 vTickAfter = _tick(vanillaId);
            uint256 vTickDelta = _abs(vTickAfter - vTickBefore);
            uint256 vCrossings = vTickDelta / uint256(uint24(TICK_SPACING));

            // SimHook pool: measure
            int24 cTickBefore = _tick(simId);
            uint256 cGas = _swap(simKey, swapAmounts[i]);
            int24 cTickAfter = _tick(simId);
            uint256 cTickDelta = _abs(cTickAfter - cTickBefore);

            uint256 overhead = cGas - vGas;

            // Tripwire, not decoration: pin the per-size overhead so a pricing or simulator
            // change that inflates it shows up as a snapshot diff rather than a console number
            // nobody reads. The assertion states the structural fact the table exists to show —
            // the hook always costs more than no hook.
            assertGt(cGas, vGas, "simhook must cost more gas than vanilla for the same swap");
            vm.snapshotValue(
                string.concat("overheadByCrossings: swap_wei=", vm.toString(uint256(-swapAmounts[i]))), overhead
            );

            console.log("---- swap_wei =", uint256(-swapAmounts[i]));
            console.log("  vanilla v4 post_tick:", int256(vTickAfter));
            console.log("  vanilla v4 gas:      ", vGas);
            console.log("  simhook    post_tick:", int256(cTickAfter));
            console.log("  simhook    gas:      ", cGas);
            console.log("  crossings (vanilla) :", vCrossings);
            console.log("  simhook overhead    :", overhead);
            if (vCrossings > 0) {
                console.log("  overhead per cross  :", overhead / vCrossings);
            }
            console.log("  vanilla tick_delta  :", vTickDelta);
            console.log("  simhook tick_delta  :", cTickDelta);
        }
    }
}
