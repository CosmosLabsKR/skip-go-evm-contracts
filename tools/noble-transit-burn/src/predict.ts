import { pad, type Address, type Hex, type PublicClient } from "viem";

import { requireRoute, type Config } from "./config.js";
import { assertDeployment, evmClient, inspectDeployment, type DeploymentInfo } from "./deployment.js";

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

export interface Prediction {
  forwarder: Address;
  deployed: boolean;
  /** The forwarder address as CCTP's 32-byte, left-padded mintRecipient. */
  mintRecipient: Hex;
  /** What the executor turned out to be — chain, version and wiring, already checked against the config. */
  deployment: DeploymentInfo;
}

/**
 * @param known A deployment already inspected by the caller. Passing it skips a second round of ~13 reads against
 *              what are usually public, rate-limited RPCs; the checks still run, on the same data.
 */
export async function predictForwarder(
  cfg: Config,
  client: PublicClient = evmClient(cfg),
  known?: DeploymentInfo,
): Promise<Prediction> {
  // Identity first: predicting an address on the wrong chain, or off a superseded executor, produces a plausible
  // answer that the transit can never resolve.
  const deployment = known ?? (await inspectDeployment(cfg, client));
  assertDeployment(cfg, deployment);

  const route = [cfg.routeSender, cfg.routeDomain, requireRoute(cfg)] as const;
  const [forwarder, deployed] = await Promise.all([
    client.readContract({ address: cfg.factory, abi: FACTORY_ABI, functionName: "getForwarderAddress", args: route }),
    client.readContract({ address: cfg.factory, abi: FACTORY_ABI, functionName: "isForwarderDeployed", args: route }),
  ]);

  return { forwarder, deployed, mintRecipient: pad(forwarder, { size: 32 }), deployment };
}
