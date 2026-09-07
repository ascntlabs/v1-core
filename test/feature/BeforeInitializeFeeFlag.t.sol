// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {ERC20PoolConfig} from "../lib/PoolConfigs.sol";
import {SimHook} from "../../src/SimHook.sol";
import {AscntBaseHook} from "../../src/AscntBaseHook.sol";

/// @title BeforeInitializeFeeFlag
/// @notice Asserts that `SimHook._beforeInitialize` rejects pools that don't
/// carry `LPFeeLibrary.DYNAMIC_FEE_FLAG`. The hook's whole reason to exist is
/// to override the fee on every swap; a static-fee pool would silently bypass
/// it, so the constructor-time gate must hold.
contract BeforeInitializeFeeFlagTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;

    ERC20PoolConfig internal cfg;

    function setUp() public {
        cfg = new ERC20PoolConfig();
        // setupSimHookAndPool already initializes ONE pool with the dynamic
        // flag; we reuse the hook + manager and try a SECOND initialize with
        // a static fee.
        setupSimHookAndPool(cfg, false);
    }

    /// @dev Re-encodes the CustomRevert.WrappedError the manager wraps beforeInitialize
    /// reverts in, so tests assert the exact inner selector.
    function _expectWrappedInitRevert(bytes4 innerError) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(innerError),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_beforeInitialize_revertsOnStaticFee() public {
        // Build a fresh PoolKey reusing the same hook + currencies but with a
        // static fee (3000 = 0.30%). PoolKey is unique per (currencies, fee,
        // tickSpacing, hooks), so swapping fee gives us a different pool id —
        // the manager won't reject as "already initialized".
        PoolKey memory badKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // static — does NOT have DYNAMIC_FEE_FLAG
            tickSpacing: cfg.tickSpacing(),
            hooks: IHooks(address(hook))
        });

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(cfg.targetTick());

        _expectWrappedInitRevert(SimHook.MustUseDynamicFee.selector);
        manager.initialize(badKey, sqrtPriceX96);
    }

    /// @dev The owner gate must hold through the full v4 plumbing: a stranger calling
    /// manager.initialize on a SimHook pool is rejected via the hook's sender check.
    /// A regression here makes pool creation on the hook permissionless.
    function test_beforeInitialize_revertsForStranger_throughManager() public {
        PoolKey memory freshKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing() + 2, // fresh pool id
            hooks: IHooks(address(hook))
        });
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(cfg.targetTick());

        address stranger = makeAddr("stranger");
        _expectWrappedInitRevert(AscntBaseHook.NotOwnerOrPoolDeployer.selector);
        vm.prank(stranger); // neither governance.owner() nor poolDeployer
        manager.initialize(freshKey, sqrtPriceX96);
    }

    /// @dev Initial price below 2^58 is rejected — the pips impact math degenerates there
    /// (pip resolution needs the X96 price to clear 1e6, so small moves misread near the floor).
    function test_beforeInitialize_revertsOnDegenerateLowPrice() public {
        PoolKey memory lowKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing() + 3, // fresh pool id
            hooks: IHooks(address(hook))
        });

        _expectWrappedInitRevert(SimHook.InitialPriceTooLow.selector);
        manager.initialize(lowKey, (uint160(1) << 58) - 1); // below MIN_USABLE_SQRT_PRICE

        // Boundary accept: exactly MIN_USABLE_SQRT_PRICE initializes cleanly.
        manager.initialize(lowKey, uint160(1) << 58);
    }

    function test_beforeInitialize_acceptsDynamicFeeFlag() public {
        // Control case — a fresh dynamic-fee pool with the same hook should
        // initialize cleanly. Use a different tickSpacing so it's a fresh pool id.
        PoolKey memory goodKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing() + 1, // different pool id from the setUp pool
            hooks: IHooks(address(hook))
        });

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(cfg.targetTick());
        // No revert, and afterInitialize must emit the full PoolInitialized event.
        vm.expectEmit(address(hook));
        emit SimHook.PoolInitialized(
            goodKey.toId(),
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            goodKey.tickSpacing,
            IHooks(address(hook)),
            sqrtPriceX96,
            cfg.targetTick()
        );
        manager.initialize(goodKey, sqrtPriceX96);
    }
}
