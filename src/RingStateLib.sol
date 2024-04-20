// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

type RingState is uint256;

using RingStateLib for RingState global;

library RingStateLib {
    uint256 internal constant CURR_TICK_OFFSET = 240;
    uint256 internal constant RING_CURR_OFFSET = 224;
    uint256 internal constant CURR_TICK_MASK = 0xFFFF000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant RING_CURR_MASK = 0x0000FFFF00000000000000000000000000000000000000000000000000000000;
    uint256 internal constant UPDATE_AT_MASK = 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    function init() internal view returns (RingState) {
        return RingState.wrap(block.timestamp);
    }

    function unpack(RingState state) internal pure returns (int256, uint256, uint256) {
        return (currTick(state), ringCurr(state), lastUpdate(state));
    }

    function pack(int256 _currTick, uint256 _ringCurr, uint256 _lastUpdate) internal pure returns (RingState) {
        uint256 s;
        assembly {
            s := shl(CURR_TICK_OFFSET, _currTick)
        }
        s |= uint256(_ringCurr) << RING_CURR_OFFSET;
        s |= _lastUpdate;
        return RingState.wrap(s);
    }

    function currTick(RingState state) internal pure returns (int256 r) {
        assembly {
            r := sar(CURR_TICK_OFFSET, and(state, CURR_TICK_MASK))
        }
    }

    function ringCurr(RingState state) internal pure returns (uint256) {
        return (RingState.unwrap(state) & RING_CURR_MASK) >> RING_CURR_OFFSET;
    }

    function lastUpdate(RingState state) internal pure returns (uint256) {
        return RingState.unwrap(state) & UPDATE_AT_MASK;
    }
}
