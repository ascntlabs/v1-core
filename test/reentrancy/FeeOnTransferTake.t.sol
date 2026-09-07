// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Phase5ReentrancyBase} from "./base/Phase5ReentrancyBase.sol";
import {Phase5FeeOnTransferERC20} from "./helpers/Phase5AdversarialTokens.sol";

/// @notice SETTLE-13 — fee-on-transfer / deflationary unspecified currency.
///
///         == WHAT THIS SUITE DOES AND DOES NOT DEMONSTRATE (read before citing it) ==
///
///         The `test_SETTLE13_*tax*` accounting vectors run a RECIPIENT-scoped tax — a modelling
///         device no shipping token implements (see `Phase5AdversarialTokens.sol`). They pin the
///         hook/manager accounting property: `PoolManager.take` books `_accountDelta(-take128)` on
///         the REQUESTED amount and the hook returns that same `take128` as its afterSwap delta,
///         so the unlock nets to zero no matter what the token delivers, and the shortfall is
///         absorbed entirely by the recipient (treasury/swapper), never by the pool or LPs. They
///         deliberately do NOT model what happens when a real token's transfer fee is enabled.
///
///         That real failure mode is pinned separately by
///         `test_SETTLE13_globallyTaxedToken_inputSideSettleReverts`: with a GLOBALLY taxing
///         token (the only shape the shipping fee mechanisms have), `PoolManager._settle` credits
///         only the DELIVERED amount, so every leg paying that token INTO the pool — exact-in and
///         exact-out swaps on the paying side, and every add-liquidity touching it — reverts
///         `CurrencyNotSettled`. That is a pool-wide brick, independent of this hook, recoverable
///         only by the token owner zeroing the fee (or abandoning the pool). The `ProtocolFeeTaken`
///         over-count (the event reports the requested, not delivered, amount) is the SECONDARY
///         effect, relevant only to the output side, which keeps closing.
///
///         Two fee-mechanism shapes matter, and only one is dangerous here:
///           - RECIPIENT-SCOPED (what this mock models): the tax applies to selected recipients.
///             The paying side still settles in full, so no `CurrencyNotSettled`.
///           - GLOBALLY-SCOPED, owner-settable (the shape real fee switches take, typically
///             dormant at zero and deducted from the transferred amount rather than burned):
///             applies to ALL transfers. Enabling it means every swap paying that token in, and
///             every liquidity add touching it, reverts `CurrencyNotSettled`; amounts paid out
///             deliver less than accounted. Pairing such a token is a deployment-time decision —
///             the guard is pair selection, not hook logic.
///
///         Coverage shape for the accounting vectors: the take is drawn from the UNSPECIFIED
///         currency, which is the output on exact-input and the input on exact-output. All four
///         (zeroForOne x exactInput) quadrants are exercised, with the tax applied to whichever
///         token is unspecified in that quadrant. Every assertion is anchored to a same-state
///         control run with the tax off (`vm.snapshotState` / `vm.revertToState`), so "unchanged"
///         means byte-identical against a real baseline. `supplyBurned` measurements are mock
///         plumbing (the mock burns its fee so the shortfall is countable), not a claim about the
///         real tokens' fee routing.
contract Phase5FeeOnTransferTakeTest is Phase5ReentrancyBase {
    using StateLibrary for IPoolManager;

    Phase5FeeOnTransferERC20 internal token0;
    Phase5FeeOnTransferERC20 internal token1;

    uint24 internal constant MIN_MIN_FEE = 100;
    uint24 internal constant MAX_MIN_FEE = 500;
    uint24 internal constant MAX_FEE = 200_000;
    uint256 internal constant DECAY = 1 hours;
    uint16 internal constant BPS = 1_000; // 10%
    uint16 internal constant CAP_BPS = 2_000;

    int256 internal constant AMOUNT = 5e19;
    uint256 internal constant TAX_BPS = 300; // 3% transfer tax

    function setUp() public {
        _deployProtocol();

        Phase5FeeOnTransferERC20 a = new Phase5FeeOnTransferERC20("Phase5FotA", "P5FA", 18);
        Phase5FeeOnTransferERC20 b = new Phase5FeeOnTransferERC20("Phase5FotB", "P5FB", 18);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        _useTokens(address(a), address(b));
        token0 = Phase5FeeOnTransferERC20(Currency.unwrap(currency0));
        token1 = Phase5FeeOnTransferERC20(Currency.unwrap(currency1));

        (key, poolId) = _initAndConfigure(1, 0, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, DECAY, 0);
        _addLiquidity(key, TICK_LOWER, TICK_UPPER, 1e21);
        _enableProtocolFee(BPS, TREASURY);

        // warm-up swap, tax still off
        _swap(key, true, -2e19);
    }

    struct Snap {
        uint128 requested;
        int256 treasuryDelta;
        int256 swapperDelta;
        int256 managerDelta;
        uint256 supplyBurned;
        uint256 feeGrowth0;
        uint256 feeGrowth1;
    }

    /// @dev The take is drawn from the UNSPECIFIED currency: currency0 iff exactInput != zeroForOne.
    function _unspecifiedIsCurrency0(bool zeroForOne, bool exactInput) internal pure returns (bool) {
        return exactInput != zeroForOne;
    }

    function _unspecifiedToken(bool zeroForOne, bool exactInput) internal view returns (Phase5FeeOnTransferERC20) {
        return _unspecifiedIsCurrency0(zeroForOne, exactInput) ? token0 : token1;
    }

    /// @dev Tax the treasury on whichever token is unspecified for this quadrant.
    function _taxTreasury(bool zeroForOne, bool exactInput, uint256 taxBps) internal {
        Phase5FeeOnTransferERC20 t = _unspecifiedToken(zeroForOne, exactInput);
        t.setFeeBps(taxBps);
        t.setTaxedRecipient(TREASURY, true);
    }

    /// @dev Run one swap in the given quadrant and measure every side of the settlement, all on the
    ///      UNSPECIFIED currency (the one the take is drawn from).
    function _measuredSwap(bool zeroForOne, bool exactInput, int256 magnitude) internal returns (Snap memory s) {
        bool unspecIs0 = _unspecifiedIsCurrency0(zeroForOne, exactInput);
        Phase5FeeOnTransferERC20 t = unspecIs0 ? token0 : token1;

        uint256 treasuryBefore = t.balanceOf(TREASURY);
        uint256 swapperBefore = t.balanceOf(address(this));
        uint256 managerBefore = t.balanceOf(address(manager));
        uint256 supplyBefore = t.totalSupply();

        (, Vm.Log[] memory logs) = _swap(key, zeroForOne, exactInput ? -magnitude : magnitude);

        TakeEvent[] memory takes = _takeEvents(logs);
        require(takes.length == 1, "expected exactly one take");
        // SETTLE-19-adjacent sanity: the amount must sit in the unspecified currency's slot.
        if (unspecIs0) {
            require(takes[0].amount1 == 0, "take landed in the wrong currency slot");
            s.requested = takes[0].amount0;
        } else {
            require(takes[0].amount0 == 0, "take landed in the wrong currency slot");
            s.requested = takes[0].amount1;
        }
        s.treasuryDelta = int256(t.balanceOf(TREASURY)) - int256(treasuryBefore);
        s.swapperDelta = int256(t.balanceOf(address(this))) - int256(swapperBefore);
        s.managerDelta = int256(t.balanceOf(address(manager))) - int256(managerBefore);
        s.supplyBurned = supplyBefore - t.totalSupply();
        (s.feeGrowth0, s.feeGrowth1) = manager.getFeeGrowthGlobals(poolId);
    }

    // =====================================================================================

    /// @notice SETTLE-13 core, run over ALL FOUR direction/exactness quadrants: with a taxed
    ///         treasury the swap still settles, the ACCOUNTED take is the requested amount (what the
    ///         pool was debited), and the shortfall lands only on the treasury — the manager's
    ///         balance movement, the swapper's own leg and the LP fee growth are byte-identical to
    ///         the untaxed control.
    function test_SETTLE13_allFourQuadrants_taxedTreasuryAbsorbsTheEntireShortfall() public {
        for (uint256 q = 0; q < 4; q++) {
            bool zeroForOne = q % 2 == 0;
            bool exactInput = q < 2;

            uint256 snap = vm.snapshotState();

            Snap memory ctrl = _measuredSwap(zeroForOne, exactInput, AMOUNT);
            assertGt(ctrl.requested, 0, "control take must be non-zero or nothing is measured");
            assertEq(uint256(ctrl.treasuryDelta), uint256(ctrl.requested), "control: treasury gets it all");
            assertEq(ctrl.supplyBurned, 0, "control: no tax burned");

            vm.revertToState(snap);

            _taxTreasury(zeroForOne, exactInput, TAX_BPS);
            Snap memory taxed = _measuredSwap(zeroForOne, exactInput, AMOUNT);

            uint256 expectedTax = (uint256(taxed.requested) * TAX_BPS) / 10_000;
            assertGt(expectedTax, 0, "tax must bite or the quadrant is vacuous");

            assertEq(taxed.requested, ctrl.requested, "accounted take is REQUEST-based, tax-independent");
            assertEq(
                taxed.treasuryDelta,
                int256(uint256(taxed.requested)) - int256(expectedTax),
                "treasury absorbs the shortfall"
            );
            assertEq(taxed.supplyBurned, expectedTax, "the shortfall is exactly the token's tax");

            assertEq(taxed.managerDelta, ctrl.managerDelta, "pool moved the requested amount, not the delivered one");
            assertEq(taxed.swapperDelta, ctrl.swapperDelta, "the swapper's own leg is untouched");
            assertEq(taxed.feeGrowth0, ctrl.feeGrowth0, "LP fee growth untouched (currency0)");
            assertEq(taxed.feeGrowth1, ctrl.feeGrowth1, "LP fee growth untouched (currency1)");

            vm.revertToState(snap);
        }
    }

    /// @notice SETTLE-13 at the degenerate endpoints, asserted deterministically rather than left to
    ///         fuzz sampling: a 100% transfer tax (the treasury receives NOTHING) still closes the
    ///         unlock and still accounts the full requested amount, and a 0% tax is the identity.
    function test_SETTLE13_taxEndpoints_zeroAndOneHundredPercent() public {
        uint256 snap = vm.snapshotState();

        // --- 0%: the tax machinery is installed but inert ---
        token1.setTaxedRecipient(TREASURY, true);
        token1.setFeeBps(0);
        Snap memory zero = _measuredSwap(true, true, AMOUNT);
        assertGt(zero.requested, 0);
        assertEq(uint256(zero.treasuryDelta), uint256(zero.requested), "0% tax delivers everything");
        assertEq(zero.supplyBurned, 0);

        vm.revertToState(snap);

        // --- 100%: the treasury receives nothing at all ---
        token1.setTaxedRecipient(TREASURY, true);
        token1.setFeeBps(10_000);
        Snap memory full = _measuredSwap(true, true, AMOUNT); // reverts if the unlock fails to close
        assertEq(full.requested, zero.requested, "the accounted take does not move with the tax");
        assertEq(full.treasuryDelta, int256(0), "100% tax: the treasury receives nothing");
        assertEq(full.supplyBurned, uint256(full.requested), "the whole slice was burned in transit");
        assertEq(full.managerDelta, zero.managerDelta, "the pool still paid out the accounted amount");
    }

    /// @notice SETTLE-13 fuzzed over the tax rate, the QUADRANT and the protocol rate: the unlock
    ///         must close every time and the accounted take must never track the delivered amount.
    function testFuzz_SETTLE13_anyTaxRateAndQuadrant_accountingStaysRequestBased(
        uint256 bpsSeed,
        uint256 quadSeed,
        uint16 protSeed,
        uint256 dtSeed
    ) public {
        uint256 taxBps = bound(bpsSeed, 0, 10_000);
        uint256 q = bound(quadSeed, 0, 3);
        bool zeroForOne = q % 2 == 0;
        bool exactInput = q < 2;
        // >= 100 bps keeps the slice off the rounding floor, so `requested > 0` is guaranteed and
        // the delivered-vs-requested comparison is never vacuous.
        _setProtocolFeeBps(uint16(bound(uint256(protSeed), 100, CAP_BPS)));
        vm.warp(block.timestamp + bound(dtSeed, 0, 2 * DECAY));

        _taxTreasury(zeroForOne, exactInput, taxBps);

        Snap memory s = _measuredSwap(zeroForOne, exactInput, AMOUNT); // reverts if the unlock fails

        assertGt(s.requested, 0, "the slice must actually settle");
        uint256 expectedTax = (uint256(s.requested) * taxBps) / 10_000;
        assertEq(s.treasuryDelta, int256(uint256(s.requested)) - int256(expectedTax), "delivered = requested - tax");
        assertEq(s.supplyBurned, expectedTax, "tax burned from the pool's outgoing transfer");
    }

    /// @notice The swapper's own leg is taxed too (a genuinely deflationary token, not a
    ///         treasury-specific tax): the swap still closes, each recipient absorbs its own
    ///         shortfall, and the pool's outgoing accounting is unchanged.
    function test_SETTLE13_taxedSwapperAndTreasury_stillCloses() public {
        uint256 snap = vm.snapshotState();
        Snap memory ctrl = _measuredSwap(true, true, AMOUNT);
        vm.revertToState(snap);

        token1.setFeeBps(TAX_BPS);
        token1.setTaxedRecipient(TREASURY, true);
        token1.setTaxedRecipient(address(this), true);

        Snap memory taxed = _measuredSwap(true, true, AMOUNT);

        assertEq(taxed.requested, ctrl.requested, "accounted take unchanged");
        assertLt(taxed.swapperDelta, ctrl.swapperDelta, "swapper now absorbs its own tax");
        assertEq(
            taxed.managerDelta,
            ctrl.managerDelta,
            "pool still pays out the accounted amounts; the tax is taken from what it sends"
        );
        assertEq(taxed.feeGrowth1, ctrl.feeGrowth1, "LP accrual is untouched by either tax");
    }

    /// @notice LP balances are intact under the tax: the position removes to exactly the same
    ///         accounted delta as in the untaxed control.
    function test_SETTLE13_lpPrincipalAndFeesUnaffectedByTax() public {
        uint256 snap = vm.snapshotState();

        _measuredSwap(true, true, AMOUNT);
        BalanceDelta ctrlRemove = _removeAll();

        vm.revertToState(snap);

        token1.setFeeBps(TAX_BPS);
        token1.setTaxedRecipient(TREASURY, true);
        _measuredSwap(true, true, AMOUNT);
        BalanceDelta taxedRemove = _removeAll();

        assertEq(taxedRemove.amount0(), ctrlRemove.amount0(), "LP principal+fees (currency0) unchanged");
        assertEq(taxedRemove.amount1(), ctrlRemove.amount1(), "LP principal+fees (currency1) unchanged");
    }

    /// @notice SETTLE-13, the boundary that matters (see the contract header): a GLOBALLY taxing
    ///         token — the shape owner-settable contract fees take — cannot be paid into the pool
    ///         at all once its fee is non-zero. Liquidity is seeded and the pool warmed while the
    ///         fee is zero (the dormant-switch case); then the fee is switched on and:
    ///           - every settle paying the taxed token IN reverts `CurrencyNotSettled` (exact-in
    ///             and exact-out swaps on the paying side, and add-liquidity) — the pool-wide
    ///             brick, independent of this hook;
    ///           - the output side (taxed token only LEAVES the pool) still closes, with each
    ///             recipient absorbing its own shortfall and the accounting request-based — the
    ///             regime the rest of this suite characterises;
    ///           - zeroing the fee again restores the input side, pinning attribution to the
    ///             token's fee switch and nothing else.
    function test_SETTLE13_globallyTaxedToken_inputSideSettleReverts() public {
        // control for the output-side comparison, captured while the token is still fee-free
        uint256 snap = vm.snapshotState();
        Snap memory ctrl = _measuredSwap(false, true, AMOUNT); // exact-in oneForZero: token0 OUT only
        assertGt(ctrl.requested, 0, "control take must settle or the output-side leg proves nothing");
        vm.revertToState(snap);

        // the dormant fee switch flips on (rate leaving zero)
        token0.setGlobalTax(true);
        token0.setFeeBps(TAX_BPS);

        // --- input side: every leg paying token0 in is bricked, CurrencyNotSettled ---
        (bool okIn, bytes memory errIn) = _trySwap(key, true, -AMOUNT); // exact-in zeroForOne pays token0
        assertFalse(okIn, "exact-in on the paying side must brick");
        assertTrue(
            _blobContains(errIn, IPoolManager.CurrencyNotSettled.selector),
            "v4 settle under-credits the delivered amount and refuses to close"
        );

        (bool okOut, bytes memory errOut) = _trySwap(key, true, int256(1e19)); // exact-out zeroForOne also pays token0
        assertFalse(okOut, "exact-out on the paying side must brick too");
        assertTrue(_blobContains(errOut, IPoolManager.CurrencyNotSettled.selector), "same failure mode");

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        this.externalAddLiquidity(1e19); // adds pay token0 in: bricked pool-wide, not just swaps

        // --- output side: token0 only leaves the pool, so the unlock still closes ---
        Snap memory taxed = _measuredSwap(false, true, AMOUNT);
        assertEq(taxed.requested, ctrl.requested, "accounting stays request-based");
        assertEq(taxed.managerDelta, ctrl.managerDelta, "the pool is debited the accounted amounts");
        uint256 takeTax = (uint256(taxed.requested) * TAX_BPS) / 10_000;
        assertGt(takeTax, 0, "the tax must bite or this leg is vacuous");
        assertEq(
            taxed.treasuryDelta,
            int256(uint256(taxed.requested)) - int256(takeTax),
            "treasury absorbs its own shortfall (and ProtocolFeeTaken over-counts by exactly this)"
        );
        uint256 swapperGross = uint256(ctrl.swapperDelta);
        assertEq(
            taxed.swapperDelta,
            int256(swapperGross) - int256((swapperGross * TAX_BPS) / 10_000),
            "the swapper absorbs the tax on its own output leg"
        );

        // --- recovery: only the token's own fee switch clears the brick ---
        token0.setFeeBps(0);
        (bool okAgain,) = _trySwap(key, true, -AMOUNT);
        assertTrue(okAgain, "zeroing the token fee restores the input side");
    }

    /// @dev External wrapper so `vm.expectRevert` can target the add-liquidity call as a single
    ///      external call (the base helper is internal).
    function externalAddLiquidity(uint256 amount0) external {
        _addLiquidity(key, TICK_LOWER, TICK_UPPER, amount0);
    }

    function _removeAll() internal returns (BalanceDelta) {
        (uint128 posLiq,,) =
            manager.getPositionInfo(poolId, address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
        require(posLiq > 0, "no position");
        return modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: -int256(uint256(posLiq)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }
}
