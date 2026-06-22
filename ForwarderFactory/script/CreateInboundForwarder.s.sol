// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {InboundForwarderFactory} from "../src/InboundForwarderFactory.sol";

contract CreateInboundForwarderScript is BaseScript {
    function run() public {
        address factoryAddress = vm.envAddress("INBOUND_FORWARDER_FACTORY_PROXY");

        vm.startBroadcast();

        InboundForwarderFactory factory = InboundForwarderFactory(factoryAddress);

        // Route key (sender, destinationChainId, destinationReceiver) — the stable final intent. The source burner
        // must set mintRecipient to the predicted address below, which is how the final intent is cryptographically
        // committed. The per-transfer IBC route (channelId, receiver, memo) is NOT set here — it rides in the CCTP
        // hookData and is decoded on-chain at mintAndRoute time (dynamic-route model).
        // sender: source-domain depositor (CCTP messageSender) authorized for this route + refund recipient.
        address sender = 0x455AAA40C707AFE214E30f418C3DD145aDFC953F;
        // destinationChainId: final destination chain id (e.g. "dydx-mainnet-1").
        string memory destinationChainId = "dydx-mainnet-1";
        // destinationReceiver: final-hop recipient on the destination chain.
        string memory destinationReceiver = "dydx1...replace_me...";

        address predictedAddress = factory.getForwarderAddress(sender, destinationChainId, destinationReceiver);
        address newInboundForwarder = factory.createForwarder(sender, destinationChainId, destinationReceiver);
        require(newInboundForwarder == predictedAddress, "predicted != deployed");

        vm.stopBroadcast();

        console2.log("new InboundForwarder:", newInboundForwarder);
        console2.log("predicted InboundForwarder:", predictedAddress);
    }
}
