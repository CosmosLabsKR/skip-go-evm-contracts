// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {InboundForwarderFactory} from "../src/InboundForwarderFactory.sol";

/**
 * @notice Deploys the per-route InboundForwarder for one route key.
 * @dev The route is DATA, not code — it comes from the environment so nobody has to edit this file to run it.
 *      Required env:
 *        INBOUND_FORWARDER_FACTORY_PROXY  factory proxy address
 *        ROUTE_SENDER                     source-domain depositor (CCTP burn-body messageSender)
 *        ROUTE_DEST_CHAIN_ID              final destination chain id, e.g. "dydx-mainnet-1"
 *        ROUTE_DEST_RECEIVER              final-hop recipient on the destination chain
 */
contract CreateInboundForwarderScript is BaseScript {
    function run() public {
        address factoryAddress = vm.envAddress("INBOUND_FORWARDER_FACTORY_PROXY");

        // Route key (sender, destinationChainId, destinationReceiver) — the stable final intent. The source burner
        // must set mintRecipient to the predicted address printed below, which is how the final intent is
        // cryptographically committed. The per-transfer IBC route (channelId, receiver, memo) is NOT set here — it
        // rides in the CCTP hookData and is decoded on-chain at mintAndRoute time (dynamic-route model).
        address sender = vm.envAddress("ROUTE_SENDER");
        string memory destinationChainId = vm.envString("ROUTE_DEST_CHAIN_ID");
        string memory destinationReceiver = vm.envString("ROUTE_DEST_RECEIVER");
        require(sender != address(0), "ROUTE_SENDER is zero");
        require(bytes(destinationChainId).length != 0, "ROUTE_DEST_CHAIN_ID is empty");
        require(bytes(destinationReceiver).length != 0, "ROUTE_DEST_RECEIVER is empty");

        InboundForwarderFactory factory = InboundForwarderFactory(factoryAddress);
        address predictedAddress = factory.getForwarderAddress(sender, destinationChainId, destinationReceiver);

        // Echo the route before broadcasting so a typo is caught by eye, not by a stuck transfer: all three values
        // are CREATE2 salt inputs, so any drift lands the forwarder on an address the source burner never targets.
        console2.log("route sender      :", sender);
        console2.log("route destChainId :", destinationChainId);
        console2.log("route destReceiver:", destinationReceiver);
        console2.log("predicted forwarder (set this as the source burn mintRecipient):", predictedAddress);
        require(
            !factory.isForwarderDeployed(sender, destinationChainId, destinationReceiver),
            "forwarder already deployed for this route"
        );

        vm.startBroadcast();
        address newInboundForwarder = factory.createForwarder(sender, destinationChainId, destinationReceiver);
        vm.stopBroadcast();

        require(newInboundForwarder == predictedAddress, "predicted != deployed");
        console2.log("new InboundForwarder:", newInboundForwarder);
    }
}
