// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the Skip ForwarderFactory contract.
 */
interface IForwarderFactory {
    // ── Errors ──
    error ZeroAddress();
    error EmptyMintRecipient();
    error ForwarderAlreadyDeployed(address forwarder);
    error AddressMismatch();

    // ── Events ──
    event ForwarderDeployed(
        address indexed forwarder, address indexed sender, uint32 destinationDomain, bytes32 mintRecipient
    );
    event ForwarderImplementationUpgraded(address indexed newImplementation);

    // ── Views ──
    function beacon() external view returns (address);

    function getForwarderAddress(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (address predicted);

    // ── State-changing ──
    function createForwarder(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        returns (address forwarder);

    function upgradeForwarderImplementation(address newImplementation) external;
}
