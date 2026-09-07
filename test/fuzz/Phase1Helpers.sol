// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {SimHookHarness} from "../harness/SimHookHarness.sol";
import {AscntGovernance} from "../../src/AscntGovernance.sol";
import {HookFlags} from "../../script/utils/HookFlags.sol";

/// @notice Phase-1 local mock PoolManager. Implements ONLY `take` (the single external manager
///         call `_takeProtocolFeeOnAfterSwap` makes); every other selector reverts because there
///         is no fallback — which doubles as a proof that the settle path touches nothing else
///         on the manager. Records every take so tests can assert amount/currency/recipient.
contract Phase1MockManager {
    struct TakeCall {
        Currency currency;
        address to;
        uint256 amount;
    }

    TakeCall[] public takes;

    function take(Currency currency, address to, uint256 amount) external {
        takes.push(TakeCall({currency: currency, to: to, amount: amount}));
    }

    function takeCount() external view returns (uint256) {
        return takes.length;
    }

    function lastTake() external view returns (TakeCall memory) {
        require(takes.length > 0, "no takes recorded");
        return takes[takes.length - 1];
    }
}

/// @notice Phase-1 subclass of the shared `SimHookHarness` (scaffolding is read-only for this
///         team, so extra exposure lives here). Adds:
///         - `exposedTakeProtocolFeeOnAfterSwap`: direct call into the REAL settle math
///           (`AscntBaseHook._takeProtocolFeeOnAfterSwap`) for the SETTLE-4/7/8 stateless fuzz.
///         - raw full-word read/write of the per-pool transient hookFee stash slot for SETTLE-18
///           (clean-word round-trip; dirty-pre-state overwrite).
///         Adds NO hook callbacks, so the permission bits — and hence the valid deploy address —
///         are identical to `SimHook` / `SimHookHarness`.
contract Phase1TakeHarness is SimHookHarness {
    /// @dev Mirror of `AscntBaseHook._HOOK_FEE_STASH` (private in src). Same tripwire rationale
    ///      as `SimHookHarness.HOOK_FEE_STASH`: if the src constant changes, the raw-word tests
    ///      diverge loudly.
    bytes32 private constant P1_HOOK_FEE_STASH = keccak256("ascnt.protocolfee.hookfee.v1");

    constructor(IPoolManager _manager, AscntGovernance _governance) SimHookHarness(_manager, _governance) {}

    /// @notice Direct entry into the real afterSwap protocol-fee settle path.
    function exposedTakeProtocolFeeOnAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        PoolId poolId
    ) external returns (int128 hookDeltaUnspecified) {
        return _takeProtocolFeeOnAfterSwap(key, params, swapDelta, poolId);
    }

    function stashSlot(PoolId poolId) public pure returns (bytes32 slot) {
        slot = keccak256(abi.encode(PoolId.unwrap(poolId), P1_HOOK_FEE_STASH));
    }

    /// @notice Read the FULL 32-byte word at the stash slot (no uint24 narrowing) so tests can
    ///         assert the real writer leaves no dirty high bits (SETTLE-18).
    function readRawStashWord(PoolId poolId) external view returns (bytes32 raw) {
        bytes32 slot = stashSlot(poolId);
        assembly ("memory-safe") {
            raw := tload(slot)
        }
    }

    /// @notice Write an arbitrary FULL word to the stash slot — simulates a hypothetical dirty
    ///         prior transient write that production code can never produce (the only writer is
    ///         `_stashHookFee` with a clean uint24). Used to prove the real writer fully
    ///         overwrites dirty pre-state (SETTLE-18).
    function writeRawStashWord(PoolId poolId, bytes32 raw) external {
        bytes32 slot = stashSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, raw)
        }
    }
}

/// @notice Shared light-weight base for the Phase-1 stateless-fuzz suites. Deploys a real
///         `AscntGovernance` (test contract = owner AND timelock, matching the `TestUtils`
///         pattern) and the `Phase1TakeHarness` at the flag-valid hook address, wired to the
///         `Phase1MockManager` — no PoolManager / routers / tokens needed for pure-math fuzzing.
abstract contract Phase1FuzzBase is Test {
    uint256 internal constant PIPS_SCALE = 1e6;
    uint256 internal constant BPS_SCALE = 10_000;
    uint16 internal constant MAX_PROTOCOL_FEE_BPS = 2_000; // AscntGovernance cap
    /// @dev Max reachable stashed hookFee: floor(MAX_LP_FEE(1e6) * 2000 / 10000) = 200_000 pips.
    uint24 internal constant MAX_REACHABLE_HOOK_FEE = 200_000;
    uint24 internal constant MAX_LP_FEE = 1_000_000; // LPFeeLibrary.MAX_LP_FEE

    Phase1MockManager internal p1Manager;
    AscntGovernance internal p1Governance;
    Phase1TakeHarness internal harness;

    address internal constant TREASURY = address(0x7E5);

    PoolId internal constant PID_A = PoolId.wrap(bytes32(uint256(0xA)));
    PoolId internal constant PID_B = PoolId.wrap(bytes32(uint256(0xB)));

    /// @dev Lets `address(this)` satisfy `AscntGovernance`'s timelock duck-type check.
    function getMinDelay() external pure returns (uint256) {
        return 1 days;
    }

    function setUp() public virtual {
        p1Manager = new Phase1MockManager();
        p1Governance = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance",
                abi.encode(address(this), address(this), address(0), address(0))
            )
        );

        address hookAddress = address(uint160(HookFlags.simHookMask()));
        deployCodeTo(
            "Phase1Helpers.sol:Phase1TakeHarness",
            abi.encode(IPoolManager(address(p1Manager)), p1Governance),
            hookAddress
        );
        harness = Phase1TakeHarness(hookAddress);

        // Test contract is the timelock, so the slow-lane setter can be called directly.
        p1Governance.setTreasury(TREASURY);
    }

    /// @dev Drive an EXACT hookFee value into the transient stash through the REAL writer
    ///      (`_computeProtocolFeeSplit` -> `_stashHookFee`): with protBps = 10000 (100%),
    ///      hookFee = floor(dynamicFee * 10000 / 10000) = dynamicFee exactly. `harnessSetProtocolFeeBps`
    ///      bypasses the governance 2000-bps cap by design (boundary probing).
    ///
    ///      REQUIRES a live `governance.treasury()` (setUp wires `TREASURY`). The split reads the
    ///      treasury and carves nothing when it is unset, so a caller that clears the treasury
    ///      first would silently stash 0 — clear it AFTER priming, not before.
    function _stashExactHookFee(PoolId pid, uint24 hookFee) internal {
        harness.harnessSetProtocolFeeBps(10_000);
        uint24 lpFee = harness.exposedComputeProtocolFeeSplit(pid, hookFee);
        assertEq(lpFee, 0, "sanity: 100% split leaves lpFee 0");
        assertEq(harness.readStash(pid), hookFee, "sanity: stash == requested hookFee");
    }

    /// @dev Build a PoolKey with distinct marker currencies so tests can assert WHICH currency
    ///      the settle path took from. Token addresses are inert (mock manager never transfers).
    function _key() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0xC0)),
            currency1: Currency.wrap(address(0xC1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }

    function _swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory p) {
        p = SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
    }
}
