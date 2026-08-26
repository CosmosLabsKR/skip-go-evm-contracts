import { createPublicClient, http, type Address, type PublicClient } from "viem";

import type { Config } from "./config.js";

/**
 * What the configured executor actually is, read from the chain, and the checks that decide whether it is the one
 * the .env describes.
 *
 * This exists because of one specific hazard: **the PROD executor and factory have the same addresses on Avalanche
 * and on Polygon.** A .env that switched `TRANSIT_CHAIN` but not `EVM_RPC` (or the reverse) therefore addresses
 * real, live, correctly-wired contracts — on the wrong chain — and every address in the summary looks right. The
 * only fields that disagree are the chain id and the CCTP domain the executor's own transmitter reports, so those
 * are read and compared before anything is built.
 *
 * The version check catches the other failure that has actually happened here: pointing at a superseded v1
 * deployment, whose `executeTransit` still takes the `feeAmount` argument the current contracts removed. A call
 * built from this source cannot decode there, and the revert says nothing useful.
 */

export const EXPECTED_EXECUTOR_VERSION = 2n;

const EXECUTOR_ABI = [
  { type: "function", name: "version", stateMutability: "pure", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "factory", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "transmitter", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "usdc", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "operator", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

const FACTORY_ABI = [
  { type: "function", name: "version", stateMutability: "pure", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "executor", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "beacon", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

const BEACON_ABI = [
  { type: "function", name: "implementation", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

const FORWARDER_ABI = [
  { type: "function", name: "version", stateMutability: "pure", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "LOCAL_DOMAIN", stateMutability: "view", inputs: [], outputs: [{ type: "uint32" }] },
  {
    type: "function",
    name: "ALLOWED_DESTINATION_DOMAIN",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint32" }],
  },
  { type: "function", name: "messenger", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "executor", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

const TRANSMITTER_ABI = [
  { type: "function", name: "localDomain", stateMutability: "view", inputs: [], outputs: [{ type: "uint32" }] },
  { type: "function", name: "version", stateMutability: "view", inputs: [], outputs: [{ type: "uint32" }] },
] as const;

export interface DeploymentInfo {
  chainId: number;
  executorVersion: bigint;
  /** The factory the executor itself will create missing forwarders through. */
  factory: Address;
  transmitter: Address;
  /** The transit chain's CCTP domain, as the mint leg's own transmitter reports it. */
  transmitterDomain: number;
  /** 0 for a CCTP v1 MessageTransmitter — the mint leg is v1, and v2 would answer 1. */
  transmitterVersion: number;
  usdc: Address;
  operator: Address;
  /** The factory, and the forwarder implementation every route on it will be a proxy to. */
  factoryVersion: bigint;
  factoryExecutor: Address;
  beacon: Address;
  forwarder: ForwarderImpl;
}

/**
 * The immutables baked into the forwarder implementation, shared by every route deployed off this factory.
 *
 * `allowedDestinationDomain` is the one that has to be checked BEFORE a burn rather than after: the forwarder
 * refuses any other destination at `initialize`, so a route with the wrong ROUTE_DOMAIN cannot be created at all —
 * and by the time the executor tries, the source chain has already burned.
 */
export interface ForwarderImpl {
  address: Address;
  version: bigint;
  localDomain: number;
  allowedDestinationDomain: number;
  messenger: Address;
  executor: Address;
}

export function evmClient(cfg: Config): PublicClient {
  return createPublicClient({ transport: http(cfg.evmRpc) });
}

export async function inspectDeployment(cfg: Config, client: PublicClient = evmClient(cfg)): Promise<DeploymentInfo> {
  const executor = { address: cfg.executor, abi: EXECUTOR_ABI } as const;

  // Both of these come first, and on their own. Reading a contract that is not there produces viem's "returned no
  // data" — true, but it describes the symptom of a wrong RPC rather than the mistake, and the mistake is the one
  // an operator is actually making when they switch --chain and leave EVM_RPC pointing at the old one.
  const chainId = await client.getChainId();
  assertChainId(cfg, chainId);

  const code = await client.getCode({ address: cfg.executor });
  if (!code || code === "0x") {
    throw new Error(
      `no contract at TRANSIT_EXECUTOR ${cfg.executor} on ${cfg.chain.label} (chain ${chainId}, via ${cfg.evmRpc})`,
    );
  }

  const [executorVersion, factory, transmitter, usdc, operator] = await Promise.all([
    client.readContract({ ...executor, functionName: "version" }),
    client.readContract({ ...executor, functionName: "factory" }),
    client.readContract({ ...executor, functionName: "transmitter" }),
    client.readContract({ ...executor, functionName: "usdc" }),
    client.readContract({ ...executor, functionName: "operator" }),
  ]);

  // Read against the factory the EXECUTOR names, not the configured one: if they disagree, assertDeployment says
  // so, and reading the executor's own factory is what makes that message describe the live wiring.
  const factoryContract = { address: factory, abi: FACTORY_ABI } as const;
  const [transmitterDomain, transmitterVersion, factoryVersion, factoryExecutor, beacon] = await Promise.all([
    client.readContract({ address: transmitter, abi: TRANSMITTER_ABI, functionName: "localDomain" }),
    client.readContract({ address: transmitter, abi: TRANSMITTER_ABI, functionName: "version" }),
    client.readContract({ ...factoryContract, functionName: "version" }),
    client.readContract({ ...factoryContract, functionName: "executor" }),
    client.readContract({ ...factoryContract, functionName: "beacon" }),
  ]);

  const implAddress = await client.readContract({ address: beacon, abi: BEACON_ABI, functionName: "implementation" });
  const impl = { address: implAddress, abi: FORWARDER_ABI } as const;
  const [forwarderVersion, localDomain, allowedDestinationDomain, messenger, forwarderExecutor] = await Promise.all([
    client.readContract({ ...impl, functionName: "version" }),
    client.readContract({ ...impl, functionName: "LOCAL_DOMAIN" }),
    client.readContract({ ...impl, functionName: "ALLOWED_DESTINATION_DOMAIN" }),
    client.readContract({ ...impl, functionName: "messenger" }),
    client.readContract({ ...impl, functionName: "executor" }),
  ]);

  return {
    chainId,
    executorVersion,
    factory,
    transmitter,
    transmitterDomain,
    transmitterVersion,
    usdc,
    operator,
    factoryVersion,
    factoryExecutor,
    beacon,
    forwarder: {
      address: implAddress,
      version: forwarderVersion,
      localDomain,
      allowedDestinationDomain,
      messenger,
      executor: forwarderExecutor,
    },
  };
}

/**
 * The chain the RPC actually answers on, against the one that was asked for.
 *
 * Its own function because it runs twice: once before anything else is read (so a wrong RPC reports itself rather
 * than a missing contract), and again in the full pass, which stays the single description of every rule.
 */
export function assertChainId(cfg: Config, chainId: number): void {
  if (chainId !== cfg.chain.chainId) {
    throw new Error(
      `EVM_RPC (${cfg.evmRpc}) is chain ${chainId}, but the transit chain is ${cfg.chain.key} ` +
        `(${cfg.chain.chainId}). Pass --rpc, or clear EVM_RPC from .env to use the chain's default. ` +
        `On PROD the same executor address exists on both chains, so only this check tells them apart.`,
    );
  }
}

/** Everything that must hold before a call is built. Throws on the first disagreement, naming both sides. */
export function assertDeployment(cfg: Config, info: DeploymentInfo): void {
  assertChainId(cfg, info.chainId);

  if (info.executorVersion !== EXPECTED_EXECUTOR_VERSION) {
    throw new Error(
      `the executor at ${cfg.executor} reports version ${info.executorVersion}, but this tool builds calls for ` +
        `version ${EXPECTED_EXECUTOR_VERSION}. v1 takes a feeAmount argument that v2 removed, so the call would ` +
        `not decode there. Point TRANSIT_EXECUTOR/TRANSIT_FACTORY at the current deployment.`,
    );
  }

  if (info.factory.toLowerCase() !== cfg.factory.toLowerCase()) {
    // The executor creates a missing forwarder through ITS OWN factory and rejects anything that factory does not
    // predict (RouteMismatch). Predicting against a different factory produces an address the transit can never
    // resolve — after the funds are already burned.
    throw new Error(
      `factory mismatch: TRANSIT_FACTORY is ${cfg.factory} but the executor at ${cfg.executor} uses ${info.factory}`,
    );
  }

  if (info.transmitterDomain !== cfg.transitDomain) {
    throw new Error(
      `the executor's transmitter ${info.transmitter} reports CCTP domain ${info.transmitterDomain}, but the ` +
        `configured transit domain is ${cfg.transitDomain}. The burn would be addressed to the wrong chain.`,
    );
  }

  if (info.transmitterVersion !== 0) {
    throw new Error(
      `the executor's transmitter ${info.transmitter} reports CCTP version ${info.transmitterVersion}, not 0. ` +
        `The mint leg is CCTP v1; a v2 MessageTransmitter here means the executor is bound to the wrong protocol.`,
    );
  }

  const fwd = info.forwarder;

  if (info.factoryExecutor.toLowerCase() !== cfg.executor.toLowerCase()) {
    throw new Error(
      `the factory at ${cfg.factory} is frozen to executor ${info.factoryExecutor}, not ${cfg.executor} — ` +
        `these two are not a pair.`,
    );
  }

  if (fwd.localDomain !== cfg.transitDomain) {
    throw new Error(
      `the forwarder implementation ${fwd.address} is built for CCTP domain ${fwd.localDomain}, but the ` +
        `configured transit domain is ${cfg.transitDomain}. Every inbound message would be refused ` +
        `(WrongDestination).`,
    );
  }

  // Checked before the burn, not after: the forwarder refuses any other destination at initialize, so a route
  // with the wrong domain cannot even be created — while the source chain has already burned.
  if (fwd.allowedDestinationDomain !== cfg.routeDomain) {
    throw new Error(
      `ROUTE_DOMAIN is ${cfg.routeDomain}, but this deployment only forwards to domain ` +
        `${fwd.allowedDestinationDomain}. The route could never be created (UnsupportedDestination).`,
    );
  }

  if (fwd.executor.toLowerCase() !== cfg.executor.toLowerCase()) {
    throw new Error(
      `the forwarder implementation ${fwd.address} answers to executor ${fwd.executor}, not ${cfg.executor} — ` +
        `the executor could not drive the forwarders this factory creates.`,
    );
  }

  // A rotated operator is legitimate — the registry only records what was deployed — so this is a note, not a stop.
  // What the operator key must match is the LIVE value, which `execute` checks separately.
  if (cfg.expectedOperator && info.operator.toLowerCase() !== cfg.expectedOperator.toLowerCase()) {
    console.warn(
      `note: the ${cfg.deployEnv?.toUpperCase()} deployment on ${cfg.chain.label} was recorded with operator ` +
        `${cfg.expectedOperator}, but answers ${info.operator} — it has been rotated since.`,
    );
  }
}
