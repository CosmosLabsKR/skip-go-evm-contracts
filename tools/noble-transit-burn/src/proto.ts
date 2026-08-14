// protobufjs/minimal is CommonJS-only, so it has to come in as a default import under ESM.
import protobuf from "protobufjs/minimal.js";
import type { GeneratedType } from "@cosmjs/proto-signing";

const { Writer, Reader } = protobuf;
type Writer = InstanceType<typeof Writer>;
type Reader = InstanceType<typeof Reader>;

/**
 * Minimal hand-rolled codec for Noble's CCTP (v1) module. cosmjs-types does not ship Noble's protos and
 * @noble/... packages are unrelated, so the two messages this tool needs are encoded here directly.
 *
 * Source of truth: circle/noble-cctp, proto/circle/cctp/v1/tx.proto
 *
 *   message MsgDepositForBurnWithCaller {
 *     string from               = 1;
 *     string amount             = 2;  // cosmossdk.io/math.Int, wire-encoded as its decimal string
 *     uint32 destination_domain = 3;
 *     bytes  mint_recipient     = 4;  // 32 bytes, left-padded
 *     string burn_token         = 5;  // "uusdc" on Noble
 *     bytes  destination_caller = 6;  // 32 bytes, left-padded
 *   }
 *   message MsgDepositForBurnWithCallerResponse { uint64 nonce = 1; }
 */

export const MSG_DEPOSIT_FOR_BURN_WITH_CALLER = "/circle.cctp.v1.MsgDepositForBurnWithCaller";

export interface MsgDepositForBurnWithCaller {
  from: string;
  amount: string;
  destinationDomain: number;
  mintRecipient: Uint8Array;
  burnToken: string;
  destinationCaller: Uint8Array;
}

export const MsgDepositForBurnWithCaller = {
  encode(m: MsgDepositForBurnWithCaller, w: Writer = Writer.create()): Writer {
    if (m.from !== "") w.uint32(10).string(m.from);
    if (m.amount !== "") w.uint32(18).string(m.amount);
    if (m.destinationDomain !== 0) w.uint32(24).uint32(m.destinationDomain);
    if (m.mintRecipient.length !== 0) w.uint32(34).bytes(m.mintRecipient);
    if (m.burnToken !== "") w.uint32(42).string(m.burnToken);
    if (m.destinationCaller.length !== 0) w.uint32(50).bytes(m.destinationCaller);
    return w;
  },

  decode(input: Uint8Array | Reader, length?: number): MsgDepositForBurnWithCaller {
    const r = input instanceof Reader ? input : Reader.create(input);
    const end = length === undefined ? r.len : r.pos + length;
    const m: MsgDepositForBurnWithCaller = {
      from: "",
      amount: "",
      destinationDomain: 0,
      mintRecipient: new Uint8Array(),
      burnToken: "",
      destinationCaller: new Uint8Array(),
    };
    while (r.pos < end) {
      const tag = r.uint32();
      switch (tag >>> 3) {
        case 1:
          m.from = r.string();
          break;
        case 2:
          m.amount = r.string();
          break;
        case 3:
          m.destinationDomain = r.uint32();
          break;
        case 4:
          m.mintRecipient = r.bytes();
          break;
        case 5:
          m.burnToken = r.string();
          break;
        case 6:
          m.destinationCaller = r.bytes();
          break;
        default:
          r.skipType(tag & 7);
      }
    }
    return m;
  },

  // Registry plumbing that cosmjs expects on a GeneratedType but that this tool never exercises.
  fromPartial(o: Partial<MsgDepositForBurnWithCaller>): MsgDepositForBurnWithCaller {
    return {
      from: o.from ?? "",
      amount: o.amount ?? "",
      destinationDomain: o.destinationDomain ?? 0,
      mintRecipient: o.mintRecipient ?? new Uint8Array(),
      burnToken: o.burnToken ?? "",
      destinationCaller: o.destinationCaller ?? new Uint8Array(),
    };
  },
} satisfies GeneratedType & { decode: unknown };

/** The nonce Noble assigns the burn — the value that identifies the message to Circle's attestation API. */
export function decodeBurnNonce(responseBytes: Uint8Array): bigint | undefined {
  const r = Reader.create(responseBytes);
  while (r.pos < r.len) {
    const tag = r.uint32();
    if (tag >>> 3 === 1) return BigInt(r.uint64().toString());
    r.skipType(tag & 7);
  }
  return undefined;
}
