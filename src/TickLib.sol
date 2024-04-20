// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library TickLib {
    int256 internal constant TICK_TRUNCATION = 30;
    int256 internal constant TICK_QUANTISATION_ADDEND_NEG = -29;
    int24 internal constant TICK_MIN = -887272;
    int24 internal constant TICK_MAX = 887272;

    error TickOutOfRange();

    function checkTick(int256 tick) internal pure {
        if (tick < TICK_MIN || tick > TICK_MAX) revert TickOutOfRange();
    }

    function quantise(int256 tick) internal pure returns (int256 result) {
        assembly {
            result := mul(slt(tick, 0), TICK_QUANTISATION_ADDEND_NEG)
            result := sdiv(add(tick, result), TICK_TRUNCATION)
        }
    }

    function unquantise(int256 tick) internal pure returns (int256) {
        unchecked {
            return tick * TICK_TRUNCATION + TICK_TRUNCATION / 2;
        }
    }

    function memoryPack(int256 tick, uint256 duration) internal pure returns (uint256) {
        unchecked {
            return (uint256(tick + 32768) << 16) | duration;
        }
    }

    function memoryUnpack(uint256 rec) internal pure returns (int256) {
        unchecked {
            return int256(rec >> 16) - 32768;
        }
    }
}
