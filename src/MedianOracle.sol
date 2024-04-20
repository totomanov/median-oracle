// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TickLib} from "src/TickLib.sol";
import {RingState, RingStateLib} from "src/RingStateLib.sol";

contract MedianOracle {
    uint256 internal constant MAX_AGE = 65535;
    uint256 internal constant MAX_RING_SIZE = 65535;
    uint256 internal immutable RING_SIZE;
    RingState internal state;
    uint256[MAX_RING_SIZE] internal ringBuffer;

    error OutOfRange();

    constructor(uint256 ringSize) {
        if (ringSize > MAX_RING_SIZE) revert OutOfRange();
        RING_SIZE = ringSize;
        state = RingStateLib.init();
    }

    function updateOracle(int256 newTick) external {
        TickLib.checkBounds(newTick);
        newTick = TickLib.quantise(newTick);

        (int256 currTick, uint256 ringCurr, uint256 lastUpdate) = state.unpack();
        if (newTick == currTick) return;

        unchecked {
            uint256 elapsed = block.timestamp - lastUpdate;

            if (elapsed != 0) {
                ringCurr = (ringCurr + 1) % RING_SIZE;
                writeRing(ringCurr, currTick, clampTime(elapsed));
            }

            state = RingStateLib.pack(newTick, ringCurr, block.timestamp);
        }
    }

    function readOracle(uint256 desiredAge) external view returns (uint256, int256, int256) {
        // returns (actualAge, median, average)
        if (desiredAge > MAX_AGE) revert OutOfRange();

        unchecked {
            (int256 currTick, uint256 ringCurr, uint256 cache) = state.unpack();
            // int currTick = currTick;
            // uint ringCurr = ringCurr;
            // uint cache = lastUpdate; // stores lastUpdate for first part of function, but then overwritten and used for something else

            uint256[] memory arr;
            uint256 actualAge = 0;

            // Load ring buffer entries into memory

            {
                uint256 arrSize = 0;
                uint256 freeMemoryPointer;
                assembly {
                    arr := mload(0x40)
                    freeMemoryPointer := add(arr, 0x20)
                }

                // Populate first element in arr with current tick, if any time has elapsed since current tick was set

                {
                    uint256 duration = clampTime(block.timestamp - cache);

                    if (duration != 0) {
                        if (duration > desiredAge) duration = desiredAge;
                        actualAge += duration;

                        uint256 packed = TickLib.memoryPack(currTick, duration);

                        assembly {
                            mstore(freeMemoryPointer, packed)
                            freeMemoryPointer := add(freeMemoryPointer, 0x20)
                        }
                        arrSize++;
                    }

                    currTick = TickLib.unquantise(currTick) * int256(duration); // currTick now becomes the average accumulator
                }

                // Continue populating elements until we have satisfied desiredAge

                {
                    uint256 i = ringCurr;
                    cache = type(uint256).max; // overwrite lastUpdate, use to cache storage reads

                    while (actualAge != desiredAge) {
                        int256 tick;
                        uint256 duration;

                        {
                            if (cache == type(uint256).max) cache = ringBuffer[i / 8];
                            uint256 entry = cache >> (32 * (i % 8));
                            tick = int256(int16(uint16((entry >> 16) & 0xFFFF)));
                            duration = entry & 0xFFFF;
                        }

                        if (duration == 0) break; // uninitialised

                        if (actualAge + duration > desiredAge) duration = desiredAge - actualAge;
                        actualAge += duration;

                        uint256 packed = TickLib.memoryPack(tick, duration);

                        assembly {
                            mstore(freeMemoryPointer, packed)
                            freeMemoryPointer := add(freeMemoryPointer, 0x20)
                        }
                        arrSize++;

                        currTick += TickLib.unquantise(tick) * int256(duration);

                        if (i & 7 == 0) cache = type(uint256).max;

                        i = (i + RING_SIZE - 1) % RING_SIZE;
                        if (i == ringCurr) break; // wrapped back around
                    }

                    assembly {
                        mstore(arr, arrSize)
                        mstore(0x40, freeMemoryPointer)
                    }
                }
            }

            return (
                actualAge,
                TickLib.unquantise(TickLib.memoryUnpack(weightedMedian(arr, actualAge / 2))),
                currTick / int256(actualAge)
            );
        }
    }

    /// @notice Find the weighted median of an array given a target weight.
    /// @param arr The array to search.
    /// @param targetWeight The weight to stop at.
    /// @dev Implements modified QuickSelect that accounts for item weights.
    function weightedMedian(uint256[] memory arr, uint256 targetWeight) internal pure returns (uint256) {
        unchecked {
            uint256 weightAccum = 0;
            uint256 left = 0;
            uint256 right = (arr.length - 1) * 32;
            uint256 arrp;

            assembly {
                arrp := add(arr, 32)
            }

            while (true) {
                if (left == right) return memload(arrp, left);

                uint256 pivot = memload(arrp, (left + right) / 2);
                uint256 i = left - 32;
                uint256 j = right + 32;
                uint256 leftWeight = 0;

                while (true) {
                    i += 32;
                    while (true) {
                        uint256 w = memload(arrp, i);
                        if (w >= pivot) break;
                        leftWeight += w & 0xFFFF;
                        i += 32;
                    }

                    do {
                        j -= 32;
                    } while (memload(arrp, j) > pivot);

                    if (i > j) break;
                    if (i == j) {
                        leftWeight += memload(arrp, j) & 0xFFFF;
                        break;
                    }

                    leftWeight += memswap(arrp, i, j) & 0xFFFF;
                }

                if (weightAccum + leftWeight >= targetWeight) {
                    right = j;
                } else {
                    weightAccum += leftWeight;
                    left = j + 32;
                }
            }
        }

        assert(false);
        return 0;
    }

    function getRingState()
        external
        view
        returns (int256 currTick, uint256 ringCurr, uint256 ringSize, uint256 lastUpdate)
    {
        // (currTick, ringCurr, lastUpdate) = state.unpack();
        currTick = state.currTick();
        ringCurr = state.ringCurr();
        ringSize = RING_SIZE;
        lastUpdate = state.lastUpdate();
    }

    // Array access without bounds checking
    function memload(uint256 arrp, uint256 i) internal pure returns (uint256 ret) {
        assembly {
            ret := mload(add(arrp, i))
        }
    }

    // Swap two items in array without bounds checking, returns new element in i

    function memswap(uint256 arrp, uint256 i, uint256 j) internal pure returns (uint256 output) {
        assembly {
            let iOffset := add(arrp, i)
            let jOffset := add(arrp, j)
            output := mload(jOffset)
            mstore(jOffset, mload(iOffset))
            mstore(iOffset, output)
        }
    }

    function writeRing(uint256 index, int256 tick, uint256 duration) internal {
        assembly {
            let packed := or(duration, sar(16, tick))
            let shift := mul(32, mod(index, 8))
            let slot := add(ringBuffer.slot, div(index, 8))
            let value := sload(slot)
            value := and(value, not(shl(shift, 0xFFFFFFFF)))
            value := or(value, shl(shift, packed))
            sstore(slot, value)
        }
    }

    function clampTime(uint256 t) internal pure returns (uint256 tc) {
        return t < MAX_AGE ? t : MAX_AGE;
    }
}
