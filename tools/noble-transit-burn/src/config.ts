import "dotenv/config";
import { getAddress, isAddress, isHex, type Address, type Hex } from "viem";

/**
 * Every value the burn depends on, resolved from the environment with the deployed-testnet defaults baked in.
 *
 * Two different "destinations" live here and mixing them up is the easiest way to lose funds:
 *   AVALANCHE_DOMAIN — where THIS burn lands (the transit chain, hop 1).
 *   ROUTE_DOMAIN     — where the forwarder re-burns to afterwards (hop 2). It is part of the CREATE2 salt, so it
 *                      changes the predicted mintRecipient rather than this message's destination.
 */

function req(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === "") throw new Error(`missing required env var: ${name}`);
  return v;
}

function reqAddress(name: string, fallback?: string): Address {
  const v = req(name, fallback);
  if (!isAddress(v)) throw new Error(`${name} is not an EVM address: ${v}`);
  return getAddress(v);
}

function reqBytes32(name: string, fallback?: string): Hex {
  const v = req(name, fallback);
  if (!isHex(v) || v.length !== 66) throw new Error(`${name} must be 32 bytes of hex (0x + 64 chars): ${v}`);
  return v.toLowerCase() as Hex;
}

function reqUint(name: string, fallback?: string): number {
  const v = Number(req(name, fallback));
  if (!Number.isInteger(v) || v < 0) throw new Error(`${name} must be a non-negative integer`);
  return v;
}

/**
 * Raw secp256k1 signing key, 32 bytes, with or without the 0x prefix. Absent means build-only mode.
 *
 * The error messages below deliberately never echo the value — this is the one env var whose contents must not
 * reach a terminal, a CI log, or a shell history.
 */
function parsePrivateKey(name: string, raw: string | undefined): Uint8Array | undefined {
  const v = raw?.trim();
  if (!v) return undefined;
  const hex = v.startsWith("0x") || v.startsWith("0X") ? v.slice(2) : v;
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) {
    throw new Error(`${name} must be a 32-byte secp256k1 key in hex (64 chars, 0x prefix optional)`);
  }
  const bytes = Uint8Array.from(Buffer.from(hex, "hex"));
  // The signer would fail later anyway, but with an opaque libsecp256k1 error rather than a nameable one.
  if (bytes.every((b) => b === 0)) throw new Error(`${name} is all zeroes — not a valid key`);
  return bytes;
}

export interface Config {
  // ── Noble (source of the burn) ──
  nobleRpc: string;
  nobleChainId: string;
  privateKey?: Uint8Array;
  burnToken: string;
  gasPrice: string;
  gasLimit: number;

  // ── Avalanche (transit chain, hop 1 destination) ──
  evmRpc: string;
  avalancheDomain: number;
  executor: Address;
  factory: Address;
  /** Operator key for TransitExecutor. Only the `execute` command needs it. */
  evmPrivateKey?: Uint8Array;

  // ── Route (hop 2, engraved in the forwarder's CREATE2 address) ──
  routeSender: Address;
  routeDomain: number;
  routeMintRecipient: Hex;

  // ── Injective (hop 3 destination — where the transit actually ends) ──
  // Injective's EVM runs the stock CCTP v2 contracts, so the final mint is an ordinary receiveMessage there.
  injectiveRpc: string;
  injectiveMessageTransmitter: Address;
  /** Key for whoever the onward burn named as destinationCaller. Only the `mint` command needs it. */
  injectivePrivateKey?: Uint8Array;

  // ── Onward burn (hop 2 parameters, passed to executeTransit) ──
  // Optional here, validated by requireExecuteParams: `burn` never touches them, and forcing a burn-only user to
  // invent fee values would be noise.
  feeAmount?: bigint;
  maxFee?: bigint;
  minFinalityThreshold?: number;
  onwardDestinationCaller?: Hex;

  // ── Attestation ──
  irisApi: string;
  nobleDomain: number;

  /** Burn amount in uusdc. Absent for commands that do not burn — see requireAmount. */
  amount?: bigint;
}

/** The burn amount, as a command that cannot proceed without one. */
export function requireAmount(cfg: Config): bigint {
  if (cfg.amount === undefined) throw new Error("no amount: pass --usdc / --amount, or set AMOUNT in .env");
  return cfg.amount;
}

/**
 * The onward-burn parameters, validated. Every rule here is also enforced on-chain — by TransitExecutor
 * (_checkStaticParams) and again by TransitForwarder — but a revert there has already consumed the attestation
 * attempt and the operator's gas, so the same checks run before the call is built.
 */
export interface ExecuteParams {
  feeAmount: bigint;
  maxFee: bigint;
  minFinalityThreshold: number;
  onwardDestinationCaller: Hex;
}

export function requireExecuteParams(cfg: Config): ExecuteParams {
  const { feeAmount, maxFee, minFinalityThreshold, onwardDestinationCaller } = cfg;
  if (feeAmount === undefined) throw new Error("FEE_AMOUNT is required to execute a transit");
  if (feeAmount <= 0n) throw new Error("FEE_AMOUNT must be greater than zero — the relayer rejects a zero fee");
  if (maxFee === undefined || maxFee < 0n) throw new Error("MAX_FEE must be set and non-negative");
  if (minFinalityThreshold !== 1000 && minFinalityThreshold !== 2000) {
    throw new Error("MIN_FINALITY_THRESHOLD must be 1000 (fast) or 2000 (standard) — CCTP v2 accepts nothing else");
  }
  if (!onwardDestinationCaller || /^0x0+$/.test(onwardDestinationCaller)) {
    throw new Error("ONWARD_DESTINATION_CALLER must be set and non-zero (EmptyDestinationCaller on-chain)");
  }
  return { feeAmount, maxFee, minFinalityThreshold, onwardDestinationCaller };
}

export function loadConfig(overrides: { amount?: bigint } = {}): Config {
  const amountRaw = overrides.amount ?? (process.env.AMOUNT ? BigInt(process.env.AMOUNT) : undefined);
  if (amountRaw !== undefined && amountRaw <= 0n) {
    throw new Error("amount must be greater than zero (in uusdc, 6 decimals)");
  }

  return {
    nobleRpc: req("NOBLE_RPC", "https://noble-testnet-rpc.polkachu.com"),
    nobleChainId: req("NOBLE_CHAIN_ID", "grand-1"),
    privateKey: parsePrivateKey("NOBLE_PK", process.env.NOBLE_PK),
    burnToken: req("BURN_TOKEN", "uusdc"),
    gasPrice: req("GAS_PRICE", "0.1uusdc"),
    gasLimit: reqUint("GAS_LIMIT", "300000"),

    evmRpc: req("EVM_RPC", "https://api.avax-test.network/ext/bc/C/rpc"),
    // Circle's domain for Avalanche C-Chain and Fuji alike — domains identify the chain, not the network.
    avalancheDomain: reqUint("AVALANCHE_DOMAIN", "1"),
    executor: reqAddress("TRANSIT_EXECUTOR", "0x015218cFdce7E8285DfFB16c457054EE2a441025"),
    factory: reqAddress("TRANSIT_FACTORY", "0x1523857349959aa02Efb00736151eaF4fD462081"),
    evmPrivateKey: parsePrivateKey("EVM_PK", process.env.EVM_PK),

    routeSender: reqAddress("ROUTE_SENDER", "0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3"),
    // Injective. The forwarder impl refuses any other value at initialize (UnsupportedDestination).
    routeDomain: reqUint("ROUTE_DOMAIN", "29"),
    // No default: this is the final recipient of the funds and a wrong value is unrecoverable.
    routeMintRecipient: reqBytes32("ROUTE_MINT_RECIPIENT"),

    injectiveRpc: req("INJECTIVE_RPC", "https://sentry.evm-rpc.injective.network"),
    // Circle deploys MessageTransmitterV2 at the same address on every EVM chain; verified against
    // localDomain() == 29 before the call is built, so a wrong override cannot silently mint on another chain.
    injectiveMessageTransmitter: reqAddress("INJECTIVE_MESSAGE_TRANSMITTER", "0x81D40F21F12A8F0E3252Bccb954D722d4c464B64"),
    injectivePrivateKey: parsePrivateKey("INJECTIVE_PK", process.env.INJECTIVE_PK),

    feeAmount: process.env.FEE_AMOUNT ? BigInt(process.env.FEE_AMOUNT) : undefined,
    maxFee: process.env.MAX_FEE ? BigInt(process.env.MAX_FEE) : undefined,
    minFinalityThreshold: reqUint("MIN_FINALITY_THRESHOLD", "2000"),
    // Who may call receiveMessage on Injective. Non-zero is enforced on-chain (EmptyDestinationCaller): leaving it
    // open is the same nonce-griefing path this design closes on Avalanche, one hop further along.
    onwardDestinationCaller: process.env.ONWARD_DESTINATION_CALLER
      ? reqBytes32("ONWARD_DESTINATION_CALLER")
      : undefined,

    // Sandbox serves testnet domains; mainnet is https://iris-api.circle.com.
    irisApi: req("IRIS_API", "https://iris-api-sandbox.circle.com"),
    nobleDomain: reqUint("NOBLE_DOMAIN", "4"),

    amount: amountRaw,
  };
}
