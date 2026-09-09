// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------------------------
// Phase 2 (access-gov): SimHook lifecycle access control + config-bounds state machine.
//
// Invariants covered here:
//   LIFE-1  — configurePool succeeds at most once; NO stored field ever changes afterwards
//   LIFE-2  — configured==true implies the FULL bound chain holds (fuzz, success-side readback)
//   LIFE-5  — configurePool reverts PoolNotInitialized for uninitialized poolIds
//             (+ documents the benign foreign-pool "squat" behavior)
//   LIFE-6  — _beforeInitialize rejects every non-dynamic fee (incl. flag|extra-bits)
//   LIFE-7  — _beforeInitialize enforces the 2^58 initial-price floor (fuzz both sides)
//   LIFE-8  — init/configure gate resolves owner/poolDeployer LIVE (rotation applies instantly)
//   LIFE-11 — beforeSwap / afterAddLiquidity return ZERO deltas; afterSwapReturnDelta is true
//   LIFE-12 — hook address bits == getHookPermissions() == HookFlags.simHookMask() (no drift)
//   ACC-7   — poolData is mutable ONLY through onlyPoolManager callbacks (no direct writes)
// ---------------------------------------------------------------------------------------------

import {TestUtils} from "../utils/TestUtils.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {HookFlags} from "../../script/utils/HookFlags.sol";
import {SimHook} from "../../src/SimHook.sol";
import {AscntBaseHook} from "../../src/AscntBaseHook.sol";

contract Phase2LifecycleAccessTest is TestUtils {
    using PoolIdLibrary for PoolKey;

    SimHook internal hook;
    uint160 internal initSqrtPrice;

    // Canonical valid config used whenever a test just needs "a" configured pool.
    uint24 internal constant C_MIN_MIN = 10;
    uint24 internal constant C_MAX_MIN = 100;
    uint24 internal constant C_MAX_FEE = 10_000;
    uint256 internal constant C_DECAY = 1 hours;
    uint48 internal constant C_JIT = 50;
    uint32 internal constant C_K = 2_000_000;
    uint32 internal constant C_C = 1_000_000;

    uint160 internal constant PRICE_FLOOR = uint160(1) << 58; // SimHook.MIN_USABLE_SQRT_PRICE

    function setUp() public {
        // Initialized but NOT configured — tests configure on demand.
        address hookAddress = deployCoreAndHookCustomDecimals("SimHook.sol", "USDC", "USDT", 6, 6, false);
        hook = SimHook(hookAddress);
        (, initSqrtPrice) = deployPool(hook, 0, 1, false);
    }

    function _configureCanonical(PoolId pid) internal {
        hook.configurePool(pid, C_MIN_MIN, C_MAX_MIN, C_MAX_FEE, C_DECAY, C_JIT, C_K, C_C);
    }

    function _expectWrappedInitRevert(bytes4 innerError) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(innerError),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    // ------ LIFE-1: one-time configure, immutable forever ------

    /// LIFE-1 (CRITICAL): after the first configure, a second call — with EVERY field changed,
    /// from the owner AND from the poolDeployer — reverts PoolAlreadyConfigured, and the stored
    /// struct stays byte-identical through the attempts and through live pool activity.
    function test_life1_configurePool_oneTime_structImmutableForever() public {
        _configureCanonical(poolId);
        _assertCanonicalConfig("post-configure");

        // Delegate the fast lane to a hot wallet, then attack the one-time slot from both roles.
        address deployer = makeAddr("p2-pool-deployer");
        governance.setPoolDeployer(deployer); // test contract is the timelock in this fixture

        // As owner, all fields different.
        vm.expectRevert(SimHook.PoolAlreadyConfigured.selector);
        hook.configurePool(poolId, 0, 555, LPFeeLibrary.MAX_LP_FEE, 999, 7200, 4e6, 2e6);

        // As poolDeployer, all fields different.
        vm.prank(deployer);
        vm.expectRevert(SimHook.PoolAlreadyConfigured.selector);
        hook.configurePool(poolId, 1, 2, 3, 4, 5, 6, 7);

        // A stranger is stopped by the authority gate (before it could even see the slot).
        address stranger = makeAddr("p2-stranger");
        vm.prank(stranger);
        vm.expectRevert(AscntBaseHook.NotOwnerOrPoolDeployer.selector);
        hook.configurePool(poolId, 1, 2, 3, 4, 5, 6, 7);

        // Live pool activity (add + swap) must not disturb the config either.
        addLiquidity(-600, 600, 1e12, initSqrtPrice, false);
        swap(true, -1e6, false);
        swap(false, -1e6, false);

        _assertCanonicalConfig("after attacks + live activity");
    }

    /// @dev Field-for-field assert of the stored struct against the canonical constants —
    ///      stronger than a before/after snapshot (pins the actual written values). Split into
    ///      its own frame so only one 8-way poolConfig destructure is ever live at a time: two
    ///      overlapping ones blow the stack on the dev profile (via-IR without the optimizer).
    function _assertCanonicalConfig(string memory when) internal view {
        (bool cfg, uint24 minMin, uint24 maxMin, uint24 maxFee, uint48 decay, uint48 jit, uint32 k, uint32 c) =
            hook.poolConfig(poolId);
        assertTrue(cfg, string.concat(when, ": configured"));
        assertEq(minMin, C_MIN_MIN, string.concat(when, ": minMinFee"));
        assertEq(maxMin, C_MAX_MIN, string.concat(when, ": maxMinFee"));
        assertEq(maxFee, C_MAX_FEE, string.concat(when, ": maxFee"));
        assertEq(decay, C_DECAY, string.concat(when, ": timeDecayLength"));
        assertEq(jit, C_JIT, string.concat(when, ": jitLockBlocks"));
        assertEq(k, C_K, string.concat(when, ": kPips"));
        assertEq(c, C_C, string.concat(when, ": cPips"));
    }

    // ------ LIFE-2: configured implies the full bound chain (success-side readback) ------

    /// LIFE-2: configurePool either reverts (with one of the named bound errors, leaving the
    /// pool unconfigured) or writes a struct satisfying the FULL chain simultaneously, with no
    /// uint48 truncation of timeDecayLength. Inputs are correlated-bounded so both the accept
    /// and every reject branch are hit at meaningful rates.
    /// forge-config: default.fuzz.runs = 200
    /// forge-config: dev.fuzz.runs = 200
    function testFuzz_life2_configuredImpliesFullBoundChain(uint24 a, uint24 b, uint24 c, uint256 e, uint48 f) public {
        uint24 maxFee = uint24(bound(a, 0, 550_000)); // straddles the hook's maxFee cap (500_000)
        uint24 maxMin = uint24(bound(b, 0, (uint256(maxFee) * 12) / 10 + 2));
        uint24 minMin = uint24(bound(c, 0, (uint256(maxMin) * 12) / 10 + 2));
        uint256 decay = bound(e, 0, hook.MAX_TIME_DECAY_LENGTH() * 2); // straddles the 1-day cap
        uint48 jit = uint48(bound(f, 0, 55_000)); // straddles MAX_JIT_LOCK_BLOCKS (50_400)

        (bool ok, bytes memory ret) = address(hook)
            .call(abi.encodeCall(SimHook.configurePool, (poolId, minMin, maxMin, maxFee, decay, jit, C_K, C_C)));

        if (ok) {
            // Accepted: stored == inputs and the whole lattice holds simultaneously.
            // (Fresh frame: this function's inputs + an 8-way destructure exceed the dev
            // profile's unoptimized-IR stack when they share one frame.)
            _assertStoredEqualsInputs(minMin, maxMin, maxFee, decay, jit);
        } else {
            // Rejected: pool stays unconfigured and the revert is one of the named bound errors.
            (bool cfg,,,,,,,) = hook.poolConfig(poolId);
            assertFalse(cfg, "rejected config must leave the pool unconfigured");
            bytes4 sel = bytes4(ret);
            assertTrue(
                sel == SimHook.MinFeeBounds.selector || sel == SimHook.FeeBounds.selector
                    || sel == SimHook.FeeTooHigh.selector || sel == SimHook.ZeroDecay.selector
                    || sel == SimHook.DecayTooLong.selector || sel == SimHook.JitLockBlocksTooHigh.selector,
                "revert must be a named bound error"
            );
        }
    }

    /// @dev Accept-side readback for LIFE-2, in its own frame for stack headroom (see caller).
    ///      Two partial destructures keep at most five components live at once.
    function _assertStoredEqualsInputs(
        uint24 minMin,
        uint24 maxMin,
        uint24 maxFee,
        uint256 decay,
        uint48 jit
    ) internal view {
        {
            (bool cfg, uint24 sMinMin, uint24 sMaxMin, uint24 sMaxFee,,,,) = hook.poolConfig(poolId);
            assertTrue(cfg, "accepted config must be marked configured");
            assertEq(sMinMin, minMin);
            assertEq(sMaxMin, maxMin);
            assertEq(sMaxFee, maxFee);

            assertLe(sMinMin, sMaxMin, "minMinFee <= maxMinFee");
            assertLe(sMaxMin, sMaxFee, "maxMinFee <= maxFee");
            assertLe(sMaxFee, HOOK_MAX_FEE, "maxFee <= hook cap");
        }
        {
            (,,,, uint48 sDecay, uint48 sJit, uint32 sK, uint32 sC) = hook.poolConfig(poolId);
            assertEq(uint256(sDecay), decay, "uint48 store must not truncate an admitted decay");
            assertEq(sJit, jit);
            assertEq(sK, C_K);
            assertEq(sC, C_C);

            assertGt(sDecay, 0, "timeDecayLength > 0");
            assertLe(sDecay, hook.MAX_TIME_DECAY_LENGTH(), "timeDecayLength <= 1 days");
            assertLe(sJit, hook.MAX_JIT_LOCK_BLOCKS(), "jitLockBlocks <= MAX_JIT_LOCK_BLOCKS");
        }
    }

    // ------ LIFE-5: no configure before PoolManager initialization ------

    /// LIFE-5: any poolId the PoolManager has never initialized (slot0.sqrtPriceX96 == 0)
    /// rejects configuration outright.
    /// forge-config: default.fuzz.runs = 64
    /// forge-config: dev.fuzz.runs = 64
    function testFuzz_life5_configureUninitializedPool_reverts(bytes32 rawId) public {
        vm.assume(rawId != PoolId.unwrap(poolId));
        vm.expectRevert(SimHook.PoolNotInitialized.selector);
        hook.configurePool(PoolId.wrap(rawId), C_MIN_MIN, C_MAX_MIN, C_MAX_FEE, C_DECAY, C_JIT, C_K, C_C);
    }

    /// LIFE-5 (harness note, DOCUMENTS CURRENT BEHAVIOR): a poolId that IS initialized on the
    /// PoolManager but belongs to a DIFFERENT hook can be "configured" on this hook, because the
    /// only initialization evidence checked is slot0.sqrtPriceX96 != 0. This is benign — this
    /// hook never receives callbacks for that pool, so the squatted config entry is dead state —
    /// but it is recorded here so the behavior is explicit for the auditors.
    function test_life5_foreignPoolId_configureSucceeds_documented() public {
        (, PoolId foreignId) = initPool(currency0, currency1, IHooks(address(0)), 100, 60, SQRT_PRICE_1_1);

        _configureCanonical(foreignId); // current behavior: accepted
        (bool cfg,,,,,,,) = hook.poolConfig(foreignId);
        assertTrue(cfg, "documented: foreign-pool configure is accepted (dead-state entry)");
    }

    // ------ LIFE-6: dynamic-fee flag is mandatory (exact match) ------

    /// LIFE-6: every fee value that is not exactly DYNAMIC_FEE_FLAG — static fees AND
    /// flag|extra-bits values — is rejected at the hook level.
    /// forge-config: default.fuzz.runs = 64
    /// forge-config: dev.fuzz.runs = 64
    function testFuzz_life6_nonDynamicFee_reverts(uint24 fee) public {
        vm.assume(fee != LPFeeLibrary.DYNAMIC_FEE_FLAG);
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: 2,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(SimHook.MustUseDynamicFee.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), k, PRICE_FLOOR);
    }

    /// LIFE-6 (explicit edge): DYNAMIC_FEE_FLAG with extra bits set is NOT a dynamic fee.
    /// (Through the manager this shape is masked by LPFeeTooLarge; the hook-level guard is
    /// exercised directly so the defense stays proven independent of v4's ordering.)
    function test_life6_dynamicFlagWithExtraBits_reverts() public {
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG | 1,
            tickSpacing: 2,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(SimHook.MustUseDynamicFee.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), k, PRICE_FLOOR);
    }

    // ------ LIFE-7: initial-price floor (2^58) ------

    /// LIFE-7 (reject side): every price in [MIN_SQRT_PRICE, 2^58) is refused.
    /// forge-config: default.fuzz.runs = 64
    /// forge-config: dev.fuzz.runs = 64
    function testFuzz_life7_priceBelowFloor_reverts(uint160 p) public {
        uint160 price = uint160(bound(p, TickMath.MIN_SQRT_PRICE, PRICE_FLOOR - 1));
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 2,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(SimHook.InitialPriceTooLow.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), k, price);
    }

    /// LIFE-7 (accept side): every price at or above the floor passes the gate (owner sender).
    /// forge-config: default.fuzz.runs = 64
    /// forge-config: dev.fuzz.runs = 64
    function testFuzz_life7_priceAtOrAboveFloor_accepted(uint160 p) public {
        uint160 price = uint160(bound(p, PRICE_FLOOR, TickMath.MAX_SQRT_PRICE - 1));
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 2,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(manager));
        bytes4 sel = hook.beforeInitialize(address(this), k, price);
        assertEq(sel, IHooks.beforeInitialize.selector);
    }

    // ------ LIFE-8: live-resolved authority for init + configure ------

    /// LIFE-8: the init/configure gate reads owner/poolDeployer from governance AT CALL TIME —
    /// a rotated-away deployer key loses both powers instantly, the new key gains them.
    function test_life8_poolDeployerRotation_appliesImmediately() public {
        address pd1 = makeAddr("p2-pd1");
        address pd2 = makeAddr("p2-pd2");

        governance.setPoolDeployer(pd1); // test contract is the timelock

        // pd1 can initialize a fresh pool through the manager.
        PoolKey memory k2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 3,
            hooks: IHooks(address(hook))
        });
        vm.prank(pd1);
        manager.initialize(k2, SQRT_PRICE_1_1);
        PoolId id2 = k2.toId();

        // Rotate: pd1 out, pd2 in.
        governance.setPoolDeployer(pd2);

        vm.prank(pd1);
        vm.expectRevert(AscntBaseHook.NotOwnerOrPoolDeployer.selector);
        hook.configurePool(id2, C_MIN_MIN, C_MAX_MIN, C_MAX_FEE, C_DECAY, C_JIT, C_K, C_C);

        vm.prank(pd2);
        hook.configurePool(id2, C_MIN_MIN, C_MAX_MIN, C_MAX_FEE, C_DECAY, C_JIT, C_K, C_C);
        (bool cfg,,,,,,,) = hook.poolConfig(id2);
        assertTrue(cfg, "new deployer key configures successfully");

        // And through the full v4 plumbing: pd1 can no longer initialize, pd2 can.
        PoolKey memory k3 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 4,
            hooks: IHooks(address(hook))
        });
        _expectWrappedInitRevert(AscntBaseHook.NotOwnerOrPoolDeployer.selector);
        vm.prank(pd1);
        manager.initialize(k3, SQRT_PRICE_1_1);

        vm.prank(pd2);
        manager.initialize(k3, SQRT_PRICE_1_1);
    }

    // ------ ACC-7: accumulator state only mutable via onlyPoolManager callbacks ------

    /// ACC-7: every hook callback reverts NotPoolManager for every non-manager caller (owner,
    /// poolDeployer, pauser, treasury, stranger), and poolData stays untouched. There is no
    /// other external/public function on SimHook/AscntBaseHook that writes poolData (the
    /// mutation surface is beforeSwap/afterSwap only — enforced here at the gate).
    function test_acc7_callbacks_revertNotPoolManager_forEveryNonManagerCaller() public {
        _configureCanonical(poolId);

        address deployer = makeAddr("p2-acc7-deployer");
        address pauser = makeAddr("p2-acc7-pauser");
        governance.setPoolDeployer(deployer);
        governance.setPauser(pauser);

        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        ModifyLiquidityParams memory mlp =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e6, salt: 0});
        BalanceDelta zero = BalanceDeltaLibrary.ZERO_DELTA;

        address[5] memory callers =
            [address(this), deployer, pauser, makeAddr("p2-acc7-treasury"), makeAddr("p2-acc7-rando")];

        for (uint256 i = 0; i < callers.length; i++) {
            address caller = callers[i];

            vm.expectRevert(ImmutableState.NotPoolManager.selector);
            vm.prank(caller);
            hook.beforeSwap(caller, key, sp, "");

            vm.expectRevert(ImmutableState.NotPoolManager.selector);
            vm.prank(caller);
            hook.afterSwap(caller, key, sp, zero, "");

            vm.expectRevert(ImmutableState.NotPoolManager.selector);
            vm.prank(caller);
            hook.afterAddLiquidity(caller, key, mlp, zero, zero, "");

            vm.expectRevert(ImmutableState.NotPoolManager.selector);
            vm.prank(caller);
            hook.beforeAddLiquidity(caller, key, mlp, "");

            vm.expectRevert(ImmutableState.NotPoolManager.selector);
            vm.prank(caller);
            hook.beforeRemoveLiquidity(caller, key, mlp, "");

            vm.expectRevert(ImmutableState.NotPoolManager.selector);
            vm.prank(caller);
            hook.beforeInitialize(caller, key, PRICE_FLOOR);

            vm.expectRevert(ImmutableState.NotPoolManager.selector);
            vm.prank(caller);
            hook.afterInitialize(caller, key, PRICE_FLOOR, 0);
        }

        // No accumulator field moved.
        (uint160 sqrtBefore, uint48 lastTs,, int256 cum) = hook.poolData(poolId);
        assertEq(sqrtBefore, 0, "sqrtPriceX96Before untouched");
        assertEq(lastTs, 0, "lastSwapTimestamp untouched");
        assertEq(cum, 0, "cumPriceImpact untouched");
    }

    // ------ LIFE-11: return-delta consistency ------

    /// LIFE-11: beforeSwap always returns a ZERO BeforeSwapDelta (its returns-delta flag is
    /// false), afterAddLiquidity always returns a ZERO BalanceDelta (flag false), and
    /// afterSwapReturnDelta is true (the protocol take needs it). Checked on the very first
    /// swap of a fresh pool and all four direction/exactness combos.
    function test_life11_returnDeltas_matchDeclaredPermissions() public {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertFalse(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta must be false");
        assertTrue(perms.afterSwapReturnDelta, "afterSwapReturnDelta must be true");
        assertTrue(perms.afterSwap, "afterSwapReturnDelta requires afterSwap");
        assertFalse(perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta must be false");

        _configureCanonical(poolId);
        addLiquidity(-600, 600, 1e12, initSqrtPrice, false);

        // First swap on a fresh pool (prices off cum = 0).
        SwapParams memory first =
            SwapParams({zeroForOne: true, amountSpecified: -1e5, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta bsd, uint24 fee) = hook.beforeSwap(address(this), key, first, "");
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(bsd), 0, "first swap must return ZERO BeforeSwapDelta");
        assertTrue(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "fee override flag set");

        // All four (direction x exactness) combos.
        for (uint256 i = 0; i < 4; i++) {
            bool zeroForOne = i % 2 == 0;
            bool exactInput = i < 2;
            SwapParams memory p = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInput ? -int256(1e5) : int256(1e5),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });
            vm.prank(address(manager));
            (, BeforeSwapDelta d,) = hook.beforeSwap(address(this), key, p, "");
            assertEq(BeforeSwapDelta.unwrap(d), 0, "dynamic branch must return ZERO BeforeSwapDelta");
        }

        // afterAddLiquidity: ZERO BalanceDelta for a positive liquidity delta.
        ModifyLiquidityParams memory mlp =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e6, salt: bytes32(uint256(0x99))});
        vm.prank(address(manager));
        (bytes4 sel2, BalanceDelta bd) = hook.afterAddLiquidity(
            address(this), key, mlp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, ""
        );
        assertEq(sel2, IHooks.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(bd), 0, "afterAddLiquidity must return ZERO BalanceDelta");
    }

    // ------ LIFE-12: address bits <-> permissions <-> shared mask ------

    /// LIFE-12: the bitmap derived from getHookPermissions(), the shared HookFlags.simHookMask()
    /// (used by every deploy path), and the deployed address's low 14 bits are all identical —
    /// no source of the permission set can drift from the others.
    function test_life12_addressBits_permissions_andSharedMask_agree() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        uint160 fromPerms = 0;
        if (p.beforeInitialize) fromPerms |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) fromPerms |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) fromPerms |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) fromPerms |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) fromPerms |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) fromPerms |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) fromPerms |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) fromPerms |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) fromPerms |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) fromPerms |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) fromPerms |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) fromPerms |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) fromPerms |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) {
            fromPerms |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        }

        // The exact expected set for SimHook (spelled out so a future permission change must
        // consciously edit this test too).
        uint160 expected = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

        assertEq(fromPerms, expected, "getHookPermissions drifted from the intended set");
        assertEq(fromPerms, HookFlags.simHookMask(), "shared HookFlags mask drifted");
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK, fromPerms, "deployed address bits drifted from permissions"
        );
    }
}
