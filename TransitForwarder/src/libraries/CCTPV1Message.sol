// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CCTPV1Message
 * @notice Fixed-offset accessors for the CCTP **v1** message and burn-message body. Reads the same bytes
 *         `transmitter.receiveMessage` verifies, so every value is attestation-backed and un-forgeable.
 *
 * @dev ⚠️ THIS PROJECT MIXES CCTP VERSIONS: mint = v1 (parsed here), burn = v2 (delegated to CCTPV2Relayer, which
 *      builds that message itself). Different Circle contracts, unrelated layouts. This is the only parser here.
 *
 *      Hand-rolled rather than vendoring Circle's source, matching ICCTPV2Relayer's self-containment. Unlike the
 *      siblings' v2 parser this is NOT a frozen copy — no v1 parser exists to copy from — so it carries its own
 *      golden vector built from a real mainnet message (test/CCTPV1MessageGolden.t.sol). That vector is the only
 *      thing standing between an offset typo and misrouted funds.
 *
 *      Offsets, pinned to Circle's evm-cctp-contracts (v1):
 *
 *        Message.sol                      BurnMessage.sol (body, absolute = 116 + rel)
 *          version           = 0    (4)     version       = 0   -> 116  (4)
 *          sourceDomain      = 4    (4)     burnToken     = 4   -> 120  (32)   // SOURCE-domain address
 *          destinationDomain = 8    (4)     mintRecipient = 36  -> 152  (32)
 *          nonce             = 12   (8)     amount        = 68  -> 184  (32)
 *          sender            = 20   (32)    messageSender = 100 -> 216  (32)   // ends the message at 248
 *          recipient         = 52   (32)
 *          destinationCaller = 84   (32)    // the executor pin that closes the griefing path
 *          messageBody       = 116  (dyn)
 *
 *      ⚠️ nonce is a uint64 here, where v2 uses 32 bytes.
 *
 *      v1 has NO maxFee, feeExecuted, expirationBlock or hookData: the mint equals the body's `amount` exactly, and
 *      there is no hook to relay. We still measure a balance delta, because it also excludes pre-existing dust.
 *
 *      ⚠️ Nothing here infers the version from the bytes and nothing pre-validates the length. The version is fixed
 *      by CONSTRUCTION — the executor holds the v1 transmitter as an immutable, and only messages it attested reach
 *      this parser. A version or length gate would be a weaker check dressed as a stronger one, and one more way to
 *      wrongly reject a legitimate message. Out-of-range slices already revert.
 *
 *      ⚠️ FUNDS-CRITICAL: a wrong offset breaks mintRecipient/amount validation.
 */
library CCTPV1Message {
    // ── outer message offsets ──
    uint256 internal constant DESTINATION_DOMAIN_OFFSET = 8;
    uint256 internal constant NONCE_OFFSET = 12;
    uint256 internal constant BODY_OFFSET = 116;

    // ── burn-message body offsets (absolute = BODY_OFFSET + relative) ──
    uint256 internal constant BURN_TOKEN_OFFSET = BODY_OFFSET + 4; // 120
    uint256 internal constant MINT_RECIPIENT_OFFSET = BODY_OFFSET + 36; // 152
    uint256 internal constant AMOUNT_OFFSET = BODY_OFFSET + 68; // 184
    uint256 internal constant MESSAGE_SENDER_OFFSET = BODY_OFFSET + 100; // 216

    /// @dev End of the burn body. A golden-vector anchor only — nothing validates against it.
    uint256 internal constant BURN_MESSAGE_END = MESSAGE_SENDER_OFFSET + 32; // 248

    function _getDestinationDomain(bytes calldata message) internal pure returns (uint32) {
        return uint32(bytes4(message[DESTINATION_DOMAIN_OFFSET:DESTINATION_DOMAIN_OFFSET + 4]));
    }

    /// @notice The v1 uint64 nonce, zero-extended to bytes32 so `TransitCompleted.sourceNonce` keeps its shape and
    ///         every off-chain log consumer is unaffected. NOT interchangeable with a v2 nonce.
    function _getNonce(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(uint256(uint64(bytes8(message[NONCE_OFFSET:NONCE_OFFSET + 8]))));
    }

    /// @notice Unused on-chain — kept so the golden vector pins BURN_TOKEN_OFFSET, which sits between the body
    ///         version and mintRecipient and would otherwise go unverified.
    /// @dev ⚠️ Do NOT compare against this chain's USDC: it is a SOURCE-domain address.
    function _getBurnToken(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[BURN_TOKEN_OFFSET:BURN_TOKEN_OFFSET + 32]);
    }

    function _getMintRecipient(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[MINT_RECIPIENT_OFFSET:MINT_RECIPIENT_OFFSET + 32]);
    }

    /// @notice The burned amount as attested. Cross-checked against the measured balance delta — v1 mints this
    ///         exactly, so the two must agree (TransitExecutor.AmountMismatch).
    function _getAmount(bytes calldata message) internal pure returns (uint256) {
        return uint256(bytes32(message[AMOUNT_OFFSET:AMOUNT_OFFSET + 32]));
    }

    /// @notice Unused on-chain — matching it against the route's `sender` would reject every non-EVM source domain
    ///         (see TransitForwarder._validateBinding). Kept to pin MESSAGE_SENDER_OFFSET.
    function _getMessageSender(bytes calldata message) internal pure returns (bytes32) {
        return bytes32(message[MESSAGE_SENDER_OFFSET:MESSAGE_SENDER_OFFSET + 32]);
    }
}
