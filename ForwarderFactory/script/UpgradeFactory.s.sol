// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {ForwarderFactory} from "../src/ForwarderFactory.sol";

/**
 * @notice Code update: swap the factory implementation (UUPS). proxy/beacon/forwarder addresses all stay the same.
 * @dev The caller must be the ForwarderFactory owner (_authorizeUpgrade onlyOwner).
 */
contract UpgradeFactoryScript is BaseScript {
    function run() public {
        address factoryProxy = vm.envAddress("FORWARDER_FACTORY_PROXY");
        address beaconBefore = ForwarderFactory(factoryProxy).beacon();

        vm.startBroadcast();
        ForwarderFactory newImpl = new ForwarderFactory();
        // Empty calldata when no extra init is needed. Use abi.encodeCall(...) if a reinitializer is required.
        ForwarderFactory(factoryProxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        require(ForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must persist across factory upgrade");
        console2.log("New ForwarderFactory impl:", address(newImpl));
        console2.log("Factory proxy (unchanged):", factoryProxy);
    }
}
