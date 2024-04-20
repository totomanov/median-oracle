// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {RingState, RingStateLib} from "src/RingStateLib.sol";

contract RingStateLibTest is Test {
    function testInit(uint256 timestamp) public {
        timestamp = bound(timestamp, 0, type(uint48).max);
        vm.warp(timestamp);
        RingState state = RingStateLib.init();
        assertEq(state.currTick(), 0);
        assertEq(state.ringCurr(), 0);
        assertEq(state.lastUpdate(), timestamp);

        (int256 currTick, uint256 ringCurr, uint256 lastUpdate) = state.unpack();
        assertEq(currTick, state.currTick());
        assertEq(ringCurr, state.ringCurr());
        assertEq(lastUpdate, state.lastUpdate());
    }

    function testPackUnpack(int256 currTick0, uint256 ringCurr0, uint256 lastUpdate0) public pure {
        currTick0 = bound(currTick0, type(int16).min, type(int16).max);
        ringCurr0 = bound(ringCurr0, 0, type(uint16).max);
        lastUpdate0 = bound(lastUpdate0, 0, type(uint48).max);
        RingState state = RingStateLib.pack(currTick0, ringCurr0, lastUpdate0);
        (int256 currTick1, uint256 ringCurr1, uint256 lastUpdate1) = state.unpack();
        assertEq(currTick1, currTick0);
        assertEq(ringCurr1, ringCurr0);
        assertEq(lastUpdate1, lastUpdate0);

        assertEq(state.currTick(), currTick1);
        assertEq(state.ringCurr(), ringCurr1);
        assertEq(state.lastUpdate(), lastUpdate0);
    }
}
