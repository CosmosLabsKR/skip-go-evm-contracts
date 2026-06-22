// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the Skip OutboundForwarderFactory contract.
 */
interface IOutboundForwarderFactory {
    // ── Errors ──
    error ZeroAddress();
    error EmptyMintRecipient();
    error ForwarderAlreadyDeployed(address forwarder);
    // AddressMismatch is declared in ForwarderFactoryBase (shared CREATE2 sanity check).

    // ── Events ──
    // OutboundForwarderDeployed keeps its prefix: its parameter shape (uint32,bytes32) differs from the inbound
    // event (string,string), so topic0 is inherently distinct — the prefix gives indexers a free discriminator.
    event OutboundForwarderDeployed(
        address indexed forwarder, address indexed sender, uint32 destinationDomain, bytes32 mintRecipient
    );
    event ForwarderImplementationUpgraded(address indexed newImplementation);

    // ── Views ──
    // beacon() is exposed by ForwarderFactoryBase's public `beacon` state variable (kept out of the interface to
    // avoid a getter/interface-function diamond when the base owns the storage).

    function getForwarderAddress(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (address predicted);

    /// @notice True iff the forwarder for this route is already deployed (code exists at its predicted CREATE2 address).
    ///         Authoritative — the address is unforgeable by third parties, so this doubles as a deployment proof.
    function isForwarderDeployed(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (bool);

    // ── State-changing ──
    function createForwarder(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        returns (address forwarder);

    function upgradeForwarderImplementation(address newImplementation) external;
}
