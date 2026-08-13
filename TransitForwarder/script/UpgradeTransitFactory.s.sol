// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";

/**
 * @notice Code update: swap the factory implementation (UUPS). proxy/beacon/forwarder addresses all stay the same.
 * @dev The caller must be the TransitForwarderFactory owner (_authorizeUpgrade onlyOwner).
 */
contract UpgradeTransitFactoryScript is BaseScript {
    function run() public {
        address factoryProxy = vm.envAddress("TRANSIT_FORWARDER_FACTORY_PROXY");
        address beaconBefore = TransitForwarderFactory(factoryProxy).beacon();

        // Pre-flight, before any broadcast: refuse an upgrade that would permanently brick createForwarder.
        _assertFactoryUpgradeKeepsAddressSpace(factoryProxy);

        vm.startBroadcast();
        TransitForwarderFactory newImpl = new TransitForwarderFactory();
        // Empty calldata when no extra init is needed. Use abi.encodeCall(...) if a reinitializer is required.
        TransitForwarderFactory(factoryProxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        require(
            TransitForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must persist across factory upgrade"
        );
        console2.log("New TransitForwarderFactory impl:", address(newImpl));
        console2.log("Factory proxy (unchanged):", factoryProxy);
    }
}
