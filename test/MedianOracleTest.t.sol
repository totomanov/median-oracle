// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MedianOracle} from "src/MedianOracle.sol";
import {TickLib} from "src/TickLib.sol";

contract MedianOracleTest is Test {
    uint16 internal constant RING_SIZE = 144;
    int24 internal constant TICK_MIN = -887272;
    int24 internal constant TICK_MAX = 887272;
    MedianOracle internal oracle;

    function setUp() public {
        oracle = new MedianOracle(RING_SIZE);
    }

    function testTickQuantization() public {
        checkTick(0, 15);
        checkTick(1, 15);
        checkTick(15, 15);
        checkTick(29, 15);
        checkTick(30, 45);
        checkTick(59, 45);
        checkTick(60, 75);

        checkTick(-1, -15);
        checkTick(-2, -15);
        checkTick(-15, -15);
        checkTick(-29, -15);
        checkTick(-30, -15);
        checkTick(-31, -45);
        checkTick(-60, -45);
        checkTick(-61, -75);

        checkTick(TICK_MAX, 887265);
        checkTick(TICK_MIN, -887265);
    }

    function testQuantizeTick_Nonnegative(int256 tick) public pure {
        tick = bound(tick, 0, TICK_MAX);
        int256 qtick = TickLib.quantise(tick);
        assertEq(qtick, tick / TickLib.TICK_TRUNCATION);
    }

    function testQuantizeTick_Negative(int256 tick) public pure {
        tick = bound(tick, TICK_MIN, 0);
        int256 qtick = TickLib.quantise(tick);
        assertEq(qtick, (tick - TickLib.TICK_TRUNCATION + 1) / TickLib.TICK_TRUNCATION);
    }

    function testUnquantizeTick(int256 qtick) public pure {
        qtick = bound(qtick, TICK_MIN, TICK_MAX);
        int256 tick = TickLib.unquantise(qtick);
        assertEq(tick, qtick * TickLib.TICK_TRUNCATION + TickLib.TICK_TRUNCATION / 2);
    }

    function checkTick(int24 tickIn, int24 tickOut) internal {
        oracle.updateOracle(tickIn);
        skip(2000);
        (, int256 median,) = oracle.readOracle(1800);

        assertEq(median, tickOut);
        assertGe(median, TICK_MIN);
        assertLe(median, TICK_MAX);
    }
}
