// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {OutboundForwarderFactory} from "../src/OutboundForwarderFactory.sol";
import {OutboundForwarder} from "../src/OutboundForwarder.sol"; // can be swapped for new logic (e.g. OutboundForwarderV2)

/**
 * @notice Code update: swap the beacon impl to new OutboundForwarder logic → applied in bulk to all N deployed instances.
 * @dev The caller must be the OutboundForwarderFactory owner (upgradeForwarderImplementation onlyOwner).
 *      The beacon address is immutable, so predicted/actual forwarder addresses stay the same.
 */
contract UpgradeOutboundForwarderScript is BaseScript {
    function run() public {
        address factoryProxy = vm.envAddress("OUTBOUND_FORWARDER_FACTORY_PROXY");
        address beaconBefore = OutboundForwarderFactory(factoryProxy).beacon();

        vm.startBroadcast();
        OutboundForwarder newImpl = _deployOutboundForwarderImpl(); // ← re-inject new logic/operator from USDC/PAYMENT_CONTRACT/OPERATOR
        OutboundForwarderFactory(factoryProxy).upgradeForwarderImplementation(address(newImpl));
        vm.stopBroadcast();

        require(OutboundForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must not change");
        console2.log("New OutboundForwarder impl:", address(newImpl));
        console2.log("Beacon (unchanged):", beaconBefore);
    }
}
