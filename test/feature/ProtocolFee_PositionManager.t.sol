// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";

import {TestUtils} from "../utils/TestUtils.sol";
import {NativeEthPoolConfig} from "../lib/PoolConfigs.sol";
import {SimHook} from "../../src/SimHook.sol";

/// @dev A hook that takes a protocol cut at LP-event time fails (`MaximumAmountExceeded` on add
///      and `SafeCastOverflow` on out-of-range burn) only through v4-periphery's `PositionManager`
///      slippage checks (`validateMaxIn` / `validateMinOut`). The rest of the test suite uses
///      `PoolModifyLiquidityTest` which talks to PoolManager directly and bypasses those checks.
///      This suite routes add / increase / decrease / burn through a real `PositionManager`
///      with protocol fee enabled and asserts every flow succeeds — the regression net for
///      that bug class on the canonical user path.
contract ProtocolFee_PositionManager_Test is TestUtils {
    using CurrencyLibrary for Currency;

    // ------ Permit2 + PositionManager scaffolding ------

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IPositionManager internal pm;
    IAllowanceTransfer internal permit2;

    // ------ Pool + hook ------

    NativeEthPoolConfig internal poolCfg;
    uint160 internal initSqrt;
    address internal hookAddr;

    address internal constant TREASURY = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);

    function setUp() public {
        // 1. Deploy hook + governance + tokens via TestUtils.
        poolCfg = new NativeEthPoolConfig();
        hookAddr = deployCoreAndHookCustomDecimals(
            "SimHook.sol",
            poolCfg.symbol0(),
            poolCfg.symbol1(),
            poolCfg.decimals0(),
            poolCfg.decimals1(),
            poolCfg.nativeEth()
        );
        (, initSqrt) = deployPool(IHooks(hookAddr), poolCfg.targetTick(), poolCfg.tickSpacing(), false);
        SimHook(hookAddr)
            .configurePool(
                poolId,
                poolCfg.minMinFee(),
                poolCfg.minMinFee(),
                poolCfg.maxFee(),
                poolCfg.timeDecayLength(),
                poolCfg.jitLockBlocks(),
                poolCfg.kPips(),
                poolCfg.cPips()
            );

        // 2. Etch Permit2 at its canonical address.
        vm.etch(CANONICAL_PERMIT2, Permit2Deployer.deploy().code);
        permit2 = IAllowanceTransfer(CANONICAL_PERMIT2);

        // 3. Deploy real v4-periphery PositionManager pointing at our PoolManager + Permit2.
        address pmAddr =
            V4PositionManagerDeployer.deploy(address(manager), CANONICAL_PERMIT2, 300_000, address(0), address(0));
        pm = IPositionManager(pmAddr);

        // 4. Approve the ERC20 leg through Permit2. Native ETH is value-passed at call time.
        address t1 = Currency.unwrap(key.currency1);
        IERC20(t1).approve(address(permit2), type(uint256).max);
        permit2.approve(t1, pmAddr, type(uint160).max, type(uint48).max);

        // 5. Fund this contract with ETH for native-pair mints.
        vm.deal(address(this), 100 ether);

        // 6. Turn protocol fee on (5% of LP fee). This is the state the regression targets.
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(500);
    }

    // ------ helpers: PositionManager actions ------

    function _mintViaPM(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal returns (uint256 tokenId) {
        tokenId = pm.nextTokenId();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        params[3] = abi.encode(key.currency1, address(this));

        uint256 value = key.currency0.isAddressZero() ? amount0Max : 0;
        pm.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp + 300);
    }

    function _burnViaPM(uint256 tokenId, uint128 amount0Min, uint128 amount1Min) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
    }

    function _increaseViaPM(uint256 tokenId, uint128 liquidityDelta, uint128 amount0Max, uint128 amount1Max) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(tokenId, liquidityDelta, amount0Max, amount1Max, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        params[3] = abi.encode(key.currency1, address(this));

        uint256 value = key.currency0.isAddressZero() ? amount0Max : 0;
        pm.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp + 300);
    }

    function _decreaseViaPM(uint256 tokenId, uint128 liquidityDelta, uint128 amount0Min, uint128 amount1Min) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidityDelta, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
    }

    function _liquidityFor(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Cap,
        uint256 amount1Cap
    ) internal view returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            initSqrt,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Cap,
            amount1Cap
        );
    }

    // ------ §1 regression: add / increase / decrease succeed with strict slippage caps ------

    /// @dev Mint via PositionManager with `amount0Max` / `amount1Max` only marginally above the
    ///      expected principal. A hook returning a non-zero hookDelta on `_afterAddLiquidity`
    ///      would make `liquidityDelta - feesAccrued` go negative and `validateMaxIn` revert
    ///      with `MaximumAmountExceeded`. This hook returns `ZERO_DELTA` so the check passes
    ///      cleanly.
    function test_mintWithStrictSlippage_noMaxExceeded() public {
        int24 tickLower = 76080;
        int24 tickUpper = 90000;
        uint128 liq = _liquidityFor(tickLower, tickUpper, 1 ether, 4_000e18);

        // Snug slippage caps — generous enough for the LP-only principal but would revert if
        // the hook tried to take an LP-event-time cut.
        uint128 amount0Max = 1.01 ether;
        uint128 amount1Max = 4_100e18;

        uint256 tokenId = _mintViaPM(tickLower, tickUpper, liq, amount0Max, amount1Max);
        assertGt(tokenId, 0, "mint produced a position");
    }

    /// @dev `INCREASE_LIQUIDITY` after some swap activity has accrued fees. A fee take at
    ///      LP-event time would be decoded as negative principal and revert.
    function test_increaseAfterFeesAccrued_noMaxExceeded() public {
        int24 tickLower = 76080;
        int24 tickUpper = 90000;
        uint128 liq = _liquidityFor(tickLower, tickUpper, 1 ether, 4_000e18);
        // amount0Max is forwarded as msg.value on native-ETH pools — use a real cap.
        uint256 tokenId = _mintViaPM(tickLower, tickUpper, liq, 2 ether, uint128(8_000e18));

        // Generate fees in both directions.
        _doSmallSwap(true);
        _doSmallSwap(false);

        // Now increase. This would revert with MaximumAmountExceeded if the hook took a cut
        // at LP-event time; it must pass with tight caps.
        uint128 amount0Max = 0.6 ether;
        uint128 amount1Max = 2_400e18;
        _increaseViaPM(tokenId, liq / 2, amount0Max, amount1Max);
    }

    // ------ §2 regression: out-of-range burn succeeds with protocol fee active ------

    /// @dev The SafeCastOverflow case. Position fully in token0 after a directional swap
    ///      pushes price out of range; fees accrued on both currencies. A hook returning a
    ///      positive hookDelta on the depleted side would make `liquidityDelta - feesAccrued`
    ///      cast a negative int128 → uint128 inside `validateMinOut`. This hook doesn't touch
    ///      LP accounting on remove, so the burn proceeds.
    function test_outOfRangeBurn_noSafeCastOverflow() public {
        int24 tickLower = 76080;
        int24 tickUpper = 90000;
        uint128 liq = _liquidityFor(tickLower, tickUpper, 1 ether, 4_000e18);
        uint256 tokenId = _mintViaPM(tickLower, tickUpper, liq, 2 ether, uint128(8_000e18));

        // Build fee growth on both sides.
        _doSmallSwap(true);
        _doSmallSwap(false);
        _doSmallSwap(true);

        // JIT lock expires.
        vm.roll(block.number + poolCfg.jitLockBlocks() + 1);

        // Force position out of range (we just need to be past tickUpper or below tickLower).
        // The default config places the active tick near 76080; a large oneForZero swap
        // pushes price up. Easier: large exact-input on token1 → drives price up → tick above tickUpper.
        _doDirectionalSwap(false, int256(-2_000e18));

        // Burn. amount0Min/amount1Min = 0 — accept any positive amount. A hook with an LP-event
        // take would revert with SafeCastOverflow here.
        _burnViaPM(tokenId, 0, 0);
    }

    // ------ Fee-poke flow: liquidityDelta = 0 ------

    /// @dev INCREASE_LIQUIDITY with `liquidityDelta = 0` is a fee-poke — collect accrued fees
    ///      without changing position size. An LP-event take would fire here too and make
    ///      `amount0Max = 0` revert. This hook has no LP-event take, so even an
    ///      `amount0Max = 0` poke succeeds.
    function test_feePoke_zeroLiquidityDelta_noMaxExceeded() public {
        int24 tickLower = 76080;
        int24 tickUpper = 90000;
        uint128 liq = _liquidityFor(tickLower, tickUpper, 1 ether, 4_000e18);
        uint256 tokenId = _mintViaPM(tickLower, tickUpper, liq, 2 ether, uint128(8_000e18));

        _doSmallSwap(true);
        _doSmallSwap(false);

        // Pure fee poke: zero liquidity delta. Both sides have positive deltas (accrued fees
        // only) so we use INCREASE_LIQUIDITY + TAKE_PAIR (no SETTLE — nothing owed). A hook
        // taking a cut at LP-event time would revert with `MaximumAmountExceeded` regardless
        // of action shape; this one succeeds.
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
    }

    // ------ shared swap helpers ------

    function _doSmallSwap(bool zeroForOne) internal {
        if (zeroForOne) {
            swap(true, -0.005 ether, false);
        } else {
            swap(false, -20e18, false);
        }
    }

    function _doDirectionalSwap(bool zeroForOne, int256 amountSpecified) internal {
        swap(zeroForOne, amountSpecified, false);
    }
}
