// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {StablePairPoolConfig} from "../lib/PoolConfigs.sol";
import {Phase4aCoreHandler} from "./handlers/Phase4aCoreHandler.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Phase-4a stateful core campaign.
///
/// Covers (via per-action ghost assertions in Phase4aCoreHandler plus the invariant functions
/// below): SETTLE-5, SETTLE-9, SETTLE-10, SETTLE-16, SETTLE-19(handler slice), ACC-2, ACC-6,
/// ACC-10, FEE-8, FEE-14, FEE-15.
///
/// Two pools share one SimHook and the same two currencies but differ in tickSpacing (so poolId
/// differs) and in config: pool A is the production-shaped stable pair, pool B an adversarial
/// extreme (maxFee 999_999 — deliberately 1 pip under the 1e6 cap so v4's InvalidFeeForExactOut
/// edge, demonstrated separately in Phase4aAccLifecycle, cannot fire inside this revert-free
/// campaign). The campaign runs with fail-on-revert=true: ANY unexpected revert in a handler
/// action (in particular any swap revert — FEE-14) fails the run.
contract Phase4aCoreInvariantTest is SimHookUtils {
    using PoolIdLibrary for PoolKey;

    Phase4aCoreHandler internal handler;

    PoolKey internal keyB;
    PoolId internal poolIdB;

    address internal constant TREASURY = address(0xBEEF);

    bytes32 internal cfgHashA;
    bytes32 internal cfgHashB;

    function setUp() public {
        StablePairPoolConfig cfg = new StablePairPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);

        // pool A depth: the Phase-0 narrow band plus a wide backstop so bounded handler swaps
        // always find liquidity (keeps the campaign revert-free without collapsing the domain)
        addLiquidity(-600, 600, 1e12, initSqrtP, false);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e12, salt: bytes32(0)}),
            ""
        );

        // pool B: same currencies + hook, tickSpacing 10 => distinct poolId; adversarial config
        (keyB, poolIdB) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, initSqrtP);
        hook.configurePool(poolIdB, 0, 1_000, 999_999, 900, 0, 2e6, 1e6);
        modifyLiquidityRouter.modifyLiquidity(
            keyB, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 3e13, salt: bytes32(0)}), ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            keyB,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e12, salt: bytes32(0)}),
            ""
        );

        // protocol fee on from the start (test contract is owner AND timelock)
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(1000);

        handler = new Phase4aCoreHandler(
            manager, swapRouter, modifyLiquidityRouter, hook, governance, address(this), TREASURY, key, keyB
        );
        MockERC20(Currency.unwrap(currency0)).transfer(address(handler), 1e24);
        MockERC20(Currency.unwrap(currency1)).transfer(address(handler), 1e24);

        // prime both pools through the handler so the take path is provably exercised in every
        // run (also runs the full per-swap ghost-check pipeline once before the campaign)
        handler.swapA(5e9, true, false);
        handler.swapB(5e9, false, false);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = Phase4aCoreHandler.swapA.selector;
        selectors[1] = Phase4aCoreHandler.swapB.selector;
        selectors[2] = Phase4aCoreHandler.advanceTime.selector;
        selectors[3] = Phase4aCoreHandler.addLiquidityA.selector;
        selectors[4] = Phase4aCoreHandler.removeLiquidityA.selector;
        selectors[5] = Phase4aCoreHandler.setProtocolFee.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        cfgHashA = _cfgHash(poolId);
        cfgHashB = _cfgHash(poolIdB);
    }

    /// @notice SETTLE-16: global value conservation of the fee path — the treasury holds exactly
    ///         the sum of every ProtocolFeeTaken amount, per currency, at every point.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: nightly.invariant.runs = 500
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_treasuryEqualsSumOfTakes() public view {
        assertEq(
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(0xBEEF)),
            handler.ghostTakes0(),
            "treasury currency0 != sum of takes"
        );
        assertEq(
            MockERC20(Currency.unwrap(currency1)).balanceOf(address(0xBEEF)),
            handler.ghostTakes1(),
            "treasury currency1 != sum of takes"
        );
    }

    /// @notice ACC-10 (config half): neither pool's one-time config ever changes, no matter what
    ///         the other pool or governance does.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: nightly.invariant.runs = 500
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_bothPoolConfigsImmutable() public view {
        assertEq(_cfgHash(poolId), cfgHashA, "pool A config mutated");
        assertEq(_cfgHash(poolIdB), cfgHashB, "pool B config mutated");
    }

    /// @notice ACC-6: stored swap timestamps never lead block.timestamp on either pool.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: nightly.invariant.runs = 500
    /// forge-config: nightly.invariant.depth = 500
    /// forge-config: nightly.invariant.fail-on-revert = true
    function invariant_lastSwapTimestampNeverFuture() public view {
        (, uint48 tsA,, int256 cumA) = hook.poolData(poolId);
        (, uint48 tsB,, int256 cumB) = hook.poolData(poolIdB);
        assertLe(uint256(tsA), block.timestamp, "pool A timestamp in the future");
        assertLe(uint256(tsB), block.timestamp, "pool B timestamp in the future");
        // FEE-8: abs/negation-safety floor
        assertTrue(cumA > type(int256).min, "pool A cum at int256.min");
        assertTrue(cumB > type(int256).min, "pool B cum at int256.min");
    }

    /// @notice Progress: the campaign is only meaningful if swaps executed on both pools and the
    ///         take path actually settled (SETTLE-5 evidence: nonzero-take unlocks closed).
    function afterInvariant() public view {
        assertGt(handler.swapCount(), 0, "no swaps executed");
        assertGt(handler.takeCount(), 0, "protocol-take path never exercised");
    }

    function _cfgHash(PoolId id) internal view returns (bytes32) {
        (
            bool configured,
            uint24 minMinFee,
            uint24 maxMinFee,
            uint24 maxFee,
            uint48 timeDecayLength,
            uint48 jitLockBlocks,
            uint32 kPips,
            uint32 cPips
        ) = hook.poolConfig(id);
        return
            keccak256(
                abi.encode(configured, minMinFee, maxMinFee, maxFee, timeDecayLength, jitLockBlocks, kPips, cPips)
            );
    }
}
