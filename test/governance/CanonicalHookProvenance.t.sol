// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {HookFactory} from "../../src/HookFactory.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";

/// @dev Minimal deployment target for the real factory (mirrors `DummyHook` in HookFactory.t.sol):
///      wires the governance pointer `deployHook` asserts on and accepts the registration push.
contract GenuineHook {
    address public immutable governance;

    constructor(address _governance) {
        governance = _governance;
    }
    function onProtocolFeeBpsUpdated(uint16) external {}
}

/// @dev Fake factory: attests ANY hook as verified and deprecated, and points its `governance()`
///      wherever the attacker likes — pointing AT a trusted contract is free.
contract FakeFactory {
    address public governance;

    constructor(address g) {
        governance = g;
    }

    function isVerifiedHook(address) external pure returns (bool) {
        return true;
    }

    function isDeprecatedHook(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Fake governance: mimics the real read surface and roots the leaf-out chain at a fake
///      factory, so `hook.governance().hookFactory().isVerifiedHook(hook)` reads true.
contract FakeGovernance {
    address public hookFactory;

    function setHookFactory(address f) external {
        hookFactory = f;
    }
}

/// @dev A hook a fake ecosystem "deployed": its leaf-out pointers are internally consistent and
///      it self-reports as verified. Only the root path exposes it.
contract FakeEcosystemHook {
    address public immutable factory;
    address public immutable governance;

    constructor(address _factory, address _governance) {
        factory = _factory;
        governance = _governance;
    }

    function isVerified() external pure returns (bool) {
        return true;
    }

    function isDeprecated() external pure returns (bool) {
        return false;
    }
}

/// @dev Pure impostor: no factory/governance story at all, just hardcoded answers.
contract ImpostorHook {
    function isVerified() external pure returns (bool) {
        return true;
    }

    function isDeprecated() external pure returns (bool) {
        return false;
    }
}

/// @dev Root-anchored provenance. `AscntGovernance.isCanonicalHook` /
///      `isCanonicalHookDeprecated` resolve the canonical factory FROM the known governance
///      address, so no hook-supplied pointer is ever trusted. Every fake-ecosystem shape must
///      read false through the root path even while its own self-attestations read true.
///      Hook-side guard coverage (the defense-in-depth half) lives in test/base/AscntBaseHook.t.sol.
contract CanonicalHookProvenanceTest is Test {
    AscntGovernance internal gov;
    HookFactory internal factory;

    address internal constant OWNER = address(0xA1);
    // Timelock must be a contract that passes AscntGovernance's duck-type check; set in setUp.
    address internal TIMELOCK;

    function setUp() public {
        TIMELOCK = address(new MockTimelock());
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, TIMELOCK, address(0), address(0)))
        );
        factory = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(address(factory));
    }

    function _deployGenuine(bytes32 salt) internal returns (address hook) {
        bytes memory initCode = abi.encodePacked(type(GenuineHook).creationCode, abi.encode(address(gov)));
        address expected = factory.computeAddress(salt, keccak256(initCode));
        vm.prank(OWNER);
        hook = factory.deployHook(initCode, salt, expected);
    }

    // ------ genuine hooks ------

    function test_isCanonicalHook_trueForFactoryDeployedHook() public {
        address hook = _deployGenuine(bytes32(uint256(1)));
        assertTrue(gov.isCanonicalHook(hook), "factory-deployed hook is canonical");
        assertFalse(gov.isCanonicalHookDeprecated(hook), "fresh hook not deprecated");
    }

    function test_isCanonicalHookDeprecated_flipsWithFactoryFlag() public {
        address hook = _deployGenuine(bytes32(uint256(2)));

        vm.prank(OWNER);
        factory.setHookDeprecated(hook, true);
        assertTrue(gov.isCanonicalHookDeprecated(hook), "deprecation visible through root path");
        // Deprecation is advisory lifecycle state; provenance survives it.
        assertTrue(gov.isCanonicalHook(hook), "deprecated hook remains canonical");

        vm.prank(OWNER);
        factory.setHookDeprecated(hook, false);
        assertFalse(gov.isCanonicalHookDeprecated(hook), "un-deprecation round-trips");
    }

    // ------ the forgery matrix: all three shapes must read false at the root ------

    function test_isCanonicalHook_falseForFakeFactoryRealGovernance() public {
        FakeFactory fake = new FakeFactory(address(gov));
        FakeEcosystemHook fakeHook = new FakeEcosystemHook(address(fake), address(gov));

        // The fake ecosystem attests the hook everywhere the attacker controls...
        assertTrue(FakeFactory(fakeHook.factory()).isVerifiedHook(address(fakeHook)));
        assertTrue(fakeHook.isVerified());

        // ...but the root path never consults any of it.
        assertFalse(gov.isCanonicalHook(address(fakeHook)), "fake factory + real gov: not canonical");
        assertFalse(gov.isCanonicalHookDeprecated(address(fakeHook)));
    }

    function test_isCanonicalHook_falseForFakeFactoryFakeGovernance() public {
        FakeGovernance fakeGov = new FakeGovernance();
        FakeFactory fake = new FakeFactory(address(fakeGov));
        fakeGov.setHookFactory(address(fake));
        FakeEcosystemHook fakeHook = new FakeEcosystemHook(address(fake), address(fakeGov));

        // Leaf-out resolution is internally consistent all the way down: querier → hook →
        // "governance" → "factory" → attests true. Forgeable at every hop — this is the shape
        // the hook-side guard alone cannot catch.
        address leafFactory = FakeGovernance(fakeHook.governance()).hookFactory();
        assertEq(leafFactory, fakeHook.factory(), "leaf chain is self-consistent");
        assertTrue(FakeFactory(leafFactory).isVerifiedHook(address(fakeHook)));

        // Root-out resolution from the KNOWN governance address is unforgeable.
        assertFalse(gov.isCanonicalHook(address(fakeHook)), "fake factory + fake gov: not canonical");
        assertFalse(gov.isCanonicalHookDeprecated(address(fakeHook)));
    }

    function test_isCanonicalHook_falseForHardcodedImpostor() public {
        ImpostorHook impostor = new ImpostorHook();
        assertTrue(impostor.isVerified(), "impostor self-reports verified");

        assertFalse(gov.isCanonicalHook(address(impostor)), "impostor: not canonical");
        assertFalse(gov.isCanonicalHookDeprecated(address(impostor)));
    }

    function testFuzz_isCanonicalHook_falseForAnyNonFactoryDeployedAddress(address a) public {
        address genuine = _deployGenuine(bytes32(uint256(3)));
        vm.assume(a != genuine);
        assertFalse(gov.isCanonicalHook(a));
        assertFalse(gov.isCanonicalHookDeprecated(a));
    }

    // ------ pre-bootstrap ------

    function test_canonicalViews_falseNotRevert_whenHookFactoryUnset() public {
        AscntGovernance freshGov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, TIMELOCK, address(0), address(0)))
        );
        assertEq(freshGov.hookFactory(), address(0), "precondition: unwired");

        assertFalse(freshGov.isCanonicalHook(address(0xBEEF)));
        assertFalse(freshGov.isCanonicalHookDeprecated(address(0xBEEF)));
    }
}
