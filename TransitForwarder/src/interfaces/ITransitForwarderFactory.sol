// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the TransitForwarderFactory.
 *
 *      The five public surfaces below keep the SAME names as the sibling ForwarderFactory factories
 *      (getForwarderAddress / isForwarderDeployed / createForwarder / upgradeForwarderImplementation /
 *      ForwarderImplementationUpgraded). This subproject is separate, so the original "one vocabulary per
 *      subproject" argument no longer applies — what survives is that the off-chain operator tooling and indexer
 *      handle all three factories on the same chain, and identical ABI names mean the third needs no special case.
 */
interface ITransitForwarderFactory {
    // ── Errors ──
    error ZeroAddress();
    error EmptyMintRecipient();
    error ForwarderAlreadyDeployed(address forwarder);
    // ZeroImplementation / AddressMismatch are declared on the factory itself (merged from ForwarderFactoryBase).

    // ── Events ──
    /// @dev ⚠️ Unlike the inbound/outbound pair, this event's parameter shape (uint32,bytes32) is IDENTICAL to
    ///      OutboundForwarderDeployed's, so the "different types make topic0 inherently distinct" reasoning used
    ///      there does NOT apply here. The only thing separating the two topic0 values is the event NAME string.
    ///      Combined with the salt preimage being byte-identical to the outbound factory's, an off-chain indexer
    ///      must key on (factory address, topic0) — never on the route tuple alone.
    event TransitForwarderDeployed(
        address indexed forwarder, address indexed sender, uint32 destinationDomain, bytes32 mintRecipient
    );
    event ForwarderImplementationUpgraded(address indexed newImplementation);

    // ── Views ──
    // beacon() / beaconInitCodeHash() are public state variables on the factory (kept out of this interface to
    // avoid a getter/interface-function diamond).

    function getForwarderAddress(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (address predicted);

    /// @notice True iff the forwarder for this route is already deployed (code exists at its predicted CREATE2
    ///         address). Authoritative — the address is bound to (this factory, salt, beacon initCodeHash), so a
    ///         third party cannot squat it.
    function isForwarderDeployed(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (bool);

    // ── State-changing ──
    /// @dev Reverts with TransitForwarder.SelfLoop() (bubbled from initialize) when destinationDomain is the local
    ///      CCTP domain — the factory itself cannot check that, since LOCAL_DOMAIN is an impl immutable.
    function createForwarder(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        returns (address forwarder);

    function upgradeForwarderImplementation(address newImplementation) external;

    /// @notice The TransitExecutor every forwarder from this factory answers to. Frozen at initialize.
    function executor() external view returns (address);
}
