import { isAddress, isHex } from "viem";

/**
 * Flags every command shares, and the .env keys they stand in for.
 *
 * A transit is described by a handful of values — which chain, which deployment, and the three that make up the
 * route — and they are exactly the values an operator changes between runs. Requiring an .env edit for each of
 * them makes the file the source of truth for something transient, which is how a stale ROUTE_MINT_RECIPIENT ends
 * up committed to a burn. A flag is visible in the command that used it and in shell history afterwards.
 *
 * Precedence is flag > .env > built-in default, and it is uniform: nothing here is special-cased.
 */
const FLAGS: Record<string, string> = {
  "--chain": "TRANSIT_CHAIN",
  "--env": "DEPLOY_ENV",
  "--rpc": "EVM_RPC",
  "--executor": "TRANSIT_EXECUTOR",
  "--factory": "TRANSIT_FACTORY",
  "--recipient": "ROUTE_MINT_RECIPIENT",
  "--route-sender": "ROUTE_SENDER",
  "--route-domain": "ROUTE_DOMAIN",
  "--onward-caller": "ONWARD_DESTINATION_CALLER",
  "--max-fee": "MAX_FEE",
  "--finality": "MIN_FINALITY_THRESHOLD",
  "--injective-rpc": "INJECTIVE_RPC",
  "--noble-rpc": "NOBLE_RPC",
  "--iris": "IRIS_API",
};

export const COMMON_HELP = `
Common options (override .env; a plain 0x address is accepted wherever 32 bytes are wanted)
  --chain <name>          transit chain: avalanche | polygon | fuji | amoy
  --env <prod|dev>        which deployment on that chain
  --recipient <addr>      ROUTE_MINT_RECIPIENT — the final recipient on Injective
  --route-sender <addr>   ROUTE_SENDER — route key and refund recipient
  --route-domain <n>      ROUTE_DOMAIN (29 = Injective)
  --onward-caller <addr>  ONWARD_DESTINATION_CALLER — who may mint on Injective
  --max-fee <uusdc>       MAX_FEE — Circle's destination-side cap
  --finality <1000|2000>  MIN_FINALITY_THRESHOLD
  --rpc <url>             EVM_RPC          --executor <addr>  TRANSIT_EXECUTOR
  --noble-rpc <url>       NOBLE_RPC        --factory <addr>   TRANSIT_FACTORY
  --injective-rpc <url>   INJECTIVE_RPC    --iris <url>       IRIS_API`;

export type Overrides = Record<string, string>;

/**
 * Pull the shared flags out of argv, leaving the command's own arguments untouched.
 *
 * Unknown flags are left in `rest` rather than rejected here — the per-command parser owns that error, so a typo
 * is reported once, by the parser that knows what the command actually accepts.
 */
export function takeCommonArgs(argv: string[]): { overrides: Overrides; rest: string[] } {
  const overrides: Overrides = {};
  const rest: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    const key = FLAGS[a];
    if (!key) {
      rest.push(a);
      continue;
    }
    const value = argv[++i];
    if (value === undefined) throw new Error(`${a} needs a value`);
    overrides[key] = value;
  }

  return { overrides, rest };
}

/**
 * A non-negative integer option, refused rather than coerced.
 *
 * `Number("abc")` is NaN, and NaN poisons the poll loops quietly: `Date.now() >= NaN` is always false, so
 * `--wait abc` never times out, and `setTimeout(r, NaN)` fires immediately, so `--poll abc` hammers Circle's API
 * with no delay and no exit. A typo has to stop the command, not change what it does.
 */
export function asCount(label: string, raw: string): number {
  const v = Number(raw);
  if (!Number.isInteger(v) || v < 0) throw new Error(`${label} must be a non-negative whole number: ${raw}`);
  return v;
}

/**
 * CCTP takes recipients and callers as 32 bytes; people have 20-byte addresses.
 *
 * Left-padding is the encoding CCTP itself uses for an EVM recipient, so accepting the short form removes a manual
 * step whose only failure mode — padding on the wrong side — silently names a different account. Anything already
 * 32 bytes is passed through untouched, since non-EVM destinations legitimately use all of them.
 */
export function toBytes32(label: string, raw: string): string {
  const v = raw.trim();
  if (isAddress(v)) return `0x${"0".repeat(24)}${v.slice(2)}`.toLowerCase();
  if (isHex(v) && v.length === 66) return v.toLowerCase();
  throw new Error(`${label} must be an EVM address or 32 bytes of hex (0x + 64 chars): ${raw}`);
}
