#!/usr/bin/env bash
#
# Upgrade an EXISTING CCTPV2Relayer proxy to the current source (UUPS). The proxy address is unchanged.
#
#   ./script/upgrade.sh 0xPROXY --chain ethereum-testnet                          # simulate (default)
#   ./script/upgrade.sh 0xPROXY --chain ethereum-testnet --private-key 0x...      # simulate as the signer
#   ./script/upgrade.sh 0xPROXY --chain ethereum-testnet --private-key 0x... --broadcast
#
# Runnable from anywhere; it cds to the foundry root itself.
#
# Simulation is the default on purpose: an upgrade swaps the code every caller of this proxy runs
# against. Read the simulated before/after output first, then re-run with --broadcast.
#
set -euo pipefail

# This file lives in script/, but forge and the broadcast/ tree are rooted one level up.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ── chain table ─────────────────────────────────────────────────────────────
# Kept identical to deploy.sh: <name> <rpc> <expected chain id>. The chain id is verified against the
# live RPC before anything is signed — Upgrade.sol proves the target is THIS chain's relayer by matching
# its usdc/messenger/transmitter against the Config values for block.chainid, so an RPC pointing at a
# different network than its name suggests would compare against the wrong table.
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

IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

# ── args ────────────────────────────────────────────────────────────────────
PROXY="${RELAYER_PROXY:-}"; CHAIN=""; PRIVATE_KEY="${PRIVATE_KEY:-}"; BROADCAST=0; VERIFY=0

usage() {
  cat <<EOF
Usage: script/upgrade.sh <proxy-address> --chain <name> [--private-key <key>] [--broadcast] [--verify]

  <proxy-address>  the CCTPV2Relayer proxy to upgrade. Falls back to \$RELAYER_PROXY.
  --chain          one of the names below
  --private-key    key of the relayer OWNER (_authorizeUpgrade is onlyOwner).
                   Falls back to \$PRIVATE_KEY. Prompted if neither is set and --broadcast is given.
  --broadcast      actually send the transactions (default: simulate only)
  --verify         pass --verify to forge for the new implementation (needs ETHERSCAN_API_KEY)

Env passthrough:
  ALLOW_CONFIG_MISMATCH=true  skip Upgrade.sol's chain-consistency check (escape hatch; think first)

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
    0x*)           PROXY="$1"; shift ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$PROXY" ]] || { echo "error: proxy address is required" >&2; usage >&2; exit 1; }
[[ -n "$CHAIN" ]] || { echo "error: --chain is required" >&2; usage >&2; exit 1; }

RPC=""; WANT_ID=""
for e in "${CHAINS[@]}"; do
  set -- $e
  if [[ "$1" == "$CHAIN" ]]; then RPC="$2"; WANT_ID="$3"; fi
done
[[ -n "$RPC" ]] || { echo "error: unknown chain '$CHAIN'" >&2; usage >&2; exit 1; }

# Normalise to a checksummed 20-byte address, which also rejects malformed input up front.
PROXY="$(cast to-check-sum-address "$PROXY")" || { echo "error: '$PROXY' is not an address" >&2; exit 1; }

# ── key ─────────────────────────────────────────────────────────────────────
# Only required to broadcast; a simulation runs with --sender set to the live owner instead.
if [[ -z "$PRIVATE_KEY" && $BROADCAST -eq 1 ]]; then
  read -rsp "owner private key for $CHAIN: " PRIVATE_KEY; echo
fi
[[ -z "$PRIVATE_KEY" || "$PRIVATE_KEY" == 0x* ]] || PRIVATE_KEY="0x$PRIVATE_KEY"

# ── preflight ───────────────────────────────────────────────────────────────
echo "chain      : $CHAIN"
echo "rpc        : $RPC"
echo "proxy      : $PROXY"

GOT_ID="$(cast chain-id --rpc-url "$RPC")" || { echo "error: RPC unreachable" >&2; exit 1; }
if [[ "$GOT_ID" != "$WANT_ID" ]]; then
  echo "error: chain id mismatch - RPC reports $GOT_ID, expected $WANT_ID for '$CHAIN'" >&2
  echo "       Upgrade.sol validates the target against block.chainid; refusing." >&2
  exit 1
fi
echo "chain id   : $GOT_ID (verified)"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# An EOA or a wrong address would otherwise fail deep inside forge with a decoding error.
[[ "$(cast code "$PROXY" --rpc-url "$RPC")" != "0x" ]] || {
  echo "error: no code at $PROXY on $CHAIN" >&2; exit 1; }

# Everything the upgrade must preserve is checked inside Upgrade.sol; what is read here is the state
# needed to decide whether to sign at all - which implementation is live, and who may replace it.
IMPL_BEFORE="$(cast parse-bytes32-address "$(cast storage "$PROXY" "$IMPL_SLOT" --rpc-url "$RPC")")" || true
if [[ -z "$IMPL_BEFORE" || "$(lower "$IMPL_BEFORE")" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "error: $PROXY has an empty ERC-1967 implementation slot - not a UUPS proxy." >&2
  exit 1
fi

# version() was added after the first implementations shipped, so its absence is expected, not an error.
VERSION_BEFORE="$(cast call "$PROXY" 'version()(uint256)' --rpc-url "$RPC" 2>/dev/null || echo "none (pre-version impl)")"
OWNER="$(cast call "$PROXY" 'owner()(address)' --rpc-url "$RPC")"

echo "impl (now) : $IMPL_BEFORE"
echo "version    : $VERSION_BEFORE"
echo "owner      : $OWNER"

if [[ -n "$PRIVATE_KEY" ]]; then
  SIGNER="$(cast wallet address --private-key "$PRIVATE_KEY")"
  echo "signer     : $SIGNER"
  echo "balance    : $(cast balance "$SIGNER" --rpc-url "$RPC" --ether)"
  SENDER_ARGS=(--private-key "$PRIVATE_KEY")

  # _authorizeUpgrade is onlyOwner. Caught here rather than in a reverted broadcast, because the revert
  # happens only AFTER the new implementation has been deployed and paid for.
  if [[ "$(lower "$SIGNER")" != "$(lower "$OWNER")" ]]; then
    echo >&2
    echo "error: signer is not the relayer owner - upgradeToAndCall would revert (onlyOwner)." >&2
    echo "       signer $SIGNER" >&2
    echo "       owner  $OWNER" >&2
    exit 1
  fi

  # ── funding + stuck-nonce preflight ───────────────────────────────────────
  # Same failure mode as deploy.sh: this run signs two txs (deploy the new impl, then upgradeToAndCall).
  # A balance covering only the second one leaves the cheap call queued behind a nonce gap, and every
  # retry re-signs it into "-32000 already known".
  BAL_WEI="$(cast balance "$SIGNER" --rpc-url "$RPC")"
  GAS_PRICE="$(cast gas-price --rpc-url "$RPC")"
  EST_GAS=2500000   # ~1.80M impl + ~0.04M upgrade call + script overhead, rounded up
  read -r NEED_OK NEED_ETH BAL_ETH <<<"$(awk -v b="$BAL_WEI" -v g="$GAS_PRICE" -v u="$EST_GAS" \
    'BEGIN { need = g * u; printf "%d %.6f %.6f", (b >= need), need/1e18, b/1e18 }')"
  if [[ "$NEED_OK" != "1" ]]; then
    echo >&2
    echo "error: insufficient balance for the upgrade" >&2
    echo "       have $BAL_ETH, need ~$NEED_ETH ($EST_GAS gas at $GAS_PRICE wei)" >&2
    echo "       Fund $SIGNER before retrying." >&2
    exit 1
  fi
  echo "est. cost  : ~$NEED_ETH  ($EST_GAS gas at $GAS_PRICE wei)"

  N_LATEST="$(cast nonce "$SIGNER" --rpc-url "$RPC")"
  N_PENDING="$(cast nonce "$SIGNER" --block pending --rpc-url "$RPC")"
  if [[ "$N_LATEST" != "$N_PENDING" ]]; then
    echo >&2
    echo "warning: $SIGNER has pending transactions (latest=$N_LATEST pending=$N_PENDING)." >&2
    echo "         Clear them first, or this run may fail with '-32000 already known':" >&2
    echo "           cast send $SIGNER --value 0 --nonce $N_LATEST --gas-price <2x current> \\" >&2
    echo "             --rpc-url $RPC --private-key <key>" >&2
  fi
else
  # onlyOwner is enforced in the simulation too, so impersonating the live owner is what makes a
  # keyless dry run reach the post-upgrade assertions instead of reverting at the authorization check.
  echo "signer     : (simulation, no key given - impersonating the owner)"
  SENDER_ARGS=(--sender "$OWNER")
fi

FORGE_ARGS=(script script/Upgrade.sol --rpc-url "$RPC" "${SENDER_ARGS[@]}")

if [[ $BROADCAST -eq 1 ]]; then
  FORGE_ARGS+=(--broadcast)
  [[ $VERIFY -eq 1 ]] && FORGE_ARGS+=(--verify)

  if [[ " $MAINNETS " == *" $CHAIN "* ]]; then
    echo
    echo "!! MAINNET UPGRADE: $CHAIN (chain id $GOT_ID)"
    echo "!! This replaces the code behind $PROXY for every caller, immediately."
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

RELAYER_PROXY="$PROXY" forge "${FORGE_ARGS[@]}"

# ── result ──────────────────────────────────────────────────────────────────
# Upgrade.sol already asserts that owner/usdc/messenger/transmitter/swapRouter survived the swap. What
# is confirmed here is the one thing a script running inside the same tx cannot: that the proxy really
# points at new code now that the transactions have landed.
#
# The chain is the only authority used for that. An earlier version compared the slot against the
# address in broadcast/Upgrade.sol/<chainid>/run-latest.json, which forge does not always write — a run
# with no file of its own silently answered with ANOTHER chain's, and since these proxies share one
# address across chains the result was a confident, wrong "expected 0x...". The broadcast file is now
# a cross-check that can only add a warning, never a verdict.
if [[ $BROADCAST -eq 1 ]]; then
  # Public RPCs sit behind load balancers, so a read issued immediately after the tx can still be
  # served pre-upgrade state. Retry before concluding anything.
  IMPL_AFTER="$IMPL_BEFORE"
  for _attempt in 1 2 3 4 5; do
    IMPL_AFTER="$(cast parse-bytes32-address "$(cast storage "$PROXY" "$IMPL_SLOT" --rpc-url "$RPC")")"
    [[ "$(lower "$IMPL_AFTER")" != "$(lower "$IMPL_BEFORE")" ]] && break
    sleep 3
  done

  if [[ "$(lower "$IMPL_AFTER")" == "$(lower "$IMPL_BEFORE")" ]]; then
    echo >&2
    echo "error: $PROXY still points at $IMPL_BEFORE after 5 reads." >&2
    echo "       The upgrade did not take effect. Do NOT treat this proxy as upgraded." >&2
    exit 1
  fi

  # Which code is live, proved rather than assumed. UUPSUpgradeable stores `address immutable __self`,
  # so an implementation's runtime code embeds its own address; blanking that one value is what makes
  # the on-chain code byte-comparable to the local build.
  ONCHAIN_CODE="$(cast code "$IMPL_AFTER" --rpc-url "$RPC")"
  LOCAL_CODE="$(forge inspect CCTPV2Relayer deployedBytecode)"
  SELF="$(lower "${IMPL_AFTER#0x}")"
  if [[ "$(lower "${ONCHAIN_CODE//$SELF/0000000000000000000000000000000000000000}")" != "$(lower "$LOCAL_CODE")" ]]; then
    echo >&2
    echo "error: the code at $IMPL_AFTER is not this working tree's build of CCTPV2Relayer." >&2
    echo "       The proxy was upgraded, but to something else. Do NOT record this as upgraded until" >&2
    echo "       the difference is explained (dirty tree, changed compiler settings, concurrent run)." >&2
    exit 1
  fi

  RUN="broadcast/Upgrade.sol/$GOT_ID/run-latest.json"
  if [[ -f "$RUN" ]]; then
    NEW_IMPL="$(jq -r '[.transactions[] | select(.contractName=="CCTPV2Relayer")][-1].contractAddress' "$RUN")"
    if [[ "$(lower "$NEW_IMPL")" != "$(lower "$IMPL_AFTER")" ]]; then
      echo "note: $RUN names $NEW_IMPL, the chain says $IMPL_AFTER - the file is from an earlier run." >&2
    fi
  fi

  echo
  echo "=========================================================="
  echo " $CHAIN"
  echo "   RELAYER_PROXY = $PROXY   <- unchanged"
  echo "   implementation= $IMPL_BEFORE"
  echo "                -> $IMPL_AFTER"
  echo "   version       = $VERSION_BEFORE -> $(cast call "$PROXY" 'version()(uint256)' --rpc-url "$RPC")"
  echo "   owner         = $(cast call "$PROXY" 'owner()(address)' --rpc-url "$RPC")"
  echo "   verified on-chain: slot moved, and the code there matches the local build"
  echo "=========================================================="
fi
