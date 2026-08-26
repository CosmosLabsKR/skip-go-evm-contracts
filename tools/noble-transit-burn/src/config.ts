import "dotenv/config";
import { getAddress, isAddress, isHex, type Address, type Hex } from "viem";

import { toBytes32, type Overrides } from "./args.js";
import { deploymentFor, resolveChain, resolveDeployEnv, type Deployment, type DeployEnv, type TransitChain } from "./chains.js";

/**
 * Every value the transit depends on, resolved from the environment.
 *
 * The transit chain (hop 1's destination, where the forwarder lives) is CHOSEN — `TRANSIT_CHAIN` — and everything
 * chain-shaped follows from that choice: the CCTP domain, the RPC, the deployed executor/factory, which Circle
 * attestation service serves it, and which Noble network to burn from. One knob rather than six is not just
 * convenience: a half-switched .env points a Polygon route at Avalanche addresses, and on PROD those addresses
 * EXIST on both chains (see chains.ts), so nothing downstream would look wrong.
 *
 * Two different "destinations" live here and mixing them up is the easiest way to lose funds:
 *   transitDomain — where THIS burn lands (the transit chain, hop 1).
 *   ROUTE_DOMAIN  — where the forwarder re-burns to afterwards (hop 2). It is part of the CREATE2 salt, so it
 *                   changes the predicted mintRecipient rather than this message's destination.
 */

/**
 * The four readers, bound to one source of values: CLI overrides first, then .env, then the built-in default.
 *
 * They are built per call rather than living at module scope so that a flag and an env var are read through the
 * same path — a second lookup mechanism for flags is how the two drift into disagreeing about precedence.
 */
function readers(ov: Overrides) {
  const raw = (name: string): string | undefined => ov[name] ?? process.env[name];

  function req(name: string, fallback?: string): string {
    const v = raw(name) ?? fallback;
    if (v === undefined || v === "") throw new Error(`missing required setting: ${name} (or its --flag)`);
    return v;
  }

  function reqAddress(name: string, fallback?: string): Address {
    const v = req(name, fallback);
    if (!isAddress(v)) throw new Error(`${name} is not an EVM address: ${v}`);
    return getAddress(v);
  }

  /** Accepts a plain 20-byte address too, left-padding it the way CCTP encodes an EVM recipient. */
  function reqBytes32(name: string, fallback?: string): Hex {
    return toBytes32(name, req(name, fallback)) as Hex;
  }

  function reqUint(name: string, fallback?: string): number {
    const v = Number(req(name, fallback));
    if (!Number.isInteger(v) || v < 0) throw new Error(`${name} must be a non-negative integer`);
    return v;
  }

  return { raw, req, reqAddress, reqBytes32, reqUint };
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

  // ── Transit chain (hop 1 destination — Avalanche or Polygon) ──
  chain: TransitChain;
  /** Which of the chain's two deployments is in play, when the addresses came from the registry. */
  deployEnv?: DeployEnv;
  evmRpc: string;
  /** The transit chain's CCTP domain: 1 on Avalanche/Fuji, 7 on Polygon/Amoy. */
  transitDomain: number;
  executor: Address;
  factory: Address;
  /** The operator this deployment is expected to answer, when known. Preflight compares the live value to it. */
  expectedOperator?: Address;
  /** Operator key for TransitExecutor. Only the `execute` command needs it. */
  evmPrivateKey?: Uint8Array;

  // ── Route (hop 2, engraved in the forwarder's CREATE2 address) ──
  routeSender: Address;
  routeDomain: number;
  /** Absent is legitimate for `check`, which reports the deployment's wiring without describing a route. */
  routeMintRecipient?: Hex;

  // ── Injective (hop 3 destination — where the transit actually ends) ──
  // Injective's EVM runs the stock CCTP v2 contracts, so the final mint is an ordinary receiveMessage there.
  injectiveRpc: string;
  injectiveMessageTransmitter: Address;
  /** Key for whoever the onward burn named as destinationCaller. Only the `mint` command needs it. */
  injectivePrivateKey?: Uint8Array;

  // ── Onward burn (hop 2 parameters, passed to executeTransit) ──
  // Optional here, validated by requireExecuteParams: `burn` never touches them, and forcing a burn-only user to
  // invent them would be noise.
  maxFee?: bigint;
  minFinalityThreshold?: number;
  onwardDestinationCaller?: Hex;

  // ── Attestation ──
  irisApi: string;
  nobleDomain: number;

  /** Burn amount in uusdc. Absent for commands that do not burn — see requireAmount. */
  amount?: bigint;
}

/** The route's final recipient, as a command that cannot describe a route without one. */
export function requireRoute(cfg: Config): Hex {
  if (!cfg.routeMintRecipient) {
    throw new Error("no route: set ROUTE_MINT_RECIPIENT in .env, or pass --recipient <address>");
  }
  return cfg.routeMintRecipient;
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
 *
 * ⚠️ There is no relayer fee any more. TransitForwarder v2 calls Circle's TokenMessenger directly and charges
 *    nothing, so `feeAmount` is gone from the contract signature and from here. `maxFee` is NOT that fee: it is
 *    CCTP v2's own destination-side cap, paid to Circle, and it stays.
 */
export interface ExecuteParams {
  maxFee: bigint;
  minFinalityThreshold: number;
  onwardDestinationCaller: Hex;
}

export function requireExecuteParams(cfg: Config): ExecuteParams {
  const { maxFee, minFinalityThreshold, onwardDestinationCaller } = cfg;
  if (maxFee === undefined || maxFee < 0n) throw new Error("MAX_FEE must be set and non-negative");
  if (minFinalityThreshold !== 1000 && minFinalityThreshold !== 2000) {
    throw new Error("MIN_FINALITY_THRESHOLD must be 1000 (fast) or 2000 (standard) — CCTP v2 accepts nothing else");
  }
  if (!onwardDestinationCaller || /^0x0+$/.test(onwardDestinationCaller)) {
    throw new Error("ONWARD_DESTINATION_CALLER must be set and non-zero (EmptyDestinationCaller on-chain)");
  }
  return { maxFee, minFinalityThreshold, onwardDestinationCaller };
}

/**
 * Variables that used to mean something and now mean something else — refused rather than ignored.
 *
 * A silently ignored AVALANCHE_DOMAIN reads, to whoever set it, as a confirmation that the tool is pointed at
 * Avalanche. FEE_AMOUNT is worse: it names a charge the route no longer takes, so honouring the intent behind it
 * is impossible and dropping it quietly would misreport what the transit costs.
 */
function rejectRetiredVars(): void {
  const retired: [string, string][] = [
    ["AVALANCHE_DOMAIN", "the transit chain's domain now comes from TRANSIT_CHAIN (override with TRANSIT_DOMAIN)"],
    ["FEE_AMOUNT", "TransitForwarder v2 takes no relayer fee — remove it; MAX_FEE is Circle's own cap and stays"],
  ];
  for (const [name, why] of retired) {
    if (process.env[name]) throw new Error(`${name} is no longer used: ${why}`);
  }
}

/** Whichever addresses are in play, and where they came from. Explicit env always wins over the registry. */
function resolveDeployment(chain: TransitChain, env: ReturnType<typeof readers>): {
  executor: Address;
  factory: Address;
  deployEnv?: DeployEnv;
  expectedOperator?: Address;
} {
  const explicitExecutor = env.raw("TRANSIT_EXECUTOR");
  const explicitFactory = env.raw("TRANSIT_FACTORY");

  // Half-explicit is the dangerous case: an executor from one environment paired with the other's factory is
  // caught on-chain (executor.factory() mismatch) but only after the RPC round-trip, and only if both exist.
  if (!!explicitExecutor !== !!explicitFactory) {
    throw new Error("TRANSIT_EXECUTOR and TRANSIT_FACTORY must be set together, or neither (then DEPLOY_ENV picks)");
  }

  if (explicitExecutor && explicitFactory) {
    return { executor: env.reqAddress("TRANSIT_EXECUTOR"), factory: env.reqAddress("TRANSIT_FACTORY") };
  }

  // No default: PROD and DEV live on the same chain behind different addresses, so a default would silently pick
  // one deployment while the operator meant the other. Same reasoning as the contracts' own DEPLOY_ENV.
  const rawEnv = env.raw("DEPLOY_ENV");
  if (!rawEnv) {
    throw new Error(
      "DEPLOY_ENV (or --env) is required (prod or dev) — it picks which of the chain's two deployments to use, and they " +
        "sit on the same chain behind different addresses. Or set TRANSIT_EXECUTOR + TRANSIT_FACTORY explicitly.",
    );
  }
  const deployEnv = resolveDeployEnv(rawEnv);
  const d: Deployment = deploymentFor(chain, deployEnv);
  return { executor: d.executor, factory: d.factory, deployEnv, expectedOperator: d.operator };
}

export function loadConfig(opts: { amount?: bigint; overrides?: Overrides } = {}): Config {
  rejectRetiredVars();

  const env = readers(opts.overrides ?? {});
  const { raw, req, reqAddress, reqBytes32, reqUint } = env;

  const amountRaw = opts.amount ?? (raw("AMOUNT") ? BigInt(raw("AMOUNT")!) : undefined);
  if (amountRaw !== undefined && amountRaw <= 0n) {
    throw new Error("amount must be greater than zero (in uusdc, 6 decimals)");
  }

  // The one choice everything chain-shaped follows from. No default: see the header.
  const chain = resolveChain(req("TRANSIT_CHAIN"));
  const { executor, factory, deployEnv, expectedOperator } = resolveDeployment(chain, env);

  // Testnet and mainnet are served by disjoint attestation indexes and disjoint Noble networks, so both follow the
  // chain rather than being set independently — a mainnet burn looked up in sandbox just 404s forever.
  const testnet = chain.testnet;

  return {
    nobleRpc: req("NOBLE_RPC", testnet ? "https://noble-testnet-rpc.polkachu.com" : "https://rpc-noble.mainnet.cosmoslabs.kr"),
    nobleChainId: req("NOBLE_CHAIN_ID", testnet ? "grand-1" : "noble-1"),
    privateKey: parsePrivateKey("NOBLE_PK", raw("NOBLE_PK")),
    burnToken: req("BURN_TOKEN", "uusdc"),
    gasPrice: req("GAS_PRICE", "0.1uusdc"),
    gasLimit: reqUint("GAS_LIMIT", "300000"),

    chain,
    deployEnv,
    evmRpc: req("EVM_RPC", chain.defaultRpc),
    // Circle's domain for the transit chain — 1 for Avalanche and Fuji alike, 7 for Polygon and Amoy. Domains
    // identify the chain, not the network. Asserted against the executor's own transmitter before any call.
    transitDomain: reqUint("TRANSIT_DOMAIN", String(chain.cctpDomain)),
    executor,
    factory,
    expectedOperator,
    evmPrivateKey: parsePrivateKey("EVM_PK", raw("EVM_PK")),

    routeSender: reqAddress("ROUTE_SENDER", "0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3"),
    // Injective. The forwarder impl refuses any other value at initialize (UnsupportedDestination).
    routeDomain: reqUint("ROUTE_DOMAIN", "29"),
    // No default: this is the final recipient of the funds and a wrong value is unrecoverable.
    routeMintRecipient: raw("ROUTE_MINT_RECIPIENT") ? reqBytes32("ROUTE_MINT_RECIPIENT") : undefined,

    injectiveRpc: req("INJECTIVE_RPC", "https://sentry.evm-rpc.injective.network"),
    // Circle deploys MessageTransmitterV2 at the same address on every EVM chain.
    // ⚠️ This default is MAINNET Injective and does NOT follow chain.testnet the way Noble and Iris do. The
    //    localDomain() == 29 check in `mint` cannot catch that: domains identify the chain, not the network, so
    //    Injective testnet answers 29 as well. On a testnet transit, set INJECTIVE_RPC (or --injective-rpc)
    //    explicitly — `mint` says so when it notices the two tiers disagree.
    injectiveMessageTransmitter: reqAddress("INJECTIVE_MESSAGE_TRANSMITTER", "0x81D40F21F12A8F0E3252Bccb954D722d4c464B64"),
    injectivePrivateKey: parsePrivateKey("INJECTIVE_PK", raw("INJECTIVE_PK")),

    maxFee: raw("MAX_FEE") ? BigInt(raw("MAX_FEE")!) : undefined,
    minFinalityThreshold: reqUint("MIN_FINALITY_THRESHOLD", "2000"),
    // Who may call receiveMessage on Injective. Non-zero is enforced on-chain (EmptyDestinationCaller): leaving it
    // open is the same nonce-griefing path this design closes on the transit chain, one hop further along.
    onwardDestinationCaller: raw("ONWARD_DESTINATION_CALLER") ? reqBytes32("ONWARD_DESTINATION_CALLER") : undefined,

    // Sandbox serves testnet domains; mainnet is https://iris-api.circle.com.
    irisApi: req("IRIS_API", testnet ? "https://iris-api-sandbox.circle.com" : "https://iris-api.circle.com"),
    nobleDomain: reqUint("NOBLE_DOMAIN", "4"),

    amount: amountRaw,
  };
}
