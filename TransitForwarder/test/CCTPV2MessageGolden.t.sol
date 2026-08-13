// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CCTPV2Message} from "../src/libraries/CCTPV2Message.sol";

/**
 * @notice Pins CCTPV2Message's byte offsets against a REAL Circle CCTP v2 message, captured from mainnet.
 *
 * @dev Why this file exists separately from CCTPV2Message.t.sol: that file is a FROZEN COPY of
 *      ForwarderFactory/test/CCTPV2Message.t.sol (see DD-7 and `make check-transit-copies`) and its vectors are
 *      SYNTHETIC — hand-built by the same understanding of the layout that the library encodes, so it can only
 *      prove self-consistency, never that the offsets match what Circle actually emits. Editing it to add a real
 *      vector would either break the copy check or force a change in the permanent ForwarderFactory project, which
 *      D-12 forbids. So the real vector lives here, in a Transit-owned file.
 *
 *      ── Provenance (verify before trusting) ──────────────────────────────────────────────────────────────────
 *      chain      : Avalanche C-Chain (43114)
 *      contract   : MessageTransmitterV2 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64
 *      tx         : 0x07c44792c44167eae5e1b48d95725516573166f3c8b8458f1741b376d8cf703e
 *      block      : 92679414
 *      captured   : 2026-08-13
 *      route      : Base (domain 6) -> Avalanche (domain 1), USDC burn message with a 138-byte hook
 *
 *      The message bytes below are the `message` argument of that transaction's calldata. Independently
 *      cross-checked: the MessageReceived event's `messageBody` equals message[148:] exactly, which is what pins
 *      BODY_OFFSET without relying on our own parser.
 *
 *      To capture a fresh one:
 *        cast logs --rpc-url <avalanche> --address 0x81D4...4B64 \
 *          'MessageReceived(address,uint32,bytes32,bytes32,uint32,bytes)'
 *        cast tx <hash> --json | jq -r .input      # decode the (bytes message, bytes attestation) arguments
 */
contract CCTPV2MessageGoldenTest is Test {
    using CCTPV2Message for bytes;

    /// @dev Real mainnet message, 514 bytes (376 header+body + 138 hookData).
    bytes internal constant REAL_MESSAGE =
        hex"000000010000000600000001640573ac5de7b2acc52575d50d301e4f8407ee9ec94a12a32631"
            hex"e3252cb1d58f00000000000000000000000028b5a0e9c621a5badaa536219b3a228c8168cf5d"
            hex"00000000000000000000000028b5a0e9c621a5badaa536219b3a228c8168cf5d000000000000"
            hex"000000000000c1062b7c5dc8e4b1df9f200fe360cdc0ed6e774100000001000003e800000001"
            hex"000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000"
            hex"000000000000c1062b7c5dc8e4b1df9f200fe360cdc0ed6e7741000000000000000000000000"
            hex"000000000000000000000000000000000000c0f3000000000000000000000000c1062b7c5dc8"
            hex"e4b1df9f200fe360cdc0ed6e7741000000000000000000000000000000000000000000000000"
            hex"0000000000000008000000000000000000000000000000000000000000000000000000000000"
            hex"0006000000000000000000000000000000000000000000000000000000000586d5ac03000000"
            hex"000000000000000000e5aa55f38df108d531246c2c1e421a92324f30ee000000000000000000"
            hex"000000000000000000000000000000000000000000000000000000000b78c300000000000000"
            hex"00000000000000028100000000000000fd000000006a7d3a6d00000000000000000000000098"
            hex"99f62ecf16b70bffc88677023026c47e48c21819";

    /// @dev The matching Circle attestation, 130 bytes (2 x 65-byte signatures). Carried so the vector documents a
    ///      complete, replayable receiveMessage call — the library never parses it.
    bytes internal constant REAL_ATTESTATION =
        hex"c252a3e37a54eb69c6e3482d53eef4058d215297adce0b834130e9f25f1d0afa088d37f93466"
            hex"9ab83877c6dddc54fe3d10d7b3b28150ddf576cd032f4b5fab091bd24277544119d998c0214a"
            hex"872f0cbf68f4d6996b80f989f6af255618bb18b710485f66ec871a17d9acbe3b38034070b4cc"
            hex"ea2d20c92e2644243134a759cb64b51c";

    function _msg() internal pure returns (bytes memory) {
        return REAL_MESSAGE;
    }

    // ── the offsets themselves ──

    function test_RealMessagePassesLengthValidation() public {
        this.validateLengthExternal(REAL_MESSAGE);
        assertEq(REAL_MESSAGE.length, 514, "captured message length drifted");
    }

    function validateLengthExternal(bytes calldata m) external pure {
        m.validateLength();
    }

    function test_DestinationDomainIsAvalanche() public {
        assertEq(this.destinationDomain(REAL_MESSAGE), 1, "DESTINATION_DOMAIN_OFFSET (8) drifted");
    }

    function test_NonceMatchesTheOnChainValue() public {
        assertEq(
            this.nonce(REAL_MESSAGE),
            bytes32(0x640573ac5de7b2acc52575d50d301e4f8407ee9ec94a12a32631e3252cb1d58f),
            "NONCE_OFFSET (12) drifted"
        );
    }

    /// @dev burnToken is a SOURCE-domain address — here Base's USDC. This is the vector that makes the
    ///      "never compare burnToken against this chain's usdc" rule concrete rather than a claim in a comment.
    function test_BurnTokenIsTheSourceChainsUsdc() public {
        assertEq(
            this.burnToken(REAL_MESSAGE),
            bytes32(uint256(uint160(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913))),
            "BURN_TOKEN_OFFSET (152) drifted"
        );
    }

    function test_MintRecipientIsAnEvmAddress() public {
        bytes32 r = this.mintRecipient(REAL_MESSAGE);
        assertEq(r, bytes32(uint256(uint160(0xC1062b7C5Dc8E4b1Df9F200fe360cDc0eD6e7741))), "MINT_RECIPIENT_OFFSET (184) drifted");
        assertEq(uint256(r) >> 160, 0, "an EVM-origin recipient must have 12 zero bytes on top");
    }

    function test_MessageSenderIsReadable() public {
        assertEq(
            this.messageSender(REAL_MESSAGE),
            bytes32(uint256(uint160(0xC1062b7C5Dc8E4b1Df9F200fe360cDc0eD6e7741))),
            "MESSAGE_SENDER_OFFSET (248) drifted"
        );
    }

    /// @dev HOOK_DATA_OFFSET is pinned by a message that actually HAS hook data — a zero-length hook would leave
    ///      an off-by-one in the offset undetectable.
    function test_HookDataStartsAt376() public {
        bytes memory hook = this.hookData(REAL_MESSAGE);
        assertEq(hook.length, 138, "HOOK_DATA_OFFSET (376) drifted");
        assertEq(hook.length, REAL_MESSAGE.length - 376);
    }

    // ── the property the whole fee split depends on ──

    /// @dev The body's `amount` (49395) exceeds what actually arrives, because CCTP deducts feeExecuted (6) on the
    ///      destination. This is REAL evidence for the rule that TransitExecutor must measure a balance delta and
    ///      never trust the body's amount: splitting 49395 when 49389 arrived would revert on the relayer's pull.
    function test_BodyAmountExceedsWhatActuallyArrives() public {
        uint256 bodyAmount = uint256(bytes32(_slice(REAL_MESSAGE, 216, 248)));
        uint256 maxFee = uint256(bytes32(_slice(REAL_MESSAGE, 280, 312)));
        uint256 feeExecuted = uint256(bytes32(_slice(REAL_MESSAGE, 312, 344)));

        assertEq(bodyAmount, 49395);
        assertEq(maxFee, 8);
        assertEq(feeExecuted, 6);
        assertGt(feeExecuted, 0, "this vector must be a fast transfer, or it proves nothing about the delta rule");
        assertLt(feeExecuted, maxFee + 1, "feeExecuted must respect maxFee");
        assertEq(bodyAmount - feeExecuted, 49389, "what the recipient actually receives");
    }

    function _slice(bytes memory b, uint256 from, uint256 to) private pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = 0; i < to - from; i++) {
            out[i] = b[from + i];
        }
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

    function messageSender(bytes calldata m) external pure returns (bytes32) {
        return m._getMessageSender();
    }

    function hookData(bytes calldata m) external pure returns (bytes memory) {
        return m._getHookData();
    }
}
