// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {TransitForwarder} from "../src/TransitForwarder.sol";
import {TransitExecutor} from "../src/TransitExecutor.sol";

/**
 * @notice Deploys the TransitForwarderFactory (impl + ERC1967 proxy). The TransitForwarder impl is deployed first
 *         only because the factory's `initialize` needs it — the factory owns the beacon it creates from that impl.
 *         Per-route forwarders are NOT deployed here; use CreateTransitForwarder.
 *
 * @dev Requires TRANSIT_EXECUTOR_PROXY (run DeployTransitExecutor first). The pre-flight below checks it outside
 *      the broadcast so a bad value costs nothing — a forwarder impl bound to the wrong executor is scrap.
 *
 *      Also injects `executor.setFactory`, the last wiring step: the executor could not take the factory at
 *      construction because the factory needs a forwarder impl, which needs the executor. The broadcaster must be
 *      the executor owner, or the first NEW route reverts FactoryNotSet until someone sets it manually.
 */
contract DeployTransitFactoryScript is BaseScript {
    function run() public {
        // Pre-flight, before any broadcast.
        address exec = _executorProxy();
        _assertIsProxy(exec, "TRANSIT_EXECUTOR_PROXY");

        vm.startBroadcast();

        TransitForwarder forwarderImpl = _deployTransitForwarderImpl();
        TransitForwarderFactory impl = new TransitForwarderFactory();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(TransitForwarderFactory.initialize, (address(forwarderImpl))));

        vm.stopBroadcast();

        // Post-conditions: the invariants every later script depends on must hold from the first block.
        TransitForwarderFactory factory = TransitForwarderFactory(address(proxy));
        address beacon = factory.beacon();
        require(factory.owner() == msg.sender, "factory owner != deployer");
        require(UpgradeableBeacon(beacon).owner() == address(factory), "beacon owner != factory proxy");
        require(UpgradeableBeacon(beacon).implementation() == address(forwarderImpl), "impl not installed on beacon");
        // Frozen invariant: the initCodeHash must be cached at initialize, never recomputed.
        require(factory.beaconInitCodeHash() != bytes32(0), "beaconInitCodeHash not cached");
        // The binding that cannot be fixed later: every forwarder this factory produces answers only to this address.
        require(forwarderImpl.executor() == exec, "forwarder impl bound to the wrong executor");

        // Last wiring step: point the executor at the factory it creates missing forwarders with.
        address execOwner = TransitExecutor(exec).owner();
        if (execOwner == msg.sender) {
            vm.broadcast();
            TransitExecutor(exec).setFactory(address(proxy));
            require(TransitExecutor(exec).factory() == address(proxy), "executor.setFactory did not take effect");
            console2.log("executor.factory set to the new factory proxy");
        } else {
            console2.log("!! ACTION REQUIRED - broadcaster is not the executor owner, so factory was NOT set.");
            console2.log("   executor owner:", execOwner);
            console2.log("   run as that owner:  executor.setFactory(", address(proxy), ")");
            console2.log("   until then, creating a NEW route reverts FactoryNotSet.");
        }

        console2.log("TransitForwarder implementation:", address(forwarderImpl));
        console2.log("  bound executor proxy:", exec);
        console2.log("TransitForwarderFactory implementation:", address(impl));
        console2.log("TransitForwarderFactory proxy:", address(proxy));
        console2.log("Beacon:", beacon);
    }
}
