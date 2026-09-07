// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IProtocolFeeBpsSubscriber {
    /// @dev Must gate on the governance caller and fit in `PUSH_GAS_STIPEND`.
    function onProtocolFeeBpsUpdated(uint16 bps) external;
}

interface ITimelockMinDelay {
    function getMinDelay() external view returns (uint256);
}

interface IHookFactoryGovernance {
    function governance() external view returns (address);
}

interface IHookFactoryAttestations {
    function isVerifiedHook(address hook) external view returns (bool);
    function isDeprecatedHook(address hook) external view returns (bool);
}

/// @title AscntGovernance
/// @notice Single point of governance for every `AscntBaseHook`.
contract AscntGovernance is Ownable {
    // ------ Events ------

    event TreasuryUpdated(address indexed treasury);
    event ProtocolFeeBpsUpdated(uint16 bps);
    event AddLiquidityPauseSet(bool paused);
    event HookAddLiquidityPauseSet(address indexed hook, bool paused);
    event PauserUpdated(address indexed pauser);
    event TimelockUpdated(address indexed timelock);
    event TimelockTransferStarted(address indexed pendingTimelock, uint48 expiry);
    event TimelockTransferCancelled(address indexed pendingTimelock);
    event PoolDeployerUpdated(address indexed poolDeployer);
    event HookFactoryUpdated(address indexed factory);
    event SubscriberRegistered(address indexed hook);
    event SubscriberRemoved(address indexed hook);
    event SubscriberPushFailed(address indexed hook, uint16 bps);

    // ------ State ------

    /// @dev `address(0)` = takes disabled; coupled to `protocolFeeBps`.
    address public treasury;
    uint16 public protocolFeeBps;
    bool public addLiquidityPaused;

    address public timelock;

    address public pendingTimelock;
    uint48 public pendingTimelockExpiry;
    /// @dev `address(0)` = role disabled.
    address public pauser;
    /// @dev `address(0)` = role disabled.
    address public poolDeployer;

    address public hookFactory;

    /// @dev Fee lifecycle, not provenance — a removed hook stays canonical.
    mapping(address hook => bool) public isSubscribedHook;

    mapping(address hook => bool) public hookAddLiquidityPaused;

    /// @dev Order not preserved (swap-and-pop).
    address[] public subscribedHooks;

    // ------ Constants ------

    /// @dev Load-bearing: `_takeProtocolFeeOnAfterSwap`'s int128 cast relies on this bound
    ///      (5x margin). Re-verify the cast before raising — KI-16.
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 2_000; // 20%

    /// @dev Counts hooks, not pools. At the cap `deployHook` fails — deliberate.
    uint256 public constant MAX_SUBSCRIBERS = 256;

    uint256 public constant PUSH_GAS_STIPEND = 50_000;

    uint256 public constant MIN_TIMELOCK_DELAY = 24 hours;

    /// @dev Liveness backstop, not a security control; the nominee's own delay is uncapped.
    uint48 public constant TIMELOCK_ACCEPT_WINDOW = 30 days;

    // ------ Errors ------

    error ProtocolFeeTooHigh();
    error TreasuryRequired();
    error NotPauserOrOwner();
    error NotTimelock();
    error InvalidTimelock();
    error NotPendingTimelock();
    error TimelockProposalExpired();
    error NotHookFactory();
    error HookFactoryAlreadySet();
    error InvalidHookFactory();
    error MaxSubscribersReached();
    error RenounceDisabled();

    constructor(
        address initialOwner,
        address initialTimelock,
        address initialPauser,
        address initialPoolDeployer
    ) Ownable(initialOwner) {
        _requireValidTimelock(initialTimelock);
        timelock = initialTimelock;
        pauser = initialPauser;
        poolDeployer = initialPoolDeployer;
        emit TimelockUpdated(initialTimelock);
        if (initialPauser != address(0)) emit PauserUpdated(initialPauser);
        if (initialPoolDeployer != address(0)) emit PoolDeployerUpdated(initialPoolDeployer);
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    /// @dev Proves delay-LIKE behaviour only, never that anyone can drive the candidate.
    function _requireValidTimelock(address tl) private view {
        if (tl == address(0)) revert InvalidTimelock();
        if (tl.code.length == 0) revert InvalidTimelock();
        try ITimelockMinDelay(tl).getMinDelay() returns (uint256 minDelay) {
            if (minDelay < MIN_TIMELOCK_DELAY) revert InvalidTimelock();
        } catch {
            revert InvalidTimelock();
        }
    }

    // ------ Bootstrap ------

    /// @dev Permanent: the factory must point back at this governance.
    function setHookFactory(address f) external onlyOwner {
        if (hookFactory != address(0)) revert HookFactoryAlreadySet();
        if (f == address(0)) revert InvalidHookFactory();
        if (f.code.length == 0) revert InvalidHookFactory();
        try IHookFactoryGovernance(f).governance() returns (address g) {
            if (g != address(this)) revert InvalidHookFactory();
        } catch {
            revert InvalidHookFactory();
        }
        hookFactory = f;
        emit HookFactoryUpdated(f);
    }

    // ------ Canonical-Hook Provenance Views ------

    /// @dev The authoritative provenance check — no hook-supplied pointer is trusted.
    function isCanonicalHook(address hook) external view returns (bool) {
        address f = hookFactory;
        if (f == address(0)) return false;
        return IHookFactoryAttestations(f).isVerifiedHook(hook);
    }

    function isCanonicalHookDeprecated(address hook) external view returns (bool) {
        address f = hookFactory;
        if (f == address(0)) return false;
        return IHookFactoryAttestations(f).isDeprecatedHook(hook);
    }

    // ------ Subscriber Registry ------

    /// @dev The initial push is deliberately NOT gas-stipended: a hook that cannot take it
    ///      must be rejected here, not drift out of sync later.
    function registerSubscriber(address hook) external {
        if (msg.sender != hookFactory) revert NotHookFactory();
        if (isSubscribedHook[hook]) return;
        if (subscribedHooks.length >= MAX_SUBSCRIBERS) revert MaxSubscribersReached();
        isSubscribedHook[hook] = true;
        subscribedHooks.push(hook);
        emit SubscriberRegistered(hook);
        IProtocolFeeBpsSubscriber(hook).onProtocolFeeBpsUpdated(protocolFeeBps);
    }

    /// @dev One-way: `registerSubscriber` is factory-only. Lands the hook add-liquidity paused.
    function removeSubscriber(address hook) external onlyTimelock {
        if (isSubscribedHook[hook]) {
            isSubscribedHook[hook] = false;
            uint256 len = subscribedHooks.length;
            for (uint256 i = 0; i < len; ++i) {
                if (subscribedHooks[i] == hook) {
                    subscribedHooks[i] = subscribedHooks[len - 1];
                    subscribedHooks.pop();
                    break;
                }
            }
            emit SubscriberRemoved(hook);
        }

        // required, not defensive: the extcodesize revert on a code-less address is not
        // catchable by the try/catch below
        if (hook.code.length > 0) {
            try IProtocolFeeBpsSubscriber(hook).onProtocolFeeBpsUpdated{gas: PUSH_GAS_STIPEND}(0) {}
            catch {
                emit SubscriberPushFailed(hook, 0);
            }
        }

        if (!hookAddLiquidityPaused[hook]) {
            hookAddLiquidityPaused[hook] = true;
            emit HookAddLiquidityPauseSet(hook, true);
        }
    }

    function subscribedHooksLength() external view returns (uint256) {
        return subscribedHooks.length;
    }

    // ------ Timelock-Gated Setters ------

    /// @dev Coupled with `setProtocolFeeBps` so a nonzero fee always has a destination.
    function setTreasury(address _treasury) external onlyTimelock {
        if (_treasury == address(0) && protocolFeeBps > 0) revert TreasuryRequired();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setProtocolFeeBps(uint16 bps) external onlyTimelock {
        if (bps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh();
        if (bps > 0 && treasury == address(0)) revert TreasuryRequired();
        protocolFeeBps = bps;
        emit ProtocolFeeBpsUpdated(bps);

        uint256 len = subscribedHooks.length;
        for (uint256 i = 0; i < len; ++i) {
            address hook = subscribedHooks[i];
            // fault-isolated: a skipped hook re-syncs via `syncProtocolFee`
            try IProtocolFeeBpsSubscriber(hook).onProtocolFeeBpsUpdated{gas: PUSH_GAS_STIPEND}(bps) {}
            catch {
                emit SubscriberPushFailed(hook, bps);
            }
        }
    }

    /// @dev Two-step so an undriveable timelock can never take the role. Not owner-gated: the
    ///      timelock is the recovery path for a compromised owner.
    function proposeTimelock(address newTimelock) external onlyTimelock {
        _requireValidTimelock(newTimelock);
        address prev = pendingTimelock;
        if (prev != address(0) && prev != newTimelock) emit TimelockTransferCancelled(prev);
        uint48 expiry = uint48(block.timestamp + TIMELOCK_ACCEPT_WINDOW);
        pendingTimelock = newTimelock;
        pendingTimelockExpiry = expiry;
        emit TimelockTransferStarted(newTimelock, expiry);
    }

    /// @dev Re-validation catches honest drift only. `getMinDelay` is `view` (STATICCALL).
    function acceptTimelock() external {
        if (msg.sender != pendingTimelock) revert NotPendingTimelock();
        if (block.timestamp > pendingTimelockExpiry) revert TimelockProposalExpired();
        _requireValidTimelock(msg.sender);
        timelock = msg.sender;
        delete pendingTimelock;
        delete pendingTimelockExpiry;
        emit TimelockUpdated(msg.sender);
    }

    function cancelTimelockTransfer() external onlyTimelock {
        address prev = pendingTimelock;
        delete pendingTimelock;
        delete pendingTimelockExpiry;
        emit TimelockTransferCancelled(prev);
    }

    function setPoolDeployer(address newDeployer) external onlyTimelock {
        poolDeployer = newDeployer;
        emit PoolDeployerUpdated(newDeployer);
    }

    /// @dev Single-step is safe because this stays timelock-callable wherever ownership sits.
    function transferOwnership(address newOwner) public override onlyTimelock {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(newOwner);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------ Pause Controls ------

    function setPauser(address _pauser) external onlyOwner {
        pauser = _pauser;
        emit PauserUpdated(_pauser);
    }

    function setAddLiquidityPaused(bool paused) external {
        if (msg.sender != owner() && msg.sender != pauser) revert NotPauserOrOwner();
        addLiquidityPaused = paused;
        emit AddLiquidityPauseSet(paused);
    }

    function setHookAddLiquidityPaused(address hook, bool paused) external {
        if (msg.sender != owner() && msg.sender != pauser) revert NotPauserOrOwner();
        hookAddLiquidityPaused[hook] = paused;
        emit HookAddLiquidityPauseSet(hook, paused);
    }

    /// @dev Global breaker OR per-hook quarantine, as one external read for hooks.
    function isAddLiquidityBlocked(address hook) external view returns (bool) {
        return addLiquidityPaused || hookAddLiquidityPaused[hook];
    }
}
