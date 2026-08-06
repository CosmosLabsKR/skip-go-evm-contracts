// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the InboundForwarder: receives a CCTP v2 message on Injective EVM (mint USDC to this
 *      address), then signals a synchronous IBC transfer to the Injective event-hook via IBCTransferRequested.
 */
interface IInboundForwarder {
    /// @notice Distinguishes the two refund situations recorded by the Refunded event.
    enum RefundKind {
        MintTime, // mintAndRefund: minted then immediately refunded (never routed)
        PostRoute // refund()/refund(amount): funds returned to this forwarder after a downstream IBC failure
    }

    // ── Errors ──
    error ZeroAddress();
    error DenomLengthUnexpected(); // constructor: rendered denom is not the 48 bytes the immutable split assumes
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
    /// @notice ABI must match injective-event/src/IBCTransferEmitter.sol exactly (the Injective hook's listener ABI).
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

    /// @notice Internal accounting signal for refunds (NOT an IBC trigger — the hook ignores it).
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
