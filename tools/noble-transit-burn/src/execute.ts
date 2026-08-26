import { readFileSync } from "node:fs";
import {
  createWalletClient,
  formatUnits,
  http,
  isHex,
  pad,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { COMMON_HELP, asCount, takeCommonArgs } from "./args.js";
import { waitForAttestation, type AttestedMessage } from "./attestation.js";
import { parseCctpV1Message, toEvmAddress } from "./cctpMessage.js";
import { loadConfig, requireExecuteParams, requireRoute, type Config, type ExecuteParams } from "./config.js";
import { evmClient } from "./deployment.js";
import { predictForwarder, type Prediction } from "./predict.js";

const EXECUTOR_ABI = [
  {
    type: "function",
    name: "executeTransit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "message", type: "bytes" },
      { name: "attestation", type: "bytes" },
      { name: "routeSender", type: "address" },
      { name: "routeDestinationDomain", type: "uint32" },
      { name: "routeMintRecipient", type: "bytes32" },
      { name: "maxFee", type: "uint256" },
      { name: "minFinalityThreshold", type: "uint32" },
      { name: "destinationCaller", type: "bytes32" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "executeRefund",
    stateMutability: "nonpayable",
    inputs: [
      { name: "message", type: "bytes" },
      { name: "attestation", type: "bytes" },
      { name: "routeSender", type: "address" },
      { name: "routeDestinationDomain", type: "uint32" },
      { name: "routeMintRecipient", type: "bytes32" },
    ],
    outputs: [],
  },
] as const;

interface Args {
  txHash?: string;
  message?: Hex;
  attestation?: Hex;
  file?: string;
  index?: number;
  refund: boolean;
  send: boolean;
  waitSeconds: number;
  pollSeconds: number;
}

export function printExecuteHelp(): void {
  console.log(`
execute — run the second hop: TransitExecutor.executeTransit on the transit chain

  npm run execute -- --tx <nobleTxHash>              fetch attestation, simulate, do not send
  npm run execute -- --tx <nobleTxHash> --send       ... and send it (requires EVM_PK = operator key)
  npm run execute -- --tx <hash> --wait 900 --send   poll up to 15 min for the attestation first
  npm run execute -- --tx <hash> --refund --send     mint and return to ROUTE_SENDER, no onward burn

Message source (pick one)
  --tx <hash>             Noble burn tx; the message + attestation come from Circle's API
  --message <0x..>        raw message bytes, with --attestation
  --attestation <0x..>    raw attestation bytes, with --message
  --file <path>           JSON holding { message, attestation }

Options
  --send                  actually broadcast (default: simulate only)
  --refund                call executeRefund instead — mints and returns everything to ROUTE_SENDER
  --wait <seconds>        how long to poll for the attestation (default: 0, one attempt)
  --poll <seconds>        interval between attempts (default: 15)
  --index <n>             pick the nth CCTP message in the tx, if it carried several

${COMMON_HELP}

There is no relayer fee: the forwarder charges nothing. MAX_FEE is Circle's own destination-side cap.
`);
}

function parseArgs(argv: string[]): Args {
  const args: Args = { refund: false, send: false, waitSeconds: 0, pollSeconds: 15 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    switch (a) {
      case "--tx":
        args.txHash = next();
        break;
      case "--message":
        args.message = asHex("--message", next());
        break;
      case "--attestation":
        args.attestation = asHex("--attestation", next());
        break;
      case "--file":
        args.file = next();
        break;
      case "--index":
        args.index = asCount("--index", next());
        break;
      case "--refund":
        args.refund = true;
        break;
      case "--send":
        args.send = true;
        break;
      case "--wait":
        args.waitSeconds = asCount("--wait", next());
        break;
      case "--poll":
        args.pollSeconds = asCount("--poll", next());
        break;
      case "-h":
      case "--help":
        printExecuteHelp();
        process.exit(0);
      default:
        throw new Error(`unknown argument: ${a}`);
    }
  }
  return args;
}

function asHex(label: string, v: string): Hex {
  if (!isHex(v)) throw new Error(`${label} must be 0x-prefixed hex`);
  return v;
}

/** Resolve the message + attestation from whichever source the caller chose. */
async function resolveMessage(cfg: Config, args: Args, forwarder: Address): Promise<AttestedMessage> {
  if (args.message || args.attestation) {
    if (!args.message || !args.attestation) throw new Error("--message and --attestation must be given together");
    return { message: args.message, attestation: args.attestation };
  }

  if (args.file) {
    const parsed = JSON.parse(readFileSync(args.file, "utf8")) as { message?: string; attestation?: string };
    if (!parsed.message || !parsed.attestation) throw new Error(`${args.file} needs both "message" and "attestation"`);
    return { message: asHex("message", parsed.message), attestation: asHex("attestation", parsed.attestation) };
  }

  if (!args.txHash) throw new Error("no message source: pass --tx <nobleTxHash>, --file, or --message/--attestation");

  const found = await waitForAttestation(cfg, args.txHash, {
    timeoutMs: args.waitSeconds * 1000,
    intervalMs: Math.max(1, args.pollSeconds) * 1000,
  });

  if (args.index !== undefined) {
    const picked = found[args.index];
    if (!picked) throw new Error(`--index ${args.index} out of range: the tx carried ${found.length} message(s)`);
    return picked;
  }

  // A burn tx normally carries one message, but selecting by the forwarder it mints to is what makes the
  // multi-message case unambiguous — and it is the same field the executor derives the forwarder from.
  const target = pad(forwarder, { size: 32 }).toLowerCase();
  const matches = found.filter((m) => {
    try {
      return parseCctpV1Message(m.message).mintRecipient.toLowerCase() === target;
    } catch {
      return false;
    }
  });
  if (matches.length === 1) return matches[0]!;
  if (matches.length === 0) {
    throw new Error(
      `none of the ${found.length} message(s) in that tx mint to the predicted forwarder ${forwarder}. ` +
        `Check that the route in .env matches the one the burn committed to.`,
    );
  }
  throw new Error(`${matches.length} messages in that tx mint to ${forwarder} — disambiguate with --index`);
}

/**
 * Everything the executor and forwarder will check on-chain, checked first.
 *
 * A revert on any of these is not free: it costs the operator gas, and a wrong-route submission would have spent
 * the attestation attempt. None of it replaces the on-chain checks — see TransitExecutor._ensureForwarder.
 */
function preflight(cfg: Config, p: Prediction, m: AttestedMessage, params: ExecuteParams | undefined): bigint {
  const parsed = parseCctpV1Message(m.message);

  if (parsed.version !== 0) throw new Error(`message version is ${parsed.version}, expected 0 (CCTP v1)`);
  if (parsed.sourceDomain !== cfg.nobleDomain) {
    throw new Error(`message sourceDomain is ${parsed.sourceDomain}, expected ${cfg.nobleDomain} (Noble)`);
  }
  // The forwarder rejects a mismatch with WrongDestination, having already paid for signature verification.
  if (parsed.destinationDomain !== cfg.transitDomain) {
    throw new Error(
      `message destinationDomain is ${parsed.destinationDomain}, expected ${cfg.transitDomain} (${cfg.chain.label})`,
    );
  }

  const recipient = toEvmAddress(parsed.mintRecipient);
  if (recipient.toLowerCase() !== p.forwarder.toLowerCase()) {
    throw new Error(`message mints to ${recipient}, but the configured route predicts ${p.forwarder} (RouteMismatch)`);
  }

  // Only the executor may receive this message — if the burn named anyone else, this tool cannot resolve it at all.
  const caller = toEvmAddress(parsed.destinationCaller);
  if (caller.toLowerCase() !== cfg.executor.toLowerCase()) {
    throw new Error(`message pins destinationCaller ${caller}, not the executor ${cfg.executor}`);
  }

  // The whole minted amount goes onward — v2 takes no relayer fee — so CCTP v2's own cap is bounded against the
  // minted amount itself, which is what TransitForwarder checks (MaxFeeTooHigh).
  if (params && params.maxFee >= parsed.amount) {
    throw new Error(
      `MAX_FEE ${params.maxFee} must be strictly below the minted amount ${parsed.amount} (InvalidMaxFee). ` +
        `Use --refund to return the funds to ROUTE_SENDER instead.`,
    );
  }

  return parsed.amount;
}

export async function runExecute(argv: string[]): Promise<void> {
  const { overrides, rest } = takeCommonArgs(argv);
  const args = parseArgs(rest);
  const cfg = loadConfig({ overrides });
  // Refund burns nothing onward, so it needs none of the fee/finality/caller parameters.
  const params = args.refund ? undefined : requireExecuteParams(cfg);

  const account = cfg.evmPrivateKey ? privateKeyToAccount(toHex(cfg.evmPrivateKey)) : undefined;
  if (args.send && !account) throw new Error("--send requires EVM_PK (the TransitExecutor operator key)");

  const publicClient = evmClient(cfg);
  // Also asserts the chain id, the executor's version and its transmitter's domain against .env — see
  // deployment.ts. On PROD the executor address alone cannot tell Avalanche and Polygon apart.
  const prediction = await predictForwarder(cfg, publicClient);

  const attested = await resolveMessage(cfg, args, prediction.forwarder);
  const amount = preflight(cfg, prediction, attested, params);

  // NotOperator is the most common failure and the cheapest to catch: the operator is an impl immutable, so a
  // rotated executor changes it without any storage write to notice.
  const operator = prediction.deployment.operator;
  if (account && operator.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(`EVM_PK is ${account.address} but the executor's operator is ${operator} (NotOperator)`);
  }

  const route = [cfg.routeSender, cfg.routeDomain, requireRoute(cfg)] as const;
  const call = params
    ? ({
        functionName: "executeTransit",
        args: [
          attested.message,
          attested.attestation,
          ...route,
          params.maxFee,
          params.minFinalityThreshold,
          params.onwardDestinationCaller,
        ],
      } as const)
    : ({ functionName: "executeRefund", args: [attested.message, attested.attestation, ...route] } as const);

  console.log(`
Message
  source domain      ${cfg.nobleDomain} (Noble)  →  ${cfg.transitDomain} (${cfg.chain.label})
  minted amount      ${formatUnits(amount, 6)} USDC (${amount})
  mints to           ${prediction.forwarder} ${prediction.deployed ? "" : "(created by this call)"}

Call
  chain              ${cfg.chain.label} (id ${prediction.deployment.chainId})${cfg.deployEnv ? `, ${cfg.deployEnv.toUpperCase()}` : ""}
  executor           ${cfg.executor} (v${prediction.deployment.executorVersion})
  function           ${call.functionName}
  operator           ${operator}${account ? (account.address === operator ? " (EVM_PK ✓)" : "") : " — no EVM_PK set"}
  route              ${cfg.routeSender} / domain ${cfg.routeDomain} / ${route[2]}${
    params
      ? `
  onward amount      ${formatUnits(amount, 6)} USDC (no relayer fee)
  maxFee             ${params.maxFee} (Circle's cap, paid on Injective)
  finality           ${params.minFinalityThreshold} (${params.minFinalityThreshold === 1000 ? "fast" : "standard"})
  destinationCaller  ${params.onwardDestinationCaller}`
      : `
  refund to          ${cfg.routeSender} (no onward burn)`
  }
`);

  // The two entry points take different argument tuples, so each is dispatched on its own rather than spread from
  // the union — that is what keeps the args type-checked against the ABI instead of erased to a widened tuple.
  const target = { address: cfg.executor, abi: EXECUTOR_ABI } as const;

  // Simulate against the operator even without a key: `account` only decides whose msg.sender the node assumes, and
  // running it as the real operator is what makes onlyOperator meaningful in a dry run.
  const as = { ...target, account: account ?? operator } as const;
  if (call.functionName === "executeTransit") {
    await publicClient.simulateContract({ ...as, functionName: "executeTransit", args: call.args });
  } else {
    await publicClient.simulateContract({ ...as, functionName: "executeRefund", args: call.args });
  }
  console.log("simulation succeeded — the call reverts nowhere.");

  if (!args.send) {
    console.log("\ndry run — nothing was sent. Re-run with --send to submit it.");
    return;
  }

  const wallet = createWalletClient({ account: account!, transport: http(cfg.evmRpc) });
  const hash =
    call.functionName === "executeTransit"
      ? await wallet.writeContract({ ...target, chain: null, functionName: "executeTransit", args: call.args })
      : await wallet.writeContract({ ...target, chain: null, functionName: "executeRefund", args: call.args });
  console.log(`\nsubmitted ${hash}\nwaiting for the receipt ...`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`  status  ${receipt.status}`);
  console.log(`  block   ${receipt.blockNumber}   gas used ${receipt.gasUsed}`);
  if (receipt.status !== "success") throw new Error("the transaction reverted on-chain");

  console.log(
    params
      ? `\ntransit complete on ${cfg.chain.label}. The forwarder re-burned toward domain ${cfg.routeDomain}; ` +
          `track that hop with Circle's attestation API for source domain ${cfg.transitDomain}.`
      : `\nrefund complete — the minted USDC went back to ${cfg.routeSender}.`,
  );
}
