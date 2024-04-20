// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console2} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {MedianOracle} from "src/MedianOracle.sol";
import {TickLib} from "src/TickLib.sol";
import {MedianOracleReference} from "test/MedianOracleReference.sol";

contract MedianOracleBenchTest is Test {
    uint256 internal constant WARP_PROBABILITY = 0.9e18;
    uint256 internal constant RUNS = 1_000;
    uint16 internal constant RING_SIZE = 144;
    int24 internal constant TICK_MIN = -887272;
    int24 internal constant TICK_MAX = 887272;

    MedianOracle internal oracle;
    MedianOracleReference internal oracleRef;
    uint256 internal seed = 2;

    uint256[RUNS] internal gasUpdate;
    uint256[RUNS] internal gasRead;
    uint256[RUNS] internal gasUpdateRef;
    uint256[RUNS] internal gasReadRef;

    function setUp() public {
        oracle = new MedianOracle(RING_SIZE);
        oracleRef = new MedianOracleReference(RING_SIZE);
    }

    function testBenchmark() public {
        vm.warp(365 days);
        for (uint256 i = 0; i < RUNS; ++i) {
            bool success;

            seed = uint256(keccak256(abi.encodePacked(seed)));
            int256 newTick = int256(uint256(keccak256(abi.encodePacked(seed))));
            newTick = bound(newTick, TickLib.TICK_MIN, TickLib.TICK_MAX);
            uint256 desiredAge = uint256(keccak256(abi.encodePacked(seed + 1)));
            desiredAge = bound(desiredAge, 0, type(uint16).max);

            uint256 before0 = gasleft();
            oracle.updateOracle(newTick);
            uint256 after0 = gasleft();
            gasUpdate[i] = before0 - after0;

            uint256 before1 = gasleft();
            oracleRef.updateOracle(newTick);
            uint256 after1 = gasleft();
            gasUpdateRef[i] = before1 - after1;

            if (seed % 1e18 > 1e18 - WARP_PROBABILITY) {
                uint256 time = uint256(keccak256(abi.encodePacked(seed + 2)));
                time = bound(time, 1, 60 minutes);
                skip(time);
            }

            bytes memory cdata = abi.encodeCall(oracleRef.readOracle, (desiredAge));
            uint256 before2 = gasleft();
            oracle.readOracle(desiredAge);
            uint256 after2 = gasleft();
            gasRead[i] = before2 - after2;

            uint256 before3 = gasleft();
            oracleRef.readOracle(desiredAge);
            uint256 after3 = gasleft();
            gasReadRef[i] = before3 - after3;
        }

        printRuns("updateOracle [reference]", gasUpdateRef);
        printRuns("updateOracle [optimized]", gasUpdate);
        printRuns("readOracle   [reference]", gasReadRef);
        printRuns("readOracle   [optimized]", gasRead);
    }

    function printRuns(string memory s, uint256[RUNS] memory runs) internal pure {
        uint256 min = type(uint256).max;
        uint256 max = 0;
        uint256 sum = 0;
        for (uint256 i = 0; i < RUNS; ++i) {
            uint256 run = runs[i];
            if (run == 0) continue;
            if (run < min) min = run;
            if (run > max) max = run;
            sum += run;
        }
        uint256 mean = sum / RUNS;
        console2.log(string.concat(s, " (min: %s, max: %s, ~: %s)"), min, max, mean);
    }

    // oracle.updateOracle(307024);
    function test_poc() public {
        vm.warp(365 days);
        oracle.updateOracle(694767);
        skip(1);
        oracle.readOracle(32753);
    }
}

// MedianOracle::updateOracle(307024)
// MedianOracle::readOracle(48433)
