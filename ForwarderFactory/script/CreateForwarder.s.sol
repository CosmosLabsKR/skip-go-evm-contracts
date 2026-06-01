// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {ForwarderFactory} from "../src/ForwarderFactory.sol";

contract CreateForwarderScript is BaseScript {
    function run() public {
        address factoryAddress = vm.envAddress("FORWARDER_FACTORY_PROXY");

        vm.startBroadcast();

        ForwarderFactory factory = ForwarderFactory(factoryAddress);
        // sender: route identifier and fund recovery authority (merged recover role)
        address sender = 0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3;
        uint32 destinationDomain = 1;
        // mintRecipient: destination receiving address as bytes32 (e.g. an EVM address left-padded)
        bytes32 mintRecipient = bytes32(uint256(uint160(0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3)));

        address predictedAddress = factory.getForwarderAddress(sender, destinationDomain, mintRecipient);
        address newForwarder = factory.createForwarder(sender, destinationDomain, mintRecipient);
        require(newForwarder == predictedAddress, "predicted != deployed");

        vm.stopBroadcast();

        console2.log("new Forwarder:", newForwarder);
        console2.log("predicted Forwarder:", predictedAddress);
    }
}
