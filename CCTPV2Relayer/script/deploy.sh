#!/usr/bin/env bash
#
# Deploy a NEW CCTPV2Relayer (impl + ERC1967 proxy) to ONE chain.
#
#   ./script/deploy.sh --chain base-testnet --private-key 0x...            # simulate (default)
#   ./script/deploy.sh --chain base-testnet --private-key 0x... --broadcast # actually send
#
# Runnable from anywhere; it cds to the foundry root itself.
#
# Simulation is the default on purpose: Deployment.s.sol mints a brand-new proxy every run and is
# not an upgrade. Look at the simulated output first, then re-run with --broadcast.
#
set -euo pipefail

# This file lives in script/, but forge and the broadcast/ tree are rooted one level up.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ── chain table ─────────────────────────────────────────────────────────────
# Each entry: <name> <rpc> <expected chain id>. The chain id is verified against the live RPC before
# anything is deployed — Deployment.s.sol picks its USDC/messenger/transmitter purely from block.chainid,
# so an RPC pointing at a different network than its name suggests would silently wire the wrong addresses.
CHAINS=(
  "ethereum-testnet   https://ethereum-sepolia-rpc.publicnode.com          11155111"
  "polygon-testnet    https://polygon-amoy-bor-rpc.publicnode.com          80002"
  "avalanche-testnet  https://api.avax-test.network/ext/bc/C/rpc           43113"
  "optimism-testnet   https://sepolia.optimism.io                          11155420"
  "base-testnet       https://sepolia.base.org                             84532"
  "arbitrum-testnet   https://sepolia-rollup.arbitrum.io/rpc               421614"
  "injective-testnet  https://rpc-evm-injective.testnet.cosmoslabs.kr      1439"
  "ethereum           https://ethereum-rpc.publicnode.com                  1"
  "polygon            https://polygon-bor-rpc.publicnode.com               137"
  "avalanche          https://api.avax.network/ext/bc/C/rpc                43114"
  "optimism           https://mainnet.optimism.io                          10"
  "base               https://mainnet.base.org                             8453"
  "arbitrum           https://arb1.arbitrum.io/rpc                         42161"
  "injective          https://rpc-evm-injective.mainnet.cosmoslabs.kr      1776"
)

MAINNETS="ethereum polygon avalanche optimism base arbitrum injective"

# ── args ────────────────────────────────────────────────────────────────────
CHAIN=""; PRIVATE_KEY="${PRIVATE_KEY:-}"; BROADCAST=0; VERIFY=0

usage() {
  cat <<EOF
Usage: script/deploy.sh --chain <name> [--private-key <key>] [--broadcast] [--verify]

  --chain        one of the names below
  --private-key  deployer key. Falls back to \$PRIVATE_KEY. Prompted if neither is set.
  --broadcast    actually send the transactions (default: simulate only)
  --verify       pass --verify to forge (needs ETHERSCAN_API_KEY)

Chains:
$(for e in "${CHAINS[@]}"; do set -- $e; printf "  %-18s %-52s chainid %s\n" "$1" "$2" "$3"; done)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain)       CHAIN="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
    --broadcast)   BROADCAST=1; shift ;;
    --verify)      VERIFY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$CHAIN" ]] || { echo "error: --chain is required" >&2; usage >&2; exit 1; }

RPC=""; WANT_ID=""
for e in "${CHAINS[@]}"; do
  set -- $e
  if [[ "$1" == "$CHAIN" ]]; then RPC="$2"; WANT_ID="$3"; fi
done
[[ -n "$RPC" ]] || { echo "error: unknown chain '$CHAIN'" >&2; usage >&2; exit 1; }

# ── key ─────────────────────────────────────────────────────────────────────
# Only required to broadcast; a simulation can run from a placeholder sender.
if [[ -z "$PRIVATE_KEY" && $BROADCAST -eq 1 ]]; then
  read -rsp "private key for $CHAIN: " PRIVATE_KEY; echo
fi
[[ -z "$PRIVATE_KEY" || "$PRIVATE_KEY" == 0x* ]] || PRIVATE_KEY="0x$PRIVATE_KEY"

# ── preflight ───────────────────────────────────────────────────────────────
echo "chain      : $CHAIN"
echo "rpc        : $RPC"

GOT_ID="$(cast chain-id --rpc-url "$RPC")" || { echo "error: RPC unreachable" >&2; exit 1; }
if [[ "$GOT_ID" != "$WANT_ID" ]]; then
  echo "error: chain id mismatch - RPC reports $GOT_ID, expected $WANT_ID for '$CHAIN'" >&2
  echo "       Deployment.s.sol wires USDC/messenger/transmitter from block.chainid; refusing." >&2
  exit 1
fi
echo "chain id   : $GOT_ID (verified)"

if [[ -n "$PRIVATE_KEY" ]]; then
  DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
  echo "deployer   : $DEPLOYER  (becomes the relayer owner)"
  echo "balance    : $(cast balance "$DEPLOYER" --rpc-url "$RPC" --ether)"
  SENDER_ARGS=(--private-key "$PRIVATE_KEY")

  # ── funding + stuck-nonce preflight ───────────────────────────────────────
  # Both matter BEFORE any signing. Deploying impl+proxy costs ~2.04M gas; if the balance only covers
  # the cheap proxy tx, the node rejects the impl (nonce N) but accepts the proxy (nonce N+1), which
  # then sits queued behind a gap. Every retry re-signs that identical tx and the node answers
  # "-32000 already known" — an error that says nothing about the actual cause.
  BAL_WEI="$(cast balance "$DEPLOYER" --rpc-url "$RPC")"
  GAS_PRICE="$(cast gas-price --rpc-url "$RPC")"
  EST_GAS=2100000   # ~1.80M impl + ~0.24M proxy, rounded up
  read -r NEED_OK NEED_ETH BAL_ETH <<<"$(awk -v b="$BAL_WEI" -v g="$GAS_PRICE" -v u="$EST_GAS" \
    'BEGIN { need = g * u; printf "%d %.6f %.6f", (b >= need), need/1e18, b/1e18 }')"
  if [[ "$NEED_OK" != "1" ]]; then
    echo >&2
    echo "error: insufficient balance for deployment" >&2
    echo "       have $BAL_ETH, need ~$NEED_ETH ($EST_GAS gas at $GAS_PRICE wei)" >&2
    echo "       Fund $DEPLOYER before retrying." >&2
    exit 1
  fi
  echo "est. cost  : ~$NEED_ETH  ($EST_GAS gas at $GAS_PRICE wei)"

  # A gap between latest and pending means earlier txs are stuck; broadcasting on top of it produces
  # "already known" rather than a new deployment.
  N_LATEST="$(cast nonce "$DEPLOYER" --rpc-url "$RPC")"
  N_PENDING="$(cast nonce "$DEPLOYER" --block pending --rpc-url "$RPC")"
  if [[ "$N_LATEST" != "$N_PENDING" ]]; then
    echo >&2
    echo "warning: $DEPLOYER has pending transactions (latest=$N_LATEST pending=$N_PENDING)." >&2
    echo "         Clear them first, or this run may fail with '-32000 already known':" >&2
    echo "           cast send $DEPLOYER --value 0 --nonce $N_LATEST --gas-price <2x current> \\" >&2
    echo "             --rpc-url $RPC --private-key <key>" >&2
  fi
else
  DEPLOYER="0x0000000000000000000000000000000000000001"
  echo "deployer   : (simulation, no key given)"
  SENDER_ARGS=(--sender "$DEPLOYER")
fi

FORGE_ARGS=(script script/Deployment.s.sol --rpc-url "$RPC" "${SENDER_ARGS[@]}")

if [[ $BROADCAST -eq 1 ]]; then
  FORGE_ARGS+=(--broadcast)
  [[ $VERIFY -eq 1 ]] && FORGE_ARGS+=(--verify)

  if [[ " $MAINNETS " == *" $CHAIN "* ]]; then
    echo
    echo "!! MAINNET BROADCAST: $CHAIN (chain id $GOT_ID)"
    echo "!! This spends real funds and deploys a new, separate relayer proxy."
    read -rp "Type the chain name to confirm: " CONFIRM
    [[ "$CONFIRM" == "$CHAIN" ]] || { echo "aborted." >&2; exit 1; }
  fi
  echo
  echo "broadcasting..."
else
  echo
  echo "SIMULATION only - re-run with --broadcast to send."
fi
echo

EXPECT_NEW_DEPLOYMENT=true forge "${FORGE_ARGS[@]}"

# ── result ──────────────────────────────────────────────────────────────────
# Read the addresses from the broadcast JSON, then PROVE which is which on-chain. forge's closing
# "##### <chain>" receipt summary pairs contract names with addresses positionally and can show them
# swapped; the JSON is right, but rather than trust either, confirm against the ERC-1967 slot.
if [[ $BROADCAST -eq 1 ]]; then
  RUN="broadcast/Deployment.s.sol/$GOT_ID/run-latest.json"
  if [[ -f "$RUN" ]]; then
    PROXY="$(jq -r '[.transactions[] | select(.contractName=="ERC1967Proxy")][-1].contractAddress' "$RUN")"
    IMPL="$(jq -r '[.transactions[] | select(.contractName=="CCTPV2Relayer")][-1].contractAddress' "$RUN")"
    IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

    # The proxy is the one whose ERC-1967 implementation slot is populated.
    # (Kept bash 3.2 compatible - macOS ships 3.2, so no ${var,,} or {1..64}.)
    lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
    SLOT_VAL="$(cast storage "$PROXY" "$IMPL_SLOT" --rpc-url "$RPC")"
    POINTS_TO="$(cast parse-bytes32-address "$SLOT_VAL")"
    if [[ "$(printf '%s' "$SLOT_VAL" | tr -d '0x')" == "" ]]; then
      echo >&2
      echo "error: $PROXY has an empty implementation slot - the two addresses are not what the" >&2
      echo "       broadcast file claims. Do NOT record either until this is resolved." >&2
      exit 1
    fi
    if [[ "$(lower "$POINTS_TO")" != "$(lower "$IMPL")" ]]; then
      echo >&2
      echo "error: proxy implementation slot points to $POINTS_TO, expected $IMPL" >&2
      exit 1
    fi

    echo
    echo "=========================================================="
    echo " $CHAIN"
    echo "   RELAYER_PROXY = $PROXY   <- record this"
    echo "   implementation= $IMPL"
    echo "   owner         = $(cast call "$PROXY" 'owner()(address)' --rpc-url "$RPC")"
    echo "   verified on-chain: proxy slot -> implementation"
    echo "=========================================================="
    echo "Ignore the addresses in forge's '##### $CHAIN' receipt block above - it mislabels them."
    echo "Next: record RELAYER_PROXY, then SetRouter.sol if the swap path is needed."
  fi
fi
