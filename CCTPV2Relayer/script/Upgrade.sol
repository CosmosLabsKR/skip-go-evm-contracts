// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "./Config.sol";

import {CCTPV2Relayer} from "../src/CCTPV2Relayer.sol";

/// @notice Upgrades the deployed CCTPV2Relayer (UUPS) to a freshly deployed implementation.
/// @dev The proxy address is resolved from Config by chain id (no hardcoded address), mirroring the
///      deploy BaseScript pattern. Only the Injective chains are supported; the broadcaster must be the
///      proxy owner (CCTPV2Relayer._authorizeUpgrade is onlyOwner).
contract UpgradeScript is Script {
    CCTPV2Relayer public relayer;

    function setUp() public {
        relayer = CCTPV2Relayer(payable(_relayerProxy()));
    }

    /// @dev Resolve the deployed CCTPV2Relayer proxy from Config by the active chain id.
    function _relayerProxy() internal view returns (address proxy) {
        if (block.chainid == CHAIN_INJECTIVE) {
            proxy = RELAYER_PROXY_INJECTIVE;
        } else if (block.chainid == CHAIN_INJECTIVE_TESTNET) {
            proxy = RELAYER_PROXY_INJECTIVE_TESTNET;
        } else {
            revert("Chain not supported.");
        }
        // Guard against an unset (address(0)) Config entry — e.g. a mainnet upgrade before the relayer is deployed.
        require(proxy != address(0), "Relayer proxy not set in Config");
    }

    function run() public {
        address proxy = address(relayer);

        vm.startBroadcast();
        CCTPV2Relayer newImplementation = new CCTPV2Relayer();
        relayer.upgradeToAndCall(address(newImplementation), bytes(""));
        vm.stopBroadcast();

        console2.log("Upgraded relayer proxy:", proxy);
        console2.log("New implementation:    ", address(newImplementation));
    }
}
