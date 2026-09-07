// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtifactDeployers} from "../utils/ArtifactDeployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AscntBaseHook} from "../../src/AscntBaseHook.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {HookFactory} from "../../src/HookFactory.sol";
import {MockTimelock} from "../mocks/MockTimelock.sol";

/// @dev Minimal concrete hook for propagation testing.
contract PropHook is AscntBaseHook {
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

/// @dev Two hook instances deployed under one `AscntGovernance`. Verifies the `protocolFeeBps`
///      push reaches every subscribed hook in one tx. Shared-governance reads (treasury, pauser,
///      addLiquidityPaused, owner) are immutable-pointer identities covered as setter unit-tests
///      in `test/governance/AscntGovernance.t.sol`.
contract PropagationTest is Test, ArtifactDeployers {
    using PoolIdLibrary for PoolKey;

    AscntGovernance internal gov;
    HookFactory internal factory;
    AscntBaseHook internal hookA;
    AscntBaseHook internal hookB;

    address internal constant OWNER = address(0x0F);
    // Timelock must be a contract that passes AscntGovernance's duck-type check; set in setUp.
    address internal TIMELOCK;
    address internal constant PAUSER = address(0xBA5E);
    address internal constant POOL_DEPLOYER = address(0xD0D0);
    address internal constant TREASURY = address(0xDEAF);

    function setUp() public {
        deployFreshManager();
        TIMELOCK = address(new MockTimelock());
        gov = AscntGovernance(
            deployCode("src/AscntGovernance.sol:AscntGovernance", abi.encode(OWNER, TIMELOCK, PAUSER, POOL_DEPLOYER))
        );
        factory = HookFactory(deployCode("src/HookFactory.sol:HookFactory", abi.encode(gov)));

        // Link the factory so `registerSubscriber` is callable from it.
        vm.prank(OWNER);
        gov.setHookFactory(address(factory));

        // Two distinct hook addresses sharing the same governance. We deploy them via
        // `deployCodeTo` (raw CREATE) and manually register them with governance via the
        // factory path — bypassing the real `deployHook` flow which has its own CREATE2 +
        // permission-bit-mining requirements not relevant to this test's focus.
        address addrA = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | (1 << 32)));
        address addrB = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | (2 << 32)));
        deployCodeTo("Propagation.t.sol:PropHook", abi.encode(manager, gov), addrA);
        deployCodeTo("Propagation.t.sol:PropHook", abi.encode(manager, gov), addrB);
        hookA = AscntBaseHook(addrA);
        hookB = AscntBaseHook(addrB);

        // Manually register both hooks as subscribers (the factory path would do this for us
        // in production; here we simulate it directly).
        vm.startPrank(address(factory));
        gov.registerSubscriber(addrA);
        gov.registerSubscriber(addrB);
        vm.stopPrank();
    }

    // ------ one setProtocolFeeBps call → push reaches both hooks atomically ------

    function test_setProtocolFeeBps_propagatesToAllHooks() public {
        // Pre-push, both hooks' caches are zero (initial governance bps was 0).
        assertEq(hookA.protocolFeeBps(), 0, "hookA cache starts at 0");
        assertEq(hookB.protocolFeeBps(), 0, "hookB cache starts at 0");

        vm.startPrank(TIMELOCK);
        gov.setTreasury(TREASURY);
        gov.setProtocolFeeBps(500);
        vm.stopPrank();

        // Both hooks' caches updated by the push from `setProtocolFeeBps`.
        assertEq(hookA.protocolFeeBps(), 500, "hookA cache updated by push");
        assertEq(hookB.protocolFeeBps(), 500, "hookB cache updated by push");
        // Governance's own value also reflects it.
        assertEq(gov.protocolFeeBps(), 500);
    }

    // ------ subscribedHooks array enumeration after mid-array removal ------

    /// @dev Verifies the swap-and-pop mechanics of `removeSubscriber`: register 3 hooks,
    ///      remove the middle one, and confirm the array compacts correctly. The third hook
    ///      (last in the array) must move into the middle slot.
    function test_subscribedHooks_enumerationAfterMidArrayRemoval() public {
        // Register a third hook (PropHook deployed at a third address).
        address addrC = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | (3 << 32)));
        deployCodeTo("Propagation.t.sol:PropHook", abi.encode(manager, gov), addrC);

        vm.prank(address(factory));
        gov.registerSubscriber(addrC);

        // Pre-state: 3 subscribers in [A, B, C] order.
        assertEq(gov.subscribedHooksLength(), 3, "three subscribers registered");
        assertEq(gov.subscribedHooks(0), address(hookA), "slot 0 = hookA");
        assertEq(gov.subscribedHooks(1), address(hookB), "slot 1 = hookB");
        assertEq(gov.subscribedHooks(2), addrC, "slot 2 = hookC");

        // Remove the middle one (hookB) — swap-and-pop should move hookC into slot 1.
        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(hookB));

        assertEq(gov.subscribedHooksLength(), 2, "length decremented");
        assertFalse(gov.isSubscribedHook(address(hookB)), "hookB no longer subscribed");
        assertTrue(gov.isSubscribedHook(address(hookA)), "hookA still subscribed");
        assertTrue(gov.isSubscribedHook(addrC), "hookC still subscribed");
        assertEq(gov.subscribedHooks(0), address(hookA), "slot 0 still hookA");
        assertEq(gov.subscribedHooks(1), addrC, "hookC moved into slot 1 (swap-and-pop)");
    }

    /// @dev `removeSubscriber` of a not-currently-subscribed hook is a no-op (early return).
    function test_removeSubscriber_unsubscribedHook_isNoOp() public {
        uint256 lenBefore = gov.subscribedHooksLength();
        vm.prank(TIMELOCK);
        gov.removeSubscriber(address(0xDEAD));
        assertEq(gov.subscribedHooksLength(), lenBefore, "length unchanged");
    }
}
