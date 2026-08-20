// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {InboundForwarderFactory} from "../src/InboundForwarderFactory.sol";

/**
 * @notice Code update: swap the factory implementation (UUPS). proxy/beacon/forwarder addresses all stay the same.
 * @dev The caller must be the InboundForwarderFactory owner (_authorizeUpgrade onlyOwner).
 */
contract UpgradeInboundFactoryScript is BaseScript {
    function run() public {
        address factoryProxy = vm.envAddress("INBOUND_FORWARDER_FACTORY_PROXY");
        address beaconBefore = InboundForwarderFactory(factoryProxy).beacon();

        // Pre-flight, before any broadcast: refuse an upgrade that would permanently brick createForwarder.
        _assertFactoryUpgradeKeepsAddressSpace(factoryProxy);

        vm.startBroadcast();
        InboundForwarderFactory newImpl = new InboundForwarderFactory();
        // Empty calldata when no extra init is needed. Use abi.encodeCall(...) if a reinitializer is required.
        InboundForwarderFactory(factoryProxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        require(InboundForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must persist across factory upgrade");
        console2.log("New InboundForwarderFactory impl:", address(newImpl));
        console2.log("Factory proxy (unchanged):", factoryProxy);
    }
}
