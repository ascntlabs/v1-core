// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------------------------
// Phase 2 (access-gov): governance authority matrix + push/cache gating.
//
// Invariants covered here:
//   GOV-1  — every slow-lane setter reverts NotTimelock for every non-timelock caller
//   GOV-2  — transferOwnership is onlyTimelock (NOT the OZ onlyOwner default)
//   GOV-13 — a skipped subscriber recovers via permissionless syncProtocolFee
//   GOV-14 — hook fee-bps cache mutable only by governance push / permissionless sync; <= 2000
//   GOV-15 — poolDeployer has zero write authority over any governance slot
//   GOV-19 — a reentrant subscriber cannot mutate governance state during the push loop
//   GOV-20 — setPauser is owner-only (pauser cannot rotate itself, timelock cannot either)
//   GOV-21 — setAddLiquidityPaused gate (incl. the pauser==0 / caller==address(0) edge)
//   GOV-22 — MAX_PROTOCOL_FEE_BPS structurally below the whole dynamic fee (static assertion)
//   GOV-23 — isVerified()/isDeprecated() fail closed (return false) on a code-less factory
// ---------------------------------------------------------------------------------------------

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {AscntGovernance, IProtocolFeeBpsSubscriber} from "../../src/AscntGovernance.sol";
import {AscntBaseHook} from "../../src/AscntBaseHook.sol";

/// @dev Local valid-timelock stub (duck-types `getMinDelay() > 0`). Local copy so this phase
///      never edits shared scaffolding; name is phase-prefixed to avoid repo-wide collisions.
contract P2Timelock {
    function getMinDelay() external pure returns (uint256) {
        return 1 days;
    }
}

/// @dev Local factory stub pointing back at the installing governance, so the one-shot
///      `setHookFactory` bootstrap passes the wired-governance duck-type; tests prank it.
contract P2Factory {
    address public governance;

    constructor(address gov_) {
        governance = gov_;
    }
}

/// @dev Minimal concrete AscntBaseHook used to probe the protocolFeeBps cache surface.
///      Single beforeInitialize permission bit so it deploys at a cheap flag address.
///      `unsafeSetCache` deliberately simulates a desynced/stale cache (what a hook skipped by
///      `SubscriberPushFailed` looks like) so the sync-recovery path can be exercised.
contract P2BareHook is AscntBaseHook {
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

    /// @dev TEST-ONLY stale-cache injector (subclass write; no such setter exists on the src
    ///      contract itself — the src surface is push + sync only).
    function unsafeSetCache(uint16 bps) external {
        protocolFeeBps = bps;
    }
}

/// @dev Armable revert subscriber: passes the strict registration push, then can be armed to
///      revert so `setProtocolFeeBps` emits SubscriberPushFailed for it (the "skipped" hook).
contract P2RevertingSubscriber is IProtocolFeeBpsSubscriber {
    bool public armed;
    uint16 public lastBps;

    function arm(bool a) external {
        armed = a;
    }

    function onProtocolFeeBpsUpdated(uint16 bps) external {
        if (armed) revert("p2 push boom");
        lastBps = bps;
    }
}

/// @dev GOV-19 probe: during its 50k-gas push callback (msg.sender == governance) it attempts
///      every reachable governance mutator and records how many unexpectedly succeeded.
contract P2ReentrantSubscriber is IProtocolFeeBpsSubscriber {
    AscntGovernance public immutable gov;
    address public peer;
    bool public armed;
    uint16 public lastBps;
    uint256 public reentrantAttempts;
    uint256 public reentrantSuccesses;

    constructor(AscntGovernance _gov) {
        gov = _gov;
    }

    function arm(address _peer) external {
        armed = true;
        peer = _peer;
    }

    function onProtocolFeeBpsUpdated(uint16 bps) external {
        lastBps = bps;
        if (!armed) return;
        // Every state-mutating governance entry point reachable with msg.sender == this hook.
        // All must revert (NotHookFactory / NotTimelock / NotPauserOrOwner / Ownable).
        reentrantAttempts++;
        try gov.registerSubscriber(peer) {
            reentrantSuccesses++;
        } catch {}
        reentrantAttempts++;
        try gov.removeSubscriber(address(this)) {
            reentrantSuccesses++;
        } catch {}
        reentrantAttempts++;
        try gov.setProtocolFeeBps(1) {
            reentrantSuccesses++;
        } catch {}
        reentrantAttempts++;
        try gov.setTreasury(address(1)) {
            reentrantSuccesses++;
        } catch {}
        reentrantAttempts++;
        try gov.setAddLiquidityPaused(true) {
            reentrantSuccesses++;
        } catch {}
    }
}

contract Phase2GovAuthorityMatrixTest is Test {
    AscntGovernance internal gov;

    address internal constant OWNER = address(0xA11CE);
    address internal constant PAUSER = address(0xBA5E2);
    address internal constant POOL_DEPLOYER = address(0xD0D02);
    address internal constant TREASURY = address(0x7EA52);
    address internal constant STRANGER = address(0xE0A2);
    /// @dev Stub contract wired as the canonical hookFactory; tests prank its address.
    address internal FACTORY;

    address internal TIMELOCK;
    address internal TIMELOCK2;

    /// @dev Dummy manager: `BaseHook`'s constructor only stores the pointer; none of the cache
    ///      tests below ever call into it.
    IPoolManager internal constant DUMMY_MANAGER = IPoolManager(address(0xD00D2));

    P2BareHook internal bareHook;

    function setUp() public {
        TIMELOCK = address(new P2Timelock());
        TIMELOCK2 = address(new P2Timelock());
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, TIMELOCK, PAUSER, POOL_DEPLOYER))
        );
        FACTORY = address(new P2Factory(address(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(FACTORY);

        // Concrete base hook at a permission-bit address; subscribe it like the factory would.
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | (0x21 << 32)));
        deployCodeTo("Phase2_GovAuthorityMatrix.t.sol:P2BareHook", abi.encode(DUMMY_MANAGER, gov), hookAddr);
        bareHook = P2BareHook(hookAddr);
        vm.prank(FACTORY);
        gov.registerSubscriber(hookAddr);
    }

    // ------ GOV-1: full (setter x caller) slow-lane matrix ------

    /// @dev All 6 timelock-gated mutators, encoded once so the matrix cannot silently drop one.
    function _slowLaneCalls() internal view returns (bytes[] memory calls, string[] memory names) {
        calls = new bytes[](7);
        names = new string[](7);
        calls[0] = abi.encodeCall(gov.setTreasury, (TREASURY));
        names[0] = "setTreasury";
        calls[1] = abi.encodeCall(gov.setProtocolFeeBps, (100));
        names[1] = "setProtocolFeeBps";
        calls[2] = abi.encodeCall(gov.setPoolDeployer, (address(0xD0D03)));
        names[2] = "setPoolDeployer";
        calls[3] = abi.encodeCall(gov.proposeTimelock, (TIMELOCK2));
        names[3] = "proposeTimelock";
        calls[4] = abi.encodeCall(gov.transferOwnership, (address(0xA11CF)));
        names[4] = "transferOwnership";
        calls[5] = abi.encodeCall(gov.removeSubscriber, (address(bareHook)));
        names[5] = "removeSubscriber";
        calls[6] = abi.encodeCall(gov.cancelTimelockTransfer, ());
        names[6] = "cancelTimelockTransfer";
    }

    /// GOV-1: every slow-lane mutator reverts NotTimelock for EVERY caller that is not the
    /// timelock — including the current owner, the poolDeployer and the pauser.
    function test_gov1_slowLaneMatrix_revertsForEveryNonTimelockCaller() public {
        (bytes[] memory calls, string[] memory names) = _slowLaneCalls();
        address[4] memory callers = [OWNER, POOL_DEPLOYER, PAUSER, STRANGER];

        for (uint256 i = 0; i < calls.length; i++) {
            for (uint256 j = 0; j < callers.length; j++) {
                vm.prank(callers[j]);
                (bool ok, bytes memory ret) = address(gov).call(calls[i]);
                assertFalse(ok, string.concat(names[i], " must revert for non-timelock caller"));
                assertEq(
                    bytes4(ret),
                    AscntGovernance.NotTimelock.selector,
                    string.concat(names[i], " must revert with NotTimelock")
                );
            }
        }

        // No state drifted while probing.
        assertEq(gov.treasury(), address(0));
        assertEq(gov.protocolFeeBps(), 0);
        assertEq(gov.poolDeployer(), POOL_DEPLOYER);
        assertEq(gov.timelock(), TIMELOCK);
        assertEq(gov.owner(), OWNER);
        assertTrue(gov.isSubscribedHook(address(bareHook)));
    }

    /// GOV-1 (positive side): the timelock address CAN execute each of the 6 setters. Ordered so
    /// cross-field guards (fee needs treasury) and the timelock rotation (must go last) hold.
    function test_gov1_slowLaneMatrix_timelockSucceedsForEverySetter() public {
        address newOwner = address(0xA11CF);
        address newDeployer = address(0xD0D03);

        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        assertEq(gov.treasury(), TREASURY);

        gov.setProtocolFeeBps(100);
        assertEq(gov.protocolFeeBps(), 100);

        gov.setPoolDeployer(newDeployer);
        assertEq(gov.poolDeployer(), newDeployer);

        gov.removeSubscriber(address(bareHook));
        assertFalse(gov.isSubscribedHook(address(bareHook)));

        gov.transferOwnership(newOwner);
        assertEq(gov.owner(), newOwner);

        gov.proposeTimelock(TIMELOCK2);
        assertEq(gov.pendingTimelock(), TIMELOCK2, "nominated, not yet rotated");
        assertEq(gov.timelock(), TIMELOCK, "incumbent holds the role until acceptance");
        vm.stopPrank();

        vm.prank(TIMELOCK2);
        gov.acceptTimelock();
        assertEq(gov.timelock(), TIMELOCK2);

        // Post-rotation liveness: old timelock is dead, new timelock is live.
        vm.prank(TIMELOCK);
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.setTreasury(address(0xDEAD1));

        vm.prank(TIMELOCK2);
        gov.setTreasury(address(0xDEAD1));
        assertEq(gov.treasury(), address(0xDEAD1));
    }

    // ------ GOV-2: transferOwnership override (onlyTimelock, not OZ onlyOwner) ------

    /// GOV-2: the OZ default would let the owner hand off ownership instantly; the override must
    /// reject the owner itself and accept only the timelock.
    function test_gov2_transferOwnership_ownerReverts_timelockSucceeds() public {
        vm.prank(OWNER);
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.transferOwnership(STRANGER);
        assertEq(gov.owner(), OWNER, "owner-initiated transfer must not take effect");

        vm.prank(TIMELOCK);
        gov.transferOwnership(STRANGER);
        assertEq(gov.owner(), STRANGER, "timelock-initiated transfer must take effect");
    }

    // ------ GOV-15: poolDeployer has zero governance write authority ------

    /// GOV-15: from the (leakable, semi-trusted) poolDeployer hot key, EVERY governance mutator
    /// reverts — slow lane, fast lane, pause flag, bootstrap and the subscriber registry.
    function test_gov15_poolDeployer_hasZeroGovernanceWriteAuthority() public {
        (bytes[] memory slowCalls, string[] memory names) = _slowLaneCalls();

        // Slow lane: NotTimelock for all 6.
        for (uint256 i = 0; i < slowCalls.length; i++) {
            vm.prank(POOL_DEPLOYER);
            (bool ok, bytes memory ret) = address(gov).call(slowCalls[i]);
            assertFalse(ok, string.concat(names[i], " must revert for poolDeployer"));
            assertEq(bytes4(ret), AscntGovernance.NotTimelock.selector);
        }

        // Fast lane (owner-only): setPauser + setHookFactory hit the Ownable modifier first.
        vm.prank(POOL_DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, POOL_DEPLOYER));
        gov.setPauser(POOL_DEPLOYER);

        vm.prank(POOL_DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, POOL_DEPLOYER));
        gov.setHookFactory(POOL_DEPLOYER);

        // Instant lane: not pauser, not owner.
        vm.prank(POOL_DEPLOYER);
        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        gov.setAddLiquidityPaused(true);

        // Registry: not the hookFactory.
        vm.prank(POOL_DEPLOYER);
        vm.expectRevert(AscntGovernance.NotHookFactory.selector);
        gov.registerSubscriber(POOL_DEPLOYER);

        // Renounce path is disabled for everyone anyway.
        vm.prank(POOL_DEPLOYER);
        vm.expectRevert(AscntGovernance.RenounceDisabled.selector);
        gov.renounceOwnership();

        // Nothing moved.
        assertEq(gov.owner(), OWNER);
        assertEq(gov.pauser(), PAUSER);
        assertEq(gov.hookFactory(), FACTORY);
        assertFalse(gov.addLiquidityPaused());
        assertFalse(gov.isSubscribedHook(POOL_DEPLOYER));
    }

    // ------ GOV-20: setPauser is owner-only ------

    /// GOV-20: a leaked pauser key must not be able to make itself permanent (self-rotation),
    /// and the timelock cannot rotate the pauser either — only the owner fast lane can.
    function test_gov20_setPauser_ownerOnly_pauserCannotSelfRotate() public {
        address[3] memory rejected = [PAUSER, TIMELOCK, STRANGER];
        for (uint256 i = 0; i < rejected.length; i++) {
            address caller = rejected[i];
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
            gov.setPauser(caller);
        }
        assertEq(gov.pauser(), PAUSER, "pauser slot untouched by unauthorized rotations");

        // Owner rotates, then revokes (setPauser(0)) — the no-delay leaked-key response.
        vm.prank(OWNER);
        gov.setPauser(STRANGER);
        assertEq(gov.pauser(), STRANGER);

        vm.prank(OWNER);
        gov.setPauser(address(0));
        assertEq(gov.pauser(), address(0));

        // The revoked pauser has lost the pause switch; the owner keeps it.
        vm.prank(STRANGER);
        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        gov.setAddLiquidityPaused(true);

        vm.prank(OWNER);
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.addLiquidityPaused());
    }

    // ------ GOV-21: setAddLiquidityPaused gate ------

    /// GOV-21: only owner or the pauser slot can toggle the pause; a rotated-away pauser loses
    /// the switch immediately.
    function test_gov21_setAddLiquidityPaused_onlyOwnerOrPauser() public {
        vm.prank(STRANGER);
        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        gov.setAddLiquidityPaused(true);

        // Timelock is NOT an authorizer for the pause flag.
        vm.prank(TIMELOCK);
        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        gov.setAddLiquidityPaused(true);

        vm.prank(PAUSER);
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.addLiquidityPaused());

        vm.prank(OWNER);
        gov.setAddLiquidityPaused(false);
        assertFalse(gov.addLiquidityPaused());

        // Zero the pauser: only the owner can toggle afterwards.
        vm.prank(OWNER);
        gov.setPauser(address(0));
        vm.prank(PAUSER);
        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        gov.setAddLiquidityPaused(true);
        vm.prank(OWNER);
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.addLiquidityPaused());
    }

    /// GOV-21 (edge, documents current behaviour): when pauser == address(0), a caller with
    /// msg.sender == address(0) satisfies `msg.sender == pauser` and CAN toggle the pause. On
    /// Ethereum a transaction from address(0) is not producible (no key hashes to it;
    /// ecrecover-failure senders are rejected at tx validation), so this is unreachable in
    /// production — but the guard is technically permissive, and a `msg.sender != address(0)`
    /// hardening (or a non-zero pauser convention) would close it.
    function test_gov21_zeroPauser_addressZeroCaller_isAdmitted_documented() public {
        vm.prank(OWNER);
        gov.setPauser(address(0));
        assertEq(gov.pauser(), address(0));

        // Current behavior: address(0) passes the `msg.sender == pauser` branch.
        vm.prank(address(0));
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.addLiquidityPaused(), "documented quirk: address(0) admitted as pauser when the slot is zeroed");
    }

    // ------ GOV-22: structural fee-cap relation (static assertion) ------

    /// GOV-22: the protocol slice is structurally bounded strictly below the whole dynamic fee.
    /// Guards against a future bump of MAX_PROTOCOL_FEE_BPS to >= 10000 breaking the split.
    function test_gov22_protocolFeeCap_structurallyBelowWholeFee() public view {
        uint256 capBps = gov.MAX_PROTOCOL_FEE_BPS();
        assertLt(capBps, 10_000, "protocol-fee cap must be < 100% of the dynamic fee");
        // Product relation at the extreme dynamic fee: hookFee(maxFee) < maxFee.
        uint256 maxHookFee = (uint256(LPFeeLibrary.MAX_LP_FEE) * capBps) / 10_000;
        assertLt(maxHookFee, LPFeeLibrary.MAX_LP_FEE, "protocol slice of max fee must be < max fee");
    }

    // ------ GOV-14: cache mutation surface + cap ------

    /// GOV-14: the hook's protocolFeeBps cache can only move via (a) the governance push
    /// (NotGovernance for anyone else) or (b) permissionless sync, which copies the governance
    /// value (itself capped at 2000). No attacker-supplied value can enter the cache.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: dev.fuzz.runs = 256
    function testFuzz_gov14_cacheOnlyMutableByPushOrSync_neverAboveCap(
        uint16 pushBpsSeed,
        uint16 attackerBps,
        address attacker
    ) public {
        vm.assume(attacker != address(gov));
        uint16 pushBps = uint16(bound(pushBpsSeed, 0, 2000));

        // (a) direct write attempt: NotGovernance for any non-governance caller (incl. owner).
        vm.prank(attacker);
        vm.expectRevert(AscntBaseHook.NotGovernance.selector);
        bareHook.onProtocolFeeBpsUpdated(attackerBps);

        vm.prank(OWNER);
        vm.expectRevert(AscntBaseHook.NotGovernance.selector);
        bareHook.onProtocolFeeBpsUpdated(attackerBps);

        // (b) legitimate push: cache tracks governance, and is capped because governance is.
        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        gov.setProtocolFeeBps(pushBps);
        vm.stopPrank();
        assertEq(bareHook.protocolFeeBps(), pushBps, "push updates the cache");
        assertLe(bareHook.protocolFeeBps(), 2000, "cache never above cap after push");

        // Governance itself rejects above-cap values, so no push source > 2000 exists.
        uint16 tooHigh = uint16(bound(attackerBps, 2001, type(uint16).max));
        vm.prank(TIMELOCK);
        vm.expectRevert(AscntGovernance.ProtocolFeeTooHigh.selector);
        gov.setProtocolFeeBps(tooHigh);

        // (c) sync from an attacker converges the cache ONLY to the authoritative value —
        // it takes no argument, so hammering it cannot inject anything.
        bareHook.unsafeSetCache(65_000); // simulate a desynced/stale cache (test-only injector)
        vm.prank(attacker);
        bareHook.syncProtocolFee();
        assertEq(bareHook.protocolFeeBps(), pushBps, "sync copies governance value only");
        assertLe(bareHook.protocolFeeBps(), 2000, "cache never above cap after sync");
    }

    // ------ GOV-13: skipped subscriber recovers via sync ------

    /// GOV-13: force a SubscriberPushFailed for a griefing subscriber, prove the well-behaved
    /// hook still got the push, then show a stale hook cache converges to the authoritative
    /// value when ANYONE (an attacker address here) calls the argument-less syncProtocolFee.
    function test_gov13_skippedSubscriber_recoversViaPermissionlessSync() public {
        P2RevertingSubscriber bad = new P2RevertingSubscriber();
        vm.prank(FACTORY);
        gov.registerSubscriber(address(bad)); // registration push succeeds (not armed yet)
        bad.arm(true);

        vm.prank(TIMELOCK);
        gov.setTreasury(TREASURY);

        // Push: the armed subscriber is skipped (event), the honest hook is updated.
        vm.expectEmit(true, false, false, true, address(gov));
        emit AscntGovernance.SubscriberPushFailed(address(bad), 700);
        vm.prank(TIMELOCK);
        gov.setProtocolFeeBps(700);

        assertEq(gov.protocolFeeBps(), 700, "fee committed despite the griefing subscriber");
        assertEq(bareHook.protocolFeeBps(), 700, "honest hook cache pushed");
        assertEq(bad.lastBps(), 0, "griefer skipped");

        // Recovery: simulate the stale state a skipped AscntBaseHook would be in, then let an
        // arbitrary address pull. sync takes no argument — it can only copy governance's value.
        bareHook.unsafeSetCache(3); // stale (test-only injector; src has no setter)
        vm.prank(STRANGER);
        bareHook.syncProtocolFee();
        assertEq(bareHook.protocolFeeBps(), 700, "sync converged to governance.protocolFeeBps()");
    }

    // ------ GOV-19: reentrant subscriber is inert ------

    /// GOV-19: a subscriber re-entering governance during its onProtocolFeeBpsUpdated push
    /// cannot reach any state-mutating function (all gated to timelock/owner/factory, none of
    /// which equals the calling hook), so the broadcast loop's registry cannot shift mid-iteration.
    function test_gov19_reentrantSubscriber_cannotMutateGovernanceDuringPush() public {
        P2ReentrantSubscriber evil = new P2ReentrantSubscriber(gov);
        vm.prank(FACTORY);
        gov.registerSubscriber(address(evil)); // registration push: not armed yet
        evil.arm(address(0xFEE7));

        uint256 lenBefore = gov.subscribedHooksLength();
        address treasuryBefore = gov.treasury();

        vm.prank(TIMELOCK);
        gov.setProtocolFeeBps(0); // bps=0 needs no treasury; still walks the push loop

        // The push reached the reentrant subscriber and it made its attempts...
        assertEq(evil.lastBps(), 0);
        assertEq(evil.reentrantAttempts(), 5, "all five mutators were attempted");
        // ...and every single reentrant mutator call failed.
        assertEq(evil.reentrantSuccesses(), 0, "no reentrant governance mutation succeeded");

        // Registry and state are untouched by the reentry.
        assertEq(gov.subscribedHooksLength(), lenBefore, "registry length unchanged");
        assertTrue(gov.isSubscribedHook(address(evil)));
        assertTrue(gov.isSubscribedHook(address(bareHook)));
        assertFalse(gov.isSubscribedHook(address(0xFEE7)), "reentrant register did not land");
        assertEq(gov.treasury(), treasuryBefore, "treasury unchanged");
        assertFalse(gov.addLiquidityPaused(), "pause flag unchanged");
        assertEq(gov.protocolFeeBps(), 0, "committed value is the outer call's value");
    }

    // ------ GOV-23: self-attest views fail closed on a code-less factory ------

    /// GOV-23 regression test: both views carry a `factory.code.length == 0` guard.
    ///
    /// GOV-23 requires: "if the factory address has no code or its view reverts, both return
    /// false via the defensive try/catch rather than propagating a revert."
    ///
    /// The CODE-LESS branch was broken. `AscntBaseHook.isVerified()/isDeprecated()` wrap the
    /// factory staticcall in try/catch, but since Solidity 0.8.10 the compiler omits the
    /// extcodesize guard when return data is expected: a staticcall to a code-less account
    /// SUCCEEDS with empty returndata, and the ABI decode of `returns (bool)` then fails in the
    /// CALLER'S frame — an exception the Solidity docs explicitly state is NOT caught by the
    /// try/catch. Without the guard, both views REVERT instead of returning false, DoS-ing any
    /// integrator that reads the attestation of a hook whose deployer was an EOA / has no code.
    ///
    /// Contrast: `AscntGovernance._requireValidTimelock` defends this exact pattern correctly
    /// with an explicit `tl.code.length == 0` check BEFORE its try/catch. The same one-line
    /// guard (`if (factory.code.length == 0) return false;`) fixes the views.
    /// (The existing base-hook tests only cover the "factory has code but wrong ABI" branch,
    /// where the inner call genuinely reverts and IS caught.)
    function test_gov23_selfAttestViews_failClosed_onCodelessFactory() public {
        address eoaDeployer = address(0xEEA23);
        assertEq(eoaDeployer.code.length, 0, "precondition: deployer is code-less");

        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | (0x23 << 32)));
        vm.prank(eoaDeployer); // constructor msg.sender becomes the hook's `factory` immutable
        deployCodeTo("Phase2_GovAuthorityMatrix.t.sol:P2BareHook", abi.encode(DUMMY_MANAGER, gov), hookAddr);
        P2BareHook orphan = P2BareHook(hookAddr);

        assertEq(orphan.factory(), eoaDeployer, "factory immutable is the code-less deployer");
        // GOV-23 spec: both views must return false — and NOT revert (the assertions only
        // execute if the calls returned normally).
        assertFalse(orphan.isVerified(), "isVerified must fail closed on a code-less factory");
        assertFalse(orphan.isDeprecated(), "isDeprecated must fail closed on a code-less factory");
    }
}
