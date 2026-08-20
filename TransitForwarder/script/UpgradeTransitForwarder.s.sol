// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {TransitForwarder} from "../src/TransitForwarder.sol"; // can be swapped for new logic (e.g. TransitForwarderV2)

/**
 * @notice Code update: swap the beacon impl to new TransitForwarder logic -> applied in bulk to all N deployed instances.
 * @dev The caller must be the TransitForwarderFactory owner (upgradeForwarderImplementation onlyOwner).
 *      The beacon address is immutable, so predicted/actual forwarder addresses stay the same.
 */
contract UpgradeTransitForwarderScript is BaseScript {
    function run() public {
        address factoryProxy = vm.envAddress("TRANSIT_FORWARDER_FACTORY_PROXY");
        address beaconBefore = TransitForwarderFactory(factoryProxy).beacon();

        // Pre-flight, before any broadcast: `_deployTransitForwarderImpl` below re-injects every immutable from
        // Config, so refuse to proceed if Config has drifted away from what is live (unless asked to rebind).
        _assertTransitImmutablesMatch(_liveForwarderImpl(factoryProxy));

        vm.startBroadcast();
        TransitForwarder newImpl = _deployTransitForwarderImpl();
        TransitForwarderFactory(factoryProxy).upgradeForwarderImplementation(address(newImpl));
        vm.stopBroadcast();

        require(TransitForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must not change");
        require(_liveForwarderImpl(factoryProxy) == address(newImpl), "new impl not installed on beacon");
        console2.log("New TransitForwarder impl:", address(newImpl));
        console2.log("Beacon (unchanged):", beaconBefore);
    }
}
