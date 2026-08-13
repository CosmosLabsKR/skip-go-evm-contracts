// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the TransitExecutor: the single fixed address source-chain burners commit as
 *      `destinationCaller`. It calls receiveMessage (minting USDC to the forwarder the message names) and, in the
 *      SAME transaction, has that forwarder re-burn toward its engraved next hop.
 *
 *      Pinning destinationCaller closes the nonce-griefing path: left open (0 = anyone), a third party can call
 *      receiveMessage first, spending the nonce without triggering the burn and stranding the funds. Since this
 *      contract is operator-gated, the whole receive path now is.
 *
 *      Error spellings match the sibling contracts so existing operator tooling needs no new cases. ReceiveFailed
 *      and NothingMinted moved here from ITransitForwarder with the mint capability — same spelling, new emitter.
 *      There is deliberately no malformed-message error: an out-of-range slice reverts by itself.
 */
interface ITransitExecutor {
    // ── Errors ──
    error ZeroAddress();
    error NotOperator();
    error Reentrancy();
    /// @notice mintRecipient's upper 12 bytes are non-zero, so it is not an EVM address.
    /// @dev Truncating would call a plausible-looking but arbitrary address. Non-EVM source domains legitimately
    ///      use all 32 bytes; failing is correct.
    error NotEvmRecipient();
    /// @notice The derived forwarder address holds no code.
    /// @dev Not theoretical: solc >= 0.8.10 omits the extcodesize check on calls returning nothing, so a call
    ///      against an EOA would succeed silently while the minted USDC stayed parked there.
    error NotContract();
    /// @notice The supplied route does not produce the forwarder the message names.
    /// @dev ⚠️ The load-bearing check of the create-on-demand path — the route is operator-supplied. A CREATE2
    ///      address commits to (factory, salt, initCodeHash), so equality proves the route describes exactly the
    ///      address the burner already committed funds to.
    error RouteMismatch();
    /// @notice The forwarder does not exist yet and no factory has been configured to create it.
    error FactoryNotSet();
    error ReceiveFailed(); // transmitter.receiveMessage returned false
    error NothingMinted(); // the forwarder's balance delta after receiveMessage was zero
    /// @notice The measured balance delta does not equal the amount the attested message says was burned.
    /// @dev CCTP v1 mints the body's `amount` exactly — it has no destination-side fee — so the two independent
    ///      sources must agree. Disagreement means the bytes are not the burn message we think they are, or
    ///      something else moved USDC mid-transaction. Either way, proceeding would put a figure into
    ///      TransitCompleted that off-chain reconciliation cannot trust.
    ///
    ///      ⚠️ This equality is v1-specific. A CCTP v2 fast transfer deducts feeExecuted on the destination, so if
    ///      v2 inbound is ever added this must relax to `minted <= amount` for that path.
    error AmountMismatch();
    /// @notice destinationCaller was left unset.
    /// @dev Leaving the next hop callable by anyone is the same griefing path this contract exists to close, one hop
    ///      further along: a third party could receive on the destination, spending the nonce without triggering
    ///      whatever should follow. There is no variant that allows it, so zero is rejected rather than forwarded.
    error EmptyDestinationCaller();

    // ── Events ──
    /// @notice The factory used to create missing forwarders was set or replaced. A configuration change, not a
    ///         transit event; creation itself is recorded by the factory's TransitForwarderDeployed.
    event FactorySet(address indexed previous, address indexed current);

    // ── State-changing (operator-only) ──

    /// @notice Create the forwarder if absent, mint, and have it re-burn — all in one transaction.
    /// @param routeSender Route key and the forwarder's refund/recovery recipient.
    /// @param routeDestinationDomain The next hop's CCTP domain.
    /// @param routeMintRecipient The next hop's recipient. NOT the message's mintRecipient, which is the forwarder.
    /// @param destinationCaller Restricts who may call receiveMessage on the next hop. Must be non-zero — leaving
    ///        it open is the griefing path this design exists to close, one hop further along.
    /// @dev The three route arguments identify the forwarder — the same tuple the factory hashes into its CREATE2
    ///      salt — and are only used when it is not deployed yet. They must resolve to the address the message
    ///      names, or the call reverts with RouteMismatch.
    function executeTransit(
        bytes calldata message,
        bytes calldata attestation,
        address routeSender,
        uint32 routeDestinationDomain,
        bytes32 routeMintRecipient,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    ) external;

    /// @notice Mint and have the forwarder return the funds to its `sender`, skipping the onward burn.
    /// @dev The exit for a message that CAN be minted but cannot be transited — e.g. the amount cannot cover a fee,
    ///      or the burn leg would revert. Without it such a message has no on-chain resolution at all: the source
    ///      chain has already burned, and only receiveMessage on this side can redeem it.
    ///
    ///      Takes no fee, finality or destinationCaller arguments: nothing is burned onward.
    function executeRefund(
        bytes calldata message,
        bytes calldata attestation,
        address routeSender,
        uint32 routeDestinationDomain,
        bytes32 routeMintRecipient
    ) external;

    // ── State-changing (owner-only) ──

    /// @notice Point the executor at the factory it creates missing forwarders with. Also settable at initialize,
    ///         for deployment orders where the factory already exists.
    /// @dev Storage, not an immutable: in the canonical order the factory cannot exist yet, and it must stay
    ///      replaceable — a factory redeployment is a real scenario.
    function setFactory(address factory_) external;

    // ── Views ──
    /// @dev The config immutables are absent by design: their getters return contract-interface types, which cannot
    ///      satisfy an `address`-returning interface function. Scripts read them off the concrete type.
    function factory() external view returns (address);
    function version() external view returns (uint256);
}
