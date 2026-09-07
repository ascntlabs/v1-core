// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {AscntBaseHook} from "../../src/AscntBaseHook.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {HookFactory} from "../../src/HookFactory.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";

/// @dev Minimal concrete hook used only by this test suite. Declares the single
///      `beforeInitialize` permission bit and exposes the base's internal helpers
///      so they can be exercised directly.
contract TestHook is AscntBaseHook {
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

    function requireOwnerOrPoolDeployerExt(address sender) external view {
        _requireOwnerOrPoolDeployer(sender);
    }
}

/// @dev Tests the slim base hook: governance pointer, role-check helpers that
///      route through governance, factory self-attest views.
///      Governance-setter coverage lives in `test/governance/AscntGovernance.t.sol`; cross-hook
///      propagation coverage lives in `test/governance/Propagation.t.sol`. Per-swap protocol-fee
///      take is integration-tested in `test/feature/ProtocolFee.t.sol` since it requires a live
///      PoolManager swap to exercise the transient handoff + take helper end-to-end.
contract AscntBaseHookTest is Test, ArtifactDeployers {
    using PoolIdLibrary for PoolKey;

    AscntGovernance internal gov;
    TestHook internal hook;

    // OWNER doubles as the timelock in this fixture; it must be a contract that passes
    // AscntGovernance's timelock duck-type check, so it is a MockTimelock set in setUp.
    address internal OWNER;
    address internal constant OTHER = address(0xB0B);
    address internal constant TREASURY = address(0xDEAF);
    address internal constant POOL_DEPLOYER = address(0xD0D0);

    PoolKey internal dummyKey;
    PoolId internal dummyId;

    function setUp() public {
        deployFreshManager();
        OWNER = address(new MockTimelock());
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, OWNER, address(0), address(0)))
        );
        hook = _deployTestHook(gov);

        dummyKey = PoolKey({
            currency0: Currency.wrap(address(0xC0)),
            currency1: Currency.wrap(address(0xC1)),
            fee: 0,
            tickSpacing: 1,
            hooks: hook
        });
        dummyId = dummyKey.toId();
    }

    function _deployTestHook(AscntGovernance _gov) internal returns (TestHook h) {
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        deployCodeTo("AscntBaseHook.t.sol:TestHook", abi.encode(manager, _gov), hookAddr);
        h = TestHook(hookAddr);
    }

    // ------ constructor ------

    function test_construction_rejectsZeroGovernance() public {
        address addr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        vm.expectRevert(AscntBaseHook.InvalidGovernance.selector);
        deployCodeTo("AscntBaseHook.t.sol:TestHook", abi.encode(manager, AscntGovernance(address(0))), addr);
    }

    function test_construction_storesImmutables() public view {
        assertEq(address(hook.governance()), address(gov));
        assertEq(hook.factory(), address(this));
    }

    // ------ owner-or-poolDeployer gate (reads through governance) ------

    function test_requireOwnerOrPoolDeployer_passesForOwner() public view {
        hook.requireOwnerOrPoolDeployerExt(OWNER);
    }

    function test_requireOwnerOrPoolDeployer_passesForPoolDeployer() public {
        vm.prank(OWNER);
        gov.setPoolDeployer(POOL_DEPLOYER);
        hook.requireOwnerOrPoolDeployerExt(POOL_DEPLOYER);
    }

    function test_requireOwnerOrPoolDeployer_revertsForNeither() public {
        vm.prank(OWNER);
        gov.setPoolDeployer(POOL_DEPLOYER);
        vm.expectRevert(AscntBaseHook.NotOwnerOrPoolDeployer.selector);
        hook.requireOwnerOrPoolDeployerExt(OTHER);
    }

    function test_requireOwnerOrPoolDeployer_zeroSlotMeansOwnerOnly() public {
        // poolDeployer defaults to 0 in this fixture; OTHER must not pass.
        vm.expectRevert(AscntBaseHook.NotOwnerOrPoolDeployer.selector);
        hook.requireOwnerOrPoolDeployerExt(OTHER);
    }

    // ------ cached protocolFeeBps + push callback ------

    function test_cachedProtocolFeeBps_seededAtConstruction() public {
        // Setting governance bps BEFORE deploying a new hook seeds the new hook's cache.
        vm.startPrank(OWNER);
        gov.setTreasury(TREASURY);
        gov.setProtocolFeeBps(500);
        vm.stopPrank();

        // Existing `hook` was deployed BEFORE bps was set — its cache snapshot is 0.
        assertEq(hook.protocolFeeBps(), 0, "pre-existing hook cache is stale (no push received)");

        // A freshly-deployed hook reads the current bps in its constructor.
        TestHook fresh = _deployTestHookAt(gov, address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | 0x10000)));
        assertEq(fresh.protocolFeeBps(), 500, "fresh hook seeds cache from governance");
    }

    function test_onProtocolFeeBpsUpdated_updatesCache_onlyFromGovernance() public {
        assertEq(hook.protocolFeeBps(), 0);

        // Pretend governance is pushing — direct call from gov address must succeed.
        vm.prank(address(gov));
        hook.onProtocolFeeBpsUpdated(750);
        assertEq(hook.protocolFeeBps(), 750);

        // From anyone else: reverts.
        vm.expectRevert(AscntBaseHook.NotGovernance.selector);
        vm.prank(OTHER);
        hook.onProtocolFeeBpsUpdated(1);
    }

    function _deployTestHookAt(AscntGovernance _gov, address hookAddr) internal returns (TestHook h) {
        deployCodeTo("AscntBaseHook.t.sol:TestHook", abi.encode(manager, _gov), hookAddr);
        h = TestHook(hookAddr);
    }

    // ------ factory self-attest views ------

    /// @dev This test contract IS the fixture hook's `factory` (deployCodeTo runs the hook
    ///      constructor with this contract as msg.sender). Attesting `true` from both records
    ///      makes the fixture a live spoof — a factory with code that claims the hook is
    ///      verified and deprecated but is not `governance.hookFactory()` — which the
    ///      canonicality guard must ignore.
    function isVerifiedHook(address) external pure returns (bool) {
        return true;
    }

    function isDeprecatedHook(address) external pure returns (bool) {
        return true;
    }

    function test_isVerified_falseWhenFactoryNotCanonical() public {
        // Guard fires with hookFactory unset (factory != address(0))...
        assertFalse(hook.isVerified(), "spoofing factory ignored while hookFactory unset");

        // ...and equally once a real canonical factory is wired: this hook wasn't deployed by it.
        HookFactory canonical = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(address(canonical));
        assertFalse(hook.isVerified(), "spoofing non-canonical factory ignored");
    }

    function test_isDeprecated_falseWhenFactoryNotCanonical() public {
        assertFalse(hook.isDeprecated(), "spoofing factory ignored while hookFactory unset");

        HookFactory canonical = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(gov)));
        vm.prank(OWNER);
        gov.setHookFactory(address(canonical));
        assertFalse(hook.isDeprecated(), "spoofing non-canonical factory ignored");
    }

    /// @dev True-return coverage: deploy a hook with a real `HookFactory` as its deployer, then
    ///      verify it reads verified through BOTH the guarded self-view (factory matches
    ///      `governance.hookFactory()`) and the root path (`governance.isCanonicalHook`).
    ///      Uses a separate hook address (different permission-bit pattern) so the existing
    ///      fixture isn't disturbed.
    function test_isVerified_trueWhenFactoryReportsVerified() public {
        HookFactory factory = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(gov)));
        // Wire the factory into governance so registerSubscriber works (called inside deployHook).
        vm.prank(OWNER);
        gov.setHookFactory(address(factory));

        (address expected, bytes32 salt) = HookMiner.find(
            address(factory), Hooks.BEFORE_INITIALIZE_FLAG, type(TestHook).creationCode, abi.encode(manager, gov)
        );

        bytes memory initCode = abi.encodePacked(type(TestHook).creationCode, abi.encode(manager, gov));

        vm.prank(OWNER);
        address deployed = factory.deployHook(initCode, salt, expected);
        TestHook freshHook = TestHook(deployed);

        // After factory deployment, both paths agree: the guarded self-view passes its
        // canonicality check, and the governance root path finds the hook in the registry.
        assertTrue(freshHook.isVerified(), "real factory marks hook as verified");
        assertTrue(gov.isCanonicalHook(deployed), "root path confirms provenance");

        // Deprecation toggles correctly through both paths.
        assertFalse(freshHook.isDeprecated(), "not deprecated initially");
        assertFalse(gov.isCanonicalHookDeprecated(deployed), "root path: not deprecated");
        vm.prank(OWNER);
        factory.setHookDeprecated(deployed, true);
        assertTrue(freshHook.isDeprecated(), "deprecated after factory flag");
        assertTrue(gov.isCanonicalHookDeprecated(deployed), "root path sees deprecation");
        assertTrue(gov.isCanonicalHook(deployed), "deprecation does not revoke provenance");
    }
}
