// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console2} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {MedianOracle} from "src/MedianOracle.sol";
import {TickLib} from "src/TickLib.sol";
import {MedianOracleReference} from "test/MedianOracleReference.sol";

contract MedianOracleDiffHarness is Test {
    uint16 internal constant RING_SIZE = 144;
    int24 internal constant TICK_MIN = -887272;
    int24 internal constant TICK_MAX = 887272;

    MedianOracle oracle;
    MedianOracleReference oracleRef;
    uint256 public numErrors;
    string[] public errors;

    constructor() {
        oracle = new MedianOracle(RING_SIZE);
        oracleRef = new MedianOracleReference(RING_SIZE);
    }

    function updateOracle(int256 newTick) external {
        newTick = bound(newTick, TICK_MIN, TICK_MAX);
        oracle.updateOracle(newTick);
        oracleRef.updateOracle(newTick);
    }

    function readOracle(uint256 desiredAge) external {
        desiredAge = bound(desiredAge, 0, type(uint16).max);
        bytes memory cdata = abi.encodeCall(oracleRef.readOracle, (desiredAge));
        (bool success0, bytes memory data0) = address(oracle).call(cdata);
        (bool success1, bytes memory data1) = address(oracleRef).call(cdata);
        if (success0 != success1) return recordError("Different success");

        (uint256 actualAge0, int256 median0, int256 average0) = abi.decode(data0, (uint256, int256, int256));
        (uint16 actualAge1, int24 median1, int24 average1) = abi.decode(data1, (uint16, int24, int24));
        if (actualAge0 != actualAge1) return recordError("Different actualAge", actualAge0, actualAge1);
        if (median0 != median1) return recordError("Different median");
        if (average0 != average1) return recordError("Different average");
    }

    function warp(uint256 delta) external {
        delta = bound(delta, 1, 65535 * 2);
        vm.warp(delta);
    }

    function assertEqualState() external view {
        (int256 currTick0, uint256 ringCurr0, uint256 ringSize0, uint256 lastUpdate0) = oracle.getRingState();
        int16 currTick1 = oracleRef.currTick();
        uint16 ringCurr1 = oracleRef.ringCurr();
        uint16 ringSize1 = oracleRef.ringSize();
        uint64 lastUpdate1 = oracleRef.lastUpdate();

        assertEqRich(ringCurr0, uint256(ringCurr1), "ringCurr");
        assertEqRich(ringSize0, uint256(ringSize1), "ringSize");
        assertEqRich(lastUpdate0, uint256(lastUpdate1), "lastUpdate");
        assertEqRich(currTick0, int256(currTick1), "currTick");
    }

    function recordError(string memory err, uint256 a, uint256 b) internal {
        errors.push(err);
        numErrors += 1;
    }

    function recordError(string memory err) internal {
        errors.push(err);
        numErrors += 1;
    }

    function assertEqRich(int256 a, int256 b, string memory param) internal pure {
        assertEq(a, b, string.concat(param, " not equivalent: %s != %s"));
    }

    function assertEqRich(uint256 a, uint256 b, string memory param) internal pure {
        assertEq(a, b, string.concat(param, " not equivalent: %s != %s"));
    }
}

contract MedianOracleDiffTest is Test {
    MedianOracleDiffHarness internal harness;

    function setUp() public {
        harness = new MedianOracleDiffHarness();
        targetContract(address(harness));
    }

    function invariant_Equivalent() public view {
        harness.assertEqualState();
        uint256 numErrors = harness.numErrors();

        for (uint256 i = 0; i < numErrors; ++i) {
            string memory err = harness.errors(i);
            console2.log(err);
        }
        if (numErrors != 0) assert(false);
    }
}
