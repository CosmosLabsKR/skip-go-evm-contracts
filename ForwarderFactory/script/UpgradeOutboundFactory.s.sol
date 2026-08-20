// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {OutboundForwarderFactory} from "../src/OutboundForwarderFactory.sol";

/**
 * @notice Code update: swap the factory implementation (UUPS). proxy/beacon/forwarder addresses all stay the same.
 * @dev The caller must be the OutboundForwarderFactory owner (_authorizeUpgrade onlyOwner).
 */
contract UpgradeOutboundFactoryScript is BaseScript {
    function run() public {
        address factoryProxy = vm.envAddress("OUTBOUND_FORWARDER_FACTORY_PROXY");
        address beaconBefore = OutboundForwarderFactory(factoryProxy).beacon();

        // Pre-flight, before any broadcast: refuse an upgrade that would permanently brick createForwarder.
        _assertFactoryUpgradeKeepsAddressSpace(factoryProxy);

        vm.startBroadcast();
        OutboundForwarderFactory newImpl = new OutboundForwarderFactory();
        // Empty calldata when no extra init is needed. Use abi.encodeCall(...) if a reinitializer is required.
        OutboundForwarderFactory(factoryProxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        require(OutboundForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must persist across factory upgrade");
        console2.log("New OutboundForwarderFactory impl:", address(newImpl));
        console2.log("Factory proxy (unchanged):", factoryProxy);
    }
}
