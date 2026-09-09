// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {TestUtils} from "../utils/TestUtils.sol";
import {IAscntFeeHook} from "../utils/IAscntFeeHook.sol";
import {ERC20PoolConfig} from "../lib/PoolConfigs.sol";

import {AscntBaseHook} from "../../src/AscntBaseHook.sol";
import {SimHook} from "../../src/SimHook.sol";

/// @dev Base contract holds every test; concrete subclass at the bottom plugs in `_hookName()`.
///      Each bound violation reverts with its own plain error (e.g. `SimHook.FeeTooHigh`).
abstract contract ConfigurePoolBoundsBase is TestUtils {
    using StateLibrary for IPoolManager;

    IAscntFeeHook internal hook;
    ERC20PoolConfig internal poolCfg;

    address internal constant ALICE = address(0xA11CE);

    function _hookName() internal pure virtual returns (string memory);

    /// @dev configurePool dispatch with `maxMinFee == minF` (feature-off flat-floor).
    function _configurePool(uint24 minF, uint24 maxF, uint256 decay, uint48 jit, uint32 k, uint32 c) internal virtual;

    /// @dev Read the (configured, minFloor, maxFee, timeDecayLength, jitLockBlocks, kPips,
    /// cPips) subset of the pool config that the shared bound tests need. SimHook concretes
    /// pull `minMinFee` for `minFloor`.
    function _readSharedConfig()
        internal
        view
        virtual
        returns (
            bool configured,
            uint24 minFloor,
            uint24 maxFee,
            uint256 timeDecayLength,
            uint48 jitLockBlocks,
            uint32 kPips,
            uint32 cPips
        );

    function setUp() public {
        poolCfg = new ERC20PoolConfig();
        address hookAddress = deployCoreAndHookCustomDecimals(
            _hookName(),
            poolCfg.symbol0(),
            poolCfg.symbol1(),
            poolCfg.decimals0(),
            poolCfg.decimals1(),
            poolCfg.nativeEth()
        );
        hook = IAscntFeeHook(hookAddress);

        // Hook owner is address(this) (set by TestUtils.deployCoreAndHookCustomDecimals).
        // Initialize the pool so configurePool has something to act on, but do NOT configure.
        deployPool(IHooks(hookAddress), poolCfg.targetTick(), poolCfg.tickSpacing(), false);
    }

    function _expectConfigRevert(bytes4 errorSelector) internal {
        vm.expectRevert(errorSelector);
    }

    // ------ authorization ------

    function test_configurePool_revertsIfNotOwner() public {
        // poolDeployer slot defaults to address(0), so the gate is effectively owner-only.
        vm.prank(ALICE);
        vm.expectRevert(AscntBaseHook.NotOwnerOrPoolDeployer.selector);
        _configurePool(100, 10_000, 1 hours, 50, 2e6, 1e6);
    }

    // ------ bounds: one test per config bound ------

    function test_configurePool_revertsOnFeeBounds() public {
        _expectConfigRevert(SimHook.FeeBounds.selector);
        _configurePool(10_000, 500, 1 hours, 50, 2e6, 1e6); // minFee > maxFee
    }

    function test_configurePool_revertsOnFeeTooHigh() public {
        // one pip above the hook-wide 50% ceiling
        _expectConfigRevert(SimHook.FeeTooHigh.selector);
        _configurePool(100, HOOK_MAX_FEE + 1, 1 hours, 50, 2e6, 1e6);
    }

    function test_configurePool_revertsOnZeroDecay() public {
        _expectConfigRevert(SimHook.ZeroDecay.selector);
        _configurePool(100, 10_000, 0, 50, 2e6, 1e6);
    }

    function test_configurePool_revertsOnDecayTooLong() public {
        // timeDecayLength is capped at MAX_TIME_DECAY_LENGTH (the markout horizon ceiling)
        uint256 tooLong = SimHook(address(hook)).MAX_TIME_DECAY_LENGTH() + 1;
        _expectConfigRevert(SimHook.DecayTooLong.selector);
        _configurePool(100, 10_000, tooLong, 50, 2e6, 1e6);
    }

    function test_configurePool_acceptsMaxDecayLength() public {
        _configurePool(100, 10_000, SimHook(address(hook)).MAX_TIME_DECAY_LENGTH(), 50, 2e6, 1e6);
        (bool configured,,,,,,,) = SimHook(address(hook)).poolConfig(poolId);
        assertTrue(configured);
    }

    // ------ accept-side boundaries (the reject side is covered above) ------

    function test_configurePool_acceptsMaxFeeAtCap() public {
        _configurePool(100, HOOK_MAX_FEE, 1 hours, 50, 2e6, 1e6);
        (bool configured,,, uint24 maxFee,,,,) = SimHook(address(hook)).poolConfig(poolId);
        assertTrue(configured);
        assertEq(maxFee, HOOK_MAX_FEE);
    }

    function test_configurePool_acceptsJitLockAtMax() public {
        uint48 maxJit = SimHook(address(hook)).MAX_JIT_LOCK_BLOCKS();
        _configurePool(100, 10_000, 1 hours, maxJit, 2e6, 1e6);
        (bool configured,,,,, uint48 jit,,) = SimHook(address(hook)).poolConfig(poolId);
        assertTrue(configured);
        assertEq(jit, maxJit);
    }

    /// @dev MAX_K_PIPS is 20e6 because the weights scale the leg MIDPOINT, not its ENDPOINT — a
    ///      from-zero leg's midpoint is half its endpoint, so a 20e6 midpoint weight is the same
    ///      effective fee ceiling as a 10e6 endpoint weight. MAX_C_PIPS is set EQUAL to
    ///      MAX_K_PIPS for tuning headroom: at the ceiling a full revert may be charged up to
    ///      10x its own impact, symmetric with k (see the src constant note).
    function test_configurePool_acceptsWeightsAtMaxima() public {
        uint32 kMax = SimHook(address(hook)).MAX_K_PIPS();
        uint32 cMax = SimHook(address(hook)).MAX_C_PIPS();
        assertEq(uint256(kMax), 20e6);
        assertEq(uint256(cMax), 20e6);
        _configurePool(100, 10_000, 1 hours, 50, kMax, cMax);
        (bool configured,,,,, uint32 kPips, uint32 cPips) = _readSharedConfig();
        assertTrue(configured);
        assertEq(kPips, kMax);
        assertEq(cPips, cMax);
    }

    /// @dev 1 pip is the smallest admissible weight on both legs (0 reverts, covered below).
    function test_configurePool_acceptsMinimalWeights() public {
        _configurePool(100, 10_000, 1 hours, 50, 1, 1);
        (bool configured,,,,, uint32 kPips, uint32 cPips) = _readSharedConfig();
        assertTrue(configured);
        assertEq(uint256(kPips), 1);
        assertEq(uint256(cPips), 1);
    }

    // ------ initial config is one-shot ------

    function test_configurePool_revertsOnSecondCall() public {
        _configurePool(100, 10_000, 1 hours, 50, 2e6, 1e6);

        // configurePool is one-time; a second call always reverts regardless of caller.
        // There is no reconfigure path — a misconfigured pool must be re-launched.
        vm.expectRevert(_poolAlreadyConfiguredSelector());
        _configurePool(100, 10_000, 1 hours, 50, 2e6, 1e6);
    }

    function _poolAlreadyConfiguredSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("PoolAlreadyConfigured()"));
    }

    // ------ poolDeployer delegation (initial configurePool only) ------

    function test_configurePool_byPoolDeployer() public {
        // Set the poolDeployer (timelock-gated; address(this) is timelock in this fixture).
        governance.setPoolDeployer(ALICE);

        // ALICE is not the owner but is the poolDeployer — initial configurePool succeeds.
        vm.prank(ALICE);
        _configurePool(100, 10_000, 1 hours, 50, 2e6, 1e6);

        (bool configured,,,,,,) = _readSharedConfig();
        assertTrue(configured);
    }

    function test_configurePool_revertsIfNotOwnerOrPoolDeployer() public {
        governance.setPoolDeployer(ALICE);
        // OTHER is neither owner nor poolDeployer.
        address OTHER = address(0xB0B);
        vm.prank(OTHER);
        vm.expectRevert(AscntBaseHook.NotOwnerOrPoolDeployer.selector);
        _configurePool(100, 10_000, 1 hours, 50, 2e6, 1e6);
    }

    // ------ happy path ------

    function test_configurePool_happyPath() public {
        _configurePool(100, 10_000, 1 hours, 50, 2e6, 1e6);
        (
            bool configured,
            uint24 minFloor,
            uint24 maxFee,
            uint256 timeDecayLength,
            uint48 jitLockBlocks,
            uint32 kPips,
            uint32 cPips
        ) = _readSharedConfig();
        assertTrue(configured);
        assertEq(minFloor, 100);
        assertEq(maxFee, 10_000);
        assertEq(timeDecayLength, 1 hours);
        assertEq(jitLockBlocks, 50);
        assertEq(uint256(kPips), 2e6);
        assertEq(uint256(cPips), 1e6);
    }

    function test_configurePool_revertsOnJitLockTooHigh() public {
        uint48 tooHigh = hook.MAX_JIT_LOCK_BLOCKS() + 1;
        _expectConfigRevert(SimHook.JitLockBlocksTooHigh.selector);
        _configurePool(100, 10_000, 1 hours, tooHigh, 2e6, 1e6);
    }

    // ------ bounds: midpoint leg weights (kPips/cPips, checked after jitLockBlocks) ------

    function test_configurePool_revertsOnZeroK() public {
        _expectConfigRevert(SimHook.ZeroK.selector);
        _configurePool(100, 10_000, 1 hours, 50, 0, 1e6);
    }

    function test_configurePool_revertsOnKTooHigh() public {
        uint32 tooHigh = SimHook(address(hook)).MAX_K_PIPS() + 1;
        _expectConfigRevert(SimHook.KTooHigh.selector);
        _configurePool(100, 10_000, 1 hours, 50, tooHigh, 1e6);
    }

    function test_configurePool_revertsOnZeroC() public {
        _expectConfigRevert(SimHook.ZeroC.selector);
        _configurePool(100, 10_000, 1 hours, 50, 2e6, 0);
    }

    function test_configurePool_revertsOnCTooHigh() public {
        // MAX_C_PIPS equals MAX_K_PIPS (tuning headroom, ordering not enforced). Reference
        // point: c = 2e6 charges a full revert-to-zero exactly its own impact; the ceiling
        // allows up to 10x that, symmetric with k.
        uint32 tooHigh = SimHook(address(hook)).MAX_C_PIPS() + 1;
        _expectConfigRevert(SimHook.CTooHigh.selector);
        _configurePool(100, 10_000, 1 hours, 50, 2e6, tooHigh);
    }

    // ------ property fuzz: bound-violating inputs always revert with the right reason ------

    /// @dev Only invokes the bound-violation path (vm.assume filters out all-valid inputs)
    /// — this fuzz is specifically about "every invalid input reverts with the right reason".
    function testFuzz_configurePool_boundsReject(
        uint24 minFee,
        uint24 maxFee,
        uint256 timeDecayLength,
        uint32 k,
        uint32 c
    ) public {
        bytes4 expected;
        bool shouldRevert = true;

        // Mirrors configurePool's check order; jitLockBlocks is pinned valid (50), so the
        // jit bound never fires between DecayTooLong and the weight checks.
        if (minFee > maxFee) {
            expected = SimHook.FeeBounds.selector;
        } else if (maxFee > HOOK_MAX_FEE) {
            expected = SimHook.FeeTooHigh.selector;
        } else if (timeDecayLength == 0) {
            expected = SimHook.ZeroDecay.selector;
        } else if (timeDecayLength > SimHook(address(hook)).MAX_TIME_DECAY_LENGTH()) {
            expected = SimHook.DecayTooLong.selector;
        } else if (k == 0) {
            expected = SimHook.ZeroK.selector;
        } else if (k > SimHook(address(hook)).MAX_K_PIPS()) {
            expected = SimHook.KTooHigh.selector;
        } else if (c == 0) {
            expected = SimHook.ZeroC.selector;
        } else if (c > SimHook(address(hook)).MAX_C_PIPS()) {
            expected = SimHook.CTooHigh.selector;
        } else {
            shouldRevert = false;
        }

        vm.assume(shouldRevert);

        _expectConfigRevert(expected);
        _configurePool(minFee, maxFee, timeDecayLength, 50, k, c);
    }
}

// ------ concrete subclasses: forge runs the inherited suite once per variant ------

contract ConfigurePoolBoundsTest is ConfigurePoolBoundsBase {
    function _hookName() internal pure override returns (string memory) {
        return "SimHook.sol";
    }

    function _configurePool(uint24 minF, uint24 maxF, uint256 decay, uint48 jit, uint32 k, uint32 c) internal override {
        // Feature-off degenerate floor: minMinFee == maxMinFee == minF.
        SimHook(address(hook)).configurePool(poolId, minF, minF, maxF, decay, jit, k, c);
    }

    function _readSharedConfig()
        internal
        view
        override
        returns (
            bool configured,
            uint24 minFloor,
            uint24 maxFee,
            uint256 timeDecayLength,
            uint48 jitLockBlocks,
            uint32 kPips,
            uint32 cPips
        )
    {
        // SimHook 8-tuple: configured, minMinFee, maxMinFee, maxFee, decay, jit, kPips, cPips
        uint24 maxMinFee;
        uint48 decay48;
        (configured, minFloor, maxMinFee, maxFee, decay48, jitLockBlocks, kPips, cPips) =
            SimHook(address(hook)).poolConfig(poolId);
        timeDecayLength = decay48;
        maxMinFee; // suppress unused warning
    }

    // ------ SimHook-only: MinFeeBounds + maxMinFee bounds (dynamic floor) ------

    /// @dev minMinFee > maxMinFee triggers the MinFeeBounds variant.
    function test_configurePool_revertsOnMinFeeBounds() public {
        _expectConfigRevert(SimHook.MinFeeBounds.selector);
        SimHook(address(hook)).configurePool(poolId, 5_000, 1_000, 10_000, 1 hours, 50, 2e6, 1e6);
    }

    /// @dev maxMinFee > maxFee triggers FeeBounds.
    function test_configurePool_revertsOnMaxMinFeeAboveMaxFee() public {
        _expectConfigRevert(SimHook.FeeBounds.selector);
        // minMinFee=100 (valid), maxMinFee=20_000 > maxFee=10_000 → FeeBounds
        SimHook(address(hook)).configurePool(poolId, 100, 20_000, 10_000, 1 hours, 50, 2e6, 1e6);
    }

    /// @dev Dynamic floor happy path: write a non-degenerate spread, read it back.
    function test_configurePool_dynamicFloor_happyPath() public {
        SimHook(address(hook)).configurePool(poolId, 100, 3_000, 10_000, 1 hours, 50, 2e6, 1e6);
        (bool configured, uint24 minMinFee, uint24 maxMinFee, uint24 maxFee,,,,) =
            SimHook(address(hook)).poolConfig(poolId);
        assertTrue(configured);
        assertEq(uint256(minMinFee), 100);
        assertEq(uint256(maxMinFee), 3_000);
        assertEq(uint256(maxFee), 10_000);
    }

    /// @dev PoolConfigured carries `kPips`/`cPips` immediately before `timestamp`
    ///      (subgraph/indexers decode this exact layout). Assert every field, weights included.
    function test_configurePool_emitsPoolConfiguredWithWeights() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit SimHook.PoolConfigured(
            PoolId.unwrap(poolId),
            true,
            100,
            100,
            10_000,
            1 hours,
            50,
            2e6,
            1e6,
            block.timestamp
        );
        SimHook(address(hook)).configurePool(poolId, 100, 100, 10_000, 1 hours, 50, 2e6, 1e6);
    }

    // ------ pool-state precondition guards (negative coverage) ------
    // setUp() initializes the pool but deliberately does NOT configure it, so these
    // exercise the guards that every other suite skips by configuring before acting.

    /// @dev configurePool on a pool that was never initialized on the PoolManager
    ///      (slot0.sqrtPriceX96 == 0) must revert PoolNotInitialized (SimHook.sol:427).
    ///      Uses a ghost poolId distinct from the initialized fixture pool. This is a direct
    ///      call to the hook (not a callback), so the selector bubbles raw — no WrappedError.
    function test_configurePool_revertsOnUninitializedPool() public {
        PoolId ghost = PoolId.wrap(bytes32(uint256(0xDEAD))); // never initialized on PoolManager
        vm.expectRevert(SimHook.PoolNotInitialized.selector);
        SimHook(address(hook)).configurePool(ghost, 100, 100, 10_000, 1 hours, 50, 2e6, 1e6);
    }

    /// @dev A swap against an initialized-but-unconfigured pool must revert PoolNotConfigured
    ///      from _beforeSwap (SimHook.sol:180). That check is the callback's first statement, so
    ///      it fires before any swap math or settlement — no liquidity required. A regression
    ///      pricing swaps on an unconfigured pool would otherwise pass undetected.
    function test_swap_revertsIfPoolNotConfigured() public {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        _expectWrappedHookRevert(IHooks.beforeSwap.selector, SimHook.PoolNotConfigured.selector);
        swapRouter.swap(key, swapParams, ts, ZERO_BYTES);
    }

    /// @dev Adding liquidity to an initialized-but-unconfigured pool must revert
    ///      PoolNotConfigured from _afterAddLiquidity (SimHook.sol:347). afterAddLiquidity runs
    ///      before the router settles tokens, so the guard is reached without any balance or
    ///      approval. Ticks aligned to the ERC20 pool's tickSpacing (10) around targetTick.
    function test_addLiquidity_revertsIfPoolNotConfigured() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: 276700,
            tickUpper: 276730,
            liquidityDelta: int256(1e18),
            salt: bytes32(0)
        });

        _expectWrappedHookRevert(IHooks.afterAddLiquidity.selector, SimHook.PoolNotConfigured.selector);
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);
    }

    /// @dev Re-encodes the CustomRevert.WrappedError that PoolManager emits when a hook callback
    ///      reverts (Hooks.callHook -> CustomRevert.bubbleUpAndRevertWith). Lets these tests
    ///      assert the SPECIFIC inner selector instead of a bare "some revert", so a wrong-reason
    ///      revert (e.g. a precondition failing earlier) fails the test rather than passing it.
    function _expectWrappedHookRevert(bytes4 callbackSelector, bytes4 innerError) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callbackSelector,
                abi.encodeWithSelector(innerError),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
