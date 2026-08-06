// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the InboundForwarder: receives a CCTP v2 message on Injective EVM, which mints USDC to the
 *      forwarder, and records the intended onward IBC transfer as IBCTransferRequested. The transfer itself is not
 *      performed yet — see the INTERIM note on InboundForwarder.
 */
interface IInboundForwarder {
    /// @notice Distinguishes the two refund situations recorded by the Refunded event.
    enum RefundKind {
        MintTime, // mintAndRefund: minted then immediately refunded (never routed)
        PostRoute // refund()/refund(amount): sweeping funds left on the forwarder after a route attempt
    }

    // ── Errors ──
    error ZeroAddress();
    error EmptyRoute(); // initialize: empty destinationChainId/destinationReceiver
    error EmptyHookRoute(); // mintAndRoute: decoded hookData has empty channelId/receiver
    error NotOperator();
    error Reentrancy();
    error NativeNotAccepted();
    error ReceiveFailed(); // transmitter.receiveMessage returned false
    error NothingMinted(); // balance delta after receiveMessage was zero
    error WrongDestination(); // message.destinationDomain != INJECTIVE_DOMAIN
    error WrongRecipient(); // burn.mintRecipient != address(this)
    error WrongSender(); // burn.messageSender != bound sender
    error ZeroAmount();
    error MissingBalance(); // refund amount exceeds current balance

    // ── Events ──
    /// @notice INTERIM signal: nothing on-chain consumes this. It carries the arguments the ICS20 precompile will
    ///         take, so the team can verify routing before that call exists. Shape is pinned by
    ///         test_EventSignatureMatchesCanonical, which is self-contained — there is no external ABI to match.
    ///         topic0 = keccak256("IBCTransferRequested(string,string,string,uint256,address,string,string,uint64)")
    event IBCTransferRequested(
        string sourcePort,
        string sourceChannel,
        string tokenDenom,
        uint256 tokenAmount,
        address sender,
        string receiver,
        string memo,
        uint64 timeoutTimestamp
    );

    /// @notice Accounting signal for refunds. Distinct from IBCTransferRequested so the two never get conflated
    ///         once that one starts driving a real transfer.
    event Refunded(bytes32 indexed sourceNonce, address indexed to, uint256 amount, RefundKind kind);

    // ── State-changing (operator-only) ──
    function mintAndRoute(bytes calldata message, bytes calldata attestation) external;
    function mintAndRefund(bytes calldata message, bytes calldata attestation) external;
    function refund() external;
    function refund(uint256 amount) external;

    // ── Views ──
    function getRoute()
        external
        view
        returns (
            address sender,
            string memory destinationChainId,
            string memory destinationReceiver,
            address refundRecipient
        );
}
