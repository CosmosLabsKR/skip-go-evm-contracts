// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {TransitForwarder} from "../src/TransitForwarder.sol"; // can be swapped for new logic (e.g. TransitForwarderV2)

/**
 * @notice Code update: swap the beacon impl to new TransitForwarder logic -> applied in bulk to all N deployed instances.
 * @dev The caller must be the TransitForwarderFactory owner (upgradeForwarderImplementation onlyOwner).
 *      The beacon address is immutable, so predicted/actual forwarder addresses stay the same.
<<<<<<< HEAD
=======
 *
 *      ⚠️ THE EXECUTOR AND THE FORWARDER ARE ONE UNIT. They share the `transferMinted` ABI, so a mismatched pair
 *      does not fail loudly — the executor's call lands in the forwarder's `fallback()` and reverts
 *      NativeNotAccepted, an error naming a completely unrelated problem, on the LIVE transit path with CCTP
 *      messages already in flight. `version()` is what makes the pair checkable, and the guard below is what makes
 *      a half-finished migration impossible from this side.
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
=======

        // ⚠️ Pair check, deliberately BEFORE the install and AFTER the impl exists (its version is only readable
        //    from an instance). A revert here aborts the whole run in simulation, so nothing is broadcast — the
        //    impl is not even deployed. Upgrade the EXECUTOR first; this refuses to leave the pair mismatched.
        uint256 execVersion = TransitExecutor(_executorProxy()).version();
        uint256 fwdVersion = newImpl.version();
        if (execVersion != fwdVersion) {
            console2.log("  live executor version:", execVersion);
            console2.log("  new forwarder version:", fwdVersion);
            revert(
                "executor/forwarder version mismatch - run UpgradeTransitExecutor first; a mismatched pair reverts NativeNotAccepted on the live transit path"
            );
        }

>>>>>>> sungrak/cctp-v2-contracts
        TransitForwarderFactory(factoryProxy).upgradeForwarderImplementation(address(newImpl));
        vm.stopBroadcast();

        require(TransitForwarderFactory(factoryProxy).beacon() == beaconBefore, "beacon must not change");
        require(_liveForwarderImpl(factoryProxy) == address(newImpl), "new impl not installed on beacon");
        console2.log("New TransitForwarder impl:", address(newImpl));
        console2.log("Beacon (unchanged):", beaconBefore);
<<<<<<< HEAD
=======
        console2.log("executor/forwarder version (matched pair):", fwdVersion);
>>>>>>> sungrak/cctp-v2-contracts
    }
}
