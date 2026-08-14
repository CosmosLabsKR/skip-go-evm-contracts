import { createPublicClient, http, pad, type Address, type Hex } from "viem";
import type { Config } from "./config.js";

/**
 * The forwarder address must come from the factory, not from a local CREATE2 re-derivation.
 *
 * `beaconInitCodeHash` is cached in factory storage at initialize and never recomputed, so a local computation from
 * the compiled BeaconProxy creation code can silently disagree with the live factory (build-config drift). Asking
 * the deployed contract is the only prediction that is guaranteed to match where the funds will actually land.
 */
const FACTORY_ABI = [
  {
    type: "function",
    name: "getForwarderAddress",
    stateMutability: "view",
    inputs: [
      { name: "sender", type: "address" },
      { name: "destinationDomain", type: "uint32" },
      { name: "mintRecipient", type: "bytes32" },
    ],
    outputs: [{ name: "predicted", type: "address" }],
  },
  {
    type: "function",
    name: "isForwarderDeployed",
    stateMutability: "view",
    inputs: [
      { name: "sender", type: "address" },
      { name: "destinationDomain", type: "uint32" },
      { name: "mintRecipient", type: "bytes32" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

const EXECUTOR_ABI = [
  { type: "function", name: "factory", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

export interface Prediction {
  forwarder: Address;
  deployed: boolean;
  /** The forwarder address as CCTP's 32-byte, left-padded mintRecipient. */
  mintRecipient: Hex;
}

export async function predictForwarder(cfg: Config): Promise<Prediction> {
  const client = createPublicClient({ transport: http(cfg.evmRpc) });
  const route = [cfg.routeSender, cfg.routeDomain, cfg.routeMintRecipient] as const;

  const [forwarder, deployed, executorFactory] = await Promise.all([
    client.readContract({ address: cfg.factory, abi: FACTORY_ABI, functionName: "getForwarderAddress", args: route }),
    client.readContract({ address: cfg.factory, abi: FACTORY_ABI, functionName: "isForwarderDeployed", args: route }),
    client.readContract({ address: cfg.executor, abi: EXECUTOR_ABI, functionName: "factory" }),
  ]);

  // The executor creates a missing forwarder through ITS OWN factory and rejects anything that factory does not
  // predict (RouteMismatch). Predicting against a different factory would produce an address the transit can never
  // resolve, so catch the mismatch here rather than after the funds are burned.
  if (executorFactory.toLowerCase() !== cfg.factory.toLowerCase()) {
    throw new Error(
      `factory mismatch: TRANSIT_FACTORY is ${cfg.factory} but the executor at ${cfg.executor} uses ${executorFactory}`,
    );
  }

  return { forwarder, deployed, mintRecipient: pad(forwarder, { size: 32 }) };
}
