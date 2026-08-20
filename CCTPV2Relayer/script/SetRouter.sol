// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {CCTPV2Relayer} from "../src/CCTPV2Relayer.sol";

/**
 * @notice Points the relayer's swap path at a swap router.
 * @dev Both the relayer and the router come from the environment. The previous version of this file hardcoded the
 *      v1 CCTPRelayer proxy on Polygon (0x1fe8e504…) together with the Polygon router — run on the wrong chain it
 *      would have reconfigured v1. `_requireRelayerProxy` now proves the target is THIS chain's v2 relayer before
 *      anything is broadcast, so the address is input rather than a constant that silently rots.
 *
 *      The router is a funds-sensitive setting: `_executeSwap` approves it for the caller's input token and calls
 *      it with caller-supplied calldata, so a wrong address here puts user funds at risk. The sanity checks below
 *      catch the mistakes that are mechanically detectable; choosing the right router remains an operator decision.
 *
 *      Usage: RELAYER_PROXY=0x... SWAP_ROUTER=0x... forge script script/SetRouter.sol --rpc-url <chain> --broadcast
 */
contract SetRouterScript is BaseScript {
    function run() public {
        address proxy = _requireRelayerProxy();
        address router = vm.envAddress("SWAP_ROUTER");
        CCTPV2Relayer relayer = CCTPV2Relayer(payable(proxy));

        require(router != address(0), "SWAP_ROUTER is zero");
        require(router.code.length != 0, "no code at SWAP_ROUTER");
        // A router that is any of these is a configuration error, not a swap venue.
        require(router != proxy, "SWAP_ROUTER is the relayer itself");
        require(router != usdc, "SWAP_ROUTER is the USDC token");
        require(router != messenger, "SWAP_ROUTER is the CCTP messenger");
        require(router != transmitter, "SWAP_ROUTER is the CCTP transmitter");

        address previous = relayer.swapRouter();
        require(router != previous, "SWAP_ROUTER already set to this address");

        console2.log("relayer proxy:", proxy);
        console2.log("swapRouter:", previous, "->", router);

        vm.startBroadcast();
        relayer.setSwapRouter(router);
        vm.stopBroadcast();

        require(relayer.swapRouter() == router, "swapRouter not applied");
    }
}
