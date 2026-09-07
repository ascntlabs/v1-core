// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {AscntBaseHook} from "../../src/AscntBaseHook.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";

/// @dev Minimal concrete hook used only by this test suite.
contract TimelockTestHook is AscntBaseHook {
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
}

/// @dev End-to-end exercise of the two-lane authority model under the centralised
///      `AscntGovernance`:
///        - SAFE is the governance owner directly (fast lane: pauser-instant, factory ops)
///        - TIMELOCK gates governance slow-lane functions (treasury, fees, pauser rotation,
///          ownership rotation, timelock rotation)
///        - SAFE is the proposer on the timelock; the same multi-sig threshold gates both lanes
///        - SAFE is also the pauser, bypassing the timelock for emergency pause only
contract TimelockTest is Test, ArtifactDeployers {
    AscntGovernance internal gov;
    AscntBaseHook internal hook;
    TimelockController internal timelock;

    address internal constant SAFE = address(0x5A1F);
    address internal constant OTHER = address(0xB0B);
    address internal constant TREASURY = address(0xDEAF);
    address internal constant NEW_OWNER = address(0xC0FFEE);

    uint256 internal constant DELAY = 1 days;

    function setUp() public {
        deployFreshManager();

        // 1. Timelock.
        address[] memory proposers = new address[](1);
        proposers[0] = SAFE;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        // 2. AscntGovernance with SAFE as owner, timelock as slow-lane gate, SAFE as pauser.
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(SAFE, address(timelock), SAFE, address(0)))
        );

        // 3. Hook pointed at governance.
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        deployCodeTo("Timelock.t.sol:TimelockTestHook", abi.encode(manager, gov), hookAddr);
        hook = AscntBaseHook(hookAddr);
    }

    // ------ fast lane: SAFE acts directly, no delay ------

    function test_fastLane_safeIsOwner() public view {
        assertEq(gov.owner(), SAFE);
        assertEq(gov.timelock(), address(timelock));
        assertEq(gov.pauser(), SAFE);
    }

    function test_fastLane_pauseUnpauseInstant() public {
        vm.prank(SAFE);
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.addLiquidityPaused(), "pauser flipped flag with no delay");

        vm.prank(SAFE);
        gov.setAddLiquidityPaused(false);
        assertFalse(gov.addLiquidityPaused());
    }

    // ------ slow lane: SAFE must schedule through timelock ------

    function test_slowLane_setTreasury_directReverts() public {
        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        vm.prank(SAFE);
        gov.setTreasury(TREASURY);
    }

    function test_slowLane_setTreasury_viaTimelock() public {
        bytes memory data = abi.encodeWithSelector(AscntGovernance.setTreasury.selector, TREASURY);
        bytes32 salt = keccak256("setTreasury-1");

        vm.prank(SAFE);
        timelock.schedule(address(gov), 0, data, bytes32(0), salt, DELAY);

        vm.expectRevert();
        timelock.execute(address(gov), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(gov), 0, data, bytes32(0), salt);
        assertEq(gov.treasury(), TREASURY);
    }

    function test_slowLane_transferOwnership_viaTimelock() public {
        bytes memory data = abi.encodeWithSelector(AscntGovernance.transferOwnership.selector, NEW_OWNER);
        bytes32 salt = keccak256("transferOwnership-to-newOwner");

        vm.prank(SAFE);
        timelock.schedule(address(gov), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(gov), 0, data, bytes32(0), salt);

        assertEq(gov.owner(), NEW_OWNER, "single-step transfer landed via timelock");
    }

    /// @dev Rotation is two-step: the nomination goes through the incumbent's delay, then the
    ///      nominee must originate the acceptance itself. Exercised here against a real
    ///      TimelockController so the schedule/execute path is covered end to end.
    function test_slowLane_proposeTimelock_viaTimelock() public {
        address newTimelock = address(new MockTimelock());
        bytes memory data = abi.encodeWithSelector(AscntGovernance.proposeTimelock.selector, newTimelock);
        bytes32 salt = keccak256("proposeTimelock-rotate");

        vm.prank(SAFE);
        timelock.schedule(address(gov), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(gov), 0, data, bytes32(0), salt);

        // Nomination landed; the role has NOT moved yet.
        assertEq(gov.pendingTimelock(), newTimelock, "nominated");
        assertEq(gov.timelock(), address(timelock), "incumbent still holds the role");

        // The nominee originates the acceptance — the step an undriveable candidate cannot take.
        vm.prank(newTimelock);
        gov.acceptTimelock();
        assertEq(gov.timelock(), newTimelock, "rotation completed");
        assertEq(gov.pendingTimelock(), address(0), "pending cleared");
    }

    // ------ access control on the timelock itself ------

    function test_nonProposerCannotSchedule() public {
        bytes memory data = abi.encodeWithSelector(AscntGovernance.setTreasury.selector, TREASURY);
        bytes32 salt = keccak256("evil");

        vm.expectRevert();
        vm.prank(OTHER);
        timelock.schedule(address(gov), 0, data, bytes32(0), salt, DELAY);
    }

    function test_safeCanCancelQueuedOperation() public {
        bytes memory data = abi.encodeWithSelector(AscntGovernance.setTreasury.selector, TREASURY);
        bytes32 salt = keccak256("setTreasury-cancel-test");

        vm.prank(SAFE);
        timelock.schedule(address(gov), 0, data, bytes32(0), salt, DELAY);

        bytes32 opId = timelock.hashOperation(address(gov), 0, data, bytes32(0), salt);
        vm.prank(SAFE);
        timelock.cancel(opId);

        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert();
        timelock.execute(address(gov), 0, data, bytes32(0), salt);

        assertEq(gov.treasury(), address(0));
    }

    function test_minDelayEnforced() public {
        bytes memory data = abi.encodeWithSelector(AscntGovernance.setTreasury.selector, TREASURY);
        bytes32 salt = keccak256("min-delay-test");

        vm.expectRevert();
        vm.prank(SAFE);
        timelock.schedule(address(gov), 0, data, bytes32(0), salt, DELAY - 1);
    }

    // ------ pauser bypass: still no delay under new model ------
    // (owner-direct pause with no timelock is covered by test_fastLane_pauseUnpauseInstant)

    function test_pauser_canBeRotatedByOwnerDirectly() public {
        vm.prank(SAFE);
        gov.setPauser(address(0));
        assertEq(gov.pauser(), address(0));

        // SAFE (owner) can still pause directly.
        vm.prank(SAFE);
        gov.setAddLiquidityPaused(true);
        assertTrue(gov.addLiquidityPaused());

        // But OTHER (no role) cannot.
        vm.expectRevert(AscntGovernance.NotPauserOrOwner.selector);
        vm.prank(OTHER);
        gov.setAddLiquidityPaused(false);
    }
}
