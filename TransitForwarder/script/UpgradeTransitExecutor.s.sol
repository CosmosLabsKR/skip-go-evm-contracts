// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {TransitExecutor} from "../src/TransitExecutor.sol";

/**
 * @notice Code update: swap the TransitExecutor implementation (UUPS). The proxy address — baked into every
 *         forwarder and into already-burned messages' destinationCaller — stays the same. That is the whole point.
 * @dev Caller must be the TransitExecutor owner. Also how `operator` is rotated (it is an impl immutable): the
 *      drift guard reports it as intentional drift, so set ALLOW_IMMUTABLE_REBIND=true for that run.
 */
contract UpgradeTransitExecutorScript is BaseScript {
    function run() public {
        address executorProxy = _executorProxy();
        _assertIsProxy(executorProxy, "TRANSIT_EXECUTOR_PROXY");

        address liveImpl = _liveImplOf(executorProxy);
        address ownerBefore = TransitExecutor(executorProxy).owner();

        // Pre-flight, before any broadcast: a failure here must cost nothing and leave no on-chain trace.
        _assertExecutorImmutablesMatch(liveImpl);

        vm.startBroadcast();
        TransitExecutor newImpl = _deployTransitExecutorImpl();
        // Empty calldata when no extra init is needed. Use abi.encodeCall(...) if a reinitializer is required.
        TransitExecutor(executorProxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        require(TransitExecutor(executorProxy).owner() == ownerBefore, "owner must persist across upgrade");
        _assertIsProxy(executorProxy, "TRANSIT_EXECUTOR_PROXY");

<<<<<<< HEAD
=======
        // ⚠️ The forwarder half of the pair cannot be checked as a hard precondition here: this script runs FIRST,
        //    so at this point the forwarder is legitimately still on the old version. Report it loudly instead —
        //    between the two steps the transit path is DOWN, and a run left half-finished is the failure mode.
        //    (UpgradeTransitForwarder does enforce the pair, because by then both versions are knowable.)
        uint256 execVersion = TransitExecutor(executorProxy).version();
        address factoryProxy = vm.envOr("TRANSIT_FORWARDER_FACTORY_PROXY", address(0));
        if (factoryProxy != address(0)) {
            uint256 fwdVersion = TransitForwarder(payable(_liveForwarderImpl(factoryProxy))).version();
            if (fwdVersion != execVersion) {
                console2.log("!! ACTION REQUIRED - the pair is now MISMATCHED and transit is DOWN.");
                console2.log("   executor version :", execVersion);
                console2.log("   forwarder version:", fwdVersion);
                console2.log("   run UpgradeTransitForwarder next to complete the migration.");
            } else {
                console2.log("executor/forwarder versions match:", execVersion);
            }
        } else {
            console2.log("!! set TRANSIT_FORWARDER_FACTORY_PROXY to have this script verify the pair.");
            console2.log("   The forwarder must end on the same version() as this executor:", execVersion);
        }

>>>>>>> sungrak/cctp-v2-contracts
        console2.log("Previous TransitExecutor impl:", liveImpl);
        console2.log("New TransitExecutor impl:", address(newImpl));
        console2.log("Executor proxy (unchanged, as required):", executorProxy);
    }
}
