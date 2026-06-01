// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @dev Interface for Skip CCTPV2Relayer contract.
 */
interface ICCTPV2Relayer {
    error ZeroAddress();
    error TransferFailed();
    error ETHSendFailed();
    error MissingBalance();
    error PaymentCannotBeZero();
    error SwapFailed();
    error InsufficientSwapOutput();
    error InsufficientNativeToken();
    error Reentrancy();
    error InvalidMaxFee();
    error InvalidFinalityThreshold(); // minFinalityThreshold must be 1000 (fast) or 2000 (standard)

    /**
     * @notice Emitted when a relayer-service fee is paid.
     * @dev CCTP v2 removes the synchronous nonce, so the fee is no longer keyed by nonce.
     * - For the burn paths (`requestCCTPTransfer*`, `swapAndRequestCCTPTransfer*`), `messageHash`
     *   is `bytes32(0)`: the off-chain relayer correlates the fee with the `MessageSent` event
     *   emitted in the SAME transaction (and Circle's v2 attestation lookup is by tx hash).
     * - For `makePaymentForRelay`, the caller supplies the `messageHash` they computed off-chain
     *   from their own `MessageSent` bytes.
     */
    event PaymentForRelay(address indexed payer, bytes32 indexed messageHash, uint256 paymentAmount);

    event FailedReceiveMessage(bytes message, bytes attestation);

    struct ReceiveCall {
        bytes message;
        bytes attestation;
    }

    function makePaymentForRelay(bytes32 messageHash, uint256 paymentAmount) external;

    function requestCCTPTransfer(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}
