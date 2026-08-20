// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {OutboundForwarderFactory} from "../src/OutboundForwarderFactory.sol";

/**
 * @notice Deploys the per-route OutboundForwarder for one route key.
 * @dev The route is DATA, not code — it comes from the environment so nobody has to edit this file to run it.
 *      Required env:
 *        OUTBOUND_FORWARDER_FACTORY_PROXY  factory proxy address
 *        ROUTE_SENDER                      route identifier and fund recovery recipient
 *        ROUTE_DEST_DOMAIN                 CCTP destination domain (uint32)
 *        ROUTE_MINT_RECIPIENT              destination recipient as bytes32 (EVM address → left-padded)
 */
contract CreateOutboundForwarderScript is BaseScript {
    function run() public {
        address factoryAddress = vm.envAddress("OUTBOUND_FORWARDER_FACTORY_PROXY");

        address sender = vm.envAddress("ROUTE_SENDER");
        uint256 rawDomain = vm.envUint("ROUTE_DEST_DOMAIN");
        bytes32 mintRecipient = vm.envBytes32("ROUTE_MINT_RECIPIENT");
        require(sender != address(0), "ROUTE_SENDER is zero");
        require(rawDomain <= type(uint32).max, "ROUTE_DEST_DOMAIN overflows uint32");
        require(mintRecipient != bytes32(0), "ROUTE_MINT_RECIPIENT is zero");
        uint32 destinationDomain = uint32(rawDomain);

        OutboundForwarderFactory factory = OutboundForwarderFactory(factoryAddress);
        address predictedAddress = factory.getForwarderAddress(sender, destinationDomain, mintRecipient);

        console2.log("route sender    :", sender);
        console2.log("route destDomain:", destinationDomain);
        console2.log("route mintRecipient:");
        console2.logBytes32(mintRecipient);
        // bytes32 recipients are easy to mis-pad — show the address reading so it can be eyeballed.
        console2.log("  as EVM address:", address(uint160(uint256(mintRecipient))));
        console2.log("predicted forwarder:", predictedAddress);
        require(
            !factory.isForwarderDeployed(sender, destinationDomain, mintRecipient),
            "forwarder already deployed for this route"
        );

        vm.startBroadcast();
        address newOutboundForwarder = factory.createForwarder(sender, destinationDomain, mintRecipient);
        vm.stopBroadcast();

        require(newOutboundForwarder == predictedAddress, "predicted != deployed");
        console2.log("new OutboundForwarder:", newOutboundForwarder);
    }
}
