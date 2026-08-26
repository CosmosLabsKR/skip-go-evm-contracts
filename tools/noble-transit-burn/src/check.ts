import { formatUnits, getAddress, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { COMMON_HELP, takeCommonArgs } from "./args.js";
import { loadConfig } from "./config.js";
import { EXPECTED_EXECUTOR_VERSION, evmClient, inspectDeployment, assertDeployment } from "./deployment.js";
import { predictForwarder } from "./predict.js";

/**
 * Read-only: does this .env describe a working transit, on the chain it claims?
 *
 * Every check here also runs inside `burn` and `execute`, where it guards a call that costs gas or moves funds.
 * Having it as its own command is what makes "is Polygon wired up?" answerable without burning anything — which
 * matters most right after a new chain is added, when the answer is genuinely unknown.
 */

const ERC20_ABI = [
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export function printCheckHelp(): void {
  console.log(`
check — read the configured deployment and report whether it is wired up

  npm run check
  npm run check -- --chain avalanche --env prod --recipient 0x<injective address>
${COMMON_HELP}

Sends nothing and needs no key. Reads TRANSIT_CHAIN / DEPLOY_ENV from .env, then asks the chain itself: which
chain id answers, what version the executor is, which factory and transmitter it uses, which CCTP domain that
transmitter reports, and where the configured route's forwarder would land.
`);
}

export async function runCheck(argv: string[]): Promise<void> {
  const { overrides, rest } = takeCommonArgs(argv);
  if (rest.some((a) => a === "-h" || a === "--help")) {
    printCheckHelp();
    return;
  }
  if (rest.length > 0) throw new Error(`unknown argument: ${rest[0]}`);

  const cfg = loadConfig({ overrides });
  const client = evmClient(cfg);

  const info = await inspectDeployment(cfg, client);

  console.log(`
Configured
  TRANSIT_CHAIN      ${cfg.chain.key} — ${cfg.chain.label} (expects chain id ${cfg.chain.chainId}, CCTP domain ${cfg.chain.cctpDomain})
  DEPLOY_ENV         ${cfg.deployEnv?.toUpperCase() ?? "— addresses given explicitly"}
  EVM_RPC            ${cfg.evmRpc}
  network tier       ${cfg.chain.testnet ? "testnet" : "mainnet"} — Noble ${cfg.nobleChainId}, attestations ${cfg.irisApi}

Live executor  ${cfg.executor}
  chain id           ${info.chainId} ${info.chainId === cfg.chain.chainId ? "✓" : "✗ WRONG CHAIN"}
  version            ${info.executorVersion} ${info.executorVersion === EXPECTED_EXECUTOR_VERSION ? "✓" : "✗ not the version this tool builds for"}
  factory            ${info.factory} ${info.factory.toLowerCase() === cfg.factory.toLowerCase() ? "✓" : `✗ TRANSIT_FACTORY is ${cfg.factory}`}
  transmitter        ${info.transmitter} (CCTP v${info.transmitterVersion}, localDomain ${info.transmitterDomain})
  usdc               ${info.usdc}
  operator           ${info.operator}${operatorNote(cfg.expectedOperator, info.operator)}`);

  console.log(`
Live factory   ${cfg.factory}
  version            ${info.factoryVersion}
  executor (frozen)  ${info.factoryExecutor} ${info.factoryExecutor.toLowerCase() === cfg.executor.toLowerCase() ? "✓" : "✗ not a pair with TRANSIT_EXECUTOR"}
  beacon             ${info.beacon}

Forwarder impl ${info.forwarder.address}  (every route on this factory is a proxy to it)
  version            ${info.forwarder.version}
  LOCAL_DOMAIN       ${info.forwarder.localDomain} ${info.forwarder.localDomain === cfg.transitDomain ? "✓" : `✗ transit domain is ${cfg.transitDomain}`}
  ALLOWED_DEST_DOM   ${info.forwarder.allowedDestinationDomain} ${info.forwarder.allowedDestinationDomain === cfg.routeDomain ? "✓ == ROUTE_DOMAIN" : `✗ ROUTE_DOMAIN is ${cfg.routeDomain}`}
  messenger          ${info.forwarder.messenger}
  executor           ${info.forwarder.executor}`);

  // Everything above is printed before it is judged, so a failing deployment still shows what it actually is.
  assertDeployment(cfg, info);

  // The route is optional: without a recipient there is no route to predict, but the wiring above is exactly what
  // `check` exists to report, and refusing to print any of it would make the command useless before a route
  // is chosen.
  if (cfg.routeMintRecipient) {
    // The deployment was already read above; passing it keeps `check` to one pass over the RPC.
    const prediction = await predictForwarder(cfg, client, info);
    const [symbol, balance] = await Promise.all([
      client.readContract({ address: info.usdc, abi: ERC20_ABI, functionName: "symbol" }).catch(() => "USDC"),
      client.readContract({
        address: info.usdc,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [prediction.forwarder],
      }),
    ]);

    console.log(`
Route (hop 2 — engraved in the forwarder's CREATE2 address)
  sender             ${cfg.routeSender}
  destinationDomain  ${cfg.routeDomain} (Injective)
  mintRecipient      ${cfg.routeMintRecipient}
  forwarder          ${prediction.forwarder}
  deployed           ${prediction.deployed ? "yes" : "no — the executor creates it on the first transit"}
  ${`${symbol} balance`.padEnd(18)} ${formatUnits(balance, 6)}${balance > 0n ? "  ⚠️ funds are sitting in the forwarder" : ""}
  onward caller      ${onwardCaller(cfg.onwardDestinationCaller)}`);
  } else {
    console.log(`
Route              none — set ROUTE_MINT_RECIPIENT (or pass --recipient) to predict the forwarder`);
  }

  const key = cfg.evmPrivateKey ? privateKeyToAccount(toHex(cfg.evmPrivateKey)).address : undefined;

  console.log(`
Keys
  EVM_PK             ${key ?? "not set — burn/check work, `execute --send` does not"}${
    key ? (key.toLowerCase() === info.operator.toLowerCase() ? " ✓ is the operator" : " ✗ NOT the operator (NotOperator)") : ""
  }
  NOBLE_PK           ${cfg.privateKey ? "set" : "not set — `burn --broadcast` does not"}
  INJECTIVE_PK       ${cfg.injectivePrivateKey ? "set" : cfg.evmPrivateKey ? "not set — `mint` falls back to EVM_PK" : "not set"}

deployment OK — chain, version and wiring all agree with .env.`);
}

/**
 * The onward destinationCaller, spelled out as the EVM address it will actually be compared against on Injective.
 *
 * Reported rather than enforced: it is the one value in the whole route that nothing can fix after hop 2 — it is
 * burned into the onward message, and only that address may ever submit it — so having it on screen before the
 * first burn is worth the two lines.
 */
function onwardCaller(raw: Hex | undefined): string {
  if (!raw) return "not set — `execute` will refuse (EmptyDestinationCaller)";
  const asAddress = `0x${raw.slice(26)}`;
  const evm = /^0x0{24}/.test(raw) ? ` → ${getAddress(asAddress)} on Injective` : " (not an EVM address)";
  return `${raw}${evm}`;
}

function operatorNote(expected: Address | undefined, live: Address): string {
  if (!expected) return "";
  return expected.toLowerCase() === live.toLowerCase() ? " ✓ as recorded" : ` (recorded as ${expected} — rotated)`;
}
