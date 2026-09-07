// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AscntGovernance, IProtocolFeeBpsSubscriber} from "../../src/AscntGovernance.sol";

/// @dev Local valid-timelock stub for handler rotations (duck-types `getMinDelay() > 0`).
contract P2HandlerTimelock {
    function getMinDelay() external pure returns (uint256) {
        return 2 days;
    }
}

/// @dev Timelock-shaped contract with zero delay — must always be rejected by proposeTimelock.
contract P2HandlerZeroDelayTimelock {
    function getMinDelay() external pure returns (uint256) {
        return 0;
    }
}

/// @dev Factory stub pointing back at the governance that installs it, so the one-shot
///      `setHookFactory` bootstrap passes the wired-governance duck-type.
contract P2HandlerFactory {
    address public governance;

    constructor(address gov_) {
        governance = gov_;
    }
}

/// @dev Recording subscriber: registration + pushes must land the capped governance value here.
contract P2RegSub is IProtocolFeeBpsSubscriber {
    uint16 public lastBps;
    uint256 public pushCount;

    function onProtocolFeeBpsUpdated(uint16 bps) external {
        lastBps = bps;
        pushCount++;
    }
}

/// @notice Phase-2 stateful handler over the AscntGovernance authority state machine.
///         Drives every mutator from both the correct role (resolved LIVE from the contract,
///         so owner/timelock rotations chain correctly) and from wrong-role callers. Expected
///         reverts are absorbed; any unauthorized call that unexpectedly SUCCEEDS increments
///         `unauthorizedSuccessCount`, which the invariant suite pins to zero.
contract Phase2GovHandler is Test {
    AscntGovernance public gov;
    address public immutable factoryAddr;

    address[] public actorPool; // candidate owners / pausers / deployers / treasuries
    address[] public timelockPool; // pre-deployed VALID timelocks (rotation targets)
    address public zeroDelayTl;
    address public eoaTl;
    P2RegSub[] public subPool; // candidate subscribers

    // ---- ghosts ----
    uint256 public actionCount;
    uint256 public mutationCount; // successful state-changing calls from the correct role
    uint256 public expectedRevertCount; // denied calls that reverted as required
    uint256 public unauthorizedSuccessCount; // MUST stay 0 (checked by invariant)
    uint256 public guardBypassCount; // invalid-value calls that slipped through; MUST stay 0

    constructor(AscntGovernance _gov, address _factoryAddr, address[] memory _timelockPool) {
        gov = _gov;
        factoryAddr = _factoryAddr;
        timelockPool = _timelockPool;
        zeroDelayTl = address(new P2HandlerZeroDelayTimelock());
        eoaTl = address(0xE0AE0A);

        actorPool.push(address(0xAA01));
        actorPool.push(address(0xAA02));
        actorPool.push(address(0xAA03));
        actorPool.push(address(0xAA04));

        for (uint256 i = 0; i < 5; i++) {
            subPool.push(new P2RegSub());
        }
    }

    function subPoolLength() external view returns (uint256) {
        return subPool.length;
    }

    // ------ helpers ------

    function _actor(uint256 seed) internal view returns (address) {
        return actorPool[seed % actorPool.length];
    }

    /// @dev Wrong-role caller: an actor-pool address that currently holds NO authority slot.
    function _stranger(uint256 seed) internal view returns (address) {
        uint256 start = seed % actorPool.length; // reduce first: `seed + i` overflows near 2^256
        for (uint256 i = 0; i < actorPool.length; i++) {
            address c = actorPool[(start + i) % actorPool.length];
            if (c != gov.owner() && c != gov.timelock() && c != gov.pauser() && c != factoryAddr) {
                return c;
            }
        }
        return address(0xDEADD00D); // never granted any role
    }

    // ------ correct-role actions (state machine driving) ------

    function setTreasury(uint256 seed) external {
        actionCount++;
        // Sometimes attempt zeroing the treasury — must revert iff fee > 0 (GOV-5).
        address target = seed % 4 == 0 ? address(0) : _actor(seed);
        bool feePositive = gov.protocolFeeBps() > 0;
        address tl = gov.timelock();
        vm.prank(tl);
        (bool ok,) = address(gov).call(abi.encodeCall(gov.setTreasury, (target)));
        if (ok) {
            mutationCount++;
            if (target == address(0) && feePositive) guardBypassCount++; // GOV-5 broken
        } else {
            expectedRevertCount++;
        }
    }

    function setProtocolFeeBps(uint256 seed) external {
        actionCount++;
        uint16 bps = uint16(bound(seed, 0, 2600)); // deliberately straddles the 2000 cap
        bool aboveCap = bps > gov.MAX_PROTOCOL_FEE_BPS();
        bool zeroTreasury = gov.treasury() == address(0);
        address tl = gov.timelock();
        vm.prank(tl);
        (bool ok,) = address(gov).call(abi.encodeCall(gov.setProtocolFeeBps, (bps)));
        if (ok) {
            mutationCount++;
            if (aboveCap || (bps > 0 && zeroTreasury)) guardBypassCount++; // GOV-4/GOV-5 broken
        } else {
            expectedRevertCount++;
        }
    }

    function setPoolDeployer(uint256 seed) external {
        actionCount++;
        address tl = gov.timelock();
        vm.prank(tl);
        gov.setPoolDeployer(seed % 5 == 0 ? address(0) : _actor(seed));
        mutationCount++;
    }

    function setPauser(uint256 seed) external {
        actionCount++;
        address owner = gov.owner();
        vm.prank(owner);
        gov.setPauser(seed % 5 == 0 ? address(0) : _actor(seed));
        mutationCount++;
    }

    function togglePause(uint256 seed, bool paused) external {
        actionCount++;
        // Alternate between the two legitimate authorizers.
        address pauser = gov.pauser();
        address caller = (seed % 2 == 0 || pauser == address(0)) ? gov.owner() : pauser;
        vm.prank(caller);
        gov.setAddLiquidityPaused(paused);
        mutationCount++;
    }

    function transferOwnership(uint256 seed) external {
        actionCount++;
        address tl = gov.timelock();
        vm.prank(tl);
        gov.transferOwnership(_actor(seed)); // actor pool is never address(0)
        mutationCount++;
    }

    /// @dev Full two-step rotation: nominate from the incumbent, then accept as the nominee.
    ///      Both halves must run or the campaign would stop exercising rotation entirely.
    function rotateTimelock(uint256 seed) external {
        actionCount++;
        address target = timelockPool[seed % timelockPool.length];
        address tl = gov.timelock();
        vm.prank(tl);
        gov.proposeTimelock(target);
        vm.prank(target);
        gov.acceptTimelock();
        mutationCount++;
    }

    /// @dev Nominate without accepting, leaving a live nomination behind. The incumbent must
    ///      retain full authority — this is the state an undriveable nominee would leave forever.
    function proposeTimelockOnly(uint256 seed) external {
        actionCount++;
        address target = timelockPool[seed % timelockPool.length];
        address tl = gov.timelock();
        vm.prank(tl);
        gov.proposeTimelock(target);
        mutationCount++;
    }

    /// @dev Only the nominee may accept; anyone else must revert.
    function probe_unauthorizedAccept(uint256 seed) external {
        actionCount++;
        address caller = _stranger(seed);
        if (caller == gov.pendingTimelock()) return;
        vm.prank(caller);
        (bool ok,) = address(gov).call(abi.encodeCall(gov.acceptTimelock, ()));
        if (ok) guardBypassCount++;
        else expectedRevertCount++;
    }

    function registerSubscriber(uint256 seed) external {
        actionCount++;
        address sub = address(subPool[seed % subPool.length]);
        vm.prank(factoryAddr);
        gov.registerSubscriber(sub); // idempotent by design; strict push always succeeds here
        mutationCount++;
    }

    function removeSubscriber(uint256 seed) external {
        actionCount++;
        // Sometimes a non-member — must be a silent no-op (GOV-10/11).
        address sub = seed % 4 == 0 ? address(0xB0B0D1) : address(subPool[seed % subPool.length]);
        address tl = gov.timelock();
        vm.prank(tl);
        gov.removeSubscriber(sub);
        mutationCount++;
    }

    // ------ guarded-value probes (must revert; success == invariant break) ------

    function probe_transferOwnershipToZero() external {
        actionCount++;
        address tl = gov.timelock();
        vm.prank(tl);
        (bool ok,) = address(gov).call(abi.encodeCall(gov.transferOwnership, (address(0))));
        if (ok) guardBypassCount++;
        else expectedRevertCount++;
    }

    function probe_renounceOwnership(uint256 seed) external {
        actionCount++;
        address caller = seed % 2 == 0 ? gov.owner() : _stranger(seed);
        vm.prank(caller);
        (bool ok,) = address(gov).call(abi.encodeCall(gov.renounceOwnership, ()));
        if (ok) guardBypassCount++;
        else expectedRevertCount++;
    }

    function probe_invalidTimelockRotation(uint256 seed) external {
        actionCount++;
        address target = seed % 3 == 0 ? address(0) : (seed % 3 == 1 ? eoaTl : zeroDelayTl);
        address tl = gov.timelock();
        vm.prank(tl);
        (bool ok,) = address(gov).call(abi.encodeCall(gov.proposeTimelock, (target)));
        if (ok) guardBypassCount++;
        else expectedRevertCount++;
    }

    function probe_rewireHookFactory(uint256 seed) external {
        actionCount++;
        // Even the live owner cannot re-point the factory after bootstrap (GOV-7).
        address caller = seed % 2 == 0 ? gov.owner() : _stranger(seed);
        vm.prank(caller);
        (bool ok,) = address(gov).call(abi.encodeCall(gov.setHookFactory, (_actor(seed))));
        if (ok) guardBypassCount++;
        else expectedRevertCount++;
    }

    // ------ unauthorized probes (wrong role; success == authority break) ------

    function probe_unauthorizedSlowLane(uint256 seed) external {
        actionCount++;
        address caller = _stranger(seed);
        bytes memory data;
        uint256 which = seed % 6;
        if (which == 0) data = abi.encodeCall(gov.setTreasury, (_actor(seed)));
        else if (which == 1) data = abi.encodeCall(gov.setProtocolFeeBps, (uint16(bound(seed, 0, 2000))));
        else if (which == 2) data = abi.encodeCall(gov.setPoolDeployer, (_actor(seed)));
        else if (which == 3) data = abi.encodeCall(gov.proposeTimelock, (timelockPool[seed % timelockPool.length]));
        else if (which == 4) data = abi.encodeCall(gov.transferOwnership, (_actor(seed)));
        else data = abi.encodeCall(gov.removeSubscriber, (address(subPool[seed % subPool.length])));

        vm.prank(caller);
        (bool ok,) = address(gov).call(data);
        if (ok) unauthorizedSuccessCount++;
        else expectedRevertCount++;
    }

    function probe_unauthorizedFastLane(uint256 seed) external {
        actionCount++;
        address caller = _stranger(seed);
        bytes memory data =
            seed % 2 == 0 ? abi.encodeCall(gov.setPauser, (caller)) : abi.encodeCall(gov.setAddLiquidityPaused, (true));
        vm.prank(caller);
        (bool ok,) = address(gov).call(data);
        if (ok) unauthorizedSuccessCount++;
        else expectedRevertCount++;
    }

    function probe_unauthorizedRegister(uint256 seed) external {
        actionCount++;
        // Neither strangers nor the current owner may touch the registry directly (GOV-8 support).
        address caller = seed % 2 == 0 ? _stranger(seed) : gov.owner();
        vm.prank(caller);
        (bool ok,) =
            address(gov).call(abi.encodeCall(gov.registerSubscriber, (address(subPool[seed % subPool.length]))));
        if (ok) unauthorizedSuccessCount++;
        else expectedRevertCount++;
    }
}
