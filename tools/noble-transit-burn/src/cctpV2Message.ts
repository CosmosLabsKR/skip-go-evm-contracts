import { slice, type Hex } from "viem";

/**
 * Read-only parser for a CCTP **v2** message — the format the Avalanche → Injective hop emits.
 *
 * This is a different layout from `cctpMessage.ts`, which parses the **v1** mint leg. The two share no offsets:
 * v2 widens `nonce` from 8 bytes to 32 and appends two finality fields to the header, so every field after byte 12
 * moves. Pointing either parser at the other's bytes yields plausible-looking garbage rather than an error, which
 * is exactly the confusion this file exists to keep out of `mint`.
 *
 *   header (148):
 *     version 0(4) | sourceDomain 4(4) | destinationDomain 8(4) | nonce 12(32) | sender 44(32)
 *     recipient 76(32) | destinationCaller 108(32) | minFinalityThreshold 140(4) | finalityThresholdExecuted 144(4)
 *   burn body (228 + hookData), from offset 148:
 *     version +0(4) | burnToken +4(32) | mintRecipient +36(32) | amount +68(32) | messageSender +100(32)
 *     maxFee +132(32) | feeExecuted +164(32) | expirationBlock +196(32) | hookData +228(dyn)
 */

const BODY = 148;
const MIN_LENGTH = BODY + 228;

export interface ParsedV2Message {
  version: number;
  sourceDomain: number;
  destinationDomain: number;
  /** v2 nonce is a 32-byte value assigned by Circle, not the v1 uint64 counter. */
  nonce: Hex;
  sender: Hex;
  recipient: Hex;
  destinationCaller: Hex;
  minFinalityThreshold: number;
  finalityThresholdExecuted: number;
  burnToken: Hex;
  mintRecipient: Hex;
  amount: bigint;
  messageSender: Hex;
  maxFee: bigint;
  feeExecuted: bigint;
  hookData: Hex;
}

function u32(message: Hex, at: number): number {
  return Number(BigInt(slice(message, at, at + 4)));
}

export function parseCctpV2Message(message: Hex): ParsedV2Message {
  const byteLength = (message.length - 2) / 2;
  if (byteLength < MIN_LENGTH) {
    throw new Error(
      `message is ${byteLength} bytes, too short for a CCTP v2 burn message (${MIN_LENGTH}). ` +
        `A 248-byte message is CCTP v1 — that is the Noble → Avalanche leg, handled by \`execute\`.`,
    );
  }

  return {
    version: u32(message, 0),
    sourceDomain: u32(message, 4),
    destinationDomain: u32(message, 8),
    nonce: slice(message, 12, 44),
    sender: slice(message, 44, 76),
    recipient: slice(message, 76, 108),
    destinationCaller: slice(message, 108, 140),
    minFinalityThreshold: u32(message, 140),
    finalityThresholdExecuted: u32(message, 144),
    burnToken: slice(message, BODY + 4, BODY + 36),
    mintRecipient: slice(message, BODY + 36, BODY + 68),
    amount: BigInt(slice(message, BODY + 68, BODY + 100)),
    messageSender: slice(message, BODY + 100, BODY + 132),
    maxFee: BigInt(slice(message, BODY + 132, BODY + 164)),
    feeExecuted: BigInt(slice(message, BODY + 164, BODY + 196)),
    hookData: byteLength > MIN_LENGTH ? slice(message, MIN_LENGTH) : "0x",
  };
}
