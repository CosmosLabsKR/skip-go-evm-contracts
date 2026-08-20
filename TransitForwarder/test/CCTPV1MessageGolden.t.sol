// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CCTPV1Message} from "../src/libraries/CCTPV1Message.sol";

/**
 * @notice Pins CCTPV1Message's byte offsets against a REAL Circle CCTP v1 message, captured from mainnet.
 *
 * @dev Unlike the sibling projects' v2 parser, CCTPV1Message is not a frozen copy of anything — there is no v1
 *      parser elsewhere in this repo to copy from — so nothing else would catch an offset typo. This vector is the
 *      whole safety net, and it is REAL rather than synthetic on purpose: a hand-built vector can only prove the
 *      parser agrees with itself.
 *
 *      ── Provenance (verify before trusting) ──────────────────────────────────────────────────────────────────
 *      chain    : Avalanche C-Chain (43114)
 *      contract : CCTP v1 MessageTransmitter 0x8186359aF5F57FbB40c6b14A588d2A59C0C29880
 *      tx       : 0xc6bb33114428ddfaafde50f71a1351112933bd3c0084ce284e68717d458ed869
 *      captured : 2026-08-13
 *      route    : Base (domain 6) -> Avalanche (domain 1), USDC burn message
 *
 *      ⚠️ Captured on Avalanche, but it grades the PARSER, not a chain. The v1 wire format is identical on every
 *      CCTP domain, so this one vector covers the Polygon deployment too — do NOT read the `1` asserted below as a
 *      config value (that lives in Config.sol as AVALANCHE_CCTP_DOMAIN / POLYGON_CCTP_DOMAIN). It is a fixed
 *      property of these captured bytes: change the bytes and it changes with them.
 *
 *      The bytes below are the `message` argument of that transaction's receiveMessage calldata (selector
 *      0x57ecfd28). To capture a fresh one:
 *        cast logs --rpc-url <avalanche> --address 0x8186359aF5F57FbB40c6b14A588d2A59C0C29880 \\
 *          'MessageReceived(address,uint32,uint64,bytes32,bytes)'
 *        cast tx <hash> --json | jq -r .input     # decode the (bytes message, bytes attestation) arguments
 */
contract CCTPV1MessageGoldenTest is Test {
    using CCTPV1Message for bytes;

    /// @dev Real mainnet v1 message. Exactly 248 bytes — v1 burn messages are fixed-length.
    bytes internal constant REAL_MESSAGE = hex"00000000000000060000000100000000000c4b500000000000000000000000001682ae6375c4"
        hex"e4a97e4b583bc394c861a46d89620000000000000000000000006b25532e1060ce10cc3b0a99"
        hex"e5683b91bfde6982000000000000000000000000000000000000000000000000000000000000"
        hex"000000000000000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"
        hex"0000000000000000000000004d12537e9851071c1855363e42e18bf9b24aff1e000000000000"
        hex"0000000000000000000000000000000000000000000000827559000000000000000000000000"
        hex"4d12537e9851071c1855363e42e18bf9b24aff1e";

    /// @dev The matching Circle attestation (65-byte signature). Carried so the vector documents a complete,
    ///      replayable receiveMessage call — the library never parses it.
    bytes internal constant REAL_ATTESTATION = hex"523f6d3edb354f75686c995f2427218a2938ba6f856d7042f5fbcc288a946e59613f2948289d"
        hex"6886e7428d65efbc5ad48c510f0a0b640453b57065ea7bc1ae2e1b75aac5b11d69d820a02be9"
        hex"48f37bd91130e72b267feb6390edeb862e672e335f4929f6770e819f466806d259c634a7415f"
        hex"634b844998634ac394aed1560d5a691c";

    // ── layout extent ──

    /// @dev A real v1 burn message is 248 bytes and every offset below lies inside it. A layout fact, not a
    ///      validation rule — the parser gates nothing on length.
    function test_RealV1MessageMatchesTheDocumentedExtent() public {
        assertEq(REAL_MESSAGE.length, 248, "captured message length drifted");
        assertEq(CCTPV1Message.BURN_MESSAGE_END, 248);
    }

    // ── the offsets themselves ──

    function test_DestinationDomainIsAvalanche() public {
        assertEq(this.destinationDomain(REAL_MESSAGE), 1, "DESTINATION_DOMAIN_OFFSET (8) drifted");
    }

    /// @dev v1's nonce is a uint64 at offset 12, where v2 puts a 32-byte value. Widening it here is what keeps
    ///      TransitCompleted.sourceNonce a bytes32 and its event signature unchanged.
    function test_NonceIsAWidenedUint64() public {
        assertEq(this.nonce(REAL_MESSAGE), bytes32(uint256(805712)), "NONCE_OFFSET (12) drifted");
    }

    /// @dev burnToken is a SOURCE-domain address — here Base's USDC, not Avalanche's. This is the vector that makes
    ///      the "never compare burnToken against this chain's usdc" rule concrete rather than a claim in a comment.
    function test_BurnTokenIsTheSourceChainsUsdc() public {
        assertEq(
            this.burnToken(REAL_MESSAGE),
            bytes32(uint256(uint160(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913))),
            "BURN_TOKEN_OFFSET (120) drifted"
        );
    }

    function test_MintRecipientIsAnEvmAddress() public {
        bytes32 r = this.mintRecipient(REAL_MESSAGE);
        assertEq(
            r,
            bytes32(uint256(uint160(0x4D12537e9851071c1855363E42e18Bf9b24aff1E))),
            "MINT_RECIPIENT_OFFSET (152) drifted"
        );
        assertEq(uint256(r) >> 160, 0, "an EVM-origin recipient must have 12 zero bytes on top");
    }

    function test_AmountIsReadable() public {
        assertEq(this.amount(REAL_MESSAGE), 8549721, "AMOUNT_OFFSET (184) drifted");
    }

    /// @dev The last field in the body. If MESSAGE_SENDER_OFFSET were wrong the slice would run past the end, so
    ///      reading it successfully also pins the total length.
    function test_MessageSenderIsTheLastField() public {
        assertEq(
            this.messageSender(REAL_MESSAGE),
            bytes32(uint256(uint160(0x4D12537e9851071c1855363E42e18Bf9b24aff1E))),
            "MESSAGE_SENDER_OFFSET (216) drifted"
        );
        assertEq(CCTPV1Message.MESSAGE_SENDER_OFFSET + 32, CCTPV1Message.BURN_MESSAGE_END);
    }

    // ── v1 has no fee deduction ──

    /// @dev v2 fast transfers deduct feeExecuted on the destination, so the body amount overstates what arrives.
    ///      v1 has no such field: the mint equals `amount` exactly. Measuring a balance delta is still correct —
    ///      it also excludes dust already sitting on the forwarder — but this records why the two versions differ.
    function test_V1BodyHasNoFeeFieldsAfterMessageSender() public {
        assertEq(REAL_MESSAGE.length - CCTPV1Message.BODY_OFFSET, 132, "v1 burn body is 132 bytes, no fee tail");
    }

    // ── calldata trampolines (the library takes `bytes calldata`) ──

    function destinationDomain(bytes calldata m) external pure returns (uint32) {
        return m._getDestinationDomain();
    }

    function nonce(bytes calldata m) external pure returns (bytes32) {
        return m._getNonce();
    }

    function burnToken(bytes calldata m) external pure returns (bytes32) {
        return m._getBurnToken();
    }

    function mintRecipient(bytes calldata m) external pure returns (bytes32) {
        return m._getMintRecipient();
    }

    function amount(bytes calldata m) external pure returns (uint256) {
        return m._getAmount();
    }

    function messageSender(bytes calldata m) external pure returns (bytes32) {
        return m._getMessageSender();
    }
}
