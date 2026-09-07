// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Revert-on-transfer token modelling a USDC/USDT-style blacklist (or a paused token).
///
///         Only transfers whose RECIPIENT is blocked revert, which is what makes it a precise
///         probe for SETTLE-17: the protocol-fee take is the only transfer in a swap that targets
///         the treasury, so blocking the treasury isolates the settlement path while leaving every
///         other pool transfer (router settle, router take, LP add/remove) healthy.
contract Phase5BlacklistERC20 is MockERC20 {
    error Phase5Blacklisted(address account);

    mapping(address => bool) public blocked;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) MockERC20(_name, _symbol, _decimals) {}

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to] || blocked[msg.sender]) revert Phase5Blacklisted(to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (blocked[to] || blocked[from]) revert Phase5Blacklisted(to);
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Fee-on-transfer token for SETTLE-13, with TWO tax scopes:
///
///         - RECIPIENT-scoped (`setTaxedRecipient`, the default shape): only transfers to chosen
///           recipients are taxed. This is a deliberate MODELLING DEVICE, not a real token shape —
///           no shipping launch token implements it. It exists because a globally taxing token
///           cannot be paid INTO a v4 pool at all (`PoolManager._settle` credits only the
///           DELIVERED amount, so every input-side settle under-credits and reverts
///           `CurrencyNotSettled`), which would mask the hook-accounting property the SETTLE-13
///           suite pins: the manager is debited the REQUESTED `take128` while the recipient
///           receives less. Recipient scoping isolates the hook's take path from that pool-wide
///           failure — the tests built on it therefore say NOTHING about what happens when a real
///           token's fee is switched on.
///
///         - GLOBAL (`setGlobalTax(true)`): every transfer is taxed, which is what real
///           owner-settable fee mechanisms do — typically dormant at zero, applying to ALL
///           transfers once non-zero. `test_SETTLE13_globallyTaxedToken_*` uses this mode to pin
///           the real failure boundary: input-side settles revert `CurrencyNotSettled` pool-wide,
///           only output-side legs keep closing.
///
///         Semantics note vs the real tokens: this mock BURNS the fee (so tests can measure the
///         shortfall as `totalSupply` delta). Real mechanisms route it to a fee recipient or the
///         token owner instead — supply-neutral. v4's accounting cares only that the recipient receives
///         less than the sender is debited, which all three share; the burn is measurement
///         plumbing, not a fidelity claim.
contract Phase5FeeOnTransferERC20 is MockERC20 {
    uint256 public feeBps;
    bool public globalTax;
    mapping(address => bool) public taxedRecipient;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) MockERC20(_name, _symbol, _decimals) {}

    function setFeeBps(uint256 bps) external {
        require(bps <= 10_000, "fee > 100%");
        feeBps = bps;
    }

    function setTaxedRecipient(address account, bool value) external {
        taxedRecipient[account] = value;
    }

    /// @notice Globally-scoped: when enabled (and `feeBps > 0`), EVERY transfer is taxed.
    function setGlobalTax(bool value) external {
        globalTax = value;
    }

    function _tax(uint256 amount, address to) internal view returns (uint256) {
        if (feeBps == 0) return 0;
        if (!globalTax && !taxedRecipient[to]) return 0;
        return (amount * feeBps) / 10_000;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = _tax(amount, to);
        if (fee > 0) _burn(msg.sender, fee);
        return super.transfer(to, amount - fee);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = _tax(amount, to);
        if (fee > 0) {
            // spend the allowance for the full requested amount, then deliver less
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - fee;
            _burn(from, fee);
        }
        return super.transferFrom(from, to, amount - fee);
    }
}
