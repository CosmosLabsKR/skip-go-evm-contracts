// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OutboundForwarderFactory} from "../src/OutboundForwarderFactory.sol";
import {OutboundForwarder} from "../src/OutboundForwarder.sol";

/**
 * @notice Deploys the OutboundForwarderFactory (impl + ERC1967 proxy). The OutboundForwarder impl is deployed first
 *         only because the factory's `initialize` needs it — the factory owns the beacon it creates from that impl.
 *         Per-route forwarders are NOT deployed here; use CreateOutboundForwarder.
 */
contract DeployOutboundFactoryScript is BaseScript {
    function run() public {
        vm.startBroadcast();

        OutboundForwarder forwarderImpl = _deployOutboundForwarderImpl();
        OutboundForwarderFactory impl = new OutboundForwarderFactory();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(OutboundForwarderFactory.initialize, (address(forwarderImpl))));

        vm.stopBroadcast();

        console2.log("OutboundForwarder implementation:", address(forwarderImpl));
        console2.log("OutboundForwarderFactory implementation:", address(impl));
        console2.log("OutboundForwarderFactory proxy:", address(proxy));
        console2.log("Beacon:", OutboundForwarderFactory(address(proxy)).beacon());
    }
}
