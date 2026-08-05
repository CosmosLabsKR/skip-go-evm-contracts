// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {InboundForwarderFactory} from "../src/InboundForwarderFactory.sol";
import {InboundForwarder} from "../src/InboundForwarder.sol"; // can be swapped for new logic (e.g. InboundForwarderV2)

/**
 * @notice Code update: swap the beacon impl to new InboundForwarder logic → applied in bulk to all N deployed instances.
 * @dev The caller must be the InboundForwarderFactory owner (upgradeForwarderImplementation onlyOwner).
 *      The beacon address is immutable, so predicted/actual forwarder addresses stay the same.
 */
contract UpgradeInboundForwarderScript is BaseScript {
    function run() public {
        address factoryProxy = vm.envAddress("INBOUND_FORWARDER_FACTORY_PROXY");
        address beaconBefore = InboundForwarderFactory(factoryProxy).beacon();

        // Pre-flight, before any broadcast: `_deployInboundForwarderImpl` below re-injects every immutable from
        // Config, so refuse to proceed if Config has drifted away from what is live (unless asked to rebind).
        _assertInboundImmutablesMatch(_liveForwarderImpl(factoryProxy));

        vm.startBroadcast();
        InboundForwarder newImpl = _deployInboundForwarderImpl(); // ← re-inject new logic/immutables from USDC/TRANSMITTER/OPERATOR/INJECTIVE_CCTP_DOMAIN
        InboundForwarderFactory(factoryProxy).upgradeForwarderImplementation(address(newImpl));
        vm.stopBroadcast();

        require(InboundForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must not change");
        require(_liveForwarderImpl(factoryProxy) == address(newImpl), "new impl not installed on beacon");
        console2.log("New InboundForwarder impl:", address(newImpl));
        console2.log("Beacon (unchanged):", beaconBefore);
    }
}
