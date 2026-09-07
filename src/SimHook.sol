// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Position keys must match v4-core's derivation exactly. `Position.sol` is BUSL-1.1 — NOTICE.md.
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookMath} from "./lib/HookMath.sol";
import {SafeCast} from "./lib/SafeCast.sol";
import {SwapSimulator} from "./lib/SwapSimulator.sol";
import {AscntBaseHook} from "./AscntBaseHook.sol";
import {AscntGovernance} from "./AscntGovernance.sol";

/// @title SimHook
/// @notice Dynamic-fee hook pricing each swap off the pool's cumulative price impact.
contract SimHook is AscntBaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------ Events ------

    event PoolInitialized(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks,
        uint160 sqrtPriceX96,
        int24 tick
    );

    event PoolConfigured(
        bytes32 indexed poolId,
        bool configured,
        uint24 minMinFee,
        uint24 maxMinFee,
        uint24 maxFee,
        uint256 timeDecayLength,
        uint48 jitLockBlocks,
        uint32 kPips,
        uint32 cPips,
        uint256 timestamp
    );

    event BeforeSwap(
        bytes32 indexed poolId,
        uint160 sqrtPriceX96Before,
        uint160 sqrtPriceX96AfterSim,
        uint256 priceImpact,
        int256 decayedCumPriceImpact,
        uint24 effectiveMinFee,
        uint24 dynamicFeePips
    );

    event AfterSwap(bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 priceImpact, int256 cumPriceImpact);

    // ------ State ------

    struct PoolConfig {
        bool configured;
        uint24 minMinFee;
        uint24 maxMinFee;
        uint24 maxFee;
        uint48 timeDecayLength;
        uint48 jitLockBlocks;
        uint32 kPips;
        uint32 cPips;
    }

    struct PoolData {
        uint160 sqrtPriceX96Before;
        uint48 lastSwapTimestamp;
        uint40 rampAnchor;
        int256 cumPriceImpact;
    }

    mapping(PoolId => PoolData) public poolData;

    mapping(PoolId => PoolConfig) public poolConfig;

    mapping(PoolId => mapping(bytes32 positionKey => uint48)) public lastAddedLiquidityBlock;

    // ------ Constants ------

    uint48 public constant MAX_JIT_LOCK_BLOCKS = 50_400;

    uint32 public constant MAX_K_PIPS = 20 * uint32(HookMath.PIPS_SCALE);
    uint32 public constant MAX_C_PIPS = 20 * uint32(HookMath.PIPS_SCALE);

    /// @dev Fee-neutral: a capped sum still clamps to `maxFee`. Only removes a mulDiv overflow.
    uint256 private constant MAX_MIDPOINT_SUM = 4e12;

    /// @dev Below 2^58 the X96 price lacks pip resolution — KI-14. Enforced at init only.
    uint160 public constant MIN_USABLE_SQRT_PRICE = uint160(1) << 58;

    uint256 public constant MAX_TIME_DECAY_LENGTH = 1 days;

    // ------ Errors ------

    error MustUseDynamicFee();
    error InitialPriceTooLow();
    error PoolAlreadyConfigured();
    error PoolNotConfigured();
    error PoolNotInitialized();
    error JitLockActive(uint48 blocksRemaining);

    error FeeBounds();
    error FeeTooHigh();
    error ZeroDecay();
    error DecayTooLong();
    error JitLockBlocksTooHigh();
    error MinFeeBounds();
    error ZeroK();
    error KTooHigh();
    error ZeroC();
    error CTooHigh();

    constructor(IPoolManager _poolManager, AscntGovernance _governance) AscntBaseHook(_poolManager, _governance) {}

    // ------ Core Hook Functions ------

    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal view override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        if (sqrtPriceX96 < MIN_USABLE_SQRT_PRICE) revert InitialPriceTooLow();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override returns (bytes4) {
        emit PoolInitialized(
            key.toId(),
            key.currency0,
            key.currency1,
            key.fee,
            key.tickSpacing,
            key.hooks,
            sqrtPriceX96,
            tick
        );
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfig[poolId];
        PoolData storage data = poolData[poolId];

        if (!config.configured) revert PoolNotConfigured();

        uint256 timeSinceLastSwap = block.timestamp - data.lastSwapTimestamp;

        // halve the floor clock's credit once per block, against lastSwapTimestamp — KI-8
        uint40 rampAnchor = data.rampAnchor;
        uint48 lastTs = data.lastSwapTimestamp;
        if (lastTs < block.timestamp && lastTs >= rampAnchor) {
            rampAnchor = uint40(lastTs - (lastTs - rampAnchor) / 2);
            data.rampAnchor = rampAnchor;
        }

        // only the floor reads the anchor; decay keeps the raw inter-swap gap
        uint24 effectiveMinFee = HookMath.calculateEffectiveMinFee(
            config.minMinFee, config.maxMinFee, block.timestamp - rampAnchor, config.timeDecayLength
        );
        int256 decayedCumPriceImpact =
            HookMath.decayCumByTime(data.cumPriceImpact, timeSinceLastSwap, config.timeDecayLength);

        SwapParams memory simParams = SwapParams({
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });
        SwapSimulator.Result memory simResult = SwapSimulator.simulate(poolManager, poolId, key.tickSpacing, simParams);
        uint160 sqrtPriceX96Before = simResult.sqrtPriceBeforeX96;
        uint160 sqrtPriceX96AfterSim = simResult.sqrtPriceAfterX96;
        uint256 priceImpact = HookMath.calculatePriceImpactCapped(sqrtPriceX96Before, sqrtPriceX96AfterSim);

        uint24 dynamicFeePips = calculateDynamicFee(
            priceImpact,
            decayedCumPriceImpact,
            params.zeroForOne,
            effectiveMinFee,
            config.maxFee,
            config.kPips,
            config.cPips
        );

        uint24 lpFeePips = _computeProtocolFeeSplit(poolId, dynamicFeePips);

        data.sqrtPriceX96Before = sqrtPriceX96Before;
        data.cumPriceImpact = decayedCumPriceImpact;

        emit BeforeSwap(
            PoolId.unwrap(poolId),
            sqrtPriceX96Before,
            sqrtPriceX96AfterSim,
            priceImpact,
            decayedCumPriceImpact,
            effectiveMinFee,
            dynamicFeePips
        );

        return
            (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];

        int256 cumPriceImpactBefore = data.cumPriceImpact;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        uint256 priceImpact = (swapDelta.amount0() == 0 && swapDelta.amount1() == 0)
            ? 0
            : HookMath.calculatePriceImpactCapped(data.sqrtPriceX96Before, sqrtPriceX96);

        int256 directionalPriceImpact =
            params.zeroForOne ? -SafeCast.toInt256Capped(priceImpact) : SafeCast.toInt256Capped(priceImpact);

        int256 cumPriceImpact = HookMath.addSaturating(directionalPriceImpact, cumPriceImpactBefore);

        data.cumPriceImpact = cumPriceImpact;
        data.lastSwapTimestamp = uint48(block.timestamp);

        emit AfterSwap(PoolId.unwrap(poolId), sqrtPriceX96, priceImpact, cumPriceImpact);

        int128 hookDelta = _takeProtocolFeeOnAfterSwap(key, params, swapDelta, poolId);
        return (BaseHook.afterSwap.selector, hookDelta);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        // liquidityDelta == 0 (fee-only poke) routes here but must not be blocked — KI-18.
        if (params.liquidityDelta < 0) {
            PoolId poolId = key.toId();
            uint48 lockBlocks = poolConfig[poolId].jitLockBlocks;
            if (lockBlocks > 0) {
                bytes32 positionKey =
                    Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
                uint48 added = lastAddedLiquidityBlock[poolId][positionKey];
                if (added != 0) {
                    uint48 elapsed = uint48(block.number) - added;
                    if (elapsed < lockBlocks) revert JitLockActive(lockBlocks - elapsed);
                }
            }
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfig[poolId];
        if (!config.configured) revert PoolNotConfigured();

        if (params.liquidityDelta > 0 && config.jitLockBlocks > 0) {
            bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
            lastAddedLiquidityBlock[poolId][positionKey] = uint48(block.number);
        }

        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ------ Swap Fee Calculation ------

    function calculateDynamicFee(
        uint256 estimatedPriceImpact,
        int256 cumPriceImpact,
        bool zeroForOne,
        uint24 effectiveMinFee,
        uint24 maxFee,
        uint32 kPips,
        uint32 cPips
    ) internal pure returns (uint24 totalDynamicFee) {
        int256 directionalPriceImpact = zeroForOne
            ? -SafeCast.toInt256Capped(estimatedPriceImpact)
            : SafeCast.toInt256Capped(estimatedPriceImpact);

        int256 estimatedCumPriceImpact = HookMath.addSaturating(directionalPriceImpact, cumPriceImpact);

        uint256 absCum = SignedMath.abs(cumPriceImpact);
        uint256 absEstCum = SignedMath.abs(estimatedCumPriceImpact);

        bool increasingImbalance = cumPriceImpact == 0 || (zeroForOne == (cumPriceImpact < 0));
        bool crossingZero = !increasingImbalance && estimatedPriceImpact > absCum;

        uint256 midpointSum = HookMath.addSaturatingUint(absCum, absEstCum);
        if (midpointSum > MAX_MIDPOINT_SUM) midpointSum = MAX_MIDPOINT_SUM;

        uint256 dynamicImpactFee;
        if (increasingImbalance) {
            dynamicImpactFee = FullMath.mulDiv(midpointSum, kPips, 2 * HookMath.PIPS_SCALE);
        } else if (!crossingZero) {
            dynamicImpactFee = FullMath.mulDiv(midpointSum, cPips, 2 * HookMath.PIPS_SCALE);
        } else {
            uint256 twoP = 2 * estimatedPriceImpact;
            uint256 twoPScaled = twoP * HookMath.PIPS_SCALE;
            dynamicImpactFee = HookMath.addSaturatingUint(
                FullMath.mulDiv(absCum * absCum, cPips, twoPScaled),
                FullMath.mulDiv(absEstCum * absEstCum, kPips, twoPScaled)
            );
        }

        if (dynamicImpactFee < effectiveMinFee) {
            totalDynamicFee = effectiveMinFee;
        } else if (dynamicImpactFee > maxFee) {
            totalDynamicFee = maxFee;
        } else {
            totalDynamicFee = SafeCast.toUint24Capped(dynamicImpactFee);
        }
    }

    // ------ Hook Configuration ------

    function configurePool(
        PoolId poolId,
        uint24 minMinFee,
        uint24 maxMinFee,
        uint24 maxFee,
        uint256 timeDecayLength,
        uint48 jitLockBlocks,
        uint32 kPips,
        uint32 cPips
    ) external onlyOwnerOrPoolDeployer {
        PoolConfig storage config = poolConfig[poolId];
        if (config.configured) revert PoolAlreadyConfigured();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        if (minMinFee > maxMinFee) revert MinFeeBounds();
        if (maxMinFee > maxFee) revert FeeBounds();
        if (maxFee >= LPFeeLibrary.MAX_LP_FEE) revert FeeTooHigh();
        if (timeDecayLength == 0) revert ZeroDecay();
        if (timeDecayLength > MAX_TIME_DECAY_LENGTH) revert DecayTooLong();
        if (jitLockBlocks > MAX_JIT_LOCK_BLOCKS) revert JitLockBlocksTooHigh();
        if (kPips == 0) revert ZeroK();
        if (kPips > MAX_K_PIPS) revert KTooHigh();
        if (cPips == 0) revert ZeroC();
        if (cPips > MAX_C_PIPS) revert CTooHigh();

        config.minMinFee = minMinFee;
        config.maxMinFee = maxMinFee;
        config.maxFee = maxFee;
        config.timeDecayLength = uint48(timeDecayLength);
        config.jitLockBlocks = jitLockBlocks;
        config.kPips = kPips;
        config.cPips = cPips;
        config.configured = true;
        // seed the floor clock
        poolData[poolId].rampAnchor = uint40(block.timestamp);

        emit PoolConfigured(
            PoolId.unwrap(poolId),
            true,
            minMinFee,
            maxMinFee,
            maxFee,
            timeDecayLength,
            jitLockBlocks,
            kPips,
            cPips,
            block.timestamp
        );
    }

    // ------ Hook Permissions ------

    /// @dev Must stay in lockstep with `HookFlags.simHookMask()`.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
