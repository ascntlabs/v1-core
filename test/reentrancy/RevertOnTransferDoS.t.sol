// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Phase5ReentrancyBase} from "./base/Phase5ReentrancyBase.sol";
import {Phase5BlacklistERC20} from "./helpers/Phase5AdversarialTokens.sol";
import {Phase5TimelockProxy} from "./helpers/Phase5TimelockProxy.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";

/// @notice SETTLE-17 — the unspecified-currency take under a hostile token is fault-isolated.
///
///         Without fault isolation a blocked treasury would brick the affected quadrants (a
///         multi-hour, timelock-recovery-only DoS). `AscntBaseHook._takeProtocolFeeOnAfterSwap`
///         wraps the direct `poolManager.take` in `try/catch`, and on failure the slice is
///         minted as ERC-6909 claims to the treasury (`ProtocolFeeTakenAsClaims`) — pure ledger
///         writes, no token call — so a hostile token cannot DoS the swap path. This suite
///         pins that contract:
///
///           - no quadrant bricks; the quadrants whose unspecified side is the hostile token
///             DEGRADE to claims settlement for exactly the amount the healthy run would take;
///           - the other quadrants keep settling real tokens;
///           - dust swaps (take rounds to 0) settle nothing of either kind;
///           - the residual OPERATIONAL risk: revenue accrues as claims (not received as tokens)
///             until governance reacts, and the governance paths that end the degraded regime
///             (`setProtocolFeeBps(0)` / `setTreasury`) are timelock-gated — asserted against the
///             proxy's ENFORCED delay, so the reaction time floor is proven, not narrated.
///
///         Fixture: both pool currencies are blacklist-capable ERC-20s; only `currency1` blocks the
///         treasury. Because a blocked RECIPIENT is the trigger, exactly the swaps whose UNSPECIFIED
///         side is `currency1` route a transfer into the blacklist, which is the honest shape of the
///         real-world risk (USDC/USDT blacklisting the treasury address, or the token pausing).
contract Phase5RevertOnTransferDoSTest is Phase5ReentrancyBase {
    using StateLibrary for IPoolManager;

    Phase5BlacklistERC20 internal token0;
    Phase5BlacklistERC20 internal token1;

    address internal constant TREASURY_2 = address(0x7EA52);

    uint24 internal constant MIN_MIN_FEE = 100;
    uint24 internal constant MAX_MIN_FEE = 500;
    uint24 internal constant MAX_FEE = 200_000;
    uint256 internal constant DECAY = 1 hours;
    uint16 internal constant BPS = 1_000; // 10%
    uint16 internal constant CAP_BPS = 2_000;

    int256 internal constant AMOUNT = 5e19;

    function setUp() public {
        _deployProtocol();

        Phase5BlacklistERC20 a = new Phase5BlacklistERC20("Phase5BlA", "P5BA", 18);
        Phase5BlacklistERC20 b = new Phase5BlacklistERC20("Phase5BlB", "P5BB", 18);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        _useTokens(address(a), address(b));
        token0 = Phase5BlacklistERC20(Currency.unwrap(currency0));
        token1 = Phase5BlacklistERC20(Currency.unwrap(currency1));

        (key, poolId) = _initAndConfigure(1, 0, MIN_MIN_FEE, MAX_MIN_FEE, MAX_FEE, DECAY, 0);
        _addLiquidity(key, TICK_LOWER, TICK_UPPER, 1e21);
        _enableProtocolFee(BPS, TREASURY);

        // warm-up swap while the token is still healthy
        _swap(key, true, -2e19);

        // the treasury gets blacklisted by currency1
        token1.setBlocked(TREASURY, true);
    }

    /// @dev The blocked-side settlement DEGRADES to claims instead of bricking: the swap succeeds
    ///      (`_swap` reverts the test otherwise), exactly one `ProtocolFeeTakenAsClaims` and no
    ///      `ProtocolFeeTaken` fires, the treasury's ERC-6909 claim balance grows by exactly the
    ///      requested amount, and no real tokens reach the blocked treasury.
    function _assertSettlesAsClaims(
        bool zeroForOne,
        int256 amount,
        string memory label
    ) internal returns (uint128 takeAmount) {
        uint256 claimsBefore = _claimsBalance(TREASURY, currency1);
        uint256 tokensBefore = token1.balanceOf(TREASURY);

        (, Vm.Log[] memory logs) = _swap(key, zeroForOne, amount); // no brick: a revert fails the test here

        TakeEvent[] memory claims = _claimsEvents(logs);
        assertEq(claims.length, 1, label);
        assertEq(_takeEvents(logs).length, 0, "no real-token take may fire on the blocked side");
        takeAmount = claims[0].amount1;
        assertGt(takeAmount, 0, "the degraded take must be non-zero or nothing is measured");
        assertEq(_claimsBalance(TREASURY, currency1) - claimsBefore, takeAmount, "claims minted == the requested take");
        assertEq(token1.balanceOf(TREASURY), tokensBefore, "no real tokens delivered to the blocked treasury");
    }

    // =====================================================================================
    // degradation radius (was: blast radius, pre-hardening)
    // =====================================================================================

    /// @notice SETTLE-17: both quadrants whose UNSPECIFIED currency is the blacklisting token
    ///         degrade to claims — exact-input zeroForOne (unspecified = output = currency1) and
    ///         exact-output oneForZero (unspecified = input = currency1) — and the degraded amount
    ///         is byte-identical to the take the same swap settles with a healthy treasury.
    function test_SETTLE17_blacklistedTreasury_unspecifiedSideDegradesToClaims() public {
        // healthy control: same state, treasury unblocked => real-token take, and its amount
        uint256 snap = vm.snapshotState();
        token1.setBlocked(TREASURY, false);
        (, Vm.Log[] memory refLogs) = _swap(key, true, -AMOUNT);
        TakeEvent[] memory refTakes = _takeEvents(refLogs);
        assertEq(refTakes.length, 1, "healthy control settles a real-token take");
        uint128 refTake = refTakes[0].amount1;
        assertGt(refTake, 0, "control take must be non-zero or the comparison is vacuous");
        vm.revertToState(snap);

        uint128 degraded = _assertSettlesAsClaims(true, -AMOUNT, "exact-in zeroForOne degrades to claims");
        assertEq(degraded, refTake, "degraded amount == the healthy run's requested take");

        _assertSettlesAsClaims(false, int256(1e19), "exact-out oneForZero degrades to claims");
    }

    /// @notice The DoS is partial, not total: the two quadrants whose unspecified currency is the
    ///         healthy token keep working. A monitoring/runbook fact — a blacklisted treasury does
    ///         not necessarily halt the pool, it halts one side of it.
    function test_SETTLE17_quadrantsOnTheHealthySideStillSwap() public {
        (bool ok1,) = _trySwap(key, false, -AMOUNT); // exact-in oneForZero  => unspecified currency0
        assertTrue(ok1, "exact-in oneForZero takes from the healthy token");

        (bool ok2,) = _trySwap(key, true, int256(1e19)); // exact-out zeroForOne => unspecified currency0
        assertTrue(ok2, "exact-out zeroForOne takes from the healthy token");

        assertGt(token0.balanceOf(TREASURY), 0, "healthy-side takes really landed");
    }

    /// @notice The DoS boundary is the ROUNDING branch inside the take: a swap whose slice rounds
    ///         to zero performs NO transfer (`AscntBaseHook.sol:180`) and therefore survives the
    ///         blacklist. Attribution is asserted, not assumed — the protocol fee is ON, the pool
    ///         stashed a NON-ZERO rate for this very swap, and yet no `ProtocolFeeTaken` fires. That
    ///         rules out "the swap survived because the fee happened to be off".
    function test_SETTLE17_dustSwap_takeRoundsToZero_survivesBlacklist() public {
        assertGt(hook.protocolFeeBps(), 0, "the protocol fee must be ON or the survival is trivial");
        assertTrue(governance.treasury() != address(0), "and a treasury must be set");

        // (the warmup swap in setUp ran before the blacklist, so the treasury is not empty)
        uint256 treasuryBefore = token1.balanceOf(TREASURY);

        (, Vm.Log[] memory logs) = _swap(key, true, -1);

        // the stashed rate for THIS swap was non-zero: the no-op came from `take == 0`, not
        // from `hookFee == 0` / `treasury == 0` (the other two early returns in the same function)
        BeforeSwapEvent[] memory bs = _beforeSwapEvents(logs);
        assertEq(bs.length, 1);
        uint24 stashedRate = uint24((uint256(bs[0].dynamicFeePips) * BPS) / 10_000);
        assertGt(stashedRate, 0, "a non-zero protocol rate was stashed for the dust swap");

        assertEq(_takeEvents(logs).length, 0, "no ProtocolFeeTaken at all - the transfer never happened");
        assertEq(token1.balanceOf(TREASURY), treasuryBefore, "nothing was delivered to the blocked treasury");
    }

    /// @notice FIXTURE PROPERTY, not a hook property (kept as a runbook fact, deliberately NOT
    ///         tagged SETTLE-17): LP add/remove move tokens only between the test contract, the
    ///         modifyLiquidity router and the PoolManager — never the treasury — so the
    ///         recipient-scoped blacklist cannot touch them. The pass is guaranteed by the mock's
    ///         construction; what it documents is that the hook takes protocol fees at SWAP time
    ///         only, so a blacklisted treasury does not trap LPs.
    function test_fixture_liquidityOperationsNeverTouchTheTreasury() public {
        // add
        _addLiquidity(key, TICK_LOWER, TICK_UPPER, 1e20);

        // remove (jitLockBlocks == 0 for this pool, so no JIT gate interferes)
        (uint128 posLiq,,) =
            manager.getPositionInfo(poolId, address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
        assertGt(posLiq, 0);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: -int256(uint256(posLiq)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        (uint128 posAfter,,) =
            manager.getPositionInfo(poolId, address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
        assertEq(posAfter, 0, "LP exited while swaps are bricked");
    }

    /// @notice SETTLE-17 fuzzed over the protocol rate, the trade size and the elapsed time: the
    ///         degradation radius is a function of whether the take TRANSFERS, not of any
    ///         particular parameterisation. For each run the same swap is first executed with the
    ///         treasury un-blacklisted (same state, via snapshot) to learn the take it would
    ///         settle; the blacklisted run must then mint exactly that amount as claims when it is
    ///         non-zero, and settle nothing of either kind when it rounds to zero. Conservation:
    ///         real-token delta + claims delta always equals the healthy run's take.
    function testFuzz_SETTLE17_degradationTracksTheTakeNotTheParameters(
        uint16 bpsSeed,
        uint256 sizeSeed,
        uint256 dtSeed
    ) public {
        uint16 bps = uint16(bound(uint256(bpsSeed), 0, CAP_BPS));
        int256 amount = -int256(bound(sizeSeed, 1, 1e20));
        vm.warp(block.timestamp + bound(dtSeed, 0, 2 * DECAY));
        _setProtocolFeeBps(bps);

        // reference run: identical state, treasury temporarily un-blacklisted
        uint256 snap = vm.snapshotState();
        token1.setBlocked(TREASURY, false);
        (, Vm.Log[] memory refLogs) = _swap(key, true, amount);
        uint256 refTake = _takeAmountOrZero(refLogs, poolId);
        vm.revertToState(snap);

        assertTrue(token1.blocked(TREASURY), "the blacklist is back in place for the real run");
        uint256 claimsBefore = _claimsBalance(TREASURY, currency1);
        uint256 tokensBefore = token1.balanceOf(TREASURY);

        (, Vm.Log[] memory logs) = _swap(key, true, amount); // never bricks

        if (refTake > 0) {
            TakeEvent[] memory claims = _claimsEvents(logs);
            assertEq(claims.length, 1, "a settling take on the blocked side degrades to claims");
            assertEq(claims[0].amount1, refTake, "degraded amount == the healthy run's take");
            assertEq(
                _claimsBalance(TREASURY, currency1) - claimsBefore, refTake, "claims ledger grew by exactly the take"
            );
        } else {
            assertEq(_claimsEvents(logs).length, 0, "a take that transfers nothing mints nothing");
            assertEq(_claimsBalance(TREASURY, currency1), claimsBefore, "claims ledger untouched");
        }
        assertEq(_takeEvents(logs).length, 0, "no real-token take on the blocked side either way");
        assertEq(token1.balanceOf(TREASURY), tokensBefore, "no real tokens reach the blocked treasury");
    }

    // =====================================================================================
    // ending the DEGRADED regime: slow lane only — and the slow lane COSTS the delay
    //
    // Post-hardening, liveness never needs recovering. What the timelock delay now bounds is
    // how long revenue keeps accruing as claims instead of real tokens. Both vectors run
    // through the proxy's delay-ENFORCING schedule/execute pair (not the instant `exec` lane
    // the reentrancy vectors use), so the reaction-time floor is asserted against an
    // enforced clock, not narrated. Full OZ TimelockController semantics live in
    // test/timelock/.
    // =====================================================================================

    /// @notice Disabling the protocol fee (timelock-gated) ends the degraded regime: no stash =>
    ///         no take of either kind. Swaps are live the ENTIRE time (fault isolation guarantees
    ///         that); the disable is scheduled, provably cannot execute early (down to the last
    ///         second of the window), claims keep accruing for the whole delay, and only the
    ///         matured execute stops the accrual. Stranded claims persist for later redemption.
    function test_SETTLE17_slowLaneFeeDisable_endsClaimsAccrual() public {
        _assertSettlesAsClaims(true, -AMOUNT, "degrading to claims before recovery");

        bytes memory disable = abi.encodeCall(AscntGovernance.setProtocolFeeBps, (0));
        timelockProxy.schedule(address(governance), disable);

        // scheduling alone changes nothing, and the delay is enforced rather than stylistic
        vm.expectPartialRevert(Phase5TimelockProxy.Phase5DelayNotElapsed.selector);
        timelockProxy.execute(address(governance), disable);
        _assertSettlesAsClaims(true, -AMOUNT, "still accruing claims the moment the op is scheduled");

        // vm.getBlockTimestamp(): opaque reads so the two consecutive warps accumulate exactly onto
        // the scheduled eta — the via-IR optimizer would fold bare block.timestamp across vm.warp.
        vm.warp(vm.getBlockTimestamp() + timelockProxy.MIN_DELAY() - 1);
        vm.expectPartialRevert(Phase5TimelockProxy.Phase5DelayNotElapsed.selector);
        timelockProxy.execute(address(governance), disable);
        _assertSettlesAsClaims(true, -AMOUNT, "still accruing claims for the whole delay window");

        vm.warp(vm.getBlockTimestamp() + 1); // opaque read: lands exactly on eta (TIMESTAMP-fold hazard)
        timelockProxy.execute(address(governance), disable);
        assertEq(hook.protocolFeeBps(), 0, "disable pushed into the hook cache");

        uint256 claimsBefore = _claimsBalance(TREASURY, currency1);
        uint256 tokensBefore = token1.balanceOf(TREASURY);

        (, Vm.Log[] memory logs) = _swap(key, true, -AMOUNT);
        assertEq(_takeEvents(logs).length, 0, "no real-token take once the fee is off");
        assertEq(_claimsEvents(logs).length, 0, "and no claims accrual either");
        assertEq(_claimsBalance(TREASURY, currency1), claimsBefore, "stranded claims persist untouched");
        assertEq(token1.balanceOf(TREASURY), tokensBefore, "and no tokens move");
    }

    /// @notice Rotating the treasury (timelock-gated) ends the degraded regime at the enforced
    ///         delay: post-rotation takes land as real tokens at the new address, the old
    ///         treasury's stranded claims persist — and, the redemption escape hatch, the old
    ///         treasury moves its claims to a clean address with a DIRECT ERC-6909 transfer (no
    ///         unlock needed), permanently out of the blacklist's reach.
    function test_SETTLE17_slowLaneTreasuryRotation_redirectsTakesAndFreesClaims() public {
        uint128 stranded = _assertSettlesAsClaims(true, -AMOUNT, "degrading to claims before recovery");

        bytes memory rotate = abi.encodeCall(AscntGovernance.setTreasury, (TREASURY_2));
        timelockProxy.schedule(address(governance), rotate);

        vm.expectPartialRevert(Phase5TimelockProxy.Phase5DelayNotElapsed.selector);
        timelockProxy.execute(address(governance), rotate);
        _assertSettlesAsClaims(true, -AMOUNT, "still accruing claims while the delay runs");

        vm.warp(block.timestamp + timelockProxy.MIN_DELAY());
        timelockProxy.execute(address(governance), rotate);

        (, Vm.Log[] memory logs) = _swap(key, true, -AMOUNT);
        TakeEvent[] memory takes = _takeEvents(logs);
        assertEq(takes.length, 1, "real-token take fires again");
        assertEq(takes[0].treasury, TREASURY_2);
        assertEq(token1.balanceOf(TREASURY_2), takes[0].amount1, "rotated treasury receives the slice");
        assertEq(_claimsEvents(logs).length, 0, "no more claims accrual after rotation");

        // the stranded claims survived rotation and exit via a direct 6909 transfer
        uint256 oldClaims = _claimsBalance(TREASURY, currency1);
        assertGe(oldClaims, stranded, "stranded claims persisted through rotation");
        vm.prank(TREASURY);
        manager.transfer(TREASURY_2, CurrencyLibrary.toId(currency1), oldClaims);
        assertEq(_claimsBalance(TREASURY_2, currency1), oldClaims, "claims moved to a clean address");
        assertEq(_claimsBalance(TREASURY, currency1), 0, "nothing left in the blacklisted name");
    }

    /// @notice The fast lanes are simply UNAFFECTED. `setProtocolFeeBps` /
    ///         `setTreasury` remain timelock-only (the owner Safe cannot end the degraded regime
    ///         instantly — the reaction-time floor is real), the pauser lane only gates
    ///         ADD-liquidity, and none of it threatens liveness: swaps keep settling as claims
    ///         throughout. The fast lanes do not matter to liveness; they only shape how long
    ///         claims keep accruing.
    function test_SETTLE17_fastLanesUnaffected_swapsStayLive() public {
        // owner == this test contract, timelock == the proxy
        assertEq(governance.owner(), address(this));
        assertTrue(governance.timelock() != address(this));

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        governance.setProtocolFeeBps(0);

        vm.expectRevert(AscntGovernance.NotTimelock.selector);
        governance.setTreasury(TREASURY_2);

        // the pauser lane works, gates only add-liquidity, and swaps stay live through it
        vm.prank(PAUSER);
        governance.setAddLiquidityPaused(true);
        assertTrue(governance.addLiquidityPaused());

        _assertSettlesAsClaims(true, -AMOUNT, "swaps keep settling as claims while adds are paused");

        // the permissionless cache re-sync changes nothing: it re-reads the same authoritative
        // value, so the regime is unchanged
        hook.syncProtocolFee();
        assertEq(hook.protocolFeeBps(), BPS);
        _assertSettlesAsClaims(true, -AMOUNT, "syncProtocolFee does not change the regime");
    }
}
