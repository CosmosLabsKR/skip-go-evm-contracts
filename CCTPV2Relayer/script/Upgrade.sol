// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {CCTPV2Relayer} from "../src/CCTPV2Relayer.sol";

contract UpgradeScript is Script {
    CCTPV2Relayer public relayer;

    function setUp() public {
        relayer = CCTPV2Relayer(payable(0xd704Dc9A8DE1a82C674452192717DEE531751818));
    }

    function run() public {
        address proxy = address(relayer);

        vm.startBroadcast();
        CCTPV2Relayer newImplementation = new CCTPV2Relayer();
        relayer.upgradeToAndCall(address(newImplementation), bytes(""));
        vm.stopBroadcast();

        console2.log("Upgraded relayer proxy:", proxy);
        console2.log("New implementation:    ", address(newImplementation));
    }
}
