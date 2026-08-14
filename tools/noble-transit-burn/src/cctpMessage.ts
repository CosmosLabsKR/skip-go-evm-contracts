import { getAddress, slice, type Address, type Hex } from "viem";

/**
 * Read-only mirror of `TransitForwarder/src/libraries/CCTPV1Message.sol`. Same offsets, same version — CCTP **v1**,
 * which is the mint leg. Do not point it at a v2 message; the layouts are unrelated.
 *
 *   version 0(4) | sourceDomain 4(4) | destinationDomain 8(4) | nonce 12(8) | sender 20(32)
 *   recipient 52(32) | destinationCaller 84(32) | body 116(dyn)
 *   body: version +0 | burnToken +4(32) | mintRecipient +36(32) | amount +68(32) | messageSender +100(32)
 *
 * This exists so a message can be checked BEFORE it is submitted. Every field below is re-derived on-chain from the
 * same bytes the transmitter attests, so this parser can never widen what the executor accepts — it only lets a
 * mismatch surface as a readable error instead of an opaque revert that has already cost gas.
 */

const BODY = 116;

export interface ParsedMessage {
  version: number;
  sourceDomain: number;
  destinationDomain: number;
  nonce: bigint;
  destinationCaller: Hex;
  mintRecipient: Hex;
  amount: bigint;
}

function u32(message: Hex, at: number): number {
  return Number(BigInt(slice(message, at, at + 4)));
}

export function parseCctpV1Message(message: Hex): ParsedMessage {
  // 248 bytes = a burn message exactly; anything shorter cannot hold the body fields read below.
  const byteLength = (message.length - 2) / 2;
  if (byteLength < 248) throw new Error(`message is ${byteLength} bytes, too short for a CCTP v1 burn message`);

  return {
    version: u32(message, 0),
    sourceDomain: u32(message, 4),
    destinationDomain: u32(message, 8),
    nonce: BigInt(slice(message, 12, 20)),
    destinationCaller: slice(message, 84, 116),
    mintRecipient: slice(message, BODY + 36, BODY + 68),
    amount: BigInt(slice(message, BODY + 68, BODY + 100)),
  };
}

/**
 * The EVM address a 32-byte CCTP recipient names.
 *
 * Mirrors TransitExecutor._forwarderOf: non-zero upper 12 bytes mean this is not an EVM address, and truncating
 * would produce a plausible-looking but arbitrary address. Failing is correct.
 */
export function toEvmAddress(value: Hex): Address {
  if (BigInt(slice(value, 0, 12)) !== 0n) throw new Error(`not an EVM address — upper 12 bytes are set: ${value}`);
  return getAddress(slice(value, 12, 32));
}
