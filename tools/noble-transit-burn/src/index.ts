import { runBurn } from "./burn.js";
import { runExecute } from "./execute.js";

function printHelp(): void {
  console.log(`
noble-transit-burn — drive a Noble → Avalanche → Injective CCTP transit end to end

  burn      hop 1: the Noble depositForBurnWithCaller that feeds the TransitForwarder
  execute   hop 2: TransitExecutor.executeTransit on Avalanche, which mints and re-burns

  npm run burn -- --usdc 1.5 --broadcast
  npm run execute -- --tx <nobleTxHash> --wait 900 --send

Run either with --help for its own options. Configuration lives in .env — see .env.example.
`);
}

async function main(): Promise<void> {
  const [command, ...rest] = process.argv.slice(2);

  switch (command) {
    case "burn":
      return runBurn(rest);
    case "execute":
      return runExecute(rest);
    case "help":
    case "-h":
    case "--help":
    case undefined:
      printHelp();
      return;
    default:
      // A bare flag almost certainly means the command word was dropped, so say that rather than "unknown command".
      if (command.startsWith("-")) throw new Error(`missing command: expected \`burn\` or \`execute\` before ${command}`);
      throw new Error(`unknown command: ${command} (expected \`burn\` or \`execute\`)`);
  }
}

main().catch((err: unknown) => {
  console.error(`\nerror: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
