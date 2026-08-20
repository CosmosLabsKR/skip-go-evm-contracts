// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CCTPV2Message} from "../src/libraries/CCTPV2Message.sol";

/// @notice Drift guard for the hand-rolled CCTPV2Message offset parser.
///
/// @dev WHY THIS EXISTS: InboundForwarder's own suite synthesizes CCTP bytes with a sequential `_buildMessage`
///      encoder, so the encoder and this decoder share the same offset assumptions — a wrong offset in BOTH passes
///      undetected (common-mode error). This suite breaks that loop two ways:
///        1. The golden message is emplaced field-by-field at ABSOLUTE byte offsets taken from Circle's published
///           reference (evm-cctp-contracts v2: MessageV2 / BurnMessageV2), NOT from the library's own relative
///           constants and NOT via the forwarder suite's encoder — an independent layout oracle.
///        2. `_readBytes32At` re-reads each field at offset ±4 and asserts the result differs ("vector sharpness"),
///           proving that any ±4 drift in a library constant WOULD change the accessor output the direct asserts check.
///
///      Absolute offsets (verified against Circle MessageV2.sol / BurnMessageV2.sol):
///        destinationDomain 8 · nonce 12 · body 148 · burnToken 152 · mintRecipient 184 · messageSender 248 · hookData 376
///
///      NOTE (provenance): the bytes below are a spec-pinned synthetic vector. When a captured mainnet/testnet CCTP v2
///      attestation message becomes available it should be added as an additional vector (the asserts here are
///      structured so a real message drops in unchanged).
contract CCTPV2MessageTest is Test {
    using CCTPV2Message for bytes;

    // absolute offsets — declared as literals here, independent of CCTPV2Message's (relative) constants.
    uint256 internal constant OFF_DEST_DOMAIN = 8;
    uint256 internal constant OFF_NONCE = 12;
    uint256 internal constant OFF_BURN_TOKEN = 152;
    uint256 internal constant OFF_MINT_RECIPIENT = 184;
    uint256 internal constant OFF_MESSAGE_SENDER = 248;
    uint256 internal constant OFF_HOOK_DATA = 376; // == minimum valid length

    // independently-known expected field values
    uint32 internal constant EXP_DEST_DOMAIN = 29; // Injective
    bytes32 internal constant EXP_NONCE = bytes32(uint256(0x0A11CE42));
    bytes32 internal constant EXP_BURN_TOKEN = bytes32(uint256(uint160(0x1234567890AbcdEF1234567890aBcdef12345678)));
    bytes32 internal constant EXP_MINT_RECIPIENT = bytes32(uint256(uint160(0x00000000000000000000000000000000DeaDBeef)));
    bytes32 internal constant EXP_MESSAGE_SENDER = bytes32(uint256(uint160(0x455AAA40C707AFE214E30f418C3DD145aDFC953F)));

    /// @dev Emplace a 32-byte word at an ABSOLUTE offset (independent of the library's relative-offset arithmetic).
    function _put32(bytes memory buf, uint256 off, bytes32 val) internal pure {
        for (uint256 i = 0; i < 32; i++) {
            buf[off + i] = val[i];
        }
    }

    /// @dev Emplace a 4-byte big-endian uint32 at an ABSOLUTE offset.
    function _put4(bytes memory buf, uint256 off, uint32 val) internal pure {
        buf[off + 0] = bytes1(uint8(val >> 24));
        buf[off + 1] = bytes1(uint8(val >> 16));
        buf[off + 2] = bytes1(uint8(val >> 8));
        buf[off + 3] = bytes1(uint8(val));
    }

    /// @dev Re-read a 32-byte word at an arbitrary offset — used for the ±4 sharpness check.
    function _readBytes32At(bytes memory buf, uint256 off) internal pure returns (bytes32 out) {
        for (uint256 i = 0; i < 32; i++) {
            out |= bytes32(uint256(uint8(buf[off + i])) << (8 * (31 - i)));
        }
    }

    /// @dev Build a golden message of total length `OFF_HOOK_DATA + hookData.length`, fields at absolute offsets.
    ///      Filler byte 0xFF everywhere else so a ±4 misread lands on distinct bytes (keeps the vector sharp).
    function _goldenMessage(bytes memory hookData) internal pure returns (bytes memory buf) {
        buf = new bytes(OFF_HOOK_DATA + hookData.length);
        for (uint256 i = 0; i < buf.length; i++) {
            buf[i] = 0xFF;
        }
        _put4(buf, OFF_DEST_DOMAIN, EXP_DEST_DOMAIN);
        _put32(buf, OFF_NONCE, EXP_NONCE);
        _put32(buf, OFF_BURN_TOKEN, EXP_BURN_TOKEN);
        _put32(buf, OFF_MINT_RECIPIENT, EXP_MINT_RECIPIENT);
        _put32(buf, OFF_MESSAGE_SENDER, EXP_MESSAGE_SENDER);
        for (uint256 i = 0; i < hookData.length; i++) {
            buf[OFF_HOOK_DATA + i] = hookData[i];
        }
    }

    // ── accessor correctness against the independent vector ──

    function test_Accessors_WithHookData() public {
        bytes memory hook = abi.encode(string("channel-0"), string("inj1nexthop"), bytes(hex"cafe"));
        bytes memory message = _goldenMessage(hook);

        assertEq(uint256(this.getDestDomain(message)), uint256(EXP_DEST_DOMAIN), "destDomain");
        assertEq(this.getNonce(message), EXP_NONCE, "nonce");
        assertEq(this.getBurnToken(message), EXP_BURN_TOKEN, "burnToken");
        assertEq(this.getMintRecipient(message), EXP_MINT_RECIPIENT, "mintRecipient");
        assertEq(this.getMessageSender(message), EXP_MESSAGE_SENDER, "messageSender");
        assertEq(this.getHookData(message), hook, "hookData tail");
    }

    function test_Accessors_EmptyHookData() public {
        bytes memory message = _goldenMessage(bytes(""));
        assertEq(message.length, OFF_HOOK_DATA, "empty hook: length == HOOK_DATA_OFFSET");
        assertEq(this.getHookData(message).length, 0, "empty hookData tail");
        // header fields still read correctly with an empty tail
        assertEq(this.getMintRecipient(message), EXP_MINT_RECIPIENT, "mintRecipient (empty hook)");
        assertEq(this.getMessageSender(message), EXP_MESSAGE_SENDER, "messageSender (empty hook)");
    }

    // ── calldata wrappers (the library accessors take `bytes calldata`) ──
    function getDestDomain(bytes calldata m) external pure returns (uint32) { return m._getDestinationDomain(); }
    function getNonce(bytes calldata m) external pure returns (bytes32) { return m._getNonce(); }
    function getBurnToken(bytes calldata m) external pure returns (bytes32) { return m._getBurnToken(); }
    function getMintRecipient(bytes calldata m) external pure returns (bytes32) { return m._getMintRecipient(); }
    function getMessageSender(bytes calldata m) external pure returns (bytes32) { return m._getMessageSender(); }
    function getHookData(bytes calldata m) external pure returns (bytes memory) { return m._getHookData(); }

    // ── validateLength boundary ──

    function test_ValidateLength_BoundaryPasses() public view {
        this.callValidate(_goldenMessage(bytes(""))); // length == HOOK_DATA_OFFSET is the minimum valid
    }

    function test_ValidateLength_TooShortReverts() public {
        bytes memory tooShort = new bytes(OFF_HOOK_DATA - 1);
        vm.expectRevert(CCTPV2Message.MalformedMessage.selector);
        this.callValidate(tooShort);
    }

    function callValidate(bytes calldata m) external pure {
        m.validateLength();
    }

    // ── vector sharpness: any ±4 offset drift would change the read (so the direct asserts above catch it) ──

    function test_VectorIsSharp_PlusMinus4Differs() public {
        bytes memory message = _goldenMessage(abi.encode(string("c"), string("r"), bytes("")));

        _assertSharp(message, OFF_BURN_TOKEN, EXP_BURN_TOKEN, "burnToken");
        _assertSharp(message, OFF_MINT_RECIPIENT, EXP_MINT_RECIPIENT, "mintRecipient");
        _assertSharp(message, OFF_MESSAGE_SENDER, EXP_MESSAGE_SENDER, "messageSender");
        _assertSharp(message, OFF_NONCE, EXP_NONCE, "nonce");
    }

    function _assertSharp(bytes memory message, uint256 off, bytes32 expected, string memory tag) internal {
        assertEq(_readBytes32At(message, off), expected, string.concat(tag, " @offset"));
        assertTrue(_readBytes32At(message, off + 4) != expected, string.concat(tag, " +4 must differ"));
        assertTrue(_readBytes32At(message, off - 4) != expected, string.concat(tag, " -4 must differ"));
    }
}
