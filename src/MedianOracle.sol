// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TickLib} from "src/TickLib.sol";
import {RingState, RingStateLib} from "src/RingStateLib.sol";

contract MedianOracle {
    uint256 internal constant MAX_AGE = 65535;
    uint256 internal constant MAX_RING_SIZE = 65535;
    int256 internal constant TICK_TRUNCATION = 30;
    int256 internal constant TICK_TRUNCATION_HALF = 15;
    int256 internal constant TICK_QUANTISATION_ADDEND_NEG = -29;
    int24 internal constant TICK_MIN = -887272;
    int24 internal constant TICK_MAX = 887272;
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
        assembly {
            if or(slt(newTick, TICK_MIN), sgt(newTick, TICK_MAX)) { revert(0, 0) }

            let t := newTick
            newTick := mul(slt(t, 0), TICK_QUANTISATION_ADDEND_NEG)
            newTick := sdiv(add(t, newTick), TICK_TRUNCATION)
        }

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
        (int256 currTick, uint256 ringCurr, uint256 cache) = state.unpack();

        unchecked {
            uint256[] memory arr;
            uint256 actualAge = 0;

            // Load ring buffer entries into memory
            {
                uint256 arrSize = 0;
                uint256 freeMemoryPointer;
                /// @solidity memory-safe-assembly
                assembly {
                    arr := mload(0x40)
                    freeMemoryPointer := add(arr, 0x20)

                    let duration := sub(timestamp(), cache)
                    if gt(duration, MAX_AGE) { duration := MAX_AGE }

                    if iszero(iszero(duration)) {
                        if gt(duration, desiredAge) { duration := desiredAge }
                        actualAge := add(actualAge, duration)
                        let packed := or(duration, shl(16, add(currTick, 32768)))

                        mstore(freeMemoryPointer, packed)
                        freeMemoryPointer := add(freeMemoryPointer, 0x20)

                        arrSize := add(arrSize, 1)
                    }

                    currTick := add(mul(currTick, TICK_TRUNCATION), TICK_TRUNCATION_HALF)
                    currTick := mul(currTick, duration)
                }

                // Continue populating elements until we have satisfied desiredAge

                {
                    uint256 i = ringCurr;
                    cache = type(uint256).max; // overwrite lastUpdate, use to cache storage reads

                    while (actualAge != desiredAge) {
                        if (cache == type(uint256).max) {
                            cache = ringBuffer[i / 8];
                        }
                        uint256 entry = cache >> (32 * (i % 8));
                        int256 tick = int256(int16(uint16((entry >> 16) & 0xFFFF)));
                        uint256 duration = entry & 0xFFFF;

                        if (duration == 0) break; // uninitialised

                        if (actualAge + duration > desiredAge) duration = desiredAge - actualAge;
                        actualAge += duration;

                        uint256 packed = TickLib.memoryPack(tick, duration);

                        /// @solidity memory-safe-assembly
                        assembly {
                            mstore(freeMemoryPointer, packed)
                            freeMemoryPointer := add(freeMemoryPointer, 0x20)

                            arrSize := add(arrSize, 1)
                            tick := add(mul(tick, TICK_TRUNCATION), TICK_TRUNCATION_HALF)
                            tick := mul(tick, duration)
                            currTick := add(currTick, tick)
                            if iszero(and(i, 7)) { cache := not(0) }
                        }

                        i = (i + RING_SIZE - 1) % RING_SIZE;
                        if (i == ringCurr) break; // wrapped back around
                    }

                    /// @solidity memory-safe-assembly
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
        /// @solidity memory-safe-assembly
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
        /// @solidity memory-safe-assembly
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
