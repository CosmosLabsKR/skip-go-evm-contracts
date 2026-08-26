import { writeFileSync } from "node:fs";
import { DirectSecp256k1Wallet, Registry } from "@cosmjs/proto-signing";
import { GasPrice, SigningStargateClient, defaultRegistryTypes } from "@cosmjs/stargate";
import { fromHex, toBase64 } from "@cosmjs/encoding";
import { formatUnits, pad } from "viem";

import { COMMON_HELP, takeCommonArgs } from "./args.js";
import { loadConfig, requireAmount, type Config } from "./config.js";
import { predictForwarder, type Prediction } from "./predict.js";
import { MSG_DEPOSIT_FOR_BURN_WITH_CALLER, MsgDepositForBurnWithCaller, decodeBurnNonce } from "./proto.js";

interface Args {
  amount?: bigint;
  broadcast: boolean;
  from?: string;
  out: string;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { broadcast: false, out: "tx.json" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    switch (a) {
      case "--amount":
        args.amount = BigInt(next());
        break;
      case "--usdc":
        // Convenience: whole USDC → uusdc. Rejects sub-micro precision rather than truncating it.
        args.amount = parseUsdc(next());
        break;
      case "--from":
        args.from = next();
        break;
      case "--broadcast":
        args.broadcast = true;
        break;
      case "--out":
        args.out = next();
        break;
      case "-h":
      case "--help":
        printBurnHelp();
        process.exit(0);
      default:
        throw new Error(`unknown argument: ${a}`);
    }
  }
  return args;
}

function parseUsdc(v: string): bigint {
  const m = /^(\d+)(?:\.(\d{1,6}))?$/.exec(v.trim());
  if (!m) throw new Error(`--usdc must be a decimal with at most 6 places: ${v}`);
  return BigInt(m[1]!) * 1_000_000n + BigInt((m[2] ?? "").padEnd(6, "0"));
}

export function printBurnHelp(): void {
  console.log(`
burn — build the Noble CCTP v1 burn that feeds a TransitForwarder on the transit chain

  npm run burn -- --usdc 1.5              build and print the tx (writes tx.json), no broadcast
  npm run burn -- --amount 1500000        same, amount in uusdc
  npm run burn -- --usdc 1.5 --broadcast  sign with NOBLE_PK and send it

Options
  --amount <uusdc>   burn amount in base units (6 decimals)
  --usdc <decimal>   burn amount in whole USDC
  --from <noble1..>  sender, when no NOBLE_PK is set (build-only mode)
  --broadcast        actually sign and send (requires NOBLE_PK)
  --out <path>       where to write the unsigned tx JSON (default: tx.json)
${COMMON_HELP}

Configuration lives in .env — see .env.example. Any of it can be overridden per run with the flags above.
`);
}

/** CCTP takes recipients and callers as 32 bytes, left-padded. */
function bytes32(hex: string): Uint8Array {
  return fromHex(hex.replace(/^0x/, ""));
}

async function resolveSender(cfg: Config, args: Args): Promise<{ address: string; wallet?: DirectSecp256k1Wallet }> {
  if (cfg.privateKey) {
    // Raw secp256k1 key, no HD derivation — the key IS the account, so there is no coin-type/path to get wrong.
    const wallet = await DirectSecp256k1Wallet.fromKey(cfg.privateKey, "noble");
    const [account] = await wallet.getAccounts();
    return { address: account!.address, wallet };
  }
  const address = args.from ?? process.env.NOBLE_SENDER;
  if (!address) throw new Error("no sender: set NOBLE_PK, or pass --from noble1... for build-only mode");
  if (!address.startsWith("noble1")) throw new Error(`--from must be a noble bech32 address: ${address}`);
  return { address };
}

function summarize(cfg: Config, p: Prediction, sender: string, amount: bigint): void {
  console.log(`
Route (hop 2 — engraved in the forwarder's address)
  sender             ${cfg.routeSender}
  destinationDomain  ${cfg.routeDomain}
  mintRecipient      ${cfg.routeMintRecipient}

Transit forwarder (${cfg.chain.label}, CCTP domain ${cfg.transitDomain}${cfg.deployEnv ? `, ${cfg.deployEnv.toUpperCase()}` : ""})
  predicted address  ${p.forwarder}
  already deployed   ${p.deployed ? "yes" : "no — the executor will create it on this message"}

Noble burn (hop 1)
  from               ${sender}
  amount             ${formatUnits(amount, 6)} USDC (${amount} ${cfg.burnToken})
  destinationDomain  ${cfg.transitDomain}
  mintRecipient      ${p.mintRecipient}
  destinationCaller  ${cfg.executor} (TransitExecutor)
`);
}

export async function runBurn(argv: string[]): Promise<void> {
  const { overrides, rest } = takeCommonArgs(argv);
  const args = parseArgs(rest);
  const cfg = loadConfig({ amount: args.amount, overrides });
  const amount = requireAmount(cfg);

  const { address: sender, wallet } = await resolveSender(cfg, args);
  const prediction = await predictForwarder(cfg);

  const msg = {
    typeUrl: MSG_DEPOSIT_FOR_BURN_WITH_CALLER,
    value: MsgDepositForBurnWithCaller.fromPartial({
      from: sender,
      amount: amount.toString(),
      destinationDomain: cfg.transitDomain,
      mintRecipient: bytes32(prediction.mintRecipient),
      burnToken: cfg.burnToken,
      // Pinning the executor as destinationCaller is what makes the transit atomic: nobody else can call
      // receiveMessage for this message, so the mint and the onward burn can only happen together.
      destinationCaller: bytes32(pad(cfg.executor, { size: 32 })),
    }),
  };

  summarize(cfg, prediction, sender, amount);

  // Unsigned tx body, in the shape `nobled tx sign` / `nobled tx broadcast` accept — so the burn can be signed by a
  // key this tool never sees (ledger, multisig, ops runbook).
  const unsigned = {
    body: {
      messages: [
        {
          "@type": MSG_DEPOSIT_FOR_BURN_WITH_CALLER,
          from: msg.value.from,
          amount: msg.value.amount,
          destination_domain: msg.value.destinationDomain,
          mint_recipient: toBase64(msg.value.mintRecipient),
          burn_token: msg.value.burnToken,
          destination_caller: toBase64(msg.value.destinationCaller),
        },
      ],
      memo: "",
      timeout_height: "0",
      extension_options: [],
      non_critical_extension_options: [],
    },
    auth_info: { signer_infos: [], fee: { amount: [], gas_limit: String(cfg.gasLimit), payer: "", granter: "" } },
    signatures: [],
  };
  writeFileSync(args.out, `${JSON.stringify(unsigned, null, 2)}\n`);
  console.log(`unsigned tx written to ${args.out}`);

  if (!args.broadcast) {
    console.log("\ndry run — nothing was sent. Re-run with --broadcast to submit it.");
    return;
  }
  if (!wallet) throw new Error("--broadcast requires NOBLE_PK");

  const registry = new Registry(defaultRegistryTypes);
  registry.register(MSG_DEPOSIT_FOR_BURN_WITH_CALLER, MsgDepositForBurnWithCaller);
  const client = await SigningStargateClient.connectWithSigner(cfg.nobleRpc, wallet, {
    registry,
    gasPrice: GasPrice.fromString(cfg.gasPrice),
  });

  console.log(`broadcasting to ${cfg.nobleChainId} via ${cfg.nobleRpc} ...`);
  const res = await client.signAndBroadcast(sender, [msg], "auto");
  if (res.code !== 0) throw new Error(`tx failed (code ${res.code}): ${res.rawLog}`);

  console.log(`  txhash  ${res.transactionHash}`);
  console.log(`  height  ${res.height}   gas used ${res.gasUsed}`);

  const nonce = res.msgResponses[0] ? decodeBurnNonce(res.msgResponses[0].value) : undefined;
  if (nonce !== undefined) console.log(`  nonce   ${nonce}`);

  console.log(
    `\nnext: wait for Circle's attestation, then run the second hop\n` +
      `  npm run execute -- --tx ${res.transactionHash} --wait 900`,
  );
  client.disconnect();
}
