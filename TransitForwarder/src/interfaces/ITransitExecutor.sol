// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the TransitExecutor: the single fixed address that source-chain burners commit as
 *      `destinationCaller`. It calls CCTP's receiveMessage (minting USDC to the forwarder named by the message's
 *      mintRecipient) and, in the SAME transaction, instructs that forwarder to re-burn toward its engraved next hop.
 *
 *      Pinning destinationCaller to one address is what closes the nonce-griefing path: with it open (0 = anyone), a
 *      third party can call receiveMessage first, spending the nonce without triggering the burn and stranding the
 *      funds on the forwarder. Because this contract is operator-gated, the entire receive path is now operator-gated.
 *
 *      Error spellings are kept identical to the sibling contracts so the off-chain operator tooling that already
 *      decodes those reverts needs no new cases. ReceiveFailed and NothingMinted MOVED here from ITransitForwarder
 *      along with the mint capability — same spelling, different emitting contract.
 *
 *      MalformedMessage is deliberately NOT redeclared here: it belongs to CCTPV2Message, matching the convention
 *      ITransitForwarder already follows.
 */
interface ITransitExecutor {
    /// @notice The route that identifies a forwarder: exactly the tuple the factory hashes into its CREATE2 salt.
    /// @dev Carried as a struct rather than three loose arguments so the entry points stay under the stack limit and
    ///      so call sites read as "this route" rather than three unrelated values.
    /// @param sender Route key and the forwarder's sole refund/recovery recipient.
    /// @param destinationDomain The next hop's CCTP domain — engraved in the forwarder's address.
    /// @param mintRecipient The next hop's recipient — also engraved. NOT the same as the message's mintRecipient,
    ///        which is the forwarder itself.
    struct Route {
        address sender;
        uint32 destinationDomain;
        bytes32 mintRecipient;
    }

    // ── Errors ──
    error ZeroAddress();
    error NotOperator();
    error Reentrancy();
    /// @notice mintRecipient's upper 12 bytes are non-zero, so it is not an EVM address.
    /// @dev Truncating to the low 20 bytes would call a plausible-looking but arbitrary address. Non-EVM source
    ///      domains (Solana, Sui, Aptos) legitimately use all 32 bytes; failing is correct.
    error NotEvmRecipient();
    /// @notice The derived forwarder address holds no code.
    /// @dev Not theoretical. solc >= 0.8.10 omits the extcodesize check on external calls that return nothing, so
    ///      transferMinted against an EOA would SUCCEED silently while the minted USDC stays parked on that EOA —
    ///      and the executor would report success to the operator. Most ERC20s reject a mint to address(0), but a
    ///      mint to an EOA is perfectly normal, so this is reachable.
    error NotContract();
    /// @notice The supplied route does not produce the forwarder the message names.
    /// @dev ⚠️ The load-bearing check of the create-on-demand path. The route arguments come from the operator, so
    ///      without this it could mint a forwarder for any route it liked. A CREATE2 address commits to
    ///      (factory, salt, initCodeHash), so equality proves the route describes exactly the address the
    ///      source-chain burner already committed funds to.
    error RouteMismatch();
    /// @notice The forwarder does not exist yet and no factory has been configured to create it.
    error FactoryNotSet();
    error ReceiveFailed(); // transmitter.receiveMessage returned false
    error NothingMinted(); // the forwarder's balance delta after receiveMessage was zero

    // ── Events ──
    /// @notice Escape hatch only. The transit path emits NOTHING here on purpose: the authoritative reconciliation
    ///         events are the forwarder's TransitCompleted / Refunded, and a duplicate in the same transaction would
    ///         leave the off-chain side unable to tell which one is the truth.
    /// @dev Recovery is off the transit path and has no reconciliation key (no sourceNonce), so without this event a
    ///      token movement would leave no trace in the logs at all. Unlike the forwarder's Recovered, this carries
    ///      `to` because the destination is an argument rather than the engraved `sender`.
    event Recovered(address indexed token, address indexed to, uint256 amount);

    /// @notice The factory used to create missing forwarders was set or replaced.
    /// @dev Not a violation of the "no events on the transit path" rule: this is a configuration change, and the
    ///      authoritative record of a forwarder's creation remains the factory's own TransitForwarderDeployed.
    event FactorySet(address indexed previous, address indexed current);

    // ── State-changing (operator-only) ──

    /// @notice Create the forwarder if it does not exist yet, mint via CCTP, and instruct that forwarder to
    ///         re-burn — all in one transaction. Next hop destinationCaller = any.
    /// @param route Only used when the forwarder is not deployed yet; ignored otherwise. It must resolve to the
    ///        address the message names, or the call reverts with RouteMismatch.
    function executeTransit(
        bytes calldata message,
        bytes calldata attestation,
        Route calldata route,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    /// @dev Argument order mirrors ICCTPV2Relayer: destinationCaller after minFinalityThreshold, before hookData.
    function executeTransitWithCaller(
        bytes calldata message,
        bytes calldata attestation,
        Route calldata route,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external;

    /// @notice Mint and have the forwarder return the funds to its `sender`, skipping the onward burn entirely.
    function executeRefund(bytes calldata message, bytes calldata attestation, Route calldata route) external;

    // ── State-changing (owner-only) ──

    /// @notice Escape hatch. This contract holds no funds by design; this exists for third-party mis-sends.
    /// @dev owner rather than operator: giving the operator an arbitrary-destination withdrawal would collapse the
    ///      least-privilege split that the operator/executor separation exists to create.
    function recoverERC20(address token, address to) external;

    /// @notice Point the executor at the factory it should create missing forwarders with.
    /// @dev Storage rather than an immutable because the factory cannot exist yet when this contract is deployed:
    ///      the factory needs a forwarder implementation, which needs this contract's address. Setting it after the
    ///      fact is what breaks that cycle. Re-settable because a factory redeployment is a real scenario.
    function setFactory(address factory_) external;

    // ── Views ──
    /// @dev The config immutables (usdc / transmitter / operator) are deliberately absent, matching
    ///      ITransitForwarder: their getters are typed as contract interfaces on the implementation, which cannot
    ///      satisfy an `address`-returning interface function. Scripts read them off the concrete type instead.
    function factory() external view returns (address);
    function version() external view returns (uint256);
}
