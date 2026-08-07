#!/usr/bin/env bash
#
# Read the wiring of a deployed CCTPV2Relayer: owner, version, usdc, messenger, transmitter, swapRouter.
#
#   ./script/inspect.sh 0xPROXY --chain ethereum-testnet
#   ./script/inspect.sh 0xPROXY --chain base --json
#
# Read-only: no key, no broadcast, nothing signed. Runnable from anywhere; it cds to the foundry root itself.
#
# The three CCTP addresses are also compared against Config.sol's constants for the target chain — the same
# check Upgrade.sol makes on-chain. A mismatch means the address is not this chain's relayer (wrong chain,
# wrong contract, or a deployment wired from a stale config), which is exactly what you want to learn
# BEFORE handing the address to deploy.sh/upgrade.sh.
set -euo pipefail

# This file lives in script/, but Config.sol and forge are rooted relative to the package root.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ── chain table ─────────────────────────────────────────────────────────────
# Kept identical to deploy.sh/upgrade.sh, plus the Config.sol suffix used for the expected-address
# lookup: <name> <rpc> <expected chain id> <config suffix>.
CHAINS=(
  "ethereum-testnet   https://ethereum-sepolia-rpc.publicnode.com          11155111  SEPOLIA"
  "polygon-testnet    https://polygon-amoy-bor-rpc.publicnode.com          80002     POLYGON_AMOY"
  "avalanche-testnet  https://api.avax-test.network/ext/bc/C/rpc           43113     AVALANCHE_FUJI"
  "optimism-testnet   https://sepolia.optimism.io                          11155420  OP_SEPOLIA"
  "base-testnet       https://sepolia.base.org                             84532     BASE_SEPOLIA"
  "arbitrum-testnet   https://sepolia-rollup.arbitrum.io/rpc               421614    ARBITRUM_SEPOLIA"
  "injective-testnet  https://rpc-evm-injective.testnet.cosmoslabs.kr      1439      INJECTIVE_TESTNET"
  "ethereum           https://ethereum-rpc.publicnode.com                  1         MAINNET"
  "polygon            https://polygon-bor-rpc.publicnode.com               137       POLYGON"
  "avalanche          https://api.avax.network/ext/bc/C/rpc                43114     AVALANCHE"
  "optimism           https://mainnet.optimism.io                          10        OP"
  "base               https://mainnet.base.org                             8453      BASE"
  "arbitrum           https://arb1.arbitrum.io/rpc                         42161     ARBITRUM"
  "injective          https://rpc-evm-injective.mainnet.cosmoslabs.kr      1776      INJECTIVE"
)

IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

# ── args ────────────────────────────────────────────────────────────────────
TARGET="${RELAYER_PROXY:-}"; CHAIN=""; RPC_OVERRIDE=""; JSON=0

usage() {
  cat <<EOF
Usage: script/inspect.sh <contract-address> --chain <name> [--rpc-url <url>] [--json]

  <contract-address>  the CCTPV2Relayer (proxy) to read. Falls back to \$RELAYER_PROXY.
  --chain             one of the names below
  --rpc-url           use this RPC instead of the table's (still checked against the chain id)
  --json              emit one JSON object instead of the human-readable block

Chains:
$(for e in "${CHAINS[@]}"; do set -- $e; printf "  %-18s %-52s chainid %s\n" "$1" "$2" "$3"; done)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain)   CHAIN="${2:-}"; shift 2 ;;
    --rpc-url) RPC_OVERRIDE="${2:-}"; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    0x*)       TARGET="$1"; shift ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "error: contract address is required" >&2; usage >&2; exit 1; }
[[ -n "$CHAIN"  ]] || { echo "error: --chain is required" >&2; usage >&2; exit 1; }

RPC=""; WANT_ID=""; SUFFIX=""
for e in "${CHAINS[@]}"; do
  set -- $e
  if [[ "$1" == "$CHAIN" ]]; then RPC="$2"; WANT_ID="$3"; SUFFIX="$4"; fi
done
[[ -n "$RPC" ]] || { echo "error: unknown chain '$CHAIN'" >&2; usage >&2; exit 1; }
[[ -n "$RPC_OVERRIDE" ]] && RPC="$RPC_OVERRIDE"

# Normalise to a checksummed 20-byte address, which also rejects malformed input up front.
TARGET="$(cast to-check-sum-address "$TARGET")" || { echo "error: '$TARGET' is not an address" >&2; exit 1; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── preflight ───────────────────────────────────────────────────────────────
GOT_ID="$(cast chain-id --rpc-url "$RPC")" || { echo "error: RPC unreachable" >&2; exit 1; }
if [[ "$GOT_ID" != "$WANT_ID" ]]; then
  echo "error: chain id mismatch - RPC reports $GOT_ID, expected $WANT_ID for '$CHAIN'" >&2
  echo "       The Config comparison below would use the wrong chain's addresses; refusing." >&2
  exit 1
fi

# An EOA or a wrong address answers every call with 0x, which decodes to a plausible-looking zero
# address rather than an error. Rule it out first.
[[ "$(cast code "$TARGET" --rpc-url "$RPC")" != "0x" ]] || {
  echo "error: no code at $TARGET on $CHAIN" >&2; exit 1; }

# ── reads ───────────────────────────────────────────────────────────────────
# Every getter is probed rather than assumed: this script's job is to identify an unknown address, and
# on a non-relayer contract each of these reverts. `none` is an answer, not a failure.
read_addr() { cast call "$TARGET" "$1" --rpc-url "$RPC" 2>/dev/null || echo "n/a"; }

OWNER="$(read_addr 'owner()(address)')"
USDC="$(read_addr 'usdc()(address)')"
MESSENGER="$(read_addr 'messenger()(address)')"
TRANSMITTER="$(read_addr 'transmitter()(address)')"
ROUTER="$(read_addr 'swapRouter()(address)')"

# version() was added after the first implementations shipped, so its absence is expected on older
# proxies, not an error.
VERSION="$(cast call "$TARGET" 'version()(uint256)' --rpc-url "$RPC" 2>/dev/null || echo "n/a")"

# Which implementation is live. Empty slot => not a UUPS/ERC-1967 proxy (possibly a bare impl).
IMPL="$(cast parse-bytes32-address "$(cast storage "$TARGET" "$IMPL_SLOT" --rpc-url "$RPC")" 2>/dev/null || echo "n/a")"
[[ "$(lower "$IMPL")" == "0x0000000000000000000000000000000000000000" ]] && IMPL="none (not an ERC-1967 proxy)"

# ── expected wiring, straight from Config.sol ───────────────────────────────
# Read from the source rather than duplicated here, so this script cannot drift from what
# Deployment.s.sol/Upgrade.sol actually use.
config_addr() {
  grep -oE "^address constant $1_$SUFFIX = 0x[0-9a-fA-F]{40}" script/Config.sol | grep -oE '0x[0-9a-fA-F]{40}' || true
}
EXP_USDC="$(config_addr USDC)"
EXP_MESSENGER="$(config_addr MESSENGER)"
EXP_TRANSMITTER="$(config_addr TRANSMITTER)"

# ok / MISMATCH / (unknown) — the last when Config has no constant for this chain, so silence would lie.
verdict() {
  local got="$1" want="$2"
  if [[ -z "$want" ]]; then printf '(not in Config)'
  elif [[ "$(lower "$got")" == "$(lower "$want")" ]]; then printf 'ok'
  else printf 'MISMATCH (expected %s)' "$want"
  fi
}
V_USDC="$(verdict "$USDC" "$EXP_USDC")"
V_MESSENGER="$(verdict "$MESSENGER" "$EXP_MESSENGER")"
V_TRANSMITTER="$(verdict "$TRANSMITTER" "$EXP_TRANSMITTER")"

# ── output ──────────────────────────────────────────────────────────────────
if [[ $JSON -eq 1 ]]; then
  cat <<EOF
{
  "chain": "$CHAIN",
  "chainId": $GOT_ID,
  "address": "$TARGET",
  "implementation": "$IMPL",
  "owner": "$OWNER",
  "version": "$VERSION",
  "usdc": "$USDC",
  "messenger": "$MESSENGER",
  "transmitter": "$TRANSMITTER",
  "swapRouter": "$ROUTER",
  "configMatch": {
    "usdc": "$V_USDC",
    "messenger": "$V_MESSENGER",
    "transmitter": "$V_TRANSMITTER"
  }
}
EOF
else
  echo "=========================================================="
  echo " $CHAIN (chain id $GOT_ID, verified)"
  echo "   address       = $TARGET"
  echo "   implementation= $IMPL"
  echo "----------------------------------------------------------"
  printf "   owner         = %s\n" "$OWNER"
  printf "   version       = %s\n" "$VERSION"
  printf "   usdc          = %-42s %s\n" "$USDC" "$V_USDC"
  printf "   messenger     = %-42s %s\n" "$MESSENGER" "$V_MESSENGER"
  printf "   transmitter   = %-42s %s\n" "$TRANSMITTER" "$V_TRANSMITTER"
  printf "   swapRouter    = %s\n" "$ROUTER"
  echo "=========================================================="
fi

# A mismatch is the whole reason to run this before an upgrade, so it must be visible to a caller that
# only checks the exit status.
case "$V_USDC$V_MESSENGER$V_TRANSMITTER" in
  *MISMATCH*)
    echo >&2
    echo "error: this contract is not wired to $CHAIN's CCTP addresses - do NOT treat it as this chain's relayer." >&2
    exit 1 ;;
esac
