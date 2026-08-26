import { getAddress, type Address } from "viem";

/**
 * The chains a transit can START from, and where its contracts live on each.
 *
 * This is the tool's mirror of TransitForwarder/script/Config.sol, and it exists for the same reason that file
 * gives: **each chain is an independent deployment**. The factory, beacon, executor and every per-route forwarder
 * on Polygon are distinct contracts from Avalanche's. Nothing here is cross-chain.
 *
 * ⚠️ THE PROD ADDRESSES ARE IDENTICAL ON AVALANCHE AND POLYGON (same deployer, same nonce). An address alone
 *    therefore does NOT tell you which chain you are on — only `cctpDomain` (1 vs 7) does, and that value is what
 *    the burn commits funds to. That is why `TRANSIT_CHAIN` is an explicit choice rather than something inferred
 *    from an address, and why every command asserts the live chain id and the executor's own transmitter domain
 *    against the row below before it builds anything.
 *
 * VERIFIED ON-CHAIN 2026-08-26 — every row read back its executor's `version`, `factory`, `transmitter`, `usdc`
 * and `operator`, and each factory's `executor` pointed back at its own executor. All six answer `version() = 2`.
 */
export interface TransitChain {
  key: ChainKey;
  label: string;
  chainId: number;
  /** Circle's CCTP domain for this chain. Identifies the CHAIN, not the network — mainnet and testnet share it. */
  cctpDomain: number;
  testnet: boolean;
  defaultRpc: string;
  /** Deployed proxies, by environment. Testnets only ever got one deployment, filed here as `dev`. */
  deployments: Partial<Record<DeployEnv, Deployment>>;
}

export interface Deployment {
  executor: Address;
  factory: Address;
  /** The executor's operator — the only account `execute --send` can be run from. Display/preflight only. */
  operator: Address;
}

export type ChainKey = "avalanche" | "polygon" | "fuji" | "amoy";
export type DeployEnv = "prod" | "dev";

const PROD: Deployment = {
  executor: getAddress("0xF9701898e7a543028d47A3913BC191CaE7371334"),
  factory: getAddress("0x62FbB2745A293c5E5A3115961b4DE69c2D524FFb"),
  operator: getAddress("0xfc05aD74C6FE2e7046E091D6Ad4F660D2A159762"),
};

export const CHAINS: Record<ChainKey, TransitChain> = {
  avalanche: {
    key: "avalanche",
    label: "Avalanche C-Chain",
    chainId: 43114,
    cctpDomain: 1,
    testnet: false,
    defaultRpc: "https://api.avax.network/ext/bc/C/rpc",
    deployments: {
      // Same addresses as Polygon PROD — see the warning above.
      prod: PROD,
      dev: {
        executor: getAddress("0x543f2c0d6d33699bf643C7bBF973f612B6cE9A70"),
        factory: getAddress("0x50Ca49b95Fe6bfdF4842f5Ce7C0D9177152fC27d"),
        operator: getAddress("0x257cac9aa58c17E09074d7089CA878167611fc00"),
      },
    },
  },
  polygon: {
    key: "polygon",
    label: "Polygon PoS",
    chainId: 137,
    cctpDomain: 7,
    testnet: false,
    // polygon-rpc.com rejects some clients outright; publicnode answers plain JSON-RPC without a key.
    defaultRpc: "https://polygon-bor-rpc.publicnode.com",
    deployments: {
      prod: PROD,
      dev: {
        executor: getAddress("0x98C3cB7129CC4300a23E14503b55300e4396b508"),
        factory: getAddress("0xbda40fDB74216a78B9cCfeEAEcafe1928De724f5"),
        operator: getAddress("0x257cac9aa58c17E09074d7089CA878167611fc00"),
      },
    },
  },
  fuji: {
    key: "fuji",
    label: "Avalanche Fuji (testnet)",
    chainId: 43113,
    cctpDomain: 1,
    testnet: true,
    defaultRpc: "https://api.avax-test.network/ext/bc/C/rpc",
    deployments: {
      // ⚠️ Redeployed 2026-08-24. The pair this tool shipped with until now (executor 0x015218cF…, factory
      //    0x15238573…) is the SUPERSEDED v1 deployment — it still answers, and its `executeTransit` still takes
      //    the removed `feeAmount` argument, which is why calls built from the current source failed against it.
      dev: {
        executor: getAddress("0xb47f65345d237637d2c086ca682e76b4f74bbed5"),
        factory: getAddress("0x0ee32556794c7d5f4c0a954b5290e222605f92bd"),
        // Not the usual DEV key: this deployment was made with the route-sender EOA as operator.
        operator: getAddress("0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3"),
      },
    },
  },
  amoy: {
    key: "amoy",
    label: "Polygon Amoy (testnet)",
    chainId: 80002,
    cctpDomain: 7,
    testnet: true,
    defaultRpc: "https://polygon-amoy-bor-rpc.publicnode.com",
    deployments: {
      dev: {
        executor: getAddress("0x1523857349959aa02Efb00736151eaF4fD462081"),
        factory: getAddress("0xe855c13435c371dc6112421bfbe5a50f6539aef5"),
        operator: getAddress("0x257cac9aa58c17E09074d7089CA878167611fc00"),
      },
    },
  },
};

/** Spellings that mean the same chain, so a plausible guess is not an error. */
const ALIASES: Record<string, ChainKey> = {
  avax: "avalanche",
  "avalanche-mainnet": "avalanche",
  "43114": "avalanche",
  matic: "polygon",
  "polygon-pos": "polygon",
  "137": "polygon",
  "avalanche-fuji": "fuji",
  "avalanche-testnet": "fuji",
  "43113": "fuji",
  "polygon-amoy": "amoy",
  "polygon-testnet": "amoy",
  "80002": "amoy",
};

export function resolveChain(raw: string): TransitChain {
  const key = raw.trim().toLowerCase();
  // Object.hasOwn, not `in`: `TRANSIT_CHAIN=constructor` otherwise passes the guard and lands on undefined.
  const resolved = Object.hasOwn(CHAINS, key)
    ? (key as ChainKey)
    : Object.hasOwn(ALIASES, key)
      ? ALIASES[key]
      : undefined;
  if (!resolved) {
    throw new Error(`unknown TRANSIT_CHAIN "${raw}" — expected one of ${Object.keys(CHAINS).join(", ")}`);
  }
  return CHAINS[resolved];
}

export function resolveDeployEnv(raw: string): DeployEnv {
  const v = raw.trim().toLowerCase();
  if (v === "prod" || v === "production" || v === "mainnet") return "prod";
  if (v === "dev" || v === "development") return "dev";
  throw new Error(`unknown DEPLOY_ENV "${raw}" — expected prod or dev`);
}

/**
 * The deployment for a chain/environment pair, or a refusal that says what does exist.
 *
 * ⚠️ There is deliberately no fallback to the other environment. PROD and DEV sit on the SAME chain behind
 *    different addresses, so a silent substitution would look entirely correct in every other field.
 */
export function deploymentFor(chain: TransitChain, env: DeployEnv): Deployment {
  const found = chain.deployments[env];
  if (!found) {
    const have = Object.keys(chain.deployments).join(", ") || "none";
    throw new Error(
      `no ${env.toUpperCase()} deployment recorded on ${chain.label} (have: ${have}). ` +
        `Set TRANSIT_EXECUTOR and TRANSIT_FACTORY explicitly if one exists.`,
    );
  }
  return found;
}
