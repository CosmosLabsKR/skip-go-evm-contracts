// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CCTPV2Message
 * @notice Hand-rolled, fixed-offset accessors for the CCTP v2 on-chain message format and burn-message body.
 *         Used by the InboundForwarder to read the *same* `message` bytes that `transmitter.receiveMessage`
 *         verifies, so every value read here is attestation-backed (un-forgeable by the operator) — see D-12/D-22.
 *
 *         Hand-rolled rather than vendoring Circle's source, matching ICCTPV2Relayer's self-containment: only the
 *         offsets we read are declared, no external dependency. Drift-guarded by a golden vector in
 *         test/CCTPV2Message.t.sol whose expected values our own encoder does not produce, so an offset typo cannot
 *         pass common-mode.
 *
 * @dev Offsets are pinned to Circle's reference implementation (evm-cctp-contracts, v2):
 *
 *      Outer message (MessageV2):
 *        version                   = 0   (4 bytes)
 *        sourceDomain              = 4   (4 bytes)
 *        destinationDomain         = 8   (4 bytes)
 *        nonce                     = 12  (32 bytes)
 *        sender                    = 44  (32 bytes)   // source-domain TokenMessenger (NOT the depositor)
 *        recipient                 = 76  (32 bytes)   // destination TokenMessenger / handler
 *        destinationCaller         = 108 (32 bytes)
 *        minFinalityThreshold      = 140 (4 bytes)
 *        finalityThresholdExecuted = 144 (4 bytes)
 *        messageBody               = 148 (dynamic)    // BODY_OFFSET
 *
 *      Burn message body (BurnMessageV2), relative to messageBody → absolute = 148 + rel:
 *        version        = 0   → 148 (4 bytes)
 *        burnToken      = 4   → 152 (32 bytes)
 *        mintRecipient  = 36  → 184 (32 bytes)
 *        amount         = 68  → 216 (32 bytes)
 *        messageSender  = 100 → 248 (32 bytes)   // the address that called depositForBurn on source (per-route identity)
 *        maxFee         = 132 → 280 (32 bytes)
 *        feeExecuted    = 164 → 312 (32 bytes)
 *        expirationBlock= 196 → 344 (32 bytes)
 *        hookData       = 228 → 376 (dynamic, tail)
 *
 *      ⚠️ FUNDS-CRITICAL: a wrong offset breaks mintRecipient/amount/sender validation. Cross-check against
 *      Circle's published MessageV2.sol / BurnMessageV2.sol before any mainnet deployment.
 */
library CCTPV2Message {
    // ── outer message offsets ──
    uint256 internal constant DESTINATION_DOMAIN_OFFSET = 8;
    uint256 internal constant NONCE_OFFSET = 12;
    uint256 internal constant BODY_OFFSET = 148;

    // ── burn-message body offsets (absolute = BODY_OFFSET + relative) ──
    uint256 internal constant BURN_TOKEN_OFFSET = BODY_OFFSET + 4; // 152
    uint256 internal constant MINT_RECIPIENT_OFFSET = BODY_OFFSET + 36; // 184
    uint256 internal constant MESSAGE_SENDER_OFFSET = BODY_OFFSET + 100; // 248
    uint256 internal constant HOOK_DATA_OFFSET = BODY_OFFSET + 228; // 376

    error MalformedMessage();

    /// @dev Reverts if the message is too short to contain a full burn-message header (through expirationBlock).
    ///      hookData (tail) may be empty, so the minimum length is the start of hookData.
    function validateLength(bytes calldata message) internal pure {
        if (message.length < HOOK_DATA_OFFSET) revert MalformedMessage();
    }

    function _getDestinationDomain(bytes calldata message) internal pure returns (uint32) {
        return uint32(bytes4(message[DESTINATION_DOMAIN_OFFSET:DESTINATION_DOMAIN_OFFSET + 4]));
    }

    function _getNonce(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[NONCE_OFFSET:NONCE_OFFSET + 32]);
    }

    /// @notice Unused on-chain by design — kept only so the golden vector can pin BURN_TOKEN_OFFSET, which sits
    ///         between load-bearing offsets. Do not wire it into validation: see the warning on
    ///         InboundForwarder._validateBinding.
    function _getBurnToken(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[BURN_TOKEN_OFFSET:BURN_TOKEN_OFFSET + 32]);
    }

    function _getMintRecipient(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[MINT_RECIPIENT_OFFSET:MINT_RECIPIENT_OFFSET + 32]);
    }

    /// @notice Burn-body messageSender = the address that called depositForBurn on the source chain (the per-route
    ///         source depositor). InboundForwarder binds this against its `sender` route key; what the CREATE2 salt
    ///         commits to is the forwarder's concern (see InboundForwarder._validateBinding), not this library's.
    function _getMessageSender(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[MESSAGE_SENDER_OFFSET:MESSAGE_SENDER_OFFSET + 32]);
    }

    /// @notice Tail slice holding the hookData (may be empty). Structured payload abi.encode(string channelId,
    ///         string receiver, bytes memo) — the InboundForwarder decodes it on-chain (D-2/D-3) to drive the IBC
    ///         route; timeout is computed on-chain, not read here (D-25). Attestation-backed (un-forgeable by the operator).
    function _getHookData(bytes calldata message) internal pure returns (bytes calldata) {
        return message[HOOK_DATA_OFFSET:];
    }
}
