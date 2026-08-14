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
      console.log(`waiting for Circle's attestation (${cfg.irisApi}, source domain ${cfg.nobleDomain}) ...`);
      announced = true;
    }
    await new Promise((r) => setTimeout(r, opts.intervalMs));
  }
}
