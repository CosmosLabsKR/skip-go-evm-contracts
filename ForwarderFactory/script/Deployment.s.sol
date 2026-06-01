// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ForwarderFactory} from "../src/ForwarderFactory.sol";
import {Forwarder} from "../src/Forwarder.sol";

contract DeploymentScript is BaseScript {
    function run() public {
        vm.startBroadcast();

        Forwarder forwarderImpl = _deployForwarderImpl();
        ForwarderFactory impl = new ForwarderFactory();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(ForwarderFactory.initialize, (address(forwarderImpl))));

        vm.stopBroadcast();

        console2.log("Forwarder implementation:", address(forwarderImpl));
        console2.log("ForwarderFactory implementation:", address(impl));
        console2.log("ForwarderFactory proxy:", address(proxy));
        console2.log("Beacon:", ForwarderFactory(address(proxy)).beacon());
    }
}
