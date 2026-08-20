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
 *
 *      ⚠️ ONE DELIBERATE BEHAVIOURAL DIVERGENCE from that parity: the two view functions here can REVERT, where the
 *      Inbound/Outbound versions always answer. Only an undeployed route with an unusable tuple reverts, so anything
 *      iterating over LIVE routes is unaffected — but tooling that batches a view across all three factories
 *      (multicall, or a loop with no per-call try/catch) must tolerate a revert from this one. Accepted on purpose:
 *      these are the values a burner commits funds against, so answering is more dangerous than refusing.
 */
interface ITransitForwarderFactory {
    // ── Errors ──
    error ZeroAddress();
    error EmptyMintRecipient();
    error ForwarderAlreadyDeployed(address forwarder);
    // ZeroImplementation / AddressMismatch are declared on the factory itself (merged from ForwarderFactoryBase).
    //
    // ⚠️ All three route-taking functions below can ALSO revert `ITransitForwarder.UnsupportedDestination()`, which
    //    is declared there rather than here — it belongs to the forwarder, and the factory only re-raises it after
    //    reading ALLOWED_DESTINATION_DOMAIN off the beacon's implementation. Import ITransitForwarder to name that
    //    selector in a try/catch.

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

    /// @notice The route's CREATE2 address. This is what a source-chain burner commits as `mintRecipient`.
    /// @dev ⚠️ REVERTS rather than returning an address the route could never occupy — that fail-closed behaviour is
    ///      the whole point, since the caller burns to whatever this returns. Only routes that are NOT deployed yet
    ///      are gated; an existing forwarder always resolves, whatever the current implementation allows.
    function getForwarderAddress(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (address predicted);

    /// @notice True iff the forwarder for this route is already deployed (code exists at its predicted CREATE2
    ///         address). Authoritative — the address is bound to (this factory, salt, beacon initCodeHash), so a
    ///         third party cannot squat it.
    /// @dev Shares createForwarder's guards, so it REVERTS on an undeployable route rather than answering `false` —
    ///      `false` would read as "not yet, but you could", which is how funds get burned toward an address that can
    ///      never hold a forwarder.
    function isForwarderDeployed(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (bool);

    // ── State-changing ──
    /// @dev Shares the same guards as the two views above (`_assertCreatable`): zero sender, empty mintRecipient, or
    ///      any destinationDomain other than the implementation's ALLOWED_DESTINATION_DOMAIN — the local CCTP domain
    ///      included — revert before the CREATE2.
    function createForwarder(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        returns (address forwarder);

    function upgradeForwarderImplementation(address newImplementation) external;

    /// @notice The TransitExecutor every forwarder from this factory answers to. Frozen at initialize.
    function executor() external view returns (address);
}
