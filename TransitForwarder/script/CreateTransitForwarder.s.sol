// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";

/**
 * @notice Deploys the per-route TransitForwarder for one route key.
 * @dev The route is DATA, not code — it comes from the environment so nobody has to edit this file to run it.
 *      Required env:
 *        TRANSIT_FORWARDER_FACTORY_PROXY  factory proxy address
 *        ROUTE_SENDER                     route identifier and fund recovery recipient
 *        ROUTE_MINT_RECIPIENT             Injective-side recipient as bytes32 (EVM address -> left-padded)
 *
 *      There is deliberately NO destination-domain env var. This deployment routes Avalanche -> Injective only, so
 *      the domain is taken from Config; the forwarder's initialize would reject anything else with
 *      UnsupportedDestination anyway. Removing the knob removes the whole class of "typo'd the domain and shipped
 *      funds to the wrong chain" — which the CREATE2 address alone could never reveal, since a wrong-domain route
 *      still produces a perfectly valid-looking address.
 */
contract CreateTransitForwarderScript is BaseScript {
    function run() public {
        address factoryAddress = vm.envAddress("TRANSIT_FORWARDER_FACTORY_PROXY");

        address sender = vm.envAddress("ROUTE_SENDER");
        bytes32 mintRecipient = vm.envBytes32("ROUTE_MINT_RECIPIENT");
        require(sender != address(0), "ROUTE_SENDER is zero");
        require(mintRecipient != bytes32(0), "ROUTE_MINT_RECIPIENT is zero");
        // Fixed by Config, not by the caller. Still passed as an argument (and still part of the CREATE2 salt) so the
        // forwarder's address keeps COMMITTING its destination — see TransitForwarder.ALLOWED_DESTINATION_DOMAIN.
        uint32 destinationDomain = INJECTIVE_CCTP_DOMAIN;

        TransitForwarderFactory factory = TransitForwarderFactory(factoryAddress);
        address predictedAddress = factory.getForwarderAddress(sender, destinationDomain, mintRecipient);

        console2.log("route sender    :", sender);
        console2.log("route destDomain:", destinationDomain); // fixed: Injective
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
        address newTransitForwarder = factory.createForwarder(sender, destinationDomain, mintRecipient);
        vm.stopBroadcast();

        require(newTransitForwarder == predictedAddress, "predicted != deployed");
        console2.log("new TransitForwarder:", newTransitForwarder);
    }
}
