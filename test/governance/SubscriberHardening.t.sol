// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {AscntBaseHook} from "../../src/AscntBaseHook.sol";
import {AscntGovernance, IProtocolFeeBpsSubscriber} from "../../src/AscntGovernance.sol";
import {HookFactory} from "../../src/HookFactory.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";

/// @dev A well-behaved subscriber: records the last pushed value.
contract GoodSubscriber is IProtocolFeeBpsSubscriber {
    uint16 public lastBps;

    function onProtocolFeeBpsUpdated(uint16 bps) external {
        lastBps = bps;
    }
}

/// @dev A subscriber that reverts on push once armed. Passes registration while disarmed.
contract RevertingSubscriber is IProtocolFeeBpsSubscriber {
    uint16 public lastBps;
    bool public armed;

    function arm(bool v) external {
        armed = v;
    }

    function onProtocolFeeBpsUpdated(uint16 bps) external {
        require(!armed, "subscriber boom");
        lastBps = bps;
    }
}

/// @dev A subscriber that burns unbounded gas on push once armed.
contract GasGriefSubscriber is IProtocolFeeBpsSubscriber {
    bool public armed;
    uint256 public sink;

    function arm(bool v) external {
        armed = v;
    }

    function onProtocolFeeBpsUpdated(uint16) external {
        if (armed) {
            for (uint256 i = 0;; ++i) {
                sink = i;
            }
        }
    }
}

/// @dev Covers the subscriber-broadcast hardening on `AscntGovernance`/`AscntBaseHook`:
///      fault-isolated push (try/catch), sync recovery, and the fixed subscriber cap.
contract SubscriberHardeningTest is Test, ArtifactDeployers {
    AscntGovernance internal gov;
    HookFactory internal factory;

    address internal constant OWNER = address(0x0F);
    address internal TIMELOCK; // MockTimelock, set in setUp
    address internal constant PAUSER = address(0xBA5E);
    address internal constant POOL_DEPLOYER = address(0xD0D0);
    address internal constant TREASURY = address(0xDEAF);

    // Mirror of the governance event, for vm.expectEmit.
    event SubscriberPushFailed(address indexed hook, uint16 bps);

    function setUp() public {
        deployFreshManager();
        TIMELOCK = address(new MockTimelock());
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, TIMELOCK, PAUSER, POOL_DEPLOYER))
        );
        factory = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(address(factory));
    }

    function _register(address hook) internal {
        vm.prank(address(factory));
        gov.registerSubscriber(hook);
    }

    function _setFee(uint16 bps) internal {
        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        gov.setProtocolFeeBps(bps);
        vm.stopPrank();
    }

    // ------ fault-isolated broadcast ------

    function test_setProtocolFeeBps_skipsRevertingSubscriber() public {
        GoodSubscriber good = new GoodSubscriber();
        RevertingSubscriber bad = new RevertingSubscriber();
        _register(address(good));
        _register(address(bad));
        bad.arm(true);

        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        vm.expectEmit(true, false, false, true, address(gov));
        emit SubscriberPushFailed(address(bad), 500);
        gov.setProtocolFeeBps(500);
        vm.stopPrank();

        assertEq(gov.protocolFeeBps(), 500, "canonical value committed");
        assertEq(good.lastBps(), 500, "good subscriber updated");
        assertEq(bad.lastBps(), 0, "reverting subscriber left stale");
    }

    function test_setProtocolFeeBps_containsGasGriefer() public {
        GoodSubscriber good = new GoodSubscriber();
        GasGriefSubscriber grief = new GasGriefSubscriber();
        _register(address(good));
        _register(address(grief));
        grief.arm(true);

        _setFee(500); // must not revert despite the griefer

        assertEq(gov.protocolFeeBps(), 500, "canonical value committed");
        assertEq(good.lastBps(), 500, "good subscriber updated past the griefer");
    }

    function test_setProtocolFeeBps_allRevert_stillCommits() public {
        RevertingSubscriber a = new RevertingSubscriber();
        RevertingSubscriber b = new RevertingSubscriber();
        _register(address(a));
        _register(address(b));
        a.arm(true);
        b.arm(true);

        _setFee(500);

        assertEq(gov.protocolFeeBps(), 500, "canonical commits even when all pushes fail");
        assertEq(a.lastBps(), 0);
        assertEq(b.lastBps(), 0);
    }

    // ------ terminal push on removal ------

    /// @dev XSUB-3: a departing hook must not keep a live cache. Without the terminal push it
    ///      would go on splitting its cached bps out of every LP fee while unsubscribed — and
    ///      since governance then reads 0, `treasury` may legally be cleared. The live-treasury
    ///      guard in `_computeProtocolFeeSplit` now stops that combination from shorting LPs
    ///      (the split degrades to "full dynamic fee to LPs"); the terminal push remains the
    ///      first line of defence, so a cleared cache never routes value to a departed hook's
    ///      treasury either.
    function test_removeSubscriber_zeroesDepartingCache() public {
        GoodSubscriber good = new GoodSubscriber();
        GoodSubscriber staying = new GoodSubscriber();
        _register(address(good));
        _register(address(staying));
        _setFee(500);
        assertEq(good.lastBps(), 500, "cache live before removal");

        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(good));

        assertEq(good.lastBps(), 0, "departing cache zeroed on the way out");
        assertFalse(gov.isSubscribedHook(address(good)), "unsubscribed");
        assertEq(staying.lastBps(), 500, "untouched subscriber keeps its value");
    }

    /// @dev The terminal push is fault-isolated for the same reason the broadcast is: a hostile
    ///      hook must not be able to block its own removal. The residual is that such a hook
    ///      keeps a stale cache — but the failure is now observable rather than silent.
    function test_removeSubscriber_containsRevertingHook() public {
        RevertingSubscriber bad = new RevertingSubscriber();
        _register(address(bad));
        _setFee(500);
        assertEq(bad.lastBps(), 500, "cache live before removal");
        bad.arm(true);

        vm.expectEmit(true, false, false, true, address(gov));
        emit SubscriberPushFailed(address(bad), 0);
        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(bad)); // must not revert

        assertFalse(gov.isSubscribedHook(address(bad)), "removed despite the reverting push");
        assertEq(gov.subscribedHooksLength(), 0, "compacted out of the registry");
        assertEq(bad.lastBps(), 500, "stale cache is the recorded residual");
    }

    /// @dev Same containment against a gas griefer — the stipend bounds it.
    function test_removeSubscriber_containsGasGriefer() public {
        GasGriefSubscriber grief = new GasGriefSubscriber();
        _register(address(grief));
        grief.arm(true);

        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(grief)); // must not revert

        assertFalse(gov.isSubscribedHook(address(grief)), "removed despite the griefer");
    }

    // ------ recovery: hook-side syncProtocolFee pull ------

    /// @dev Deploy a real hook at the flag-valid address. Deployed BEFORE any fee is set, so the
    ///      constructor seed (`governance.protocolFeeBps()`) is 0.
    function _deployPropHook() internal returns (AscntBaseHook hook) {
        address addr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | (7 << 32)));
        deployCodeTo("Propagation.t.sol:PropHook", abi.encode(manager, gov), addr);
        hook = AscntBaseHook(addr);
    }

    /// @dev The pull is authoritative FOR THE HOOK'S LIFECYCLE STATE, not for the global rate: a
    ///      hook that is not in the subscriber registry converges to 0. Without that read, this
    ///      permissionless entry point would let ANY caller re-arm the protocol fee on a
    ///      decommissioned hook — permanently, since a hook can never be re-subscribed.
    function test_syncProtocolFee_unsubscribedHookConvergesToZero() public {
        AscntBaseHook hook = _deployPropHook(); // deliberately never registered

        _setFee(500);
        assertEq(hook.protocolFeeBps(), 0, "unsubscribed hook not pushed");
        assertFalse(gov.isSubscribedHook(address(hook)), "sanity: hook is not a subscriber");

        vm.expectEmit(address(hook));
        emit AscntBaseHook.ProtocolFeeBpsCached(0);
        vm.prank(address(0xCAFE)); // permissionless: an arbitrary caller, not governance
        hook.syncProtocolFee();
        assertEq(hook.protocolFeeBps(), 0, "unsubscribed sync must re-assert 0, not the global rate");

        // Convergence is stable: repeating the pull (or raising the global rate again) cannot
        // walk the cache back up.
        vm.prank(TIMELOCK);
        gov.setProtocolFeeBps(2000);
        hook.syncProtocolFee();
        assertEq(hook.protocolFeeBps(), 0, "unsubscribed cache must stay 0 across repeated pulls");
    }

    /// @dev The other half of the same invariant — and the original recovery property: a hook that
    ///      IS subscribed pulls the LIVE global rate, so a push that was skipped
    ///      (`SubscriberPushFailed`) is repairable by anyone. A real `AscntBaseHook` cannot be made
    ///      to fail its own push, so the miss is engineered by mocking a revert on the push
    ///      selector ONLY; the mock is cleared before `syncProtocolFee` so the real code runs.
    function test_syncProtocolFee_subscribedHookPullsCurrentValue() public {
        AscntBaseHook hook = _deployPropHook();
        _register(address(hook)); // registration push lands while the global rate is still 0

        vm.mockCallRevert(
            address(hook), abi.encodeWithSelector(IProtocolFeeBpsSubscriber.onProtocolFeeBpsUpdated.selector), ""
        );
        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        vm.expectEmit(true, false, false, true, address(gov));
        emit SubscriberPushFailed(address(hook), 500);
        gov.setProtocolFeeBps(500);
        vm.stopPrank();
        vm.clearMockedCalls();

        assertTrue(gov.isSubscribedHook(address(hook)), "hook must still be subscribed");
        assertEq(hook.protocolFeeBps(), 0, "stranded below the global rate by the skipped push");

        vm.expectEmit(address(hook));
        emit AscntBaseHook.ProtocolFeeBpsCached(500);
        vm.prank(address(0xCAFE)); // permissionless: anyone can repair the miss
        hook.syncProtocolFee();
        assertEq(hook.protocolFeeBps(), 500, "sync pulled the live global value");
    }

    // The post-removal re-arm attempt itself is pinned in
    // `HookLifecycleHardening.t.sol:test_h1_syncAfterRemoval_cannotReArmTheFee`, alongside the
    // rest of the lifecycle invariant; it is not duplicated here.

    // ------ fixed subscriber cap ------

    /// @dev The cap is a compile-time constant (no setter). Register up to `MAX_SUBSCRIBERS`
    ///      hooks, then assert the next registration reverts at the boundary.
    function test_maxSubscribers_capBlocksRegistration() public {
        uint256 cap = gov.MAX_SUBSCRIBERS();
        for (uint256 i = 0; i < cap; ++i) {
            _register(address(new GoodSubscriber()));
        }
        assertEq(gov.subscribedHooksLength(), cap, "registered exactly up to the cap");

        // Deploy BEFORE arming prank/expectRevert: a `new` in the call argument is itself a
        // CREATE that would consume the prank and be latched by expectRevert.
        address overflow = address(new GoodSubscriber());
        vm.prank(address(factory));
        vm.expectRevert(AscntGovernance.MaxSubscribersReached.selector);
        gov.registerSubscriber(overflow); // one over the cap
    }

    // ------ registration push stays strict (self-protection) ------

    function test_registration_strictlyRejectsRevertingHook() public {
        RevertingSubscriber bad = new RevertingSubscriber();
        bad.arm(true); // reverts even on the registration push
        vm.prank(address(factory));
        vm.expectRevert(bytes("subscriber boom"));
        gov.registerSubscriber(address(bad));
        assertFalse(gov.isSubscribedHook(address(bad)), "bad hook not registered");
    }
}
