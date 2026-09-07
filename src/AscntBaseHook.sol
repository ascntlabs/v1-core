// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {HookMath} from "./lib/HookMath.sol";
import {SafeCast} from "./lib/SafeCast.sol";
import {AscntGovernance, IProtocolFeeBpsSubscriber} from "./AscntGovernance.sol";

interface IHookFactoryView {
    function isVerifiedHook(address hook) external view returns (bool);
    function isDeprecatedHook(address hook) external view returns (bool);
}

/// @title AscntBaseHook
/// @notice Shared base for every Ascnt hook: authority gates, pause gate, protocol-fee take.
abstract contract AscntBaseHook is BaseHook, IProtocolFeeBpsSubscriber {
    using CurrencySettler for Currency;

    // ------ Events ------

    /// @dev Amounts are nominal, pre-transfer-fee — KI-9.
    event ProtocolFeeTaken(bytes32 indexed poolId, address indexed treasury, uint128 amount0, uint128 amount1);

    event ProtocolFeeTakenAsClaims(bytes32 indexed poolId, address indexed treasury, uint128 amount0, uint128 amount1);

    event ProtocolFeeBpsCached(uint16 bps);

    // ------ State ------

    AscntGovernance public immutable governance;

    /// @dev Equals the canonical `HookFactory` only for factory-deployed hooks.
    address public immutable factory;

    uint16 public protocolFeeBps;

    // ------ Errors ------

    error NotOwnerOrPoolDeployer();
    error NotGovernance();
    error AddLiquidityIsPaused();
    error InvalidGovernance();

    constructor(IPoolManager _poolManager, AscntGovernance _governance) BaseHook(_poolManager) {
        if (address(_governance) == address(0)) revert InvalidGovernance();
        factory = msg.sender;
        governance = _governance;
        protocolFeeBps = _governance.protocolFeeBps();
    }

    // ------ Authority Gates ------

    function _requireOwnerOrPoolDeployer(address sender) internal view {
        if (sender == governance.owner()) return;
        if (sender != governance.poolDeployer()) revert NotOwnerOrPoolDeployer();
    }

    modifier onlyOwnerOrPoolDeployer() {
        _requireOwnerOrPoolDeployer(msg.sender);
        _;
    }

    /// @dev Concrete hooks overriding `_beforeInitialize` must call `super._beforeInitialize`.
    function _beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) internal view virtual override returns (bytes4) {
        _requireOwnerOrPoolDeployer(sender);
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Concrete hooks overriding `_beforeAddLiquidity` must call `super._beforeAddLiquidity`.
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view virtual override returns (bytes4) {
        // one read covering both layers: global breaker OR this hook's quarantine
        if (governance.isAddLiquidityBlocked(address(this))) revert AddLiquidityIsPaused();
        return BaseHook.beforeAddLiquidity.selector;
    }

    // ------ Governance Push Callback ------

    /// @inheritdoc IProtocolFeeBpsSubscriber
    function onProtocolFeeBpsUpdated(uint16 bps) external {
        if (msg.sender != address(governance)) revert NotGovernance();
        protocolFeeBps = bps;
        emit ProtocolFeeBpsCached(bps);
    }

    /// @dev Permissionless is safe only because of the `isSubscribedHook` read: an unsubscribed
    ///      hook converges to 0, so nobody can re-arm a decommissioned hook.
    function syncProtocolFee() external {
        protocolFeeBps = governance.isSubscribedHook(address(this)) ? governance.protocolFeeBps() : 0;
        emit ProtocolFeeBpsCached(protocolFeeBps);
    }

    // ------ Self-Attest Views ------

    /// @dev Self-attestation; integrators should use `AscntGovernance.isCanonicalHook`. The
    ///      code-length check is required: a decode revert on empty data is not catchable.
    function isVerified() external view returns (bool) {
        if (factory != governance.hookFactory()) return false;
        if (factory.code.length == 0) return false;
        try IHookFactoryView(factory).isVerifiedHook(address(this)) returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }

    function isDeprecated() external view returns (bool) {
        if (factory != governance.hookFactory()) return false;
        if (factory.code.length == 0) return false;
        try IHookFactoryView(factory).isDeprecatedHook(address(this)) returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }

    // ------ Protocol Fee Take ------

    function _computeProtocolFeeSplit(PoolId poolId, uint24 dynamicFee) internal returns (uint24 lpFee) {
        uint16 protBps = protocolFeeBps;
        uint24 hookFee = 0;
        // read the LIVE treasury: a desync must not carve from LPs here and take nothing later
        if (protBps != 0 && governance.treasury() != address(0)) {
            uint256 hookFeeRaw = FullMath.mulDiv(uint256(dynamicFee), uint256(protBps), 10_000);
            hookFee = SafeCast.toUint24Capped(hookFeeRaw);
        }
        // MAX_PROTOCOL_FEE_BPS (20%) ⇒ hookFee < dynamicFee
        _stashHookFee(poolId, hookFee);
        lpFee = dynamicFee - hookFee;
    }

    /// @dev v4 permits an afterSwap hook delta only in the unspecified currency. Rounds down — KI-3.
    function _takeProtocolFeeOnAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        PoolId poolId
    ) internal returns (int128 hookDeltaUnspecified) {
        uint24 hookFee = _loadHookFee(poolId);
        if (hookFee == 0) return 0;

        address _treasury = governance.treasury();
        if (_treasury == address(0)) return 0;

        // unspecified = currency0 iff (exactInput != zeroForOne)
        bool exactInput = params.amountSpecified < 0;
        bool unspecifiedIsCurrency0 = (exactInput != params.zeroForOne);
        Currency unspecified = unspecifiedIsCurrency0 ? key.currency0 : key.currency1;
        int128 deltaComponent = unspecifiedIsCurrency0 ? swapDelta.amount0() : swapDelta.amount1();

        uint256 mag = SignedMath.abs(int256(deltaComponent));
        uint256 take = FullMath.mulDiv(mag, uint256(hookFee), HookMath.PIPS_SCALE);
        if (take == 0) return 0;

        // one value feeds both the take and the delta; cap and cast unreachable — KI-16
        uint128 take128 = SafeCast.toUint128Capped(take);

        // fall back to ERC-6909 claims so a reverting token cannot brick the swap — KI-4
        bool asClaims = false;
        try poolManager.take(unspecified, _treasury, take128) {}
        catch {
            unspecified.take(poolManager, _treasury, take128, true);
            asClaims = true;
        }

        uint128 amount0 = unspecifiedIsCurrency0 ? take128 : 0;
        uint128 amount1 = unspecifiedIsCurrency0 ? 0 : take128;
        if (asClaims) {
            emit ProtocolFeeTakenAsClaims(PoolId.unwrap(poolId), _treasury, amount0, amount1);
        } else {
            emit ProtocolFeeTaken(PoolId.unwrap(poolId), _treasury, amount0, amount1);
        }

        hookDeltaUnspecified = int128(take128);
    }

    // ------ Transient hookFee stash (beforeSwap -> afterSwap) ------

    /// @dev Must be read before any external call so a re-entrant swap sees only its own value.
    bytes32 private constant _HOOK_FEE_STASH = keccak256("ascnt.protocolfee.hookfee.v1");

    function _stashHookFee(PoolId poolId, uint24 hookFee) private {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(poolId), _HOOK_FEE_STASH));
        assembly ("memory-safe") {
            tstore(slot, hookFee)
        }
    }

    /// @dev `tload` does not truncate; mask to uint24.
    function _loadHookFee(PoolId poolId) private view returns (uint24 hookFee) {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(poolId), _HOOK_FEE_STASH));
        assembly ("memory-safe") {
            hookFee := and(tload(slot), 0xffffff)
        }
    }
}
