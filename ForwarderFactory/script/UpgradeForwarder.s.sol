// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {ForwarderFactory} from "../src/ForwarderFactory.sol";
import {Forwarder} from "../src/Forwarder.sol"; // can be swapped for new logic (e.g. ForwarderV2)

/**
 * @notice Code update: swap the beacon impl to new Forwarder logic → applied in bulk to all N deployed instances.
 * @dev The caller must be the ForwarderFactory owner (upgradeForwarderImplementation onlyOwner).
 *      The beacon address is immutable, so predicted/actual forwarder addresses stay the same.
 */
contract UpgradeForwarderScript is BaseScript {
    function run() public {
        address factoryProxy = vm.envAddress("FORWARDER_FACTORY_PROXY");
        address beaconBefore = ForwarderFactory(factoryProxy).beacon();

        vm.startBroadcast();
        Forwarder newImpl = _deployForwarderImpl(); // ← re-inject new logic/operator from USDC/PAYMENT_CONTRACT/OPERATOR
        ForwarderFactory(factoryProxy).upgradeForwarderImplementation(address(newImpl));
        vm.stopBroadcast();

        require(ForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must not change");
        console2.log("New Forwarder impl:", address(newImpl));
        console2.log("Beacon (unchanged):", beaconBefore);
    }
}
