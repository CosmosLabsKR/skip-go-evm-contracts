// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @dev Interface for the CCTP v2 TokenMessengerV2 contract.
 * @notice v2 differs from v1: `depositForBurn` takes `destinationCaller`, `maxFee` and
 * `minFinalityThreshold`, returns nothing (no synchronous nonce), and `depositForBurnWithCaller`
 * is removed (the caller is now a standard parameter of `depositForBurn`).
 */
interface ITokenMessenger {
    // ============ Events ============
    /**
     * @notice Emitted when a DepositForBurn message is sent.
     * @dev v2 event: there is no `nonce` field (the nonce is assigned off-chain by the
     * attestation service). `maxFee`, `minFinalityThreshold` and `hookData` are added.
     * @param burnToken address of token burnt on source domain
     * @param amount deposit amount
     * @param depositor address where deposit is transferred from
     * @param mintRecipient address receiving minted tokens on destination domain as bytes32
     * @param destinationDomain destination domain
     * @param destinationTokenMessenger address of TokenMessenger on destination domain as bytes32
     * @param destinationCaller authorized caller as bytes32 of receiveMessage() on destination domain.
     * If equal to bytes32(0), any address can call receiveMessage().
     * @param maxFee maximum fee to pay on the destination domain, in burnToken units
     * @param minFinalityThreshold the minimum finality at which the message should be attested to
     * @param hookData optional hook data for the destination
     */
    event DepositForBurn(
        address indexed burnToken,
        uint256 amount,
        address indexed depositor,
        bytes32 mintRecipient,
        uint32 destinationDomain,
        bytes32 destinationTokenMessenger,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 indexed minFinalityThreshold,
        bytes hookData
    );

    // ============ External Functions ============
    /**
     * @notice Deposits and burns tokens from sender to be minted on destination domain.
     * Emits a `DepositForBurn` event.
     * @param amount amount of tokens to burn
     * @param destinationDomain destination domain
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken address of contract to burn deposited tokens, on local domain
     * @param destinationCaller caller on the destination domain, as bytes32. bytes32(0) = any caller
     * @param maxFee maximum fee to pay on the destination domain, in burnToken units (< amount)
     * @param minFinalityThreshold minimum finality threshold (e.g. 2000 = standard, 1000 = fast)
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    /**
     * @notice Same as `depositForBurn`, but with arbitrary `hookData` forwarded to the destination.
     * @param hookData hook data to append to the burn message for interpretation on destination domain
     */
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}
