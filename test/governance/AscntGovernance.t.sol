// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AscntGovernance, IProtocolFeeBpsSubscriber} from "../../src/AscntGovernance.sol";
import {
    MockTimelock,
    MockZeroDelayTimelock,
    MockShortDelayTimelock,
    MockMutableDelayTimelock
} from "../mocks/MockTimelock.sol";

/// @dev Minimal subscriber stub. Governance's `registerSubscriber` pushes an initial sync to
///      the registered address; without code at that address, foundry's "call to non-contract
///      address" guard escapes the try/catch and fails the test.
contract StubSubscriber is IProtocolFeeBpsSubscriber {
    uint16 public lastBps;

    function onProtocolFeeBpsUpdated(uint16 bps) external {
        lastBps = bps;
    }
}

/// @dev Minimal factory stand-in: `setHookFactory` requires the candidate to have code and to
///      point back at the governance installing it via `governance()`.
contract StubHookFactory {
    address public governance;

    constructor(address gov_) {
        governance = gov_;
    }
}

/// @dev Direct coverage of `AscntGovernance` storage + setters. Tests use distinct
///      owner/timelock addresses to exercise the two-lane authority cleanly. Cross-hook
///      propagation is covered in `test/governance/Propagation.t.sol`.
contract AscntGovernanceTest is Test {
    using PoolIdLibrary for PoolKey;

    AscntGovernance internal gov;

    address internal constant OWNER = address(0x0F);
    // Timelock must be a contract that passes AscntGovernance's duck-type check; set in setUp.
    address internal TIMELOCK;
    address internal constant OTHER = address(0xB0B);
    address internal constant TREASURY = address(0xDEAF);
    address internal constant PAUSER = address(0xBA5E);
    address internal constant POOL_DEPLOYER = address(0xD0D0);
    address internal constant HOOK = address(0x40);

    PoolKey internal dummyKey;
    PoolId internal dummyId;

    function setUp() public {
        TIMELOCK = address(new MockTimelock());
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, TIMELOCK, address(0), address(0)))
        );
        dummyKey = PoolKey({
            currency0: Currency.wrap(address(0xC0)),
            currency1: Currency.wrap(address(0xC1)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(HOOK)
        });
        dummyId = dummyKey.toId();
    }

    // ------ constructor ------

    function test_construction_rejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AscntGovernance(address(0), TIMELOCK, address(0), address(0));
    }

    function test_construction_rejectsZeroTimelock() public {
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        new AscntGovernance(OWNER, address(0), address(0), address(0));
    }

    function test_construction_rejectsEoaTimelock() public {
        // (fix 1) An EOA has no code — not a valid timelock.
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        new AscntGovernance(OWNER, address(0xEEEE), address(0), address(0));
    }

    function test_construction_rejectsNonTimelockContract() public {
        // (fix 2) A contract without getMinDelay() fails the duck-type check.
        address notTimelock = address(new StubSubscriber());
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        new AscntGovernance(OWNER, notTimelock, address(0), address(0));
    }

    function test_construction_rejectsZeroDelayTimelock() public {
        // (fix 2) A timelock-shaped contract with a zero delay provides no protection.
        address zeroDelay = address(new MockZeroDelayTimelock());
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        new AscntGovernance(OWNER, zeroDelay, address(0), address(0));
    }

    function test_construction_rejectsShortDelayTimelock() public {
        // A delay one second under MIN_TIMELOCK_DELAY (24h) is still rejected — boundary pin.
        address shortDelay = address(new MockShortDelayTimelock());
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        new AscntGovernance(OWNER, shortDelay, address(0), address(0));
    }

    function test_construction_storesSlots() public view {
        assertEq(gov.owner(), OWNER);
        assertEq(gov.timelock(), TIMELOCK);
        assertEq(gov.pauser(), address(0));
        assertEq(gov.poolDeployer(), address(0));
        assertEq(gov.treasury(), address(0));
        assertEq(gov.protocolFeeBps(), 0);
        assertFalse(gov.addLiquidityPaused());
    }

    // ------ setTreasury ------

    function test_setTreasury_byTimelock() public {
        vm.prank(TIMELOCK);
        gov.setTreasury(TREASURY);
        assertEq(gov.treasury(), TREASURY);
    }

    function test_setTreasury_revertsForNonTimelock() public {
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(OWNER);
        gov.setTreasury(TREASURY);
    }

    function test_setTreasury_zeroAllowedWhenBpsZero() public {
        vm.prank(TIMELOCK);
        gov.setTreasury(address(0));
        assertEq(gov.treasury(), address(0));
    }

    function test_setTreasury_revertsZeroIfBpsNonZero() public {
        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        gov.setProtocolFeeBps(500);
        vm.expectRevert(AscntGovernance.TreasuryRequired.selector);
        gov.setTreasury(address(0));
        vm.stopPrank();
    }

    // ------ setProtocolFeeBps ------

    function test_setProtocolFeeBps_basic() public {
        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        gov.setProtocolFeeBps(500);
        vm.stopPrank();
        assertEq(gov.protocolFeeBps(), 500);
    }

    function test_setProtocolFeeBps_revertsAboveCap() public {
        uint16 cap = gov.MAX_PROTOCOL_FEE_BPS();
        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        vm.expectRevert(AscntGovernance.ProtocolFeeTooHigh.selector);
        gov.setProtocolFeeBps(cap + 1);
        vm.stopPrank();
    }

    function test_setProtocolFeeBps_revertsWhenTreasuryZero() public {
        vm.expectRevert(AscntGovernance.TreasuryRequired.selector);
        vm.prank(TIMELOCK);
        gov.setProtocolFeeBps(500);
    }

    function test_setProtocolFeeBps_revertsForNonTimelock() public {
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(OWNER);
        gov.setProtocolFeeBps(500);
    }

    // ------ pauser slot ------

    function test_setPauser_byOwner() public {
        vm.prank(OWNER);
        gov.setPauser(PAUSER);
        assertEq(gov.pauser(), PAUSER);
    }

    function test_setPauser_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", TIMELOCK));
        vm.prank(TIMELOCK);
        gov.setPauser(PAUSER);
    }

    function test_setPauser_emitsEvent() public {
        vm.expectEmit(true, false, false, false, address(gov));
        emit AscntGovernance.PauserUpdated(PAUSER);
        vm.prank(OWNER);
        gov.setPauser(PAUSER);
    }

    function test_setAddLiquidityPaused_byOwner() public {
        vm.prank(OWNER);
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.addLiquidityPaused());
    }

    function test_setAddLiquidityPaused_byPauser() public {
        vm.prank(OWNER);
        gov.setPauser(PAUSER);

        vm.prank(PAUSER);
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.addLiquidityPaused());
    }

    function test_setAddLiquidityPaused_revertsForNeitherOwnerNorPauser() public {
        vm.prank(OWNER);
        gov.setPauser(PAUSER);

        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        vm.prank(OTHER);
        gov.setAddLiquidityPaused(true);
    }

    // ------ ownership ------

    function test_ownershipTransfer_singleStep_byTimelock() public {
        vm.prank(TIMELOCK);
        gov.transferOwnership(OTHER);
        assertEq(gov.owner(), OTHER, "owner updated immediately (single-step)");
    }

    function test_ownershipTransfer_revertsForNonTimelock() public {
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(OWNER);
        gov.transferOwnership(OTHER);
    }

    function test_ownershipTransfer_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        vm.prank(TIMELOCK);
        gov.transferOwnership(address(0));
    }

    function test_renounceOwnership_disabled() public {
        // Reverts for every caller — even the timelock (the highest-authority lane).
        vm.expectRevert(AscntGovernance.RenounceDisabled.selector);
        vm.prank(TIMELOCK);
        gov.renounceOwnership();
    }

    // ------ poolDeployer slot ------

    function test_setPoolDeployer_byTimelock() public {
        vm.prank(TIMELOCK);
        gov.setPoolDeployer(POOL_DEPLOYER);
        assertEq(gov.poolDeployer(), POOL_DEPLOYER);
    }

    function test_setPoolDeployer_revertsForNonTimelock() public {
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(OWNER);
        gov.setPoolDeployer(POOL_DEPLOYER);
    }

    function test_setPoolDeployer_emitsEvent() public {
        vm.expectEmit(true, false, false, false, address(gov));
        emit AscntGovernance.PoolDeployerUpdated(POOL_DEPLOYER);
        vm.prank(TIMELOCK);
        gov.setPoolDeployer(POOL_DEPLOYER);
    }

    // ------ timelock slot ------

    /// @dev Helper: run a full two-step rotation to `newTimelock`.
    function _rotateTimelock(address from, address newTimelock) internal {
        vm.prank(from);
        gov.proposeTimelock(newTimelock);
        vm.prank(newTimelock);
        gov.acceptTimelock();
    }

    function test_proposeTimelock_byTimelock_doesNotRotateYet() public {
        address newTimelock = address(new MockTimelock());
        vm.prank(TIMELOCK);
        gov.proposeTimelock(newTimelock);

        // Nomination recorded, but the incumbent still holds the role.
        assertEq(gov.pendingTimelock(), newTimelock, "nomination recorded");
        assertEq(gov.timelock(), TIMELOCK, "incumbent unchanged until acceptance");
        assertEq(
            uint256(gov.pendingTimelockExpiry()),
            block.timestamp + gov.TIMELOCK_ACCEPT_WINDOW(),
            "expiry = now + window"
        );
    }

    function test_acceptTimelock_completesRotation() public {
        address newTimelock = address(new MockTimelock());
        _rotateTimelock(TIMELOCK, newTimelock);

        assertEq(gov.timelock(), newTimelock, "role transferred");
        assertEq(gov.pendingTimelock(), address(0), "pending cleared");
        assertEq(uint256(gov.pendingTimelockExpiry()), 0, "expiry cleared");
    }

    function test_proposeTimelock_revertsForNonTimelock() public {
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(OTHER);
        gov.proposeTimelock(OTHER);
    }

    /// @dev The owner is deliberately NOT able to nominate: transferOwnership is onlyTimelock, so
    ///      the timelock is the recovery path for a compromised owner. Letting the owner nominate
    ///      would let a compromised owner capture the slow lane and close that path.
    function test_proposeTimelock_revertsForOwner() public {
        address newTimelock = address(new MockTimelock());
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(OWNER);
        gov.proposeTimelock(newTimelock);
    }

    function test_proposeTimelock_rejectsZero() public {
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        vm.prank(TIMELOCK);
        gov.proposeTimelock(address(0));
    }

    function test_proposeTimelock_rejectsEoa() public {
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        vm.prank(TIMELOCK);
        gov.proposeTimelock(address(0xEEEE));
    }

    function test_proposeTimelock_rejectsZeroDelayTimelock() public {
        address zeroDelay = address(new MockZeroDelayTimelock());
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        vm.prank(TIMELOCK);
        gov.proposeTimelock(zeroDelay);
    }

    function test_proposeTimelock_rejectsShortDelayTimelock() public {
        // Under MIN_TIMELOCK_DELAY (24h) is rejected — boundary pin.
        address shortDelay = address(new MockShortDelayTimelock());
        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        vm.prank(TIMELOCK);
        gov.proposeTimelock(shortDelay);
    }

    function test_acceptTimelock_revertsForNonNominee() public {
        address newTimelock = address(new MockTimelock());
        vm.prank(TIMELOCK);
        gov.proposeTimelock(newTimelock);

        vm.expectRevert(AscntGovernance.NotPendingTimelock.selector);
        vm.prank(OTHER);
        gov.acceptTimelock();
    }

    function test_acceptTimelock_revertsWithNoNomination() public {
        vm.expectRevert(AscntGovernance.NotPendingTimelock.selector);
        vm.prank(OTHER);
        gov.acceptTimelock();
    }

    /// @dev The reason this change exists: a nominee that passes validation but can never
    ///      originate a call must not be able to strand the slow lane. Here it simply never
    ///      accepts, and the incumbent retains full authority indefinitely.
    function test_undriveableNominee_cannotStrandSlowLane() public {
        address undriveable = address(new MockTimelock()); // valid shape, nobody drives it
        vm.prank(TIMELOCK);
        gov.proposeTimelock(undriveable);

        // Nomination outstanding, never accepted — incumbent keeps working.
        assertEq(gov.timelock(), TIMELOCK, "incumbent retains the role");

        vm.prank(TIMELOCK);
        gov.setTreasury(TREASURY);
        assertEq(gov.treasury(), TREASURY, "slow lane still live");

        // And can still rotate to a nominee that does accept.
        address good = address(new MockTimelock());
        _rotateTimelock(TIMELOCK, good);
        assertEq(gov.timelock(), good, "recovered by nominating a driveable timelock");
    }

    function test_acceptTimelock_revertsAfterExpiry() public {
        address newTimelock = address(new MockTimelock());
        vm.prank(TIMELOCK);
        gov.proposeTimelock(newTimelock);

        vm.warp(block.timestamp + gov.TIMELOCK_ACCEPT_WINDOW() + 1);

        vm.expectRevert(AscntGovernance.TimelockProposalExpired.selector);
        vm.prank(newTimelock);
        gov.acceptTimelock();
        assertEq(gov.timelock(), TIMELOCK, "incumbent unchanged");
    }

    function test_acceptTimelock_succeedsOnFinalWindowSecond() public {
        address newTimelock = address(new MockTimelock());
        vm.prank(TIMELOCK);
        gov.proposeTimelock(newTimelock);

        // Boundary: expiry itself is still acceptable (strict `>` in the guard).
        vm.warp(gov.pendingTimelockExpiry());
        vm.prank(newTimelock);
        gov.acceptTimelock();
        assertEq(gov.timelock(), newTimelock);
    }

    function test_secondProposal_displacesFirst() public {
        address first = address(new MockTimelock());
        address second = address(new MockTimelock());

        vm.prank(TIMELOCK);
        gov.proposeTimelock(first);
        vm.prank(TIMELOCK);
        gov.proposeTimelock(second);

        assertEq(gov.pendingTimelock(), second, "latest nomination wins");

        vm.expectRevert(AscntGovernance.NotPendingTimelock.selector);
        vm.prank(first);
        gov.acceptTimelock();

        vm.prank(second);
        gov.acceptTimelock();
        assertEq(gov.timelock(), second);
    }

    function test_cancelTimelockTransfer_clearsNomination() public {
        address newTimelock = address(new MockTimelock());
        vm.prank(TIMELOCK);
        gov.proposeTimelock(newTimelock);

        vm.prank(TIMELOCK);
        gov.cancelTimelockTransfer();
        assertEq(gov.pendingTimelock(), address(0), "pending cleared");

        vm.expectRevert(AscntGovernance.NotPendingTimelock.selector);
        vm.prank(newTimelock);
        gov.acceptTimelock();
    }

    function test_cancelTimelockTransfer_revertsForNonTimelock() public {
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(OTHER);
        gov.cancelTimelockTransfer();
    }

    /// @dev Re-validation on acceptance catches an honest drift in the nominee's delay between
    ///      nomination and acceptance. (It does not stop a dishonest nominee lowering its delay
    ///      AFTER accepting — nothing on-chain can.)
    function test_acceptTimelock_revalidatesDelayAtAcceptance() public {
        MockMutableDelayTimelock nominee = new MockMutableDelayTimelock(24 hours);
        vm.prank(TIMELOCK);
        gov.proposeTimelock(address(nominee));

        nominee.setMinDelay(1 hours); // drifts below the floor before accepting

        vm.expectRevert(AscntGovernance.InvalidTimelock.selector);
        vm.prank(address(nominee));
        gov.acceptTimelock();
        assertEq(gov.timelock(), TIMELOCK, "incumbent unchanged");
    }

    function test_timelock_oldRevertsAfterRotation_newCanCall() public {
        address newTimelock = address(new MockTimelock());
        _rotateTimelock(TIMELOCK, newTimelock);

        vm.prank(newTimelock);
        gov.setTreasury(TREASURY);
        assertEq(gov.treasury(), TREASURY);

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(TIMELOCK);
        gov.setTreasury(address(0xCAFE));
    }

    // ------ poolDeployer isolation: no slow-lane access ------

    function test_poolDeployer_cannotCallSlowLaneSetters() public {
        vm.prank(TIMELOCK);
        gov.setPoolDeployer(POOL_DEPLOYER);

        vm.startPrank(POOL_DEPLOYER);

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.setTreasury(TREASURY);

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.setProtocolFeeBps(100);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", POOL_DEPLOYER));
        gov.setPauser(POOL_DEPLOYER);

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.setPoolDeployer(POOL_DEPLOYER);

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.proposeTimelock(POOL_DEPLOYER);

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.cancelTimelockTransfer();

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        gov.transferOwnership(POOL_DEPLOYER);

        vm.stopPrank();
    }

    // ------ hookFactory bootstrap ------

    function test_setHookFactory_byOwner_initialSet() public {
        address f = address(new StubHookFactory(address(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(f);
        assertEq(gov.hookFactory(), f);
    }

    function test_setHookFactory_revertsAfterFirstSet() public {
        address f = address(new StubHookFactory(address(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(f);

        // Already-set check fires before candidate validation, so a bare address suffices here.
        vm.expectRevert(AscntGovernance.HookFactoryAlreadySet.selector);
        vm.prank(OWNER);
        gov.setHookFactory(address(0xFAC8));
    }

    function test_setHookFactory_rejectsZero() public {
        vm.expectRevert(AscntGovernance.InvalidHookFactory.selector);
        vm.prank(OWNER);
        gov.setHookFactory(address(0));
    }

    function test_setHookFactory_rejectsEoa() public {
        // An EOA has no code — not a valid factory.
        vm.expectRevert(AscntGovernance.InvalidHookFactory.selector);
        vm.prank(OWNER);
        gov.setHookFactory(address(0xFAC7));
    }

    function test_setHookFactory_rejectsNonFactoryContract() public {
        // A contract without governance() fails the duck-type check.
        address notFactory = address(new StubSubscriber());
        vm.expectRevert(AscntGovernance.InvalidHookFactory.selector);
        vm.prank(OWNER);
        gov.setHookFactory(notFactory);
    }

    function test_setHookFactory_rejectsForeignGovernance() public {
        // A real factory wired to a DIFFERENT governance is rejected.
        address foreign = address(new StubHookFactory(OTHER));
        vm.expectRevert(AscntGovernance.InvalidHookFactory.selector);
        vm.prank(OWNER);
        gov.setHookFactory(foreign);
    }

    function test_setHookFactory_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        vm.prank(OTHER);
        gov.setHookFactory(address(0xFAC7));
    }

    // ------ subscriber registry ------

    function test_registerSubscriber_onlyFromHookFactory() public {
        address f = address(new StubHookFactory(address(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(f);

        address stub = address(new StubSubscriber());

        // Non-factory caller (even owner) cannot register.
        vm.expectRevert(AscntGovernance.NotHookFactory.selector);
        vm.prank(OWNER);
        gov.registerSubscriber(stub);

        // Factory call succeeds.
        vm.prank(f);
        gov.registerSubscriber(stub);
        assertTrue(gov.isSubscribedHook(stub));
        assertEq(gov.subscribedHooksLength(), 1);
    }

    function test_registerSubscriber_isIdempotent() public {
        address f = address(new StubHookFactory(address(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(f);

        address stub = address(new StubSubscriber());
        vm.startPrank(f);
        gov.registerSubscriber(stub);
        gov.registerSubscriber(stub);
        vm.stopPrank();
        assertEq(gov.subscribedHooksLength(), 1, "second register is a no-op");
    }

    function test_removeSubscriber_byTimelock() public {
        address f = address(new StubHookFactory(address(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(f);

        address stub = address(new StubSubscriber());
        vm.prank(f);
        gov.registerSubscriber(stub);

        vm.prank(TIMELOCK);
        gov.removeSubscriber(stub);
        assertFalse(gov.isSubscribedHook(stub));
        assertEq(gov.subscribedHooksLength(), 0);
    }

    function test_removeSubscriber_revertsForNonTimelock() public {
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(OWNER);
        gov.removeSubscriber(HOOK);
    }
}
