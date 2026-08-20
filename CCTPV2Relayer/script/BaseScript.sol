// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./Config.sol";

/// @dev The wiring a deployed CCTPV2Relayer exposes — enough to prove an address is this chain's relayer.
interface IRelayerWiring {
    function usdc() external view returns (address);
    function messenger() external view returns (address);
    function transmitter() external view returns (address);
}

abstract contract BaseScript is Script {
    address public immutable usdc;
    address public immutable messenger;
    address public immutable transmitter;

    constructor() {
        if (block.chainid == CHAIN_MAINNET) {
            usdc = USDC_MAINNET;
            messenger = MESSENGER_MAINNET;
            transmitter = TRANSMITTER_MAINNET;
        } else if (block.chainid == CHAIN_AVALANCHE) {
            usdc = USDC_AVALANCHE;
            messenger = MESSENGER_AVALANCHE;
            transmitter = TRANSMITTER_AVALANCHE;
        } else if (block.chainid == CHAIN_OP) {
            usdc = USDC_OP;
            messenger = MESSENGER_OP;
            transmitter = TRANSMITTER_OP;
        } else if (block.chainid == CHAIN_ARBITRUM) {
            usdc = USDC_ARBITRUM;
            messenger = MESSENGER_ARBITRUM;
            transmitter = TRANSMITTER_ARBITRUM;
        } else if (block.chainid == CHAIN_BASE) {
            usdc = USDC_BASE;
            messenger = MESSENGER_BASE;
            transmitter = TRANSMITTER_BASE;
        } else if (block.chainid == CHAIN_POLYGON) {
            usdc = USDC_POLYGON;
            messenger = MESSENGER_POLYGON;
            transmitter = TRANSMITTER_POLYGON;
        } else if (block.chainid == CHAIN_SEPOLIA) {
            usdc = USDC_SEPOLIA;
            messenger = MESSENGER_SEPOLIA;
            transmitter = TRANSMITTER_SEPOLIA;
        } else if (block.chainid == CHAIN_AVALANCHE_FUJI) {
            usdc = USDC_AVALANCHE_FUJI;
            messenger = MESSENGER_AVALANCHE_FUJI;
            transmitter = TRANSMITTER_AVALANCHE_FUJI;
        } else if (block.chainid == CHAIN_OP_SEPOLIA) {
            usdc = USDC_OP_SEPOLIA;
            messenger = MESSENGER_OP_SEPOLIA;
            transmitter = TRANSMITTER_OP_SEPOLIA;
        } else if (block.chainid == CHAIN_ARBITRUM_SEPOLIA) {
            usdc = USDC_ARBITRUM_SEPOLIA;
            messenger = MESSENGER_ARBITRUM_SEPOLIA;
            transmitter = TRANSMITTER_ARBITRUM_SEPOLIA;
        } else if (block.chainid == CHAIN_BASE_SEPOLIA) {
            usdc = USDC_BASE_SEPOLIA;
            messenger = MESSENGER_BASE_SEPOLIA;
            transmitter = TRANSMITTER_BASE_SEPOLIA;
        } else if (block.chainid == CHAIN_POLYGON_AMOY) {
            usdc = USDC_POLYGON_AMOY;
            messenger = MESSENGER_POLYGON_AMOY;
            transmitter = TRANSMITTER_POLYGON_AMOY;
        } else if (block.chainid == CHAIN_INJECTIVE) {
            usdc = USDC_INJECTIVE;
            messenger = MESSENGER_INJECTIVE;
            transmitter = TRANSMITTER_INJECTIVE;
        } else if (block.chainid == CHAIN_INJECTIVE_TESTNET) {
            usdc = USDC_INJECTIVE_TESTNET;
            messenger = MESSENGER_INJECTIVE_TESTNET;
            transmitter = TRANSMITTER_INJECTIVE_TESTNET;
        } else {
            revert("Chain not supported.");
        }
    }

    /// @dev Entry guard for scripts that act on an EXISTING relayer.
    ///
    ///      The target comes from the environment (same convention as the ForwarderFactory scripts) rather than a
    ///      per-chain constant: this relayer ships to every CCTP chain and is redeployed over time, so a table of
    ///      proxy addresses in Config would be stale by construction.
    ///
    ///      What is checked instead is that the contract at that address really is THIS chain's relayer — its
    ///      dependency wiring must equal the Config values BaseScript resolved for the current chain id. That
    ///      catches a wrong-chain address, a stale address, and a v1 CCTPRelayer address alike, on all 14 chains,
    ///      without hardcoding anything.
    function _requireRelayerProxy() internal view returns (address proxy) {
        proxy = _relayerProxyTarget();
        require(proxy != address(0), "RELAYER_PROXY is zero");
        require(proxy.code.length != 0, "no code at RELAYER_PROXY");

        if (_configMismatchAllowed()) {
            console2.log("!! skipping the chain-consistency check (ALLOW_CONFIG_MISMATCH=true)");
            return proxy;
        }
        IRelayerWiring target = IRelayerWiring(proxy);
        require(target.usdc() == usdc, "RELAYER_PROXY.usdc() != Config usdc for this chain");
        require(target.messenger() == messenger, "RELAYER_PROXY.messenger() != Config messenger for this chain");
        require(
            target.transmitter() == transmitter, "RELAYER_PROXY.transmitter() != Config transmitter for this chain"
        );
    }

    /// @dev `virtual` so tests can drive these deterministically — vm.setEnv writes the real process environment,
    ///      which forge shares across the test contracts it runs in parallel.
    function _relayerProxyTarget() internal view virtual returns (address) {
        return vm.envAddress("RELAYER_PROXY");
    }

    function _configMismatchAllowed() internal view virtual returns (bool) {
        return vm.envOr("ALLOW_CONFIG_MISMATCH", false);
    }

    /// @dev Reads `version()` without assuming it exists. `version()` was added after the first implementations
    ///      shipped, so a plain `relayer.version()` reverts against any pre-version impl — which is precisely the
    ///      impl an upgrade is most likely to be replacing. It is a diagnostic, so a missing one must never block
    ///      the upgrade that introduces it.
    /// @return version The reported version, or 0 when the implementation predates `version()`.
    /// @return exists Whether the call returned a decodable value.
    function _tryVersion(address proxy) internal view returns (uint256 version, bool exists) {
        (bool ok, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("version()"));
        if (ok && data.length == 32) return (abi.decode(data, (uint256)), true);
        return (0, false);
    }
}
