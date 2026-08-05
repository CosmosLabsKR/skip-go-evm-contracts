// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseScript.sol";

import {CCTPV2Relayer} from "../src/CCTPV2Relayer.sol";

/**
 * @notice Code update: swap the relayer implementation (UUPS). The proxy address is unchanged.
 * @dev The target comes from RELAYER_PROXY (env) — never hardcoded. This relayer ships to every CCTP chain and is
 *      redeployed over time, so the address is per-run input, not a constant. `_requireRelayerProxy` then proves the
 *      contract at that address is THIS chain's relayer by matching its usdc/messenger/transmitter against the
 *      Config values for the current chain id, which is what a hardcoded address could never do.
 *      The caller must be the relayer owner (_authorizeUpgrade onlyOwner).
 *
 *      Usage: RELAYER_PROXY=0x... forge script script/Upgrade.sol --rpc-url <chain> --broadcast
 */
contract UpgradeScript is BaseScript {
    function run() public {
        address proxy = _requireRelayerProxy();
        CCTPV2Relayer relayer = CCTPV2Relayer(payable(proxy));

        // Snapshot the storage a UUPS upgrade must never disturb.
        address ownerBefore = relayer.owner();
        address usdcBefore = address(relayer.usdc());
        address messengerBefore = address(relayer.messenger());
        address transmitterBefore = address(relayer.transmitter());
        address routerBefore = relayer.swapRouter();
        uint256 versionBefore = relayer.version();

        vm.startBroadcast();
        CCTPV2Relayer newImplementation = new CCTPV2Relayer();
        relayer.upgradeToAndCall(address(newImplementation), bytes(""));
        vm.stopBroadcast();

        // A storage-layout mistake surfaces here instead of in production.
        require(relayer.owner() == ownerBefore, "owner changed across upgrade");
        require(address(relayer.usdc()) == usdcBefore, "usdc changed across upgrade");
        require(address(relayer.messenger()) == messengerBefore, "messenger changed across upgrade");
        require(address(relayer.transmitter()) == transmitterBefore, "transmitter changed across upgrade");
        require(relayer.swapRouter() == routerBefore, "swapRouter changed across upgrade");

        uint256 versionAfter = relayer.version();
        require(versionAfter >= versionBefore, "version() regressed");
        if (versionAfter == versionBefore) {
            // version() exists so an operator can tell which implementation is live; shipping without a bump
            // leaves that question unanswerable. Surfaced, not blocked — whether to bump is the author's call.
            console2.log("!! version() unchanged at", versionAfter, "- consider bumping it in the new impl");
        }

        console2.log("Relayer proxy (unchanged):", proxy);
        console2.log("New implementation:       ", address(newImplementation));
        console2.log("version:", versionBefore, "->", versionAfter);
    }
}
