// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {ArtifactDeployers} from "../../utils/ArtifactDeployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookFlags} from "../../../script/utils/HookFlags.sol";
import {AscntGovernance} from "../../../src/AscntGovernance.sol";
import {SimHookHarness} from "../../harness/SimHookHarness.sol";
import {Phase5TimelockProxy} from "../helpers/Phase5TimelockProxy.sol";

/// @notice Shared scaffolding for the phase-5 settlement-reentrancy suites (XSUB-1, SETTLE-12/13/17).
///
///         Why this base rather than `TestUtils`/`SimHookFeatureBase`:
///           - the pool currencies must be adversarial token types (armable-reentrant,
///             fee-on-transfer, revert-on-transfer), which the shared helpers cannot deploy;
///           - governance's timelock must be a DISTINCT address from the owner, otherwise
///             SETTLE-17's fast-lane/slow-lane separation assertions (the fast lane cannot
///             reach `setTreasury`/`setProtocolFeeBps`) are vacuous.
///
///         Everything else mirrors production wiring: governance owns the hook, the hook is a
///         registered `protocolFeeBps` subscriber, and the pool is configured exactly once.
///         `SimHookHarness` is deployed in place of `SimHook` — identical permissions (so the same
///         hook-address bits) plus `readStash`, which lets the adversary observe the transient
///         hookFee slot mid-settlement.
abstract contract Phase5ReentrancyBase is ArtifactDeployers {
    using StateLibrary for IPoolManager;

    SimHookHarness internal hook;
    // Public so the auto-getter satisfies setHookFactory's wired-governance duck-type — the test
    // contract stands in as the canonical factory here, mirroring TestUtils.
    AscntGovernance public governance;
    Phase5TimelockProxy internal timelockProxy;
    PoolId internal poolId;

    address internal constant TREASURY = address(0x7EA5);
    address internal constant PAUSER = address(0xBEEF01);

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    // ---- hook event signatures (multi-occurrence parsing; one swap can emit several) ----
    bytes32 internal constant BEFORE_SWAP_SIG =
        keccak256("BeforeSwap(bytes32,uint160,uint160,uint256,int256,uint24,uint24)");
    bytes32 internal constant AFTER_SWAP_SIG = keccak256("AfterSwap(bytes32,uint160,uint256,int256)");
    bytes32 internal constant PROTOCOL_FEE_TAKEN_SIG = keccak256("ProtocolFeeTaken(bytes32,address,uint128,uint128)");
    /// @dev Emitted INSTEAD of `ProtocolFeeTaken` by the hook's SETTLE-17 fault-isolation path:
    ///      the direct treasury transfer reverted and the slice was minted as ERC-6909 claims.
    bytes32 internal constant PROTOCOL_FEE_TAKEN_AS_CLAIMS_SIG =
        keccak256("ProtocolFeeTakenAsClaims(bytes32,address,uint128,uint128)");

    struct BeforeSwapEvent {
        bytes32 poolId;
        uint160 sqrtPriceX96Before;
        uint160 sqrtPriceX96AfterSim;
        uint256 priceImpact;
        int256 decayedCumPriceImpact;
        uint24 effectiveMinFee;
        uint24 dynamicFeePips;
    }

    struct AfterSwapEvent {
        bytes32 poolId;
        uint160 sqrtPriceX96;
        uint256 priceImpact;
        int256 cumPriceImpact;
    }

    struct TakeEvent {
        bytes32 poolId;
        address treasury;
        uint128 amount0;
        uint128 amount1;
    }

    // ------ protocol bring-up ------

    /// @dev Manager + routers + governance (owner = test contract, timelock = proxy) + hook.
    function _deployProtocol() internal {
        deployArtifactManagerAndRouters();

        timelockProxy = new Phase5TimelockProxy();
        governance = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance",
                abi.encode(address(this), address(timelockProxy), PAUSER, address(0))
            )
        );
        governance.setHookFactory(address(this));

        address hookAddress = address(uint160(HookFlags.simHookMask()));
        deployCodeTo("SimHookHarness.sol", abi.encode(manager, governance), hookAddress);
        hook = SimHookHarness(hookAddress);

        // mirrors HookFactory.deployHook's registration of the new hook as a fee subscriber
        governance.registerSubscriber(hookAddress);
    }

    /// @dev Sort two freshly deployed tokens into `currency0` / `currency1` and approve the routers.
    function _useTokens(address tokenA, address tokenB) internal {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        currency0 = Currency.wrap(t0);
        currency1 = Currency.wrap(t1);
        _approveRouters(t0);
        _approveRouters(t1);
    }

    function _approveRouters(address token) internal {
        MockERC20(token).approve(address(swapRouter), type(uint256).max);
        MockERC20(token).approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    /// @dev Initialize a dynamic-fee pool on the hook at `startTick` and configure it (one-time).
    function _initAndConfigure(
        int24 tickSpacing,
        int24 startTick,
        uint24 minMinFee,
        uint24 maxMinFee,
        uint24 maxFee,
        uint256 timeDecayLength,
        uint48 jitLockBlocks
    ) internal returns (PoolKey memory k, PoolId id) {
        (k, id) = initPool(
            currency0,
            currency1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing,
            TickMath.getSqrtPriceAtTick(startTick)
        );
        hook.configurePool(id, minMinFee, maxMinFee, maxFee, timeDecayLength, jitLockBlocks, 2e6, 1e6);
    }

    function _addLiquidity(PoolKey memory k, int24 lower, int24 upper, uint256 amount0) internal {
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0
        );
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ------ governance (slow lane runs through the proxy) ------

    function _timelockCall(bytes memory data) internal returns (bytes memory) {
        return timelockProxy.exec(address(governance), data);
    }

    function _enableProtocolFee(uint16 bps, address treasury) internal {
        _timelockCall(abi.encodeCall(AscntGovernance.setTreasury, (treasury)));
        _timelockCall(abi.encodeCall(AscntGovernance.setProtocolFeeBps, (bps)));
    }

    function _setProtocolFeeBps(uint16 bps) internal {
        _timelockCall(abi.encodeCall(AscntGovernance.setProtocolFeeBps, (bps)));
    }

    // ------ direct state pokes (no production path exists) ------

    /// @dev Storage slot of `poolData[poolId].cumPriceImpact`.
    ///      `poolData` is declared at slot 1 of `SimHook` (verified with `forge inspect`); the
    ///      `PoolData` struct packs `sqrtPriceX96Before|lastSwapTimestamp` into its slot 0 and
    ///      holds `cumPriceImpact` alone in its slot 1.
    ///
    ///      Used ONLY to pre-load the accumulator near `int256` saturation — a state the hook can
    ///      reach over its lifetime (impacts are capped at 1e6 pips per swap, so getting there by
    ///      swapping would need ~1e71 swaps) but that no test can reach by swapping. Everything
    ///      after the poke runs through the real code path.
    uint256 internal constant POOL_DATA_SLOT = 1;

    function _pokeCumPriceImpact(PoolId id, int256 cum) internal {
        bytes32 base = keccak256(abi.encode(PoolId.unwrap(id), POOL_DATA_SLOT));
        vm.store(address(hook), bytes32(uint256(base) + 1), bytes32(uint256(cum)));
        (,,, int256 readBack) = hook.poolData(id);
        require(readBack == cum, "cum poke targeted the wrong slot");
    }

    /// @dev Tick spacings that divide 600 (so `TICK_LOWER`/`TICK_UPPER` stay aligned) and are not
    ///      already used by the suites' setUp pools. Each distinct spacing yields a distinct poolId
    ///      on the same currency pair, which is how the fuzzes get a FRESH pool per run.
    function _freshTickSpacing(uint256 seed) internal pure returns (int24) {
        int24[20] memory spacings =
            [int24(2), 3, 4, 5, 6, 8, 12, 15, 20, 24, 25, 30, 40, 50, 60, 75, 100, 120, 150, 200];
        return spacings[seed % 20];
    }

    // ------ swapping ------

    function _swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _swap(
        PoolKey memory k,
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (BalanceDelta delta, Vm.Log[] memory logs) {
        vm.recordLogs();
        delta = swapRouter.swap(
            k,
            _swapParams(zeroForOne, amountSpecified),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        logs = vm.getRecordedLogs();
    }

    /// @dev Raw swap that does not revert on failure — for the DoS assertions, which need the
    ///      revert BLOB (nested ERC-7751 `WrappedError`s) rather than just "it reverted".
    function _trySwap(
        PoolKey memory k,
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (bool ok, bytes memory err) {
        return _trySwap(k, zeroForOne, amountSpecified, false);
    }

    /// @dev `takeClaims = true` makes the router take its output as ERC-6909 claims — no ERC-20
    ///      transfer on the output side — which isolates the HOOK's take as the only ERC-20
    ///      transfer of the unspecified currency in the transaction.
    function _trySwap(
        PoolKey memory k,
        bool zeroForOne,
        int256 amountSpecified,
        bool takeClaims
    ) internal returns (bool ok, bytes memory err) {
        (ok, err) = address(swapRouter)
            .call(
                abi.encodeCall(
                    PoolSwapTest.swap,
                    (
                        k,
                        _swapParams(zeroForOne, amountSpecified),
                        PoolSwapTest.TestSettings({takeClaims: takeClaims, settleUsingBurn: false}),
                        ZERO_BYTES
                    )
                )
            );
    }

    // ------ event parsing (arrays: a re-entered swap emits each event more than once) ------

    function _beforeSwapEvents(Vm.Log[] memory logs) internal pure returns (BeforeSwapEvent[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BEFORE_SWAP_SIG) n++;
        }
        out = new BeforeSwapEvent[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != BEFORE_SWAP_SIG) continue;
            BeforeSwapEvent memory e;
            e.poolId = logs[i].topics[1];
            (
                e.sqrtPriceX96Before,
                e.sqrtPriceX96AfterSim,
                e.priceImpact,
                e.decayedCumPriceImpact,
                e.effectiveMinFee,
                e.dynamicFeePips
            ) = abi.decode(logs[i].data, (uint160, uint160, uint256, int256, uint24, uint24));
            out[j++] = e;
        }
    }

    function _afterSwapEvents(Vm.Log[] memory logs) internal pure returns (AfterSwapEvent[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == AFTER_SWAP_SIG) n++;
        }
        out = new AfterSwapEvent[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != AFTER_SWAP_SIG) continue;
            AfterSwapEvent memory e;
            e.poolId = logs[i].topics[1];
            (e.sqrtPriceX96, e.priceImpact, e.cumPriceImpact) = abi.decode(logs[i].data, (uint160, uint256, int256));
            out[j++] = e;
        }
    }

    function _takeEvents(Vm.Log[] memory logs) internal pure returns (TakeEvent[] memory out) {
        return _settleEvents(logs, PROTOCOL_FEE_TAKEN_SIG);
    }

    /// @dev `ProtocolFeeTakenAsClaims` occurrences — same shape as `ProtocolFeeTaken`, emitted on
    ///      the claims fallback path (direct transfer reverted, slice minted as ERC-6909 claims).
    function _claimsEvents(Vm.Log[] memory logs) internal pure returns (TakeEvent[] memory out) {
        return _settleEvents(logs, PROTOCOL_FEE_TAKEN_AS_CLAIMS_SIG);
    }

    function _settleEvents(Vm.Log[] memory logs, bytes32 sig) internal pure returns (TakeEvent[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) n++;
        }
        out = new TakeEvent[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            TakeEvent memory e;
            e.poolId = logs[i].topics[1];
            e.treasury = address(uint160(uint256(logs[i].topics[2])));
            (e.amount0, e.amount1) = abi.decode(logs[i].data, (uint128, uint128));
            out[j++] = e;
        }
    }

    /// @dev ERC-6909 claims balance `who` holds on the PoolManager ledger for `c`.
    function _claimsBalance(address who, Currency c) internal view returns (uint256) {
        return manager.balanceOf(who, uint256(uint160(Currency.unwrap(c))));
    }

    /// @dev Amount settled for `id` (last take on that pool), or 0 when the pool took nothing at
    ///      all. Quadrant-agnostic: `ProtocolFeeTaken` puts the amount in exactly one slot and 0 in
    ///      the other, so the sum is the taken amount whichever currency was unspecified.
    function _takeAmountOrZero(Vm.Log[] memory logs, PoolId id) internal pure returns (uint256) {
        TakeEvent[] memory takes = _takeEvents(logs);
        for (uint256 i = takes.length; i > 0; i--) {
            if (takes[i - 1].poolId == PoolId.unwrap(id)) {
                return uint256(takes[i - 1].amount0) + uint256(takes[i - 1].amount1);
            }
        }
        return 0;
    }

    // ------ misc ------

    /// @dev Scan a revert blob for a 4-byte selector. v4 wraps hook/transfer failures in nested
    ///      ERC-7751 `WrappedError(address,bytes4,bytes,bytes4)` payloads, so the interesting
    ///      selectors are buried at varying offsets; a scan is the robust way to attribute a
    ///      failure to a specific call site.
    function _blobContains(bytes memory blob, bytes4 selector) internal pure returns (bool) {
        if (blob.length < 4) return false;
        for (uint256 i = 0; i + 4 <= blob.length; i++) {
            if (
                blob[i] == selector[0] && blob[i + 1] == selector[1] && blob[i + 2] == selector[2]
                    && blob[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }
}
