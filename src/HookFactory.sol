// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {AscntGovernance} from "./AscntGovernance.sol";

interface IHookGovernanceView {
    function governance() external view returns (address);
}

/// @title HookFactory
/// @notice CREATE2-deploys Ascnt hooks and records them as canonical protocol-deployed hooks.
contract HookFactory {
    // ------ Events ------

    event HookDeployed(address indexed hook, bytes32 indexed salt);
    event HookDeprecationChanged(address indexed hook, bool deprecated);

    // ------ State ------

    AscntGovernance public immutable governance;

    /// @dev Attests deployment through this factory — not a statement about the hook's code.
    mapping(address hook => bool verified) public isVerifiedHook;

    mapping(address hook => bool deprecated) public isDeprecatedHook;

    // ------ Errors ------

    error AddressMismatch(address expected, address actual);
    error HookNotVerified(address hook);
    error NotOwner();
    error InvalidGovernance();
    error GovernanceMismatch(address hookGovernance, address factoryGovernance);

    /// @dev Zero-check only: a factory wired to a code-less governance is inert, not dangerous.
    constructor(AscntGovernance _governance) {
        if (address(_governance) == address(0)) revert InvalidGovernance();
        governance = _governance;
    }

    modifier onlyOwner() {
        if (msg.sender != governance.owner()) revert NotOwner();
        _;
    }

    // ------ Views ------

    function owner() external view returns (address) {
        return governance.owner();
    }

    function computeAddress(bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    // ------ Deploy & Deprecate ------

    /// @dev `expectedAddress` makes the approved calldata self-verifying.
    /// @param initCode        Full init code (creation bytecode + ABI-encoded constructor args).
    /// @param salt            CREATE2 salt producing an address whose low bits match the hook's permission bits.
    /// @param expectedAddress Address the signer committed to when approving the call.
    /// @return hook           The deployed hook address (equals `expectedAddress`).
    function deployHook(
        bytes calldata initCode,
        bytes32 salt,
        address expectedAddress
    ) external onlyOwner returns (address hook) {
        hook = Create2.deploy(0, salt, initCode);
        if (hook != expectedAddress) revert AddressMismatch(expectedAddress, hook);
        // initCode carries the governance pointer: a hook wired elsewhere must not register here
        address hookGovernance = IHookGovernanceView(hook).governance();
        if (hookGovernance != address(governance)) revert GovernanceMismatch(hookGovernance, address(governance));
        isVerifiedHook[hook] = true;
        governance.registerSubscriber(hook);
        emit HookDeployed(hook, salt);
    }

    function setHookDeprecated(address hook, bool deprecated) external onlyOwner {
        if (!isVerifiedHook[hook]) revert HookNotVerified(hook);
        isDeprecatedHook[hook] = deprecated;
        emit HookDeprecationChanged(hook, deprecated);
    }
}
