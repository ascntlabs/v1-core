// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------------------------
// Phase 2 (access-gov): stateful invariants over the AscntGovernance authority state machine.
//
// Invariants covered here:
//   GOV-3  — owner() is never address(0) in any reachable state
//   GOV-4  — protocolFeeBps <= MAX_PROTOCOL_FEE_BPS in any reachable state
//   GOV-5  — protocolFeeBps > 0 implies treasury != address(0) (bidirectional guard)
//   GOV-6  — timelock always a contract with getMinDelay() > 0
//   GOV-7  — hookFactory immutable after bootstrap
//   GOV-10 — subscriber registry mapping <-> array bijection, no duplicates
//   GOV-11 — swap-and-pop removal preserves every OTHER member; non-member removal is a no-op
//   GOV-14 (support) — every subscriber's pushed value is the capped governance value
//
// The handler (Phase2_GovHandler.sol) drives every mutator from live-resolved correct roles AND
// wrong-role callers; `unauthorizedSuccessCount` / `guardBypassCount` pin the access side.
// ---------------------------------------------------------------------------------------------

import {Test} from "forge-std/Test.sol";

import {AscntGovernance, ITimelockMinDelay} from "../../src/AscntGovernance.sol";
import {Phase2GovHandler, P2HandlerTimelock, P2HandlerFactory, P2RegSub} from "./Phase2_GovHandler.sol";

contract Phase2GovInvariantTest is Test {
    AscntGovernance internal gov;
    Phase2GovHandler internal handler;

    address internal constant OWNER0 = address(0xAA01); // in the handler's actor pool
    address internal FACTORY;

    address[] internal timelockPool;

    function setUp() public {
        timelockPool.push(address(new P2HandlerTimelock()));
        timelockPool.push(address(new P2HandlerTimelock()));

        gov = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER0, timelockPool[0], address(0), address(0))
            )
        );
        FACTORY = address(new P2HandlerFactory(address(gov)));
        vm.prank(OWNER0);
        gov.setHookFactory(FACTORY);

        handler = new Phase2GovHandler(gov, FACTORY, timelockPool);

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = Phase2GovHandler.setTreasury.selector;
        selectors[1] = Phase2GovHandler.setProtocolFeeBps.selector;
        selectors[2] = Phase2GovHandler.setPoolDeployer.selector;
        selectors[3] = Phase2GovHandler.setPauser.selector;
        selectors[4] = Phase2GovHandler.togglePause.selector;
        selectors[5] = Phase2GovHandler.transferOwnership.selector;
        selectors[6] = Phase2GovHandler.rotateTimelock.selector;
        selectors[7] = Phase2GovHandler.registerSubscriber.selector;
        selectors[8] = Phase2GovHandler.removeSubscriber.selector;
        selectors[9] = Phase2GovHandler.probe_transferOwnershipToZero.selector;
        selectors[10] = Phase2GovHandler.probe_renounceOwnership.selector;
        selectors[11] = Phase2GovHandler.probe_invalidTimelockRotation.selector;
        selectors[12] = Phase2GovHandler.probe_rewireHookFactory.selector;
        selectors[13] = Phase2GovHandler.probe_unauthorizedSlowLane.selector;
        selectors[14] = Phase2GovHandler.proposeTimelockOnly.selector;
        selectors[15] = Phase2GovHandler.probe_unauthorizedAccept.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        bytes4[] memory selectors2 = new bytes4[](2);
        selectors2[0] = Phase2GovHandler.probe_unauthorizedFastLane.selector;
        selectors2[1] = Phase2GovHandler.probe_unauthorizedRegister.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors2}));

        targetContract(address(handler));
    }

    /// GOV-3: the fast lane can never be bricked by a zero owner.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 32
    /// forge-config: dev.invariant.depth = 40
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_gov3_ownerNeverZero() public view {
        assertTrue(gov.owner() != address(0), "GOV-3: owner must never be address(0)");
    }

    /// GOV-4: stored fee bps never exceeds the cap.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 32
    /// forge-config: dev.invariant.depth = 40
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_gov4_protocolFeeBpsCapped() public view {
        assertLe(gov.protocolFeeBps(), gov.MAX_PROTOCOL_FEE_BPS(), "GOV-4: fee above cap");
    }

    /// GOV-5: a positive fee never coexists with a zero treasury (either ordering).
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 32
    /// forge-config: dev.invariant.depth = 40
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_gov5_feeImpliesTreasury() public view {
        if (gov.protocolFeeBps() > 0) {
            assertTrue(gov.treasury() != address(0), "GOV-5: positive fee with zero treasury");
        }
    }

    /// GOV-6: the slow lane always sits behind a real (contract, non-zero-delay) timelock.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 32
    /// forge-config: dev.invariant.depth = 40
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_gov6_timelockAlwaysValid() public view {
        address tl = gov.timelock();
        assertTrue(tl != address(0), "GOV-6: zero timelock");
        assertGt(tl.code.length, 0, "GOV-6: timelock must be a contract");
        assertGe(
            ITimelockMinDelay(tl).getMinDelay(),
            gov.MIN_TIMELOCK_DELAY(),
            "GOV-6: timelock delay must clear the 24h floor"
        );
    }

    /// GOV-7: the factory pointer never moves after the one-shot bootstrap.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 32
    /// forge-config: dev.invariant.depth = 40
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_gov7_hookFactoryImmutableAfterBootstrap() public view {
        assertEq(gov.hookFactory(), FACTORY, "GOV-7: hookFactory pointer moved");
    }

    /// GOV-10 + GOV-11: mapping <-> array bijection with no duplicates, after any interleaving
    /// of register / remove (incl. re-register, remove-nonmember, remove-twice sequences the
    /// handler generates).
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 32
    /// forge-config: dev.invariant.depth = 40
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_gov10_gov11_registryBijectionNoDuplicates() public view {
        uint256 len = gov.subscribedHooksLength();
        assertLe(len, gov.MAX_SUBSCRIBERS(), "GOV-9 backstop: length above cap");

        // Every array entry is flagged in the mapping and appears exactly once.
        for (uint256 i = 0; i < len; i++) {
            address h = gov.subscribedHooks(i);
            assertTrue(gov.isSubscribedHook(h), "GOV-10: array entry not flagged in mapping");
            for (uint256 j = i + 1; j < len; j++) {
                assertTrue(gov.subscribedHooks(j) != h, "GOV-10: duplicate array entry");
            }
        }

        // Every candidate the handler can register: flagged iff present exactly once (GOV-11 —
        // a removal never drops or duplicates an unrelated member).
        uint256 candidates = handler.subPoolLength();
        for (uint256 c = 0; c < candidates; c++) {
            address sub = address(handler.subPool(c));
            uint256 occurrences = 0;
            for (uint256 i = 0; i < len; i++) {
                if (gov.subscribedHooks(i) == sub) occurrences++;
            }
            if (gov.isSubscribedHook(sub)) {
                assertEq(occurrences, 1, "GOV-11: member must appear exactly once");
            } else {
                assertEq(occurrences, 0, "GOV-11: non-member must not appear");
            }
        }
    }

    /// GOV-14 (support): whatever value a subscriber last received via push is the capped
    /// governance value — pushes never carry an uncapped bps.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 32
    /// forge-config: dev.invariant.depth = 40
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_gov14_subscriberPushesAlwaysCapped() public view {
        uint256 candidates = handler.subPoolLength();
        for (uint256 c = 0; c < candidates; c++) {
            P2RegSub sub = handler.subPool(c);
            assertLe(sub.lastBps(), gov.MAX_PROTOCOL_FEE_BPS(), "GOV-14: uncapped push observed");
        }
    }

    /// Access side: no wrong-role caller ever succeeded, and no guarded value slipped through.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: dev.invariant.runs = 32
    /// forge-config: dev.invariant.depth = 40
    /// forge-config: dev.invariant.fail-on-revert = false
    /// forge-config: nightly.invariant.runs = 1000
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_gov_accessMatrixHolds() public view {
        assertEq(handler.unauthorizedSuccessCount(), 0, "unauthorized caller mutated governance");
        assertEq(handler.guardBypassCount(), 0, "a value guard was bypassed");
    }

    /// Progress guard: the run actually drove the state machine (not a vacuous pass).
    function afterInvariant() public view {
        assertGt(handler.actionCount(), 0, "handler made no calls");
        assertGt(handler.mutationCount(), 0, "no successful state mutation in the whole run");
        assertGt(handler.expectedRevertCount(), 0, "no denial path was ever exercised");
    }
}
