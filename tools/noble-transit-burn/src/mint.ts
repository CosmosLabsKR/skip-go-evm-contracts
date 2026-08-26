import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, formatUnits, http, isHex, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { COMMON_HELP, asCount, takeCommonArgs } from "./args.js";
import { waitForV2Attestation, type AttestedMessage } from "./attestation.js";
import { parseCctpV2Message, type ParsedV2Message } from "./cctpV2Message.js";
import { loadConfig, requireRoute, type Config } from "./config.js";
import { toEvmAddress } from "./cctpMessage.js";

/**
 * Hop 3: the transit chain → Injective.
 *
 * Injective's EVM runs the stock CCTP v2 contracts — MessageTransmitterV2 at Circle's usual address, reporting
 * localDomain() == 29 — so the last leg needs no contract of ours at all. It is `receiveMessage(message,
 * attestation)` called by whoever the onward burn pinned as destinationCaller, and the USDC mints to the
 * mintRecipient the forwarder committed to on the transit chain.
 *
 * Neither field can be changed after the fact: they were burned into the message on the transit-chain hop. So every
 * check here is a read of what the message already says, never a choice — the only question this command can
 * actually answer is whether the caller is allowed to submit it.
 */

const TRANSMITTER_ABI = [
  {
    type: "function",
    name: "receiveMessage",
    stateMutability: "nonpayable",
    inputs: [
      { name: "message", type: "bytes" },
      { name: "attestation", type: "bytes" },
    ],
    outputs: [{ type: "bool" }],
  },
  { type: "function", name: "localDomain", stateMutability: "view", inputs: [], outputs: [{ type: "uint32" }] },
  {
    type: "function",
    name: "usedNonces",
    stateMutability: "view",
    inputs: [{ name: "nonce", type: "bytes32" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

// Only used to name the minted token in the summary — the message itself carries the TokenMessenger as `recipient`,
// so the lookup needs no extra configuration.
const MESSENGER_ABI = [
  { type: "function", name: "localMinter", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;
const MINTER_ABI = [
  {
    type: "function",
    name: "getLocalToken",
    stateMutability: "view",
    inputs: [
      { name: "remoteDomain", type: "uint32" },
      { name: "remoteToken", type: "bytes32" },
    ],
    outputs: [{ type: "address" }],
  },
] as const;
const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
] as const;

interface Args {
  txHash?: string;
  message?: Hex;
  attestation?: Hex;
  file?: string;
  index?: number;
  sourceDomain?: number;
  send: boolean;
  waitSeconds: number;
  pollSeconds: number;
}

export function printMintHelp(): void {
  console.log(`
mint — run the third hop: MessageTransmitterV2.receiveMessage on Injective

  npm run mint -- --tx <transitTxHash>               fetch attestation, simulate, do not send
  npm run mint -- --tx <hash> --wait 900 --send      poll for the attestation, then submit
  npm run mint -- --message 0x.. --attestation 0x..  submit bytes you already have

Message source (pick one)
  --tx <hash>             the transit-chain tx that ran \`execute\`; message + attestation from Circle's v2 API
  --message <0x..>        raw message bytes, with --attestation
  --attestation <0x..>    raw attestation bytes, with --message
  --file <path>           JSON holding { message, attestation }

Options
  --send                  actually broadcast (default: simulate only)
  --wait <seconds>        how long to poll for the attestation (default: 0, one attempt)
  --poll <seconds>        interval between attempts (default: 15)
  --source <domain>       source domain of the tx (default: the TRANSIT_CHAIN domain — 1 avalanche, 7 polygon)
  --index <n>             pick the nth CCTP message in the tx, if it carried several

${COMMON_HELP}

The signing key is INJECTIVE_PK, falling back to EVM_PK. It has to be the destinationCaller the onward burn
pinned (ONWARD_DESTINATION_CALLER at the time \`execute\` ran) — nobody else can submit the message.
`);
}

function parseArgs(argv: string[]): Args {
  const args: Args = { send: false, waitSeconds: 0, pollSeconds: 15 };
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
      case "--source":
        args.sourceDomain = asCount("--source", next());
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
        printMintHelp();
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

async function resolveMessage(cfg: Config, args: Args, sourceDomain: number): Promise<AttestedMessage> {
  if (args.message || args.attestation) {
    if (!args.message || !args.attestation) throw new Error("--message and --attestation must be given together");
    return { message: args.message, attestation: args.attestation };
  }

  if (args.file) {
    const parsed = JSON.parse(readFileSync(args.file, "utf8")) as { message?: string; attestation?: string };
    if (!parsed.message || !parsed.attestation) throw new Error(`${args.file} needs both "message" and "attestation"`);
    return { message: asHex("message", parsed.message), attestation: asHex("attestation", parsed.attestation) };
  }

  if (!args.txHash) {
    throw new Error("no message source: pass --tx <transitTxHash>, --file, or --message/--attestation");
  }

  const found = await waitForV2Attestation(cfg, args.txHash, sourceDomain, {
    timeoutMs: args.waitSeconds * 1000,
    intervalMs: Math.max(1, args.pollSeconds) * 1000,
  });

  if (args.index !== undefined) {
    const picked = found[args.index];
    if (!picked) throw new Error(`--index ${args.index} out of range: the tx carried ${found.length} message(s)`);
    return picked;
  }

  // A transit tx emits exactly one onward message. More than one means the hash is not the one this command
  // expects, and guessing which to submit would spend an irreversible nonce on the wrong funds.
  if (found.length !== 1) {
    throw new Error(`that tx carried ${found.length} CCTP v2 messages — pick one with --index`);
  }
  return found[0]!;
}

/**
 * Everything MessageTransmitterV2 will check, checked first — plus the two things it will NOT check but that
 * decide whether the funds land where the transit intended.
 *
 * The transmitter is indifferent to who the mintRecipient is; it only enforces the attestation and the
 * destinationCaller. So a message whose mintRecipient drifted from ROUTE_MINT_RECIPIENT would still mint
 * successfully — to someone else, permanently. That mismatch is a hard stop here rather than a warning.
 */
function preflight(cfg: Config, parsed: ParsedV2Message, sourceDomain: number, localDomain: number, caller?: Address) {
  const routeMintRecipient = requireRoute(cfg);
  if (parsed.version !== 1) {
    throw new Error(`message version is ${parsed.version}, expected 1 (CCTP v2)`);
  }
  if (parsed.sourceDomain !== sourceDomain) {
    throw new Error(`message sourceDomain is ${parsed.sourceDomain}, expected ${sourceDomain} — is this the right tx?`);
  }
  if (parsed.destinationDomain !== localDomain) {
    throw new Error(
      `message is addressed to domain ${parsed.destinationDomain}, but INJECTIVE_RPC points at a chain whose ` +
        `MessageTransmitter reports localDomain ${localDomain}. Submitting it here is impossible.`,
    );
  }
  if (parsed.destinationDomain !== cfg.routeDomain) {
    throw new Error(`message destinationDomain is ${parsed.destinationDomain}, but ROUTE_DOMAIN is ${cfg.routeDomain}`);
  }
  if (parsed.mintRecipient.toLowerCase() !== routeMintRecipient.toLowerCase()) {
    throw new Error(
      `message mints to ${parsed.mintRecipient}, not the configured ROUTE_MINT_RECIPIENT ` +
        `${routeMintRecipient}. The recipient is fixed in the burned message and cannot be redirected.`,
    );
  }

  // destinationCaller is the one field that decides whether this command can do anything at all. Zero means open
  // to anyone; anything else is a single address, and no key but that one will ever satisfy it.
  const pinned = BigInt(parsed.destinationCaller) === 0n ? undefined : toEvmAddress(parsed.destinationCaller);
  if (pinned && caller && pinned.toLowerCase() !== caller.toLowerCase()) {
    throw new Error(
      `this message may only be submitted by ${pinned}, but the configured key is ${caller}. ` +
        `That address was fixed as destinationCaller when \`execute\` ran and cannot be changed now.`,
    );
  }
  return pinned;
}

export async function runMint(argv: string[]): Promise<void> {
  const { overrides, rest } = takeCommonArgs(argv);
  const args = parseArgs(rest);
  const cfg = loadConfig({ overrides });
  const sourceDomain = args.sourceDomain ?? cfg.transitDomain;

  // The operator key is the usual fallback: on a single-operator deployment the same EOA tends to be pinned as the
  // onward destinationCaller, and requiring it to be duplicated into a second variable buys nothing.
  const key = cfg.injectivePrivateKey ?? cfg.evmPrivateKey;
  const account = key ? privateKeyToAccount(toHex(key)) : undefined;
  if (args.send && !account) throw new Error("--send requires INJECTIVE_PK (or EVM_PK) for the destinationCaller");

  // The one leg that does NOT follow the transit chain's network tier — and localDomain() cannot catch it, since
  // Injective's testnet reports domain 29 just as its mainnet does.
  if (cfg.chain.testnet && !process.env.INJECTIVE_RPC && !overrides.INJECTIVE_RPC) {
    console.warn(
      `warning: ${cfg.chain.label} is a testnet, but INJECTIVE_RPC is unset and defaults to MAINNET Injective ` +
        `(${cfg.injectiveRpc}). Pass --injective-rpc <url> for the testnet endpoint.`,
    );
  }

  const publicClient = createPublicClient({ transport: http(cfg.injectiveRpc) });
  const transmitter = cfg.injectiveMessageTransmitter;

  // Read the domain from the chain rather than trusting INJECTIVE_RPC to be what it claims: an RPC pointed at the
  // wrong network is the one mistake here that a correct-looking message would sail straight past.
  const localDomain = await publicClient.readContract({
    address: transmitter,
    abi: TRANSMITTER_ABI,
    functionName: "localDomain",
  });

  const attested = await resolveMessage(cfg, args, sourceDomain);
  const parsed = parseCctpV2Message(attested.message);
  const pinnedCaller = preflight(cfg, parsed, sourceDomain, localDomain, account?.address);

  // The nonce is spent on the destination chain, so a replay does not fail quietly — it reverts after gas. Reading
  // it first also turns "did my earlier run land?" into an answer instead of a second attempt.
  const used = await publicClient.readContract({
    address: transmitter,
    abi: TRANSMITTER_ABI,
    functionName: "usedNonces",
    args: [parsed.nonce],
  });
  if (used !== 0n) {
    console.log(`\nnonce ${parsed.nonce} is already used — this message was minted. Nothing to do.`);
    return;
  }

  const recipient = toEvmAddress(parsed.mintRecipient);
  const token = await localToken(publicClient, parsed);

  console.log(`
Message (CCTP v2)
  domain             ${parsed.sourceDomain} (${cfg.chain.label})  →  ${parsed.destinationDomain} (Injective)
  nonce              ${parsed.nonce}
  finality           ${parsed.minFinalityThreshold} requested / ${parsed.finalityThresholdExecuted} executed

Mint
  chain              ${cfg.injectiveRpc} (localDomain ${localDomain})
  transmitter        ${transmitter}
  recipient          ${recipient}
  amount             ${formatUnits(parsed.amount - parsed.feeExecuted, 6)} ${token?.symbol ?? "USDC"}${
    parsed.feeExecuted > 0n ? `  (${formatUnits(parsed.amount, 6)} burned − ${formatUnits(parsed.feeExecuted, 6)} fee)` : ""
  }
  token              ${token?.address ?? "unknown"}
  destinationCaller  ${pinnedCaller ?? "0x0 — open to anyone"}
  submitting as      ${account?.address ?? "— no key set (simulation only)"}
`);

  // Simulate as the pinned caller even without a key: that is the only account the transmitter will accept, so
  // running as anyone else would prove nothing.
  await publicClient.simulateContract({
    address: transmitter,
    abi: TRANSMITTER_ABI,
    functionName: "receiveMessage",
    args: [attested.message, attested.attestation],
    account: account ?? pinnedCaller ?? undefined,
  });
  console.log("simulation succeeded — the mint reverts nowhere.");

  if (!args.send) {
    console.log("\ndry run — nothing was sent. Re-run with --send to submit it.");
    return;
  }

  const before = token ? await balanceOf(publicClient, token.address, recipient) : undefined;
  const wallet = createWalletClient({ account: account!, transport: http(cfg.injectiveRpc) });
  const hash = await wallet.writeContract({
    address: transmitter,
    abi: TRANSMITTER_ABI,
    chain: null,
    functionName: "receiveMessage",
    args: [attested.message, attested.attestation],
  });
  console.log(`\nsubmitted ${hash}\nwaiting for the receipt ...`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`  status  ${receipt.status}`);
  console.log(`  block   ${receipt.blockNumber}   gas used ${receipt.gasUsed}`);
  if (receipt.status !== "success") throw new Error("the transaction reverted on-chain");

  if (token && before !== undefined) {
    const after = await balanceOf(publicClient, token.address, recipient);
    console.log(`  minted  ${formatUnits(after - before, 6)} ${token.symbol} to ${recipient}`);
  }
  console.log(`\ntransit complete — the funds have arrived on Injective.`);
}

type PublicClient = ReturnType<typeof createPublicClient>;

function balanceOf(client: PublicClient, token: Address, holder: Address): Promise<bigint> {
  return client.readContract({ address: token, abi: ERC20_ABI, functionName: "balanceOf", args: [holder] });
}

/**
 * The local token the burn maps to, resolved from the message alone: its `recipient` is the destination
 * TokenMessenger, whose minter knows what (sourceDomain, burnToken) becomes locally.
 *
 * Best effort — this is display only, and a chain that lays its contracts out differently should not stop a mint
 * that the transmitter itself is perfectly happy with.
 */
async function localToken(
  client: PublicClient,
  parsed: ParsedV2Message,
): Promise<{ address: Address; symbol: string } | undefined> {
  try {
    const messenger = toEvmAddress(parsed.recipient);
    const minter = await client.readContract({ address: messenger, abi: MESSENGER_ABI, functionName: "localMinter" });
    const address = await client.readContract({
      address: minter,
      abi: MINTER_ABI,
      functionName: "getLocalToken",
      args: [parsed.sourceDomain, parsed.burnToken],
    });
    if (BigInt(address) === 0n) return undefined;
    const symbol = await client.readContract({ address, abi: ERC20_ABI, functionName: "symbol" });
    return { address, symbol };
  } catch {
    return undefined;
  }
}
