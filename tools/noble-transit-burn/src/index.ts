import { runBurn } from "./burn.js";
import { runCheck } from "./check.js";
import { runExecute } from "./execute.js";
import { runMint } from "./mint.js";

function printHelp(): void {
  console.log(`
noble-transit-burn — drive a Noble → <transit chain> → Injective CCTP transit end to end

The transit chain is Avalanche or Polygon (Fuji/Amoy on testnet), chosen with TRANSIT_CHAIN in .env. Each is an
independent deployment; DEPLOY_ENV (prod | dev) picks which one on that chain.

  check     read the configured deployment and report whether it is wired up — sends nothing
  burn      hop 1: the Noble depositForBurnWithCaller that feeds the TransitForwarder
  execute   hop 2: TransitExecutor.executeTransit on the transit chain, which mints and re-burns
  mint      hop 3: MessageTransmitterV2.receiveMessage on Injective, where the funds land

  npm run check
  npm run burn -- --usdc 1.5 --broadcast
  npm run execute -- --tx <nobleTxHash> --wait 900 --send
  npm run mint -- --tx <transitTxHash> --wait 900 --send

Each hop takes the tx hash the previous one printed. Note the attestation for hop 3 comes from Circle's **v2**
API (source domain 1 on Avalanche, 7 on Polygon), not the v1 endpoint hops 1–2 use — a v1 lookup reports a
transit-chain hash as not found.

Run any command with --help for its own options. Configuration lives in .env — see .env.example.
`);
}

const COMMANDS = "`check`, `burn`, `execute` or `mint`";

async function main(): Promise<void> {
  const [command, ...rest] = process.argv.slice(2);

  switch (command) {
    case "check":
      return runCheck(rest);
    case "burn":
      return runBurn(rest);
    case "execute":
      return runExecute(rest);
    case "mint":
      return runMint(rest);
    case "help":
    case "-h":
    case "--help":
    case undefined:
      printHelp();
      return;
    default:
      // A bare flag almost certainly means the command word was dropped, so say that rather than "unknown command".
      if (command.startsWith("-")) throw new Error(`missing command: expected ${COMMANDS} before ${command}`);
      throw new Error(`unknown command: ${command} (expected ${COMMANDS})`);
  }
}

main().catch((err: unknown) => {
  console.error(`\nerror: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
