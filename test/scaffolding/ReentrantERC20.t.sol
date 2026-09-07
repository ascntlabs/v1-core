// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrantERC20} from "../mocks/ReentrantERC20.sol";

/// @dev Minimal reentry sink for the smoke test.
contract Sink {
    uint256 public hits;

    function poke() external {
        hits++;
    }

    function boom() external pure {
        revert("boom");
    }
}

/// @notice Phase-0 smoke test: proves the reentrant token behaves as a plain ERC20 when disarmed
///         and fires its callback exactly once (with the one-shot guard) when armed.
contract ReentrantERC20SmokeTest is Test {
    ReentrantERC20 internal token;
    Sink internal sink;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new ReentrantERC20("Reentrant", "RE", 18);
        sink = new Sink();
        token.mint(alice, 1_000e18);
    }

    function test_disarmed_behavesAsPlainERC20() public {
        vm.prank(alice);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(bob), 100e18);
        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.reenterCount(), 0);
    }

    function test_armed_firesCallbackOnceAndTransfersStillSettle() public {
        token.arm(address(sink), abi.encodeCall(Sink.poke, ()), true, false, true);

        vm.prank(alice);
        token.transfer(bob, 100e18);

        // callback fired exactly once (one-shot guard prevents recursion)
        assertEq(sink.hits(), 1, "callback should fire once");
        assertEq(token.reenterCount(), 1, "reenterCount");
        // and the transfer itself still settled
        assertEq(token.balanceOf(bob), 100e18, "transfer settled");
        assertEq(token.balanceOf(alice), 900e18);
    }

    function test_armed_bubblesNestedRevert() public {
        token.arm(address(sink), abi.encodeCall(Sink.boom, ()), true, false, true);
        vm.prank(alice);
        vm.expectRevert(bytes("boom"));
        token.transfer(bob, 1e18);
    }

    function test_armed_swallowsNestedRevertWhenNotBubbling() public {
        token.arm(address(sink), abi.encodeCall(Sink.boom, ()), true, false, false);
        vm.prank(alice);
        token.transfer(bob, 1e18); // no revert; failed reentry swallowed
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_transferFromPath() public {
        token.arm(address(sink), abi.encodeCall(Sink.poke, ()), false, true, true);
        vm.prank(alice);
        token.approve(address(this), 50e18);
        token.transferFrom(alice, bob, 50e18);
        assertEq(sink.hits(), 1);
        assertEq(token.balanceOf(bob), 50e18);
    }
}
