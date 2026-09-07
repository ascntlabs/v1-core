// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AscntBaseHook} from "../../src/AscntBaseHook.sol";
import {AscntGovernance, IProtocolFeeBpsSubscriber} from "../../src/AscntGovernance.sol";
import {HookFactory} from "../../src/HookFactory.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";

/// @dev Minimal concrete base hook. One permission bit so it deploys at a cheap flag address.
///      `unsafeSetCache` injects a desynced cache — what a hook skipped by `SubscriberPushFailed`
///      looks like — so the self-healing path can be exercised without a hostile subscriber.
contract LifecycleHook is AscntBaseHook {
    constructor(IPoolManager pm, AscntGovernance gov) AscntBaseHook(pm, gov) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev TEST-ONLY stale-cache injector; no such setter exists on the src surface.
    function unsafeSetCache(uint16 bps) external {
        protocolFeeBps = bps;
    }

    /// @dev TEST-ONLY view onto the internal split, so the carve can be asserted without a pool.
    function exposedSplit(uint24 dynamicFee) external returns (uint24 lpFee) {
        return _computeProtocolFeeSplit(PoolId.wrap(bytes32(uint256(1))), dynamicFee);
    }
}

/// @dev Reverts on push once armed, so `removeSubscriber`'s zeroing push can be made to fail and
///      leave the cache stranded — the precondition for the self-healing test.
contract ArmableSubscriberHook is IProtocolFeeBpsSubscriber {
    uint16 public lastBps;
    bool public armed;

    function arm(bool v) external {
        armed = v;
    }

    function onProtocolFeeBpsUpdated(uint16 bps) external {
        require(!armed, "push boom");
        lastBps = bps;
    }
}

/// @notice Regression suite for the hook-lifecycle hardening.
///
///         A permissionless AND unconditional `syncProtocolFee` would let any address re-arm the
///         protocol fee on a hook that governance had just decommissioned via `removeSubscriber`
///         — permanently, since `registerSubscriber` is factory-only and only reachable on a
///         fresh CREATE2 deploy. Once the global rate is later set to 0 and the treasury zeroed
///         (both legal at that point), the stranded nonzero cache would make the split carve a
///         protocol slice out of the LP fee that the take then silently fails to collect: the
///         slice reaches neither LPs nor treasury.
///
///         The lifecycle invariant this pins: an unsubscribed hook has protocol fee 0, permanently,
///         and converges there from ANY caller — the permissionless sync is self-healing in both
///         directions rather than a re-arming vector.
///
///         Also covers the per-hook add-liquidity quarantine alongside protocol-wide pausing, so
///         containing one bad hook does not freeze deposits everywhere.
contract HookLifecycleHardeningTest is Test, ArtifactDeployers {
    AscntGovernance internal gov;
    HookFactory internal factory;
    LifecycleHook internal hook;

    address internal constant OWNER = address(0x0F);
    address internal TIMELOCK;
    address internal constant PAUSER = address(0xBA5E);
    address internal constant POOL_DEPLOYER = address(0xD0D0);
    address internal constant TREASURY = address(0xDEAF);
    address internal constant STRANGER = address(0xE0A);

    event HookAddLiquidityPauseSet(address indexed hook, bool paused);
    event ProtocolFeeBpsCached(uint16 bps);
    event SubscriberPushFailed(address indexed hook, uint16 bps);
    event SubscriberRemoved(address indexed hook);

    function setUp() public {
        deployFreshManager();
        TIMELOCK = address(new MockTimelock());
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, TIMELOCK, PAUSER, POOL_DEPLOYER))
        );
        factory = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(address(factory));

        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | (0x77 << 32)));
        deployCodeTo("HookLifecycleHardening.t.sol:LifecycleHook", abi.encode(manager, gov), hookAddr);
        hook = LifecycleHook(hookAddr);

        vm.prank(address(factory));
        gov.registerSubscriber(hookAddr);
    }

    function _setFee(uint16 bps) internal {
        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        gov.setProtocolFeeBps(bps);
        vm.stopPrank();
    }

    // ------ The re-arm vector is dead ------

    /// @notice After removal the cache is 0, and `syncProtocolFee` from an arbitrary address
    ///         leaves it at 0 instead of restoring the live global rate.
    function test_h1_syncAfterRemoval_cannotReArmTheFee() public {
        _setFee(2000);
        assertEq(hook.protocolFeeBps(), 2000, "subscribed hook tracks the push");

        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(hook));
        assertEq(hook.protocolFeeBps(), 0, "removal zeroes the cache");
        assertEq(gov.protocolFeeBps(), 2000, "global rate is untouched by removal");

        vm.expectEmit(false, false, false, true, address(hook));
        emit ProtocolFeeBpsCached(0);
        vm.prank(STRANGER);
        hook.syncProtocolFee();

        assertEq(hook.protocolFeeBps(), 0, "sync must not re-arm a decommissioned hook");
    }

    /// @notice Self-healing: a cache stranded nonzero on an unsubscribed hook (the skipped-push
    ///         case) is zeroed by anyone calling the permissionless sync.
    function test_selfHealing_strandedCacheZeroedByAnyone() public {
        _setFee(2000);
        hook.unsafeSetCache(1500); // simulate a zeroing push that never landed

        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(hook));
        hook.unsafeSetCache(1500); // and strand it again, post-removal

        vm.prank(STRANGER);
        hook.syncProtocolFee();
        assertEq(hook.protocolFeeBps(), 0, "sync converges an unsubscribed hook to 0");
    }

    /// @notice Removal is re-assertable: a second call re-pushes 0 rather than silently
    ///         no-oping, and touches neither the registry nor the caller with a revert.
    function test_removalIsReAssertable_repeatCallRePushesZero() public {
        _setFee(2000);
        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(hook));

        hook.unsafeSetCache(1234); // desync again after removal
        assertEq(gov.subscribedHooksLength(), 0, "registry already empty");

        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(hook)); // must not revert, must re-push 0

        assertEq(hook.protocolFeeBps(), 0, "repeat removal re-asserts the zero");
        assertEq(gov.subscribedHooksLength(), 0, "registry untouched by the repeat call");
        assertFalse(gov.isSubscribedHook(address(hook)), "still unsubscribed");
    }

    // ------ carve-but-fail-to-collect is structurally impossible ------

    /// @notice With any nonzero cached bps and `treasury == address(0)`, the split carves
    ///         nothing: the full dynamic fee goes to LPs. This is the shape the audit PoC
    ///         exploited — reduce the LP fee, then take nothing because there is no treasury.
    function test_carveNoCollect_impossibleWhenTreasuryUnset() public {
        _setFee(2000);
        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(hook));

        // The full PoC end state: global rate back to 0, treasury cleared, stale cache stranded.
        vm.startPrank(TIMELOCK);
        gov.setProtocolFeeBps(0);
        gov.setTreasury(address(0));
        vm.stopPrank();
        hook.unsafeSetCache(2000);

        uint24 dynamicFee = 10_000;
        uint24 lpFee = hook.exposedSplit(dynamicFee);
        assertEq(lpFee, dynamicFee, "no treasury => no carve; LPs keep the whole dynamic fee");
    }

    /// @notice The guard is on the LIVE treasury, so it also protects a still-subscribed hook
    ///         whose treasury was cleared underneath it.
    function test_carveNoCollect_impossibleForSubscribedHookToo() public {
        _setFee(2000);
        assertEq(hook.protocolFeeBps(), 2000, "cache armed");

        vm.startPrank(TIMELOCK);
        gov.setProtocolFeeBps(0); // must precede clearing the treasury (TreasuryRequired)
        gov.setTreasury(address(0));
        vm.stopPrank();
        hook.unsafeSetCache(2000); // strand the cache high

        assertEq(hook.exposedSplit(10_000), 10_000, "no treasury => full fee to LPs");
    }

    // ------ per-hook add-liquidity quarantine ------

    /// @notice Removal lands the hook paused (fail-safe), and owner or pauser can reopen it.
    function test_removalLandsHookPaused_andIsReversible() public {
        assertFalse(gov.hookAddLiquidityPaused(address(hook)), "starts open");

        vm.expectEmit(true, false, false, true, address(gov));
        emit HookAddLiquidityPauseSet(address(hook), true);
        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(hook));

        assertTrue(gov.hookAddLiquidityPaused(address(hook)), "removal quarantines deposits");
        assertTrue(gov.isAddLiquidityBlocked(address(hook)), "combined view agrees");

        vm.prank(PAUSER);
        gov.setHookAddLiquidityPaused(address(hook), false);
        assertFalse(gov.isAddLiquidityBlocked(address(hook)), "pauser can reopen a pruned hook");
    }

    /// @notice The two layers compose as OR and never overwrite each other: clearing the global
    ///         breaker restores each hook's own state exactly.
    function test_pauseLayering_globalAndPerHookAreIndependent() public {
        address other = address(0xA0A0);

        vm.prank(OWNER);
        gov.setHookAddLiquidityPaused(address(hook), true);
        assertTrue(gov.isAddLiquidityBlocked(address(hook)), "hook quarantined");
        assertFalse(gov.isAddLiquidityBlocked(other), "other hook unaffected");

        vm.prank(PAUSER);
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.isAddLiquidityBlocked(other), "global breaker covers everything");

        vm.prank(PAUSER);
        gov.setAddLiquidityPaused(false);
        assertTrue(gov.isAddLiquidityBlocked(address(hook)), "per-hook state survives the global lift");
        assertFalse(gov.isAddLiquidityBlocked(other), "healthy hooks reopen");
    }

    /// @notice Authority: the per-hook lever is instant-lane (owner or pauser), and closed to
    ///         everyone else. Removal stays timelock-only.
    function test_authorization_perHookPauseAndRemoval() public {
        vm.prank(STRANGER);
        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        gov.setHookAddLiquidityPaused(address(hook), true);

        vm.prank(POOL_DEPLOYER);
        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        gov.setHookAddLiquidityPaused(address(hook), true);

        vm.prank(STRANGER);
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.removeSubscriber(address(hook));

        vm.prank(OWNER);
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.removeSubscriber(address(hook));
    }

    // ------ unchanged behaviour ------

    /// @notice A subscribed hook still tracks pushes, and sync still recovers a skipped push.
    function test_unchanged_subscribedHookTracksPushesAndRecovers() public {
        _setFee(1500);
        assertEq(hook.protocolFeeBps(), 1500, "push landed");

        hook.unsafeSetCache(0); // simulate SubscriberPushFailed leaving it stale-low
        vm.prank(STRANGER);
        hook.syncProtocolFee();
        assertEq(hook.protocolFeeBps(), 1500, "sync still recovers a skipped push while subscribed");
    }

    /// @notice A reverting hook cannot block its own removal, and the failure is announced —
    ///         the recovery is then permissionless via sync.
    function test_hostileHookCannotBlockRemoval_andSyncCleansUp() public {
        ArmableSubscriberHook bad = new ArmableSubscriberHook();
        vm.prank(address(factory));
        gov.registerSubscriber(address(bad));
        _setFee(2000);
        bad.arm(true);

        vm.expectEmit(true, false, false, true, address(gov));
        emit SubscriberPushFailed(address(bad), 0);
        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(bad));

        assertFalse(gov.isSubscribedHook(address(bad)), "removed despite the reverting push");
        assertTrue(gov.hookAddLiquidityPaused(address(bad)), "and quarantined fail-safe");
    }
}
