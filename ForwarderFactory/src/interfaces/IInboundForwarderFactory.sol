// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the InboundForwarderFactory: deterministically deploys InboundForwarders
 *      (BeaconProxy) from the route key (sender, destinationChainId, destinationReceiver) — the final intent.
 */
interface IInboundForwarderFactory {
    // ── Errors ──
    error ZeroAddress();
    error EmptyRoute();
    error ForwarderAlreadyDeployed(address forwarder);
    // AddressMismatch is declared in ForwarderFactoryBase (shared CREATE2 sanity check).

    // ── Events ──
    event InboundForwarderDeployed(
        address indexed forwarder, address indexed sender, string destinationChainId, string destinationReceiver
    );
    event ForwarderImplementationUpgraded(address indexed newImplementation);

    // ── Views ──
    // beacon() is exposed by ForwarderFactoryBase's public `beacon` state variable (kept out of the interface to
    // avoid a getter/interface-function diamond when the base owns the storage).

    function getForwarderAddress(
        address sender,
        string calldata destinationChainId,
        string calldata destinationReceiver
    ) external view returns (address predicted);

    /// @notice True iff the forwarder for this route is already deployed (code exists at its predicted CREATE2 address).
    ///         Authoritative — the address is unforgeable by third parties, so this doubles as a deployment proof.
    function isForwarderDeployed(
        address sender,
        string calldata destinationChainId,
        string calldata destinationReceiver
    ) external view returns (bool);

    // ── State-changing ──
    function createForwarder(
        address sender,
        string calldata destinationChainId,
        string calldata destinationReceiver
    ) external returns (address forwarder);

    function upgradeForwarderImplementation(address newImplementation) external;
}
