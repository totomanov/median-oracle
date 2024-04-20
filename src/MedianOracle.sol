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
    function weightedMedian(uint256[] memory arr, uint256 targetWeight) private pure returns (uint256 r) {
        assembly {
            let weightAccum := 0
            let left := 0
            let right := mul(32, sub(mload(arr), 1))
            let arrp := add(arr, 32)
            for {} iszero(eq(left, right)) {} {
                let pivot := mload(add(arrp, shl(5, shr(6, add(left, right)))))
                let i := left
                let j := add(right, 32)
                let leftWeight := 0
                for {} 1 {} {
                    let word := 0
                    for {} 1 {} {
                        word := mload(add(arrp, i))
                        if iszero(lt(word, pivot)) { break }
                        leftWeight := add(leftWeight, and(word, 0xFFFF))
                        i := add(i, 32)
                    }

                    for {} 1 {} {
                        j := sub(j, 32)
                        word := mload(add(arrp, j))
                        if iszero(gt(word, pivot)) { break }
                    }

                    if lt(i, j) {
                        let iOffset := add(arrp, i)
                        let jOffset := add(arrp, j)
                        let output := mload(jOffset)
                        mstore(jOffset, mload(iOffset))
                        mstore(iOffset, output)
                        leftWeight := add(leftWeight, and(0xFFFF, output))
                        i := add(i, 32)
                        continue
                    }

                    if eq(i, j) { leftWeight := add(leftWeight, and(0xFFFF, mload(add(arrp, j)))) }
                    break
                }

                let nextWeightAccum := add(weightAccum, leftWeight)
                if lt(nextWeightAccum, targetWeight) {
                    weightAccum := nextWeightAccum
                    left := add(j, 32)
                    continue
                }
                right := j
            }
            r := mload(add(arrp, left))
        }
    }

    function getRingState()
        external
        view
        returns (int256 currTick, uint256 ringCurr, uint256 ringSize, uint256 lastUpdate)
    {
        (currTick, ringCurr, lastUpdate) = state.unpack();
        ringSize = RING_SIZE;
    }

    function writeRing(uint256 index, int256 tick, uint256 duration) internal {
        uint256 packed = (uint256(uint16(int16(tick))) << 16) | duration;
        assembly {
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
