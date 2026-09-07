// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {TestUtils} from "../utils/TestUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";
import {ReentrantERC20} from "../mocks/ReentrantERC20.sol";
import {P4Ev, P4Reverter} from "./helpers/P4Helpers.sol";
import {P4MultiSwapRouter} from "./helpers/P4MultiSwapRouter.sol";

import {SimHook} from "../../src/SimHook.sol";
import {AscntBaseHook} from "../../src/AscntBaseHook.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Phase-4a accumulator + lifecycle state-machine scenarios:
///         ACC-3 (sign tracks net flow), ACC-4 (saturation self-corrects via decay),
///         LIFE-3/LIFE-4 (unconfigured-pool guards), LIFE-9 (leaked poolDeployer blast radius),
///         LIFE-10 (pause is add-only), LIFE-13 (first-swap pricing), FEE-14 (swap-path liveness).
contract Phase4aAccLifecycleTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;

    address internal constant TREASURY = address(0xBEEF);
    uint256 internal constant DECAY_LEN = 3600; // StablePairPoolConfig.timeDecayLength
    uint24 internal constant MAX_FEE_A = 10_000; // StablePairPoolConfig.maxFee

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(-600, 600, 1e12, initSqrtP, false);
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(1000);
    }

    function _params(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    // ------ ACC-3: accumulator sign tracks net directional flow ------

    /// @notice From a fresh (zero) accumulator, any prefix of same-direction swaps — with
    ///         arbitrary time gaps (decay) in between — keeps cum on that direction's side of
    ///         zero: <=0 for zeroForOne prefixes, >=0 for oneForZero.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_acc3_sameDirectionPrefixKeepsSign(uint256 seed, bool zeroForOne) public {
        uint256 n = 2 + (seed % 5); // 2..6 swaps
        // Explicit timeline rather than `vm.warp(block.timestamp + gap)`: on the via-IR optimized
        // profile `TIMESTAMP` is transaction-invariant to the optimizer, so a read inside a loop
        // that warps gets hoisted out, and `vm.warp` mutates it where the optimizer cannot see —
        // collapsing every gap to zero and removing the decay this property is meant to survive.
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i = 0; i < n; i++) {
            uint256 amount = _bound(uint256(keccak256(abi.encode(seed, i))), 1e8, 2e10);
            swap(zeroForOne, -int256(amount), false);
            (,,, int256 cum) = hook.poolData(poolId);
            if (zeroForOne) {
                assertLe(cum, 0, "zeroForOne prefix pushed cum positive");
            } else {
                assertGe(cum, 0, "oneForZero prefix pushed cum negative");
            }
            // decay between swaps must also preserve the side (or reach exactly 0)
            t += uint256(keccak256(abi.encode(seed, i, "gap"))) % (DECAY_LEN / 2);
            vm.warp(t);
        }
    }

    // ------ ACC-4: a heavily-loaded accumulator fully decays after >= timeDecayLength ------

    /// @notice Load the accumulator with several large same-direction swaps, then stay quiet for
    ///         at least timeDecayLength: the next swap's beforeSwap must see decayedCum == 0 —
    ///         the accumulator is never permanently stuck (the reachable slice of the +/-int256
    ///         saturation statement; per-swap steps are capped at 1e6 so the int256 bound itself
    ///         is unreachable through swaps, see HookMath addSaturating unit coverage).
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_acc4_fullDecayZeroesLoadedAccumulator(uint256 extraGap) public {
        for (uint256 i = 0; i < 4; i++) {
            swap(true, -2e10, false);
        }
        (,,, int256 cumLoaded) = hook.poolData(poolId);
        assertLt(cumLoaded, -1000, "accumulator not meaningfully loaded");

        vm.warp(block.timestamp + DECAY_LEN + _bound(extraGap, 0, 30 days));

        (, Vm.Log[] memory logs) = swap(true, -1e9, false);
        BeforeSwapEventData memory bev = getBeforeSwapEventData(logs);
        assertEq(bev.decayedCumPriceImpact, 0, "decayed accumulator must be exactly 0 after full gap");
    }

    // ------ LIFE-3 / LIFE-4: unconfigured-pool guards ------

    /// @notice A swap on an initialized-but-unconfigured pool always reverts PoolNotConfigured
    ///         and writes no runtime state.
    function test_life3_swapOnUnconfiguredPoolReverts() public {
        (PoolKey memory keyU, PoolId idU) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 7, SQRT_PRICE_1_1);

        try swapRouter.swap(keyU, _params(true, -1e9), SETTINGS, "") {
            fail("swap on unconfigured pool must revert");
        } catch (bytes memory reason) {
            assertTrue(
                P4Ev.containsSelector(reason, SimHook.PoolNotConfigured.selector), "revert must be PoolNotConfigured"
            );
        }
        (uint160 spb, uint48 ts,, int256 cum) = hook.poolData(idU);
        assertEq(uint256(spb), 0, "sqrtPriceX96Before leaked");
        assertEq(uint256(ts), 0, "lastSwapTimestamp leaked");
        assertEq(cum, 0, "cumPriceImpact leaked");
    }

    /// @notice An add-liquidity on an unconfigured pool reverts PoolNotConfigured (the gate lives
    ///         in afterAddLiquidity, so the revert must unwind the already-applied core delta):
    ///         no position and no JIT stamp survive.
    function test_life4_addOnUnconfiguredPoolRevertsAndUnwinds() public {
        (PoolKey memory keyU, PoolId idU) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 7, SQRT_PRICE_1_1);

        try modifyLiquidityRouter.modifyLiquidity(
            keyU, ModifyLiquidityParams({tickLower: -595, tickUpper: 595, liquidityDelta: 1e10, salt: bytes32(0)}), ""
        ) {
            fail("add on unconfigured pool must revert");
        } catch (bytes memory reason) {
            assertTrue(
                P4Ev.containsSelector(reason, SimHook.PoolNotConfigured.selector), "revert must be PoolNotConfigured"
            );
        }
        (uint128 posLiq,,) =
            StateLibrary.getPositionInfo(manager, idU, address(modifyLiquidityRouter), -595, 595, bytes32(0));
        assertEq(uint256(posLiq), 0, "position survived the revert");
    }

    // ------ LIFE-9: leaked poolDeployer blast radius is bounded ------

    function test_life9_leakedPoolDeployerDamageBounded() public {
        address attacker = makeAddr("attacker");
        governance.setPoolDeployer(attacker); // test contract is the timelock

        // attacker squats a poolId with the most adversarial config the bound chain admits
        PoolKey memory keyX = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 3, IHooks(address(hook)));
        PoolId idX = keyX.toId();
        vm.prank(attacker);
        manager.initialize(keyX, SQRT_PRICE_1_1);
        vm.prank(attacker);
        hook.configurePool(idX, 0, 0, LPFeeLibrary.MAX_LP_FEE - 1, 1, 7200, 2e6, 1e6);

        // the stored config still satisfies the full bound chain — damage is capped
        (
            bool configured,
            uint24 minMinFee,
            uint24 maxMinFee,
            uint24 maxFee,
            uint48 timeDecayLength,
            uint48 jitLockBlocks,
            uint32 kPips,
            uint32 cPips
        ) = hook.poolConfig(idX);
        assertTrue(configured);
        assertLe(minMinFee, maxMinFee);
        assertLe(maxMinFee, maxFee);
        assertLt(maxFee, LPFeeLibrary.MAX_LP_FEE);
        assertGe(timeDecayLength, 1);
        assertLe(timeDecayLength, hook.MAX_TIME_DECAY_LENGTH());
        assertLe(jitLockBlocks, hook.MAX_JIT_LOCK_BLOCKS());
        assertGe(kPips, 1);
        assertLe(kPips, hook.MAX_K_PIPS());
        assertGe(cPips, 1);
        assertLe(cPips, hook.MAX_C_PIPS());

        // squatted config is immutable — for the attacker AND for the honest owner
        vm.prank(attacker);
        vm.expectRevert(SimHook.PoolAlreadyConfigured.selector);
        hook.configurePool(idX, 10, 10, 10_000, 3600, 0, 2e6, 1e6);
        vm.expectRevert(SimHook.PoolAlreadyConfigured.selector);
        hook.configurePool(idX, 10, 10, 10_000, 3600, 0, 2e6, 1e6);

        // honest team relaunches on a fresh poolId (different tickSpacing => different id)
        (PoolKey memory keyY, PoolId idY) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 5, SQRT_PRICE_1_1);
        hook.configurePool(idY, 10, 10, 10_000, 3600, 0, 2e6, 1e6);
        modifyLiquidityRouter.modifyLiquidity(
            keyY, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e12, salt: bytes32(0)}), ""
        );
        swapRouter.swap(keyY, _params(true, -1e9), SETTINGS, ""); // relaunch trades normally

        // relaunch config is independent of the squatted one
        (,,, uint24 maxFeeY,,,,) = hook.poolConfig(idY);
        assertEq(uint256(maxFeeY), 10_000, "relaunch config wrong");
        (,,, uint24 maxFeeX,,,,) = hook.poolConfig(idX);
        assertEq(uint256(maxFeeX), LPFeeLibrary.MAX_LP_FEE - 1, "squatted config must be untouched by the relaunch");
    }

    // ------ LIFE-10: the pause is add-only and complete ------

    function test_life10_pauseBlocksOnlyAdds() public {
        // get past the JIT window of the setUp position first
        vm.roll(block.number + 51);
        governance.setAddLiquidityPaused(true);

        // add blocked
        try modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e9, salt: bytes32(0)}), ""
        ) {
            fail("add must revert while paused");
        } catch (bytes memory reason) {
            assertTrue(
                P4Ev.containsSelector(reason, AscntBaseHook.AddLiquidityIsPaused.selector),
                "add revert must be AddLiquidityIsPaused"
            );
        }

        // remove, fee-only poke, and swap all succeed while paused
        removeLiquidity(-600, 600, 1e9);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 0, salt: bytes32(0)}), ""
        );
        swap(true, -1e9, false);

        // unpause restores adds
        governance.setAddLiquidityPaused(false);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e9, salt: bytes32(0)}), ""
        );
    }

    // ------ LIFE-13: first-swap pricing off cum = 0 + swap #2 decay/ramp path ------

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_life13_firstSwapPricesOffZeroCumThenWellDefinedSecondSwap(uint256 gap) public {
        gap = _bound(gap, 0, 2 * DECAY_LEN);

        (SwapValues memory sv1, Vm.Log[] memory logs1) = swap(true, -2e9, false);
        BeforeSwapEventData memory b1 = getBeforeSwapEventData(logs1);
        AfterSwapEventData memory a1 = getAfterSwapEventData(logs1);

        // swap #1 prices normally off cum = 0: k x midpoint of the 0 -> P leg = P at k = 2e6
        assertEq(b1.decayedCumPriceImpact, 0, "first swap must see a zero accumulator");
        uint256 expected1 = b1.priceImpact;
        if (expected1 < b1.effectiveMinFee) expected1 = b1.effectiveMinFee;
        if (expected1 > MAX_FEE_A) expected1 = MAX_FEE_A;
        assertEq(uint256(b1.dynamicFeePips), expected1, "first swap fee != fresh-push recompute");

        (uint160 spb, uint48 ts,, int256 cum) = hook.poolData(poolId);
        assertEq(uint256(spb), uint256(sv1.sqrtPriceX96Before), "baseline price not recorded");
        assertEq(uint256(ts), block.timestamp, "lastSwapTimestamp not recorded");
        assertEq(cum, a1.cumPriceImpact, "seeded cum mismatch");

        // swap #2 (same block or after a gap): decay/ramp path fully defined, no revert
        vm.warp(block.timestamp + gap);
        (, Vm.Log[] memory logs2) = swap(true, -2e9, false);
        BeforeSwapEventData memory b2 = getBeforeSwapEventData(logs2);
        if (gap == 0) {
            assertEq(b2.decayedCumPriceImpact, cum, "no-gap decay must be the identity");
        } else if (gap >= DECAY_LEN) {
            assertEq(b2.decayedCumPriceImpact, 0, "full-gap decay must be zero");
        } else {
            assertLe(b2.decayedCumPriceImpact, 0, "partial decay flipped the sign");
            assertGe(b2.decayedCumPriceImpact, cum, "partial decay amplified the magnitude");
        }
        assertGe(b2.dynamicFeePips, b2.effectiveMinFee, "fee below the effective min");
        assertLe(uint256(b2.dynamicFeePips), uint256(MAX_FEE_A), "fee above maxFee");
    }

    // ------ FEE-14: swap-path liveness ------

    /// @notice On a configured pool with liquidity, NO swap input (size within int128, either
    ///         direction/exactness, any time gap) makes the fee/accumulator path revert.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_fee14_swapNeverReverts(uint256 amtSeed, bool zeroForOne, bool exactOut, uint256 gapSeed) public {
        swap(true, -1e9, false); // warmup swap stamps the swap clock
        vm.warp(block.timestamp + _bound(gapSeed, 0, 3650 days));
        uint256 amount = _bound(amtSeed, 1, 1e22);
        // no try/catch: a revert here IS the failure
        swapRouter.swap(key, _params(zeroForOne, exactOut ? int256(amount) : -int256(amount)), SETTINGS, "");
    }

    /// @notice FEE-14 zero-liquidity slice: drain the pool past its only liquidity range (realized
    ///         impact pins at the 100% cap — the documented "temporary break"), then swap starting
    ///         INSIDE the empty region via a raw unlock router (PoolSwapTest's sanity requires
    ///         don't apply). The fee/simulator path must handle liquidity==0 without reverting.
    function test_fee14_zeroLiquidityRegionSwapDoesNotRevert() public {
        swap(true, -1e9, false); // warmup
        // drain: exact-in far beyond range depth => price slides to the MIN limit (empty zone)
        (, Vm.Log[] memory logs) = swap(true, -1e15, false);
        AfterSwapEventData memory aev = getAfterSwapEventData(logs);
        assertEq(aev.priceImpact, 1e6, "drain swap must pin realized impact at the 100% cap");
        (,,, int256 cum) = hook.poolData(poolId);
        assertLe(cum, -1_000_000, "accumulator must carry the capped impact");

        // now a swap that STARTS in the zero-liquidity region (price ~ MIN): must not revert
        P4MultiSwapRouter raw = new P4MultiSwapRouter(manager, address(hook));
        MockERC20(Currency.unwrap(currency0)).transfer(address(raw), 1e20);
        MockERC20(Currency.unwrap(currency1)).transfer(address(raw), 1e20);
        P4MultiSwapRouter.Step[] memory steps = new P4MultiSwapRouter.Step[](1);
        steps[0] = P4MultiSwapRouter.Step({key: key, params: _params(false, -1e9)});
        raw.batchSwap(steps); // reverting here fails the test — that is the assertion
    }

    // NOTE: configurePool rejects maxFee == MAX_LP_FEE, so the 100%-fee exact-output revert
    // (InvalidFeeForExactOut) is unreachable; the admissible cap MAX_LP_FEE - 1 is pinned in
    // Phase4aProbe.t.sol:Phase4aExactOutFeeCapTest. Draining the price below
    // MIN_USABLE_SQRT_PRICE via a drain swap is impractical on such a pool: at the cap only one
    // pip of each exact-input trades, throttling price movement ~1e6x before the floor is near.
}

/// @notice ACC-8 + LIFE-13(revert half): a swap that fails inside _afterSwap (the protocol-fee
///         treasury transfer reverts via an armed ReentrantERC20) must roll back EVERY hook state
///         write of that swap — accumulator, bracket price, and timestamp.
contract Phase4aRevertRollbackTest is TestUtils {
    using PoolIdLibrary for PoolKey;

    SimHook internal shook;
    ReentrantERC20 internal rtok;
    MockERC20 internal htok;
    P4Reverter internal reverter;
    address internal constant TREASURY = address(0xBEEF);

    bool internal rtokIs0; // whether the reentrant token sorted as currency0
    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        deployArtifactManagerAndRouters();
        rtok = new ReentrantERC20("RTOK", "RTOK", 6);
        htok = new MockERC20("USDC", "USDC", 6);
        rtok.mint(address(this), 1e30);
        htok.mint(address(this), 1e30);
        rtok.approve(address(swapRouter), type(uint256).max);
        htok.approve(address(swapRouter), type(uint256).max);
        rtok.approve(address(modifyLiquidityRouter), type(uint256).max);
        htok.approve(address(modifyLiquidityRouter), type(uint256).max);

        rtokIs0 = address(rtok) < address(htok);
        if (rtokIs0) {
            currency0 = Currency.wrap(address(rtok));
            currency1 = Currency.wrap(address(htok));
        } else {
            currency0 = Currency.wrap(address(htok));
            currency1 = Currency.wrap(address(rtok));
        }

        governance = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance",
                abi.encode(address(this), address(this), address(0), address(0))
            )
        );
        governance.setHookFactory(address(this));
        address hookAddress = address(uint160(hookFlags()));
        deployCodeTo("SimHook.sol", abi.encode(manager, governance), hookAddress);
        governance.registerSubscriber(hookAddress);
        shook = SimHook(hookAddress);

        (key, poolId) =
            initPool(currency0, currency1, IHooks(hookAddress), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, SQRT_PRICE_1_1);
        shook.configurePool(poolId, 10, 10, 10_000, 3600, 0, 2e6, 1e6);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e13, salt: bytes32(0)}), ""
        );
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(2000);
        reverter = new P4Reverter();
    }

    /// @dev exact-in swap whose OUTPUT (the unspecified side, i.e. the taken currency) is rtok.
    function _paramsOutRtok(uint256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = !rtokIs0; // output currency is the *other* side
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _arm() internal {
        rtok.arm(address(reverter), abi.encodeWithSignature("boom()"), true, false, true);
    }

    /// @notice ACC-8: post-first-swap state rollback. Swap #2's treasury transfer reverts; every
    ///         poolData field must be byte-identical to the post-swap-#1 state and the treasury
    ///         must not have been paid.
    function test_acc8_afterSwapRevertRollsBackAllRuntimeState() public {
        swapRouter.swap(key, _paramsOutRtok(2e9), SETTINGS, ""); // swap #1 (take succeeds)

        (uint160 spb1, uint48 ts1, uint40 ra1, int256 cum1) = shook.poolData(poolId);
        uint256 treasuryR1 = rtok.balanceOf(TREASURY);
        assertGt(treasuryR1, 0, "setup take must have paid the treasury");

        vm.warp(block.timestamp + 100); // make the (would-be) decay write observable
        _arm();
        try swapRouter.swap(key, _paramsOutRtok(3e9), SETTINGS, "") {
            fail("swap must revert when the treasury transfer reverts");
        } catch {}
        rtok.disarm();

        (uint160 spb2, uint48 ts2, uint40 ra2, int256 cum2) = shook.poolData(poolId);
        assertEq(uint256(spb2), uint256(spb1), "sqrtPriceX96Before not rolled back");
        assertEq(uint256(ts2), uint256(ts1), "lastSwapTimestamp not rolled back");
        // The reverted swap crossed a block boundary (warp +100), so its _beforeSwap SETTLED the
        // ramp anchor before the take reverted — the rollback must restore the pre-settle value.
        assertEq(uint256(ra2), uint256(ra1), "rampAnchor not rolled back");
        assertEq(cum2, cum1, "cumPriceImpact not rolled back");
        assertEq(rtok.balanceOf(TREASURY), treasuryR1, "treasury paid by a reverted swap");

        // pool is healthy again once the token stops reverting
        swapRouter.swap(key, _paramsOutRtok(1e9), SETTINGS, "");
    }

    /// @notice A FIRST swap that reverts in _afterSwap must leave the runtime fields zeroed, the
    ///         ramp anchor at its configure-time seed, and the next swap re-runs as a fresh first
    ///         swap (pricing off cum = 0).
    function test_life13_firstSwapRevertLeavesFreshState() public {
        (,, uint40 raSeed,) = shook.poolData(poolId);
        _arm();
        try swapRouter.swap(key, _paramsOutRtok(2e9), SETTINGS, "") {
            fail("armed first swap must revert");
        } catch {}
        rtok.disarm();

        (uint160 spb, uint48 ts, uint40 ra, int256 cum) = shook.poolData(poolId);
        assertEq(uint256(spb), 0, "baseline price leaked");
        assertEq(uint256(ts), 0, "timestamp leaked");
        assertEq(uint256(ra), uint256(raSeed), "ramp anchor must keep its configure-time seed");
        assertEq(cum, 0, "cum leaked");

        // the next swap re-runs as a fresh first swap: cum = 0, fee = clamp of its own impact
        vm.recordLogs();
        swapRouter.swap(key, _paramsOutRtok(2e9), SETTINGS, "");
        P4Ev.BeforeSwapEv[] memory bevs = P4Ev.beforeSwaps(vm.getRecordedLogs());
        assertEq(bevs.length, 1);
        assertEq(bevs[0].decayedCum, 0, "re-run must price off a zero accumulator");
        uint256 expected = bevs[0].priceImpact;
        if (expected < bevs[0].effMinFee) expected = bevs[0].effMinFee;
        if (expected > 10_000) expected = 10_000;
        assertEq(uint256(bevs[0].dynFee), expected, "re-run fee != fresh-push recompute");
        (, uint48 tsAfter,,) = shook.poolData(poolId);
        assertEq(uint256(tsAfter), block.timestamp, "swap clock must stamp on the successful first swap");
    }
}
