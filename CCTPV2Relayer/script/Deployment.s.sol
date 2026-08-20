// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CCTPV2Relayer} from "../src/CCTPV2Relayer.sol";

/**
 * @notice Deploys a NEW CCTPV2Relayer (impl + ERC1967 proxy) for the current chain.
 * @dev This mints a brand-new proxy every run — it is not idempotent and it is not an upgrade. To change the code
 *      behind an existing relayer use Upgrade.sol; running this instead strands a second relayer on-chain that
 *      nobody upgrades and that operator config may silently pick up. Set EXPECT_NEW_DEPLOYMENT=true to confirm a
 *      fresh deployment is really what is wanted.
 */
contract DeploymentScript is BaseScript {
    function run() public {
        require(
            vm.envOr("EXPECT_NEW_DEPLOYMENT", false),
            "refusing to mint a new relayer proxy: set EXPECT_NEW_DEPLOYMENT=true (use Upgrade.sol to change code)"
        );

        vm.startBroadcast();

        CCTPV2Relayer relayerImpl = new CCTPV2Relayer();
        // abi.encodeCall, not encodeWithSignature: the signature is checked at compile time, so a change to
        // initialize's parameters breaks the build instead of the deployment.
        ERC1967Proxy relayerProxy = new ERC1967Proxy(
            address(relayerImpl), abi.encodeCall(CCTPV2Relayer.initialize, (usdc, messenger, transmitter))
        );

        vm.stopBroadcast();

        // Post-conditions: a failure here aborts the run before anything is broadcast (forge simulates first).
        CCTPV2Relayer relayer = CCTPV2Relayer(payable(address(relayerProxy)));
        require(relayer.owner() == msg.sender, "relayer owner != deployer");
        require(address(relayer.usdc()) == usdc, "usdc not wired");
        require(address(relayer.messenger()) == messenger, "messenger not wired");
        require(address(relayer.transmitter()) == transmitter, "transmitter not wired");
        // The proxy must not be re-initializable by anyone else.
        (bool reinit,) = address(relayerProxy).call(
            abi.encodeCall(CCTPV2Relayer.initialize, (usdc, messenger, transmitter))
        );
        require(!reinit, "proxy is still initializable");

        console2.log("Relayer implementation:", address(relayerImpl));
        console2.log("Relayer proxy (record this as RELAYER_PROXY):", address(relayerProxy));
        console2.log("owner:", relayer.owner());
        console2.log("version:", relayer.version());
        // swapRouter starts unset; the swap entry points stay unusable until SetRouter runs.
        console2.log("swapRouter (unset until SetRouter.sol runs):", relayer.swapRouter());
    }
}
