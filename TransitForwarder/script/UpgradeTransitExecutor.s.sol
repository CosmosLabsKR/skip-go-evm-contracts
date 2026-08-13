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

        console2.log("Previous TransitExecutor impl:", liveImpl);
        console2.log("New TransitExecutor impl:", address(newImpl));
        console2.log("Executor proxy (unchanged, as required):", executorProxy);
    }
}
