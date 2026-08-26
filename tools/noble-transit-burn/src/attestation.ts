import type { Hex } from "viem";
import type { Config } from "./config.js";

/**
 * Circle's attestation service (Iris), v1 API — the version that serves CCTP v1 messages, which is what the mint
 * leg uses. Testnet is served by iris-api-sandbox, mainnet by iris-api.
 *
 *   GET /v1/messages/{sourceDomain}/{txHash}
 *     → { messages: [ { message: "0x…", attestation: "0x…" | "PENDING", eventNonce: "…" } ] }
 *
 * An attestation only exists once Circle has observed the burn finalise, so "not there yet" is the normal state for
 * the first minutes rather than an error.
 */

export interface AttestedMessage {
  message: Hex;
  attestation: Hex;
  eventNonce?: string;
}

interface IrisMessage {
  message?: string;
  attestation?: string;
  eventNonce?: string;
}

function isComplete(m: IrisMessage): boolean {
  // Iris reports an unfinished attestation as the literal string "PENDING", not as an absent field.
  return !!m.message && !!m.attestation && m.attestation.startsWith("0x") && m.attestation.length > 2;
}

async function fetchOnce(cfg: Config, txHash: string): Promise<AttestedMessage[] | undefined> {
  const url = `${cfg.irisApi}/v1/messages/${cfg.nobleDomain}/${txHash}`;
  const res = await fetch(url);

  // 404 means Iris has not indexed the burn yet — indistinguishable from "too early", so treat it as pending.
  if (res.status === 404) return undefined;
  if (!res.ok) throw new Error(`attestation API ${res.status} ${res.statusText} for ${url}`);

  const body = (await res.json()) as { messages?: IrisMessage[] };
  const messages = body.messages ?? [];
  if (messages.length === 0 || !messages.every(isComplete)) return undefined;

  return messages.map((m) => ({
    message: m.message as Hex,
    attestation: m.attestation as Hex,
    eventNonce: m.eventNonce,
  }));
}

/**
 * Poll until every message in the burn tx is attested.
 *
 * Waits for ALL of them rather than returning the first: a tx carrying more than one CCTP message would otherwise
 * hand back a half-ready set, and the caller picks by mintRecipient anyway.
 */
export async function waitForAttestation(
  cfg: Config,
  txHash: string,
  opts: { timeoutMs: number; intervalMs: number },
): Promise<AttestedMessage[]> {
  const deadline = Date.now() + opts.timeoutMs;
  let announced = false;

  for (;;) {
    const found = await fetchOnce(cfg, txHash);
    if (found) return found;

    if (Date.now() >= deadline) {
      throw new Error(
        `no attestation for ${txHash} after ${Math.round(opts.timeoutMs / 1000)}s. ` +
          `The burn is not lost — re-run \`execute --tx ${txHash}\` later, or check ` +
          `${cfg.irisApi}/v1/messages/${cfg.nobleDomain}/${txHash}`,
      );
    }
    if (!announced) {
      console.log(`waiting for Circle's attestation — ${cfg.irisApi}/v1/messages/${cfg.nobleDomain}/${txHash} ...`);
      announced = true;
    }
    await new Promise((r) => setTimeout(r, opts.intervalMs));
  }
}

/**
 * The same thing for the **v2** API, which serves the transit chain → Injective hop.
 *
 *   GET /v2/messages/{sourceDomain}?transactionHash={txHash}
 *     → { messages: [ { message, attestation, eventNonce, cctpVersion, status: "complete" | "pending_confirmations" } ] }
 *
 * The two APIs are disjoint indexes, not two views of one: a v2 message is simply absent from /v1 and vice versa,
 * and both answer 404 for anything they do not hold. That 404 is why a transit-chain tx hash looks like "no such
 * transaction" rather than "wrong endpoint", so the error below names both coordinates that have to line up.
 */
export async function waitForV2Attestation(
  cfg: Config,
  txHash: string,
  sourceDomain: number,
  opts: { timeoutMs: number; intervalMs: number },
): Promise<AttestedMessage[]> {
  const url = `${cfg.irisApi}/v2/messages/${sourceDomain}?transactionHash=${txHash}`;
  const deadline = Date.now() + opts.timeoutMs;
  let announced = false;
  let lastStatus: string | undefined;

  for (;;) {
    const res = await fetch(url);
    if (res.ok) {
      const body = (await res.json()) as { messages?: (IrisMessage & { status?: string })[] };
      const messages = body.messages ?? [];
      lastStatus = messages[0]?.status;
      if (messages.length > 0 && messages.every((m) => m.status === "complete" && isComplete(m))) {
        return messages.map((m) => ({
          message: m.message as Hex,
          attestation: m.attestation as Hex,
          eventNonce: m.eventNonce,
        }));
      }
    } else if (res.status !== 404) {
      throw new Error(`attestation API ${res.status} ${res.statusText} for ${url}`);
    }

    if (Date.now() >= deadline) {
      throw new Error(
        lastStatus
          ? `attestation for ${txHash} is still "${lastStatus}" after ${Math.round(opts.timeoutMs / 1000)}s — ` +
            `re-run later, nothing is lost.`
          : `Circle's v2 API has no message for ${txHash} on source domain ${sourceDomain}. ` +
            `Check both: the hash must be the transit-chain tx that ran \`execute\` (not the Noble burn), and the ` +
            `domain must be the chain that tx ran on. See ${url}`,
      );
    }
    if (!announced) {
      console.log(`waiting for Circle's attestation — ${url} ...`);
      announced = true;
    }
    await new Promise((r) => setTimeout(r, opts.intervalMs));
  }
}
