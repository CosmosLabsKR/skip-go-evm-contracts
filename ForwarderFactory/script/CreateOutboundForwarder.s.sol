// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {OutboundForwarderFactory} from "../src/OutboundForwarderFactory.sol";

contract CreateOutboundForwarderScript is BaseScript {
    function run() public {
        address factoryAddress = vm.envAddress("OUTBOUND_FORWARDER_FACTORY_PROXY");

        vm.startBroadcast();

        OutboundForwarderFactory factory = OutboundForwarderFactory(factoryAddress);
        // sender: route identifier and fund recovery authority (merged recover role)
        address sender = 0x455AAA40C707AFE214E30f418C3DD145aDFC953F;
        uint32 destinationDomain = 0; // Sepolia testnet domain (to be updated for mainnet)
        // mintRecipient: destination receiving address as bytes32 (e.g. an EVM address left-padded)
        bytes32 mintRecipient = bytes32(uint256(uint160(0x455AAA40C707AFE214E30f418C3DD145aDFC953F)));

        address predictedAddress = factory.getForwarderAddress(sender, destinationDomain, mintRecipient);
        address newOutboundForwarder = factory.createForwarder(sender, destinationDomain, mintRecipient);
        require(newOutboundForwarder == predictedAddress, "predicted != deployed");

        vm.stopBroadcast();

        console2.log("new OutboundForwarder:", newOutboundForwarder);
        console2.log("predicted OutboundForwarder:", predictedAddress);
    }
}
