// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {HookFactory} from "../../src/HookFactory.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";

/// @dev Minimal contract used as the deployment target. Constructor arg is included to verify
///      that differing constructor args produce differing addresses. Implements the
///      `IProtocolFeeBpsSubscriber` callback as a no-op so `governance.registerSubscriber`
///      (called from `HookFactory.deployHook`) can complete.
contract DummyHook {
    address public immutable governance;
    uint256 public immutable value;

    constructor(address _governance, uint256 _value) {
        governance = _governance;
        value = _value;
    }
    function onProtocolFeeBpsUpdated(uint16) external {}
}

contract HookFactoryTest is Test {
    AscntGovernance internal gov;
    HookFactory internal factory;

    address internal constant OWNER = address(0xA1);
    // Timelock must be a contract that passes AscntGovernance's duck-type check; set in setUp.
    address internal TIMELOCK;
    address internal constant OTHER = address(0xB0B);

    function setUp() public {
        TIMELOCK = address(new MockTimelock());
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, TIMELOCK, address(0), address(0)))
        );
        factory = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(gov)));
        // Wire the factory into governance so `deployHook` → `governance.registerSubscriber` works.
        vm.prank(OWNER);
        gov.setHookFactory(address(factory));
    }

    function _initCode(uint256 value) internal view returns (bytes memory) {
        return abi.encodePacked(type(DummyHook).creationCode, abi.encode(address(gov), value));
    }

    // ------ construction ------

    function test_construction_storesGovernance() public view {
        assertEq(address(factory.governance()), address(gov));
    }

    function test_construction_ownerRoutesThroughGovernance() public view {
        assertEq(factory.owner(), OWNER);
    }

    function test_construction_revertsOnZeroGovernance() public {
        vm.expectRevert(HookFactory.InvalidGovernance.selector);
        new HookFactory(AscntGovernance(address(0)));
    }

    // ------ deploy happy path ------

    function test_deployHook_happyPath() public {
        bytes memory initCode = _initCode(42);
        bytes32 salt = bytes32(uint256(1));
        address expected = factory.computeAddress(salt, keccak256(initCode));

        // Two events fire in this order: SubscriberRegistered (from governance) then HookDeployed.
        vm.expectEmit(true, false, false, false, address(gov));
        emit AscntGovernance.SubscriberRegistered(expected);
        vm.expectEmit(true, true, false, true, address(factory));
        emit HookFactory.HookDeployed(expected, salt);

        vm.prank(OWNER);
        address hook = factory.deployHook(initCode, salt, expected);

        assertEq(hook, expected);
        assertTrue(factory.isVerifiedHook(hook));
        assertEq(DummyHook(hook).value(), 42);
    }

    /// @dev Tier 1C — verify auto-registration: after deployHook, the hook is in the governance
    ///      subscriber registry.
    function test_deployHook_registersWithGovernance() public {
        bytes memory initCode = _initCode(1);
        bytes32 salt = bytes32(uint256(0xAA));
        address expected = factory.computeAddress(salt, keccak256(initCode));

        assertFalse(gov.isSubscribedHook(expected), "not subscribed pre-deploy");
        uint256 lenBefore = gov.subscribedHooksLength();

        vm.prank(OWNER);
        factory.deployHook(initCode, salt, expected);

        assertTrue(gov.isSubscribedHook(expected), "subscribed post-deploy");
        assertEq(gov.subscribedHooksLength(), lenBefore + 1, "subscriber array grew by one");
    }

    /// @dev Tier 1C — verify the initial bps push lands in the hook's local cache at deploy
    ///      time. Uses a custom hook that records every push it receives.
    function test_deployHook_pushesInitialBpsToNewSubscriber() public {
        // Pre-set governance bps. setProtocolFeeBps requires treasury != 0, so set treasury too.
        vm.prank(TIMELOCK);
        gov.setTreasury(address(0xBEEF));
        vm.prank(TIMELOCK);
        gov.setProtocolFeeBps(750);

        // Deploy a hook that records the most recent push.
        bytes memory initCode = abi.encodePacked(type(BpsRecorderHook).creationCode, abi.encode(address(gov)));
        bytes32 salt = bytes32(uint256(0xBB));
        address expected = factory.computeAddress(salt, keccak256(initCode));

        vm.prank(OWNER);
        factory.deployHook(initCode, salt, expected);

        // The hook should have received the 750 bps on registerSubscriber's initial sync.
        assertEq(BpsRecorderHook(expected).lastBps(), 750, "initial push reached the new hook");
    }

    // ------ governance-pointer consistency ------

    /// @dev A hook whose constructor wires it to a different governance than the factory's must be
    ///      rejected at deploy, so it can't be verified/registered under the wrong governance.
    function test_deployHook_revertsOnGovernanceMismatch() public {
        address wrongGov = address(0xBADBAD);
        bytes memory initCode = abi.encodePacked(type(DummyHook).creationCode, abi.encode(wrongGov, uint256(7)));
        bytes32 salt = bytes32(uint256(0xC0FFEE));
        address expected = factory.computeAddress(salt, keccak256(initCode));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(HookFactory.GovernanceMismatch.selector, wrongGov, address(gov)));
        factory.deployHook(initCode, salt, expected);
    }

    // ------ wrong expected address ------

    function test_deployHook_revertsOnAddressMismatch() public {
        bytes memory initCode = _initCode(42);
        bytes32 salt = bytes32(uint256(1));
        address correct = factory.computeAddress(salt, keccak256(initCode));
        address wrong = address(uint160(correct) + 1);

        vm.expectRevert(abi.encodeWithSelector(HookFactory.AddressMismatch.selector, wrong, correct));
        vm.prank(OWNER);
        factory.deployHook(initCode, salt, wrong);

        assertFalse(factory.isVerifiedHook(correct));
    }

    // ------ owner gating (routed through governance) ------

    function test_deployHook_revertsIfNotOwner() public {
        bytes memory initCode = _initCode(42);
        bytes32 salt = bytes32(uint256(1));
        address expected = factory.computeAddress(salt, keccak256(initCode));

        vm.expectRevert(HookFactory.NotOwner.selector);
        vm.prank(OTHER);
        factory.deployHook(initCode, salt, expected);
    }

    // ------ differing constructor args produce differing addresses ------

    function test_computeAddress_isSaltAndInitCodeSensitive() public view {
        bytes memory ic1 = _initCode(42);
        bytes memory ic2 = _initCode(43);
        bytes32 salt = bytes32(uint256(1));

        address a1 = factory.computeAddress(salt, keccak256(ic1));
        address a2 = factory.computeAddress(salt, keccak256(ic2));
        assertTrue(a1 != a2, "different init code must produce different address");

        bytes32 saltB = bytes32(uint256(2));
        address a3 = factory.computeAddress(saltB, keccak256(ic1));
        assertTrue(a1 != a3, "different salt must produce different address");
    }

    // ------ double deploy (same salt + initCode) reverts ------

    function test_deployHook_secondDeployAtSameAddressReverts() public {
        bytes memory initCode = _initCode(42);
        bytes32 salt = bytes32(uint256(1));
        address expected = factory.computeAddress(salt, keccak256(initCode));

        vm.prank(OWNER);
        factory.deployHook(initCode, salt, expected);

        vm.prank(OWNER);
        vm.expectRevert();
        factory.deployHook(initCode, salt, expected);
    }

    // ------ deprecation flag ------

    function test_setHookDeprecated_byOwner() public {
        bytes memory initCode = _initCode(42);
        bytes32 salt = bytes32(uint256(1));
        address expected = factory.computeAddress(salt, keccak256(initCode));

        vm.prank(OWNER);
        factory.deployHook(initCode, salt, expected);

        assertFalse(factory.isDeprecatedHook(expected));

        vm.expectEmit(true, false, false, true, address(factory));
        emit HookFactory.HookDeprecationChanged(expected, true);

        vm.prank(OWNER);
        factory.setHookDeprecated(expected, true);
        assertTrue(factory.isDeprecatedHook(expected));

        vm.prank(OWNER);
        factory.setHookDeprecated(expected, false);
        assertFalse(factory.isDeprecatedHook(expected));
    }

    function test_setHookDeprecated_revertsIfNotVerified() public {
        address fake = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(HookFactory.HookNotVerified.selector, fake));
        vm.prank(OWNER);
        factory.setHookDeprecated(fake, true);
    }

    function test_setHookDeprecated_revertsIfNotOwner() public {
        bytes memory initCode = _initCode(42);
        bytes32 salt = bytes32(uint256(1));
        address expected = factory.computeAddress(salt, keccak256(initCode));

        vm.prank(OWNER);
        factory.deployHook(initCode, salt, expected);

        vm.expectRevert(HookFactory.NotOwner.selector);
        vm.prank(OTHER);
        factory.setHookDeprecated(expected, true);
    }

    // ------ ownership rotation propagation: factory follows governance ------

    /// @dev After `governance.transferOwnership(OTHER)`, the factory's owner-gated functions
    ///      accept OTHER and reject OWNER — no separate rotation on the factory needed.
    function test_governanceOwnershipRotation_propagatesToFactory() public {
        bytes memory initCode = _initCode(42);
        bytes32 salt = bytes32(uint256(1));
        address expected = factory.computeAddress(salt, keccak256(initCode));
        vm.prank(OWNER);
        factory.deployHook(initCode, salt, expected);

        vm.prank(TIMELOCK);
        gov.transferOwnership(OTHER);
        assertEq(factory.owner(), OTHER, "factory.owner() reads through governance");

        // New owner can deprecate.
        vm.prank(OTHER);
        factory.setHookDeprecated(expected, true);
        assertTrue(factory.isDeprecatedHook(expected));

        // Old owner can no longer call setHookDeprecated.
        vm.expectRevert(HookFactory.NotOwner.selector);
        vm.prank(OWNER);
        factory.setHookDeprecated(expected, false);
    }
}

/// @dev Subscriber that records the most recent bps it was pushed. Lets us assert the
///      initial-sync push fires at deploy time.
contract BpsRecorderHook {
    address public immutable governance;
    uint16 public lastBps;

    constructor(address _governance) {
        governance = _governance;
    }

    function onProtocolFeeBpsUpdated(uint16 bps) external {
        lastBps = bps;
    }
}
