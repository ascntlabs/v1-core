// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {SimHook} from "../../src/SimHook.sol";

/// @dev Per-party token-flow ledger for the 5-step JIT sandwich on a stable pool:
///      frontrun through the deep band → single-sided far-tick JIT add → victim filled by the
///      JIT → attacker self-rebalance back to peg → remove JIT (after the 50-block lock).
///      Every USDC/USDT movement is attributed to a party and conservation is asserted EXACTLY,
///      with protocolFeeBps = 0 and = 500 (5% of the dynamic fee to treasury).
contract StableTokenFlowTest is SimHookUtils {
    using StateLibrary for IPoolManager;

    uint160 internal _sp;
    address internal constant TREASURY = address(0xFEE);
    int24 internal constant JTL = 1800; // far-tick JIT band ≈ 20% off peg
    int24 internal constant JTU = 1810;

    function _t0() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency0));
    }

    function _t1() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency1));
    }

    function _b0(address a) internal view returns (int256) {
        return int256(_t0().balanceOf(a));
    }

    function _b1(address a) internal view returns (int256) {
        return int256(_t1().balanceOf(a));
    }

    function _mkTrader(string memory name) internal returns (address a) {
        a = makeAddr(name);
        vm.deal(a, 1_000 ether);
        _t0().mint(a, 100_000_000e6);
        _t1().mint(a, 100_000_000e6);
        vm.startPrank(a);
        _t0().approve(address(swapRouter), type(uint256).max);
        _t1().approve(address(swapRouter), type(uint256).max);
        _t0().approve(address(modifyLiquidityRouter), type(uint256).max);
        _t1().approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Single-sided USDC (token0-only) position in [tl,tu] entirely ABOVE the current price.
    function _addUSDConly(int24 tl, int24 tu, uint256 usdc) internal returns (int256 liq) {
        uint128 L = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), usdc
        );
        liq = int256(uint256(L));
        modifyLiquidityRouter.modifyLiquidity{value: usdc + 1}(
            key,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: liq, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function _removeLiq(int24 tl, int24 tu, int256 liq) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: -liq, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // 7 tracked parties: baselineLP, attacker, victim, warmer, treasury, pool manager, deployer.
    function _snap7(address[7] memory P) internal view returns (int256[7] memory a, int256[7] memory b) {
        for (uint256 i = 0; i < 7; i++) {
            a[i] = _b0(P[i]);
            b[i] = _b1(P[i]);
        }
    }

    /// @dev Per-party ledger for `_runTokenFlow`, bundled into one memory struct: as six separate
    ///      locals (P, N, st0, st1, a, b) the instrumented via-IR frame exceeds 16 slots and
    ///      `forge coverage --ir-minimum` fails stack-too-deep.
    struct Ledger {
        address[7] P; // parties
        string[7] N; // party names (logging)
        int256[7] st0; // conservation baseline, token0
        int256[7] st1; // conservation baseline, token1
        int256[7] a; // running per-step snapshot, token0
        int256[7] b; // running per-step snapshot, token1
    }

    /// @dev Snapshot after a step and log each party's USDC/USDT movement since the last snapshot.
    ///      Advances the running snapshot (`L.a`/`L.b`) in place. The per-party log body lives in
    ///      its own frame: with the unit's post-k/c inlining, the combined loop body pushed the
    ///      optimized via-IR frame over the stack limit.
    function _logStep(string memory label, Ledger memory L) internal {
        (int256[7] memory a, int256[7] memory b) = _snap7(L.P);
        emit log("");
        emit log(label);
        for (uint256 i = 0; i < 7; i++) {
            _logPartyDelta(L.N[i], a[i] - L.a[i], b[i] - L.b[i]);
        }
        (, int24 tk,,) = StateLibrary.getSlot0(manager, poolId);
        emit log_named_int("  -> pool tick after step", tk);
        L.a = a;
        L.b = b;
    }

    function _logPartyDelta(string memory name, int256 d0, int256 d1) internal {
        if (d0 != 0 || d1 != 0) {
            emit log_named_string("  party", name);
            emit log_named_int("    USDC (token0)", d0);
            emit log_named_int("    USDT (token1)", d1);
        }
    }

    /// @dev Pool deploy + config + governance for `_runTokenFlow`, in its own frame: the 9-arg
    ///      configurePool call site alone holds ~11 live stack items, which pushed the ledger
    ///      function's already-tight optimized via-IR frame over the limit (same class of issue
    ///      the Ledger struct itself works around — see its comment).
    function _setupFlowPool(uint16 bps) internal {
        address hookAddr = deployCoreAndHookCustomDecimals("SimHook.sol", "USDC", "USDT", 6, 6, false);
        hook = SimHook(hookAddr);
        (, _sp) = deployPool(IHooks(hookAddr), 0, 1, false);
        hook.configurePool(poolId, 10, 10, 500_000, 1 hours, 50, 2e6, 1e6);
        governance.setTreasury(TREASURY);
        if (bps > 0) governance.setProtocolFeeBps(bps);
    }

    /// @dev The 5-step sandwich with a full per-party ledger. token0 = USDC, token1 = USDT.
    ///      Frontrun and victim both BUY USDC (sell USDT), pushing price up; the attacker's
    ///      USDC-only JIT above the price fills the victim; the attacker then sells USDC back
    ///      to peg and unwinds the JIT after the 50-block lock.
    function _runTokenFlow(uint16 bps) internal {
        _setupFlowPool(bps);

        address lp = _mkTrader("baselineLP");
        address att = _mkTrader("attacker");
        address victim = _mkTrader("victim");
        address warmer = _mkTrader("warmer");
        Ledger memory L;
        L.P = [lp, att, victim, warmer, TREASURY, address(manager), address(this)];
        L.N = ["baselineLP", "attacker", "victim", "warmer", "treasury", "poolManager", "deployer"];

        // conservation baseline: BEFORE any liquidity, so LP nets to fees and manager nets ~0 at exit.
        (L.st0, L.st1) = _snap7(L.P);

        // setup: deep band tight around peg + thin USDC-only tail beyond it, then a tiny warmup.
        vm.startPrank(lp);
        LiquidityValues memory lpDeep = addLiquidity(-100, 100, 10_000e6, _sp, false); // deep [-100,100]
        int256 lpThin = _addUSDConly(100, 3000, 100e6); // ~100 USDC tail
        vm.stopPrank();
        vm.startPrank(warmer);
        swap(false, -1e6, false);
        vm.stopPrank();

        (L.a, L.b) = _snap7(L.P); // per-step running snapshot

        // STEP 1 — frontrun: attacker buys USDC through the deep band, price-limited just past it.
        vm.startPrank(att);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1_000_000e6,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(150)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();
        _logStep("STEP 1  frontrun: attacker buys USDC through the deep band to ~tick 150", L);

        // STEP 2 — JIT add: 5k USDC concentrated at a far tick so the victim fills there.
        vm.startPrank(att);
        int256 jitLiq = _addUSDConly(JTL, JTU, 5_000e6);
        vm.stopPrank();
        _logStep("STEP 2  JIT add: attacker parks 5k USDC at ~tick 1800", L);

        // STEP 3 — victim: sells 5k USDT same direction; tail is ~empty, so the JIT fills it.
        vm.startPrank(victim);
        swap(false, -5_000e6, false);
        vm.stopPrank();
        _logStep("STEP 3  victim: sells 5k USDT -> buys USDC, filled by the JIT", L);

        // STEP 4 — attacker self-rebalance: sells USDC back to peg (price-limited at _sp).
        vm.startPrank(att);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10_000_000e6, sqrtPriceLimitX96: _sp}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();
        _logStep("STEP 4  attacker rebalances: sells USDC -> buys USDT back to peg", L);

        // JIT lock is live: removing inside the 50-block window reverts (wrapped by v4).
        vm.startPrank(att);
        vm.expectRevert();
        _removeLiq(JTL, JTU, jitLiq);
        vm.stopPrank();

        // STEP 5 — roll past the lock, remove the JIT (round-tripped position + accrued fees).
        vm.roll(block.number + 60);
        vm.startPrank(att);
        _removeLiq(JTL, JTU, jitLiq);
        vm.stopPrank();
        _logStep("STEP 5  remove JIT: attacker withdraws position + LP fees (post-lock)", L);

        // settle the baseline LP out, then prove conservation over the whole sequence.
        vm.startPrank(lp);
        _removeLiq(-100, 100, lpDeep.liquidityDelta);
        _removeLiq(100, 3000, lpThin);
        vm.stopPrank();

        this.assertConservationAndTreasury(L, bps);
    }

    /// @dev Whole-sequence conservation + treasury asserts. Called EXTERNALLY (`this.`) on
    ///      purpose: an internal helper gets re-inlined by the optimized via-IR pipeline and
    ///      tips the caller's frame one slot too deep — an external self-call is a real CALL
    ///      and cannot be inlined.
    function assertConservationAndTreasury(Ledger memory L, uint16 bps) external {
        int256 sum0;
        int256 sum1;
        emit log("");
        emit log("================ NET PER PARTY (whole sequence, end - start) ================");
        for (uint256 i = 0; i < 7; i++) {
            int256 nd0 = _b0(L.P[i]) - L.st0[i];
            int256 nd1 = _b1(L.P[i]) - L.st1[i];
            emit log_named_string("party", L.N[i]);
            emit log_named_int("  USDC", nd0);
            emit log_named_int("  USDT", nd1);
            sum0 += nd0;
            sum1 += nd1;
        }
        // Every token that left one party landed at another — nothing minted, burned, or stuck.
        assertEq(sum0, 0, "USDC conserved");
        assertEq(sum1, 0, "USDT conserved");

        // Treasury only accrues when the protocol slice is on; takes hit both tokens
        // (oneForZero exact-in -> USDC output side, zeroForOne exact-in -> USDT output side).
        int256 tr0 = _b0(TREASURY) - L.st0[4];
        int256 tr1 = _b1(TREASURY) - L.st1[4];
        if (bps > 0) {
            assertGt(tr0, 0, "protocol slice lands in treasury (USDC)");
            assertGt(tr1, 0, "protocol slice lands in treasury (USDT)");
        } else {
            assertEq(tr0, 0, "no protocol fee -> no treasury USDC");
            assertEq(tr1, 0, "no protocol fee -> no treasury USDT");
        }
    }

    function test_tokenFlow_conservation_noProtocolFee() public {
        _runTokenFlow(0);
    }

    function test_tokenFlow_conservation_withProtocolFee() public {
        _runTokenFlow(500); // 5% of the dynamic fee to treasury
    }
}
