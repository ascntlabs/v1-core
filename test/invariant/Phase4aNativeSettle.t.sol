// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {SimHookUtils} from "../utils/SimHookUtils.sol";
import {NativeEthPoolConfig} from "../lib/PoolConfigs.sol";
import {P4Ev, P4NonPayableTreasury} from "./helpers/P4Helpers.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice XSUB-6: native-ETH settlement of the protocol take, on a shipping-shaped native pool
///         (currency0 == address(0), ETH/DAI). Two quadrants take NATIVE ETH to the treasury
///         (exact-in oneForZero: ETH output; exact-out zeroForOne: ETH input); the other two take
///         the ERC-20. All four must close the unlock and credit the treasury by exactly the
///         emitted take.
///
///         Native-ETH sibling of SETTLE-17: a non-payable treasury does not brick the native
///         side. `AscntBaseHook._takeProtocolFeeOnAfterSwap` wraps the direct
///         `poolManager.take` in try/catch and, when the native-ETH transfer to a non-payable
///         treasury reverts, mints the slice as ERC-6909 claims to the treasury
///         (`ProtocolFeeTakenAsClaims`, native currency id 0) — the swap SURVIVES. The DoS test
///         below pins that degraded-but-live behavior.
contract Phase4aNativeSettleTest is SimHookUtils {
    address internal constant TREASURY = address(0xBEEF);

    address internal dai;

    function setUp() public {
        NativeEthPoolConfig cfg = new NativeEthPoolConfig();
        (, uint160 initSqrtP) = setupSimHookAndPool(cfg, false);
        addLiquidity(78000, 81000, 10 ether, initSqrtP, false);
        governance.setTreasury(TREASURY);
        governance.setProtocolFeeBps(2000);
        dai = Currency.unwrap(key.currency1);
        swap(true, -0.05 ether, false); // prime the latch (its ERC-20 take goes to TREASURY)
    }

    /// @dev Runs one quadrant through the TestUtils swap helper (handles msg.value for native
    ///      input sides) and asserts: exactly one take, event amount in the unspecified slot,
    ///      and the treasury credited in exactly that currency by exactly that amount.
    function _quadrant(bool zeroForOne, bool exactOut, int256 amountSpecified) internal {
        uint256 tEth = TREASURY.balance;
        uint256 tDai = MockERC20(dai).balanceOf(TREASURY);

        (, Vm.Log[] memory logs) = swap(zeroForOne, amountSpecified, false);
        P4Ev.FeeTakenEv[] memory takes = P4Ev.feeTakes(logs);
        assertEq(takes.length, 1, "quadrant must produce exactly one take");

        bool exactInput = !exactOut;
        bool unspecIsNative = (exactInput != zeroForOne); // currency0 == native ETH
        uint256 dEth = TREASURY.balance - tEth;
        uint256 dDai = MockERC20(dai).balanceOf(TREASURY) - tDai;

        if (unspecIsNative) {
            assertGt(uint256(takes[0].amount0), 0, "native take must sit in the currency0 slot");
            assertEq(uint256(takes[0].amount1), 0, "currency1 slot must be zero on a native take");
            assertEq(dEth, uint256(takes[0].amount0), "treasury ETH delta != emitted native take");
            assertEq(dDai, 0, "ERC-20 credited on a native-take quadrant");
        } else {
            assertGt(uint256(takes[0].amount1), 0, "ERC-20 take must sit in the currency1 slot");
            assertEq(uint256(takes[0].amount0), 0, "currency0 slot must be zero on an ERC-20 take");
            assertEq(dDai, uint256(takes[0].amount1), "treasury DAI delta != emitted take");
            assertEq(dEth, 0, "ETH credited on an ERC-20-take quadrant");
        }
    }

    /// @notice All four direction/exactness quadrants settle and credit the treasury exactly —
    ///         including both NATIVE-ETH take paths of the shipping launch shape.
    function test_xsub6_allFourQuadrantsSettleAndCreditTreasury() public {
        _quadrant(true, false, -1 ether); // exact-in  ETH->DAI: ERC-20 take (DAI out)
        _quadrant(false, false, -2000e18); // exact-in  DAI->ETH: NATIVE take (ETH out)
        _quadrant(true, true, int256(1000e18)); // exact-out DAI: NATIVE take (ETH in)
        _quadrant(false, true, int256(0.5 ether)); // exact-out ETH: ERC-20 take (DAI in)
    }

    /// @notice XSUB-6: a treasury that cannot receive ETH does not brick the native side — the
    ///         native take DEGRADES to ERC-6909 claims (native currency id 0) and the swap
    ///         SURVIVES. The degraded amount is byte-identical to what a payable treasury takes
    ///         as real ETH; no ETH reaches the non-payable treasury; the ERC-20 quadrant keeps
    ///         settling real tokens to it; and rotating back to a payable treasury (slow-lane
    ///         setTreasury in production) restores real-ETH settlement.
    function test_xsub6_nonPayableTreasuryNativeSideDegradesToClaims() public {
        // healthy control: SAME state, a payable treasury (0xBEEF) => a REAL native-ETH take, and
        // its amount, learned via snapshot so the degraded run starts from identical state.
        uint256 snap = vm.snapshotState();
        (, Vm.Log[] memory refLogs) = swap(false, -100e18, false); // exact-in DAI->ETH: native (ETH) take
        P4Ev.FeeTakenEv[] memory refTakes = P4Ev.feeTakes(refLogs);
        assertEq(refTakes.length, 1, "control settles exactly one real native take");
        uint128 refTake = refTakes[0].amount0;
        assertGt(refTake, 0, "control native take must be non-zero or the comparison is vacuous");
        assertEq(uint256(refTakes[0].amount1), 0, "control native take sits in the currency0 slot only");
        vm.revertToState(snap);

        // degraded run: a non-payable treasury. The direct native `poolManager.take` reverts and
        // the slice falls back to ERC-6909 claims — the swap must not brick.
        P4NonPayableTreasury np = new P4NonPayableTreasury();
        governance.setTreasury(address(np));
        uint256 claimsBefore = manager.balanceOf(address(np), 0); // native currency id == 0

        // no brick: `swap` bubbles any revert and fails the test right here.
        (, Vm.Log[] memory logs) = swap(false, -100e18, false);

        // the swap ran to completion (afterSwap emitted) — positive survival proof, not just "no revert".
        assertEq(P4Ev.afterSwaps(logs).length, 1, "the swap completed and emitted AfterSwap");

        // exactly one ProtocolFeeTakenAsClaims on the native (currency0) side; ProtocolFeeTaken does NOT fire.
        P4Ev.FeeTakenEv[] memory claims = P4Ev.feeTakesAsClaims(logs);
        assertEq(claims.length, 1, "native take degrades to exactly one claims settlement");
        assertEq(P4Ev.feeTakes(logs).length, 0, "no real-token ProtocolFeeTaken on the non-payable native side");
        uint128 take = claims[0].amount0;
        assertGt(take, 0, "the degraded native take must be non-zero or nothing is measured");
        assertEq(uint256(claims[0].amount1), 0, "native claims sit in the currency0 slot only");
        assertEq(take, refTake, "degraded native amount == the payable run's real take");

        // treasury credited in native ERC-6909 claims (id 0) by exactly the take; no real ETH delivered.
        assertEq(
            manager.balanceOf(address(np), 0) - claimsBefore, take, "native claims ledger grew by exactly the take"
        );
        assertEq(address(np).balance, 0, "no real ETH delivered to the non-payable treasury");

        // the ERC-20-take quadrant still settles REAL tokens (a contract can hold ERC-20).
        uint256 npDai = MockERC20(dai).balanceOf(address(np));
        (, Vm.Log[] memory erc20Logs) = swap(true, -0.05 ether, false); // exact-in ETH->DAI: ERC-20 (DAI) take
        P4Ev.FeeTakenEv[] memory erc20Takes = P4Ev.feeTakes(erc20Logs);
        assertEq(erc20Takes.length, 1, "ERC-20 quadrant settles exactly one real-token take");
        assertGt(uint256(erc20Takes[0].amount1), 0, "ERC-20 take sits in the currency1 slot");
        assertEq(P4Ev.feeTakesAsClaims(erc20Logs).length, 0, "the non-native quadrant does not degrade to claims");
        assertEq(
            MockERC20(dai).balanceOf(address(np)) - npDai,
            uint256(erc20Takes[0].amount1),
            "non-payable treasury still receives real ERC-20 by exactly the take"
        );

        // recovery: rotate to a payable treasury — the native side settles REAL ETH again, no claims.
        governance.setTreasury(TREASURY);
        uint256 tEth = TREASURY.balance;
        (, Vm.Log[] memory healLogs) = swap(false, -100e18, false);
        P4Ev.FeeTakenEv[] memory healTakes = P4Ev.feeTakes(healLogs);
        assertEq(healTakes.length, 1, "native take settles a real ETH take after rotation");
        assertGt(healTakes[0].amount0, 0, "post-rotation real native take is non-zero");
        assertEq(P4Ev.feeTakesAsClaims(healLogs).length, 0, "no claims fallback once the treasury is payable");
        assertEq(
            TREASURY.balance - tEth, healTakes[0].amount0, "payable treasury receives real ETH by exactly the take"
        );
    }
}
