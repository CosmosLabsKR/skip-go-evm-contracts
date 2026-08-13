// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransitExecutor} from "../src/TransitExecutor.sol";

/**
 * @notice Deploys the TransitExecutor (impl + ERC1967 proxy). This runs FIRST, before the forwarder impl and the
 *         factory — the forwarder needs the executor PROXY address as a constructor immutable, while the executor
 *         needs nothing from either (it derives the forwarder from each message's mintRecipient), so there is no
 *         circular dependency to break.
 *
 * @dev ⚠️ THE PROXY ADDRESS PRINTED BELOW IS PERMANENT. It goes into two places that can never be revised:
 *      TRANSIT_EXECUTOR_PROXY for every subsequent script, and the source side's `destinationCaller` constant.
 *      Record it before doing anything else. Never publish the implementation address for either use.
 */
contract DeployTransitExecutorScript is BaseScript {
    function run() public {
        // Owner of the proxy (upgrade authority). TRANSIT_EXECUTOR_OWNER when set, otherwise the broadcasting
        // signer — the deployer keeps control by default, which is the sane fallback for a one-off deployment.
        address owner = vm.envOr("TRANSIT_EXECUTOR_OWNER", msg.sender);
        require(owner != address(0), "TRANSIT_EXECUTOR_OWNER is the zero address");
        console2.log("Owner will be:", owner);

        vm.startBroadcast();

        TransitExecutor impl = _deployTransitExecutorImpl();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (owner)));

        vm.stopBroadcast();

        // Post-conditions. The proxy check is not ceremony: every later script consumes this address, and passing an
        // implementation instead would orphan every forwarder at the first upgrade.
        _assertIsProxy(address(proxy), "TransitExecutor proxy");
        TransitExecutor executor = TransitExecutor(address(proxy));
        require(executor.owner() == owner, "executor owner != requested owner");
        require(address(executor.usdc()) == usdc, "usdc not bound");
        require(address(executor.transmitter()) == transmitter, "transmitter not bound");
        require(executor.operator() == operator, "operator not bound");

        console2.log("TransitExecutor implementation (DO NOT USE DOWNSTREAM):", address(impl));
        console2.log("=========================================================");
        console2.log("TRANSIT_EXECUTOR_PROXY (permanent, use this everywhere):", address(proxy));
        console2.log("=========================================================");
        console2.log("Owner:", owner);
        console2.log("Next: set TRANSIT_EXECUTOR_PROXY, then run DeployTransitFactory");
        console2.log("      (that script calls executor.setFactory to close the cycle - run it as the owner above).");
        console2.log("Also: inject this same address as destinationCaller on the SOURCE side, or the griefing");
        console2.log("path this contract exists to close stays open.");
    }
}
