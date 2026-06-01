// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {CCTPV2Relayer} from "src/CCTPV2Relayer.sol";

contract UpgradeScript is Script {
    CCTPV2Relayer public relayer;

    function setUp() public {
        relayer = CCTPV2Relayer(payable(0x32cb9574650AFF312c80edc4B4343Ff5500767cA));
    }

    function run() public {
        vm.startBroadcast();
        CCTPV2Relayer newImplementation = new CCTPV2Relayer();
        relayer.upgradeToAndCall(address(newImplementation), bytes(""));
        vm.stopBroadcast();
    }
}
