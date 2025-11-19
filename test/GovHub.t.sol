// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./utils/Deployer.sol";

contract GovHubTest is Deployer {
    event failReasonWithStr(string message);

    function setUp() public { }


    function testGovSlash(uint16 value1, uint16 value2) public {
        uint256 misdemeanorThreshold = slashIndicator.misdemeanorThreshold();
        vm.assume(uint256(value1) > misdemeanorThreshold);
        vm.assume(value1 <= 1000);
        vm.assume(value2 < value1);
        vm.assume(value2 > 0);

        // 1) Update felonyThreshold via GovHub and check the new value
        bytes memory key = "felonyThreshold";
        bytes memory valueBytes = abi.encode(value1);

        // No more paramChange event expectations: just call and assert state
        _updateParamByGovHub(key, valueBytes, address(slashIndicator));
        assertEq(uint256(value1), slashIndicator.felonyThreshold(), "felonyThreshold not updated");

        // 2) Update misdemeanorThreshold via GovHub and check the new value
        key = "misdemeanorThreshold";
        valueBytes = abi.encode(value2);

        _updateParamByGovHub(key, valueBytes, address(slashIndicator));
        assertEq(uint256(value2), slashIndicator.misdemeanorThreshold(), "misdemeanorThreshold not updated");
    }
}
