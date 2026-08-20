#!/usr/bin/env bash
#
# Read a deployed forwarder factory AND the forwarder implementation it currently installs.
#
#   ./script/inspect.sh 0xFACTORY --chain injective-testnet
#   ./script/inspect.sh 0xFACTORY --chain injective --json
#
# Read-only: no key, no broadcast, nothing signed. Runnable from anywhere; it cds to the foundry root itself.
#
# Why this is two contracts and not one: only `owner`/`beacon`/`version` live on the factory. usdc, transmitter,
# operator (and paymentContract, INJECTIVE_DOMAIN) are IMMUTABLES of the forwarder implementation — they are baked
# into its bytecode and shared by every forwarder the beacon serves. The factory cannot answer for them. So the
# chain walked here is:
#
#     factory proxy --beacon()--> UpgradeableBeacon --implementation()--> forwarder impl
#
# and the impl's fields are printed under their own heading with the FORWARDER version next to them, because the
# factory and the forwarder version independently. Reading a usdc/operator value without knowing which forwarder
# version it came from tells you almost nothing after a beacon swap.
#
# Inbound and outbound factories are both supported; the kind is detected from the impl (`transmitter()` exists
# only on inbound, `paymentContract()` only on outbound) and the fields printed follow from it.
set -euo pipefail

# This file lives in script/, but Config.sol and forge are rooted one level up.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ── chain table ─────────────────────────────────────────────────────────────
# <name> <rpc> <expected chain id> <config suffix>. Only the two Injective EVM chains: BaseScript.sol reverts
# "Chain not supported." on anything else, so a factory cannot legitimately exist elsewhere.
CHAINS=(
  "injective-testnet  https://rpc-evm-injective.testnet.cosmoslabs.kr      1439  INJECTIVE_TESTNET"
  "injective          https://rpc-evm-injective.mainnet.cosmoslabs.kr      1776  INJECTIVE"
)

IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

# ── args ────────────────────────────────────────────────────────────────────
TARGET="${FACTORY_PROXY:-}"; CHAIN=""; RPC_OVERRIDE=""; JSON=0; ENVIRONMENT=""

usage() {
  cat <<EOF
Usage: script/inspect.sh <factory-proxy-address> --chain <name> --env <prod|dev> [--rpc-url <url>] [--json]

  <factory-proxy>  the Inbound/OutboundForwarderFactory proxy. Falls back to \$FACTORY_PROXY.
  --chain          one of the names below
  --env            REQUIRED. prod or dev — EVERY chain hosts both, and they differ only in \`operator\`.
                   No default: the two resolve identically apart from that one key, so a guess would grade the
                   wrong deployment while every other field still looked correct.
  --rpc-url        use this RPC instead of the table's (still checked against the chain id)
  --json           emit one JSON object instead of the human-readable block

Chains:
$(for e in "${CHAINS[@]}"; do set -- $e; printf "  %-18s %-52s chainid %s\n" "$1" "$2" "$3"; done)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain)   CHAIN="${2:-}"; shift 2 ;;
    --env)     ENVIRONMENT="${2:-}"; shift 2 ;;
    --rpc-url) RPC_OVERRIDE="${2:-}"; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    0x*)       TARGET="$1"; shift ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "error: factory proxy address is required" >&2; usage >&2; exit 1; }
[[ -n "$CHAIN"  ]] || { echo "error: --chain is required" >&2; usage >&2; exit 1; }
[[ -n "$ENVIRONMENT" ]] || {
  echo "error: --env is required (prod | dev)" >&2
  echo "       Every chain hosts BOTH deployments and they differ only in 'operator', so there is no safe" >&2
  echo "       default — guessing would grade the wrong one while every other field still looked correct." >&2
  usage >&2; exit 1; }
[[ "$ENVIRONMENT" == "prod" || "$ENVIRONMENT" == "dev" ]] || {
  echo "error: --env must be 'prod' or 'dev' (got '$ENVIRONMENT')" >&2; exit 1; }

RPC=""; WANT_ID=""; SUFFIX=""
for e in "${CHAINS[@]}"; do
  set -- $e
  if [[ "$1" == "$CHAIN" ]]; then RPC="$2"; WANT_ID="$3"; SUFFIX="$4"; fi
done
[[ -n "$RPC" ]] || { echo "error: unknown chain '$CHAIN'" >&2; usage >&2; exit 1; }
[[ -n "$RPC_OVERRIDE" ]] && RPC="$RPC_OVERRIDE"

TARGET="$(cast to-check-sum-address "$TARGET")" || { echo "error: '$TARGET' is not an address" >&2; exit 1; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
ZERO=0x0000000000000000000000000000000000000000

# ── preflight ───────────────────────────────────────────────────────────────
GOT_ID="$(cast chain-id --rpc-url "$RPC")" || { echo "error: RPC unreachable" >&2; exit 1; }
if [[ "$GOT_ID" != "$WANT_ID" ]]; then
  echo "error: chain id mismatch - RPC reports $GOT_ID, expected $WANT_ID for '$CHAIN'" >&2
  echo "       The Config comparison below would use the wrong chain's addresses; refusing." >&2
  exit 1
fi

[[ "$(cast code "$TARGET" --rpc-url "$RPC")" != "0x" ]] || {
  echo "error: no code at $TARGET on $CHAIN" >&2; exit 1; }

# ── factory ─────────────────────────────────────────────────────────────────
# Probed, not assumed: on a non-factory each of these reverts, and `n/a` is the answer that says so.
fcall() { cast call "$TARGET" "$1" --rpc-url "$RPC" 2>/dev/null || echo "n/a"; }

F_OWNER="$(fcall 'owner()(address)')"
# Ownable2Step: a transfer is only half-done until the new owner accepts. Invisible in owner() alone, and it
# decides who can actually authorize the next upgrade.
F_PENDING="$(fcall 'pendingOwner()(address)')"
F_VERSION="$(fcall 'version()(uint256)')"
BEACON="$(fcall 'beacon()(address)')"
INITCODEHASH="$(cast call "$TARGET" 'beaconInitCodeHash()(bytes32)' --rpc-url "$RPC" 2>/dev/null || echo "n/a")"
[[ "$(lower "$F_PENDING")" == "$ZERO" ]] && F_PENDING="none"

F_IMPL="$(cast parse-bytes32-address "$(cast storage "$TARGET" "$IMPL_SLOT" --rpc-url "$RPC")" 2>/dev/null || echo "n/a")"
[[ "$(lower "$F_IMPL")" == "$ZERO" ]] && F_IMPL="none (not an ERC-1967 proxy)"

if [[ "$BEACON" == "n/a" || "$(lower "$BEACON")" == "$ZERO" ]]; then
  echo "error: $TARGET has no beacon() - it is not an initialized forwarder factory." >&2
  exit 1
fi

# ── beacon ──────────────────────────────────────────────────────────────────
B_OWNER="$(cast call "$BEACON" 'owner()(address)' --rpc-url "$RPC" 2>/dev/null || echo "n/a")"
IMPL="$(cast call "$BEACON" 'implementation()(address)' --rpc-url "$RPC" 2>/dev/null || echo "n/a")"

# The factory (proxy) must own its beacon — that is what makes upgradeForwarderImplementation work. If ownership
# ever moved, forwarder upgrades are dead and nothing else on the factory would show it.
if [[ "$(lower "$B_OWNER")" == "$(lower "$TARGET")" ]]; then B_OWNER_V="ok (== factory)"
else B_OWNER_V="MISMATCH (upgradeForwarderImplementation would revert)"; fi

[[ "$IMPL" != "n/a" && "$(lower "$IMPL")" != "$ZERO" ]] || {
  echo "error: beacon $BEACON has no implementation." >&2; exit 1; }

# ── forwarder impl ──────────────────────────────────────────────────────────
icall() { cast call "$IMPL" "$1" --rpc-url "$RPC" 2>/dev/null || echo "n/a"; }

# Kind detection, same rule as BaseScript._requireForwarderKind: usdc() exists on both, so only the kind-specific
# getter separates them. Without this the fields below would be read off the wrong contract — the forwarders'
# fallback swallows selectors they do not have.
TRANSMITTER="$(icall 'transmitter()(address)')"
PAYMENT="$(icall 'paymentContract()(address)')"
if   [[ "$TRANSMITTER" != "n/a" ]]; then KIND="InboundForwarder"
elif [[ "$PAYMENT"     != "n/a" ]]; then KIND="OutboundForwarder"
else
  echo "error: the impl at $IMPL is neither an Inbound nor an Outbound forwarder." >&2
  exit 1
fi

FWD_VERSION="$(icall 'version()(uint256)')"
USDC="$(icall 'usdc()(address)')"
OPERATOR="$(icall 'operator()(address)')"
DOMAIN="$(cast call "$IMPL" 'INJECTIVE_DOMAIN()(uint32)' --rpc-url "$RPC" 2>/dev/null || echo "n/a")"
DENOM="$(cast call "$IMPL" 'DENOM()(string)' --rpc-url "$RPC" 2>/dev/null | tr -d '"' || echo "n/a")"
PORT="$(cast call "$IMPL" 'PORT()(string)' --rpc-url "$RPC" 2>/dev/null | tr -d '"' || echo "n/a")"

# ── expected wiring, straight from Config.sol ───────────────────────────────
# Read from the source rather than duplicated here, so this script cannot drift from what the deploy/upgrade
# scripts inject. This is the read-only twin of BaseScript._assert*ImmutablesMatch.
config_addr() {
  grep -oE "^address constant $1_$SUFFIX = 0x[0-9a-fA-F]{40}" script/Config.sol | grep -oE '0x[0-9a-fA-F]{40}' || true
}
# ⚠️ The operator is the ONE value keyed by ENVIRONMENT rather than by chain — the same key drives every chain of
#    an environment, so there are exactly two constants and the chain suffix plays no part. Every chain hosts both
#    deployments; resolving without --env would grade a correct DEV deployment against the PROD key.
#
#    Plain `tr`, not ${VAR^^}: that is bash 4+, and macOS still ships bash 3.2 — where it expands to nothing
#    rather than failing, leaving the expectation EMPTY. verdict() reads an empty expectation as
#    "(no Config value)", which is not a failure, so the operator would go ungraded while the script exited 0.
OPERATOR_CONST="OPERATOR_$(printf '%s' "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')"
EXP_USDC="$(config_addr USDC)"
EXP_OPERATOR="$(grep -oE "^address constant $OPERATOR_CONST = 0x[0-9a-fA-F]{40}" script/Config.sol | grep -oE '0x[0-9a-fA-F]{40}' || true)"
[[ -n "$EXP_OPERATOR" ]] || {
  echo "error: $OPERATOR_CONST not found in script/Config.sol - cannot grade the operator" >&2; exit 1; }
EXP_TRANSMITTER="$(config_addr TRANSMITTER)"
EXP_PAYMENT="$(config_addr PAYMENT_CONTRACT)"
# The domain identifies the chain, so it is shared by mainnet and testnet (no suffix).
EXP_DOMAIN="$(grep -oE '^uint32 constant INJECTIVE_CCTP_DOMAIN = [0-9]+' script/Config.sol | grep -oE '[0-9]+$' || true)"

verdict() {
  local got="$1" want="$2"
  if [[ -z "$want" || "$got" == "n/a" ]]; then printf '(no Config value)'
  elif [[ "$(lower "$got")" == "$(lower "$want")" ]]; then printf 'ok'
  else printf 'DRIFT (Config says %s)' "$want"
  fi
}
V_USDC="$(verdict "$USDC" "$EXP_USDC")"
V_OPERATOR="$(verdict "$OPERATOR" "$EXP_OPERATOR")"
V_TRANSMITTER="$(verdict "$TRANSMITTER" "$EXP_TRANSMITTER")"
V_PAYMENT="$(verdict "$PAYMENT" "$EXP_PAYMENT")"
V_DOMAIN="$(verdict "$DOMAIN" "$EXP_DOMAIN")"

# DENOM is not a second usdc check (the line above covers the value) — it catches a change to the RENDERING,
# prefix or EIP-55 casing, which comparing raw addresses cannot see.
V_DENOM="(skipped)"
if [[ "$DENOM" != "n/a" && "$USDC" != "n/a" ]]; then
  if [[ "$DENOM" == "erc20:$(cast to-check-sum-address "$USDC")" ]]; then V_DENOM="ok"
  else V_DENOM="DRIFT (expected erc20:$(cast to-check-sum-address "$USDC"))"; fi
fi

# ── would a factory upgrade still work? ─────────────────────────────────────
# beaconInitCodeHash was frozen in storage at deploy time, but a new factory impl builds proxies from ITS OWN
# compile-time BeaconProxy creationCode. If those disagree, the upgrade succeeds and every later createForwarder
# reverts AddressMismatch permanently. This is the read-only form of
# BaseScript._assertFactoryUpgradeKeepsAddressSpace — cheap to answer here, and the answer is worth having BEFORE
# an upgrade is drafted. It describes the LOCAL working tree, not the chain, so it only ever warns.
BUILD_CHECK="(skipped - could not build BeaconProxy creation code)"
if CREATION="$(forge inspect BeaconProxy bytecode 2>/dev/null)" && [[ "$CREATION" == 0x* ]]; then
  FROM_BUILD="$(cast keccak "$(cast concat-hex "$CREATION" "$(cast abi-encode 'f(address,bytes)' "$BEACON" 0x)")")"
  if [[ "$(lower "$FROM_BUILD")" == "$(lower "$INITCODEHASH")" ]]; then
    BUILD_CHECK="ok - a factory upgrade from this tree keeps the address space"
  else
    BUILD_CHECK="BUILD DRIFT - this tree computes $FROM_BUILD; upgrading the factory from it would brick createForwarder"
  fi
fi

# ── output ──────────────────────────────────────────────────────────────────
if [[ $JSON -eq 1 ]]; then
  cat <<EOF
{
  "chain": "$CHAIN",
  "env": "$ENVIRONMENT",
  "chainId": $GOT_ID,
  "kind": "$KIND",
  "factory": {
    "address": "$TARGET",
    "implementation": "$F_IMPL",
    "owner": "$F_OWNER",
    "pendingOwner": "$F_PENDING",
    "version": "$F_VERSION",
    "beacon": "$BEACON",
    "beaconInitCodeHash": "$INITCODEHASH"
  },
  "beacon": {
    "address": "$BEACON",
    "owner": "$B_OWNER",
    "ownerCheck": "$B_OWNER_V",
    "implementation": "$IMPL"
  },
  "forwarderImpl": {
    "address": "$IMPL",
    "version": "$FWD_VERSION",
    "usdc": "$USDC",
    "operator": "$OPERATOR",
    "transmitter": "$TRANSMITTER",
    "paymentContract": "$PAYMENT",
    "injectiveDomain": "$DOMAIN",
    "denom": "$DENOM",
    "port": "$PORT"
  },
  "configMatch": {
    "usdc": "$V_USDC",
    "operator": "$V_OPERATOR",
    "transmitter": "$V_TRANSMITTER",
    "paymentContract": "$V_PAYMENT",
    "injectiveDomain": "$V_DOMAIN",
    "denom": "$V_DENOM"
  },
  "beaconInitCodeHashVsLocalBuild": "$BUILD_CHECK"
}
EOF
else
  echo "=========================================================="
  echo " $CHAIN [$ENVIRONMENT] (chain id $GOT_ID, verified) - $KIND"
  echo "=========================================================="
  echo " factory (proxy)"
  printf "   address        = %s\n" "$TARGET"
  printf "   implementation = %s\n" "$F_IMPL"
  printf "   owner          = %s\n" "$F_OWNER"
  printf "   pendingOwner   = %s\n" "$F_PENDING"
  printf "   version        = %s   (factory)\n" "$F_VERSION"
  printf "   beacon         = %s\n" "$BEACON"
  printf "   beaconInitCodeHash = %s\n" "$INITCODEHASH"
  echo "----------------------------------------------------------"
  echo " beacon"
  printf "   owner          = %-42s %s\n" "$B_OWNER" "$B_OWNER_V"
  printf "   implementation = %s\n" "$IMPL"
  echo "----------------------------------------------------------"
  echo " forwarder impl   (forwarder version = $FWD_VERSION)"
  echo "   -- immutables baked into the impl, shared by every deployed forwarder --"
  printf "   usdc           = %-42s %s\n" "$USDC" "$V_USDC"
  printf "   operator       = %-42s %s\n" "$OPERATOR" "$V_OPERATOR"
  if [[ "$KIND" == "InboundForwarder" ]]; then
    printf "   transmitter    = %-42s %s\n" "$TRANSMITTER" "$V_TRANSMITTER"
    printf "   INJECTIVE_DOMAIN = %-40s %s\n" "$DOMAIN" "$V_DOMAIN"
    printf "   DENOM          = %-42s %s\n" "$DENOM" "$V_DENOM"
    printf "   PORT           = %s\n" "$PORT"
  else
    printf "   paymentContract= %-42s %s\n" "$PAYMENT" "$V_PAYMENT"
  fi
  echo "----------------------------------------------------------"
  echo " upgrade safety"
  printf "   beaconInitCodeHash vs local build: %s\n" "$BUILD_CHECK"
  echo "=========================================================="
fi

case "$BUILD_CHECK" in
  *"BUILD DRIFT"*)
    echo >&2
    echo "warning: this working tree's BeaconProxy build no longer matches the factory's frozen hash." >&2
    echo "         Do NOT upgrade this factory from this tree - deploy a fresh factory and migrate instead." >&2 ;;
esac

# Drift and a stolen beacon are the reasons to run this before touching a live factory, so they must be visible
# to a caller that only checks the exit status.
ALL="$V_USDC$V_OPERATOR$V_TRANSMITTER$V_PAYMENT$V_DOMAIN$V_DENOM$B_OWNER_V"
case "$ALL" in
  *DRIFT*|*MISMATCH*)
    echo >&2
    echo "error: the live wiring does not match Config.sol for $CHAIN - see the marked lines above." >&2
    exit 1 ;;
esac
