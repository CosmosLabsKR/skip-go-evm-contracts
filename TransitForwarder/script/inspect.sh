#!/usr/bin/env bash
#
# Read a deployed TransitExecutor, or a TransitForwarderFactory and the chain it installs.
#
#   ./script/inspect.sh 0xEXECUTOR --chain avalanche --env prod       # executor only
#   ./script/inspect.sh 0xFACTORY  --chain polygon-testnet --env dev  # factory -> beacon -> forwarder impl
#   ./script/inspect.sh 0xFACTORY  --chain polygon --env prod --json
#
# --env is REQUIRED: every chain hosts a PROD and a DEV deployment that differ ONLY in `operator`.
#
# Read-only: no key, no broadcast, nothing signed. Runnable from anywhere; it cds to the foundry root itself.
#
# ⚠️ SOURCE CHAINS ONLY — Avalanche C-Chain and Polygon PoS. Unlike the ForwarderFactory sibling this subproject
#    deploys to those, and BaseScript.sol reverts "Chain not supported." on anything else, so a Transit deployment
#    cannot legitimately exist elsewhere. They are where it LIVES (LOCAL_DOMAIN = 1 / 7); Injective is where it
#    SENDS (domain 29).
#
# ⚠️ --chain is not a label, it is the Config row this report compares against, and each chain is an INDEPENDENT
#    deployment. Naming the wrong one would grade a live deployment against another chain's addresses — which the
#    messenger's cross-tier address collision would hide (MESSENGER_*_TIER is one address for EVERY chain of a
#    tier) — so the chain id is verified before any read.
#
# TWO MODES, chosen by what you pass — the report describes the contract you asked about, nothing more.
#
#   executor  Its own wiring: owner, the three immutables, and the factory it creates missing forwarders with.
#             Self-contained; it does not walk anywhere.
#
#   factory   Necessarily three contracts, because the factory cannot answer for its own forwarders:
#
#               factory proxy --beacon()--> UpgradeableBeacon --implementation()--> forwarder impl
#
#             owner/beacon/version live on the factory, while usdc, messenger, operator, LOCAL_DOMAIN,
#             ALLOWED_DESTINATION_DOMAIN and executor are IMMUTABLES of the impl — baked into its bytecode and
#             shared by every forwarder the beacon serves.
#
# The misconfigurations this exists to catch, none of which a single getter reveals:
#
#   1. executor is an IMPLEMENTATION, not a proxy     -> every forwarder orphaned at the first upgrade. No recovery.
#   2. executor.factory() unset or stale              -> creating a NEW route reverts FactoryNotSet / RouteMismatch.
#   3. factory.executor() != forwarderImpl.executor() -> upgradeForwarderImplementation is stuck (ExecutorMismatch).
#   4. beaconInitCodeHash drifted from this build     -> a factory upgrade would brick createForwarder forever.
set -euo pipefail

# This file lives in script/, but Config.sol and forge are rooted one level up.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ── chain table ─────────────────────────────────────────────────────────────
# <name> <rpc> <expected chain id> <config suffix>. Only the supported source networks — see the header.
# The config suffix is what pairs a row with Config.sol's constants: <NAME>_$SUFFIX for addresses, and
# ${SUFFIX%_TESTNET}_CCTP_DOMAIN for the chain's own domain (domains identify the chain, so both networks share one).
CHAINS=(
  "avalanche-testnet  https://api.avax-test.network/ext/bc/C/rpc           43113  AVALANCHE_TESTNET"
  "avalanche          https://api.avax.network/ext/bc/C/rpc                43114  AVALANCHE"
  "polygon-testnet    https://polygon-amoy-bor-rpc.publicnode.com          80002  POLYGON_TESTNET"
  "polygon            https://polygon-bor-rpc.publicnode.com               137    POLYGON"
)

IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
ZERO=0x0000000000000000000000000000000000000000

# ── args ────────────────────────────────────────────────────────────────────
TARGET="${TRANSIT_FORWARDER_FACTORY_PROXY:-${TRANSIT_EXECUTOR_PROXY:-}}"
CHAIN=""; RPC_OVERRIDE=""; JSON=0; ENVIRONMENT=""

usage() {
  cat <<EOF
Usage: script/inspect.sh <address> --chain <name> --env <prod|dev> [--rpc-url <url>] [--json]

  <address>        a TransitExecutor proxy or a TransitForwarderFactory proxy. The kind is detected, and the
                   report covers that contract only. Falls back to \$TRANSIT_FORWARDER_FACTORY_PROXY, then
                   \$TRANSIT_EXECUTOR_PROXY.
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

[[ -n "$TARGET" ]] || { echo "error: an executor or factory proxy address is required" >&2; usage >&2; exit 1; }
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

# ── preflight ───────────────────────────────────────────────────────────────
GOT_ID="$(cast chain-id --rpc-url "$RPC")" || { echo "error: RPC unreachable" >&2; exit 1; }
if [[ "$GOT_ID" != "$WANT_ID" ]]; then
  echo "error: chain id mismatch - RPC reports $GOT_ID, expected $WANT_ID for '$CHAIN'" >&2
  echo "       The Config comparison below would use the wrong chain's addresses; refusing." >&2
  exit 1
fi

[[ "$(cast code "$TARGET" --rpc-url "$RPC")" != "0x" ]] || {
  echo "error: no code at $TARGET on $CHAIN" >&2; exit 1; }

probe() { cast call "$1" "$2" --rpc-url "$RPC" 2>/dev/null || echo "n/a"; }

# Which implementation an ERC-1967 proxy points at. An empty slot means it is not one.
impl_of() {
  cast parse-bytes32-address "$(cast storage "$1" "$IMPL_SLOT" --rpc-url "$RPC")" 2>/dev/null || echo "n/a"
}

# ── expected wiring, straight from Config.sol ───────────────────────────────
# Read from the source rather than duplicated here, so this script cannot drift from what the deploy/upgrade
# scripts inject. This is the read-only twin of BaseScript._assert*ImmutablesMatch.
config_addr() {
  grep -oE "^address constant $1_$SUFFIX = 0x[0-9a-fA-F]{40}" script/Config.sol | grep -oE '0x[0-9a-fA-F]{40}' || true
}
# Domains identify the CHAIN, not the network, so mainnet and testnet share them: strip _TESTNET off the suffix.
# Config declares one <CHAIN>_CCTP_DOMAIN per supported chain; picking the wrong one would report the wrong
# LOCAL_DOMAIN as "ok", which is the value that decides whether legitimate messages are accepted at all.
LOCAL_DOMAIN_CONST="${SUFFIX%_TESTNET}_CCTP_DOMAIN"
# The burn-leg messenger is ONE address per network tier (identical on every chain of that tier), so unlike every
# other address here it is not keyed by chain — only by whether this row is a testnet.
case "$SUFFIX" in
  *_TESTNET) MESSENGER_CONST="MESSENGER_TESTNET_TIER" ;;
  *)         MESSENGER_CONST="MESSENGER_MAINNET_TIER" ;;
esac
# ⚠️ The operator is the ONE value keyed by ENVIRONMENT rather than by chain — the same key drives every chain of
#    an environment, so there are exactly two constants and the chain suffix plays no part. Every chain hosts both
#    deployments; resolving without --env would grade a correct DEV deployment against the PROD key and report a
#    bogus DRIFT, and a guard that always cries wolf gets routinely bypassed.
# ⚠️ Plain `tr`, not ${VAR^^}: that is bash 4+, and macOS still ships bash 3.2 — where it does not merely fail
#    loudly but expands to nothing, leaving the expected value EMPTY. verdict() reads an empty expectation as
#    "(no Config value)", which is not a failure, so the operator would have gone ungraded while the script still
#    exited 0. Resolved once here and asserted, rather than being recomputed per call site.
OPERATOR_CONST="OPERATOR_$(printf '%s' "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')"
EXP_OPERATOR="$(grep -oE "^address constant $OPERATOR_CONST = 0x[0-9a-fA-F]{40}" script/Config.sol | grep -oE '0x[0-9a-fA-F]{40}' || true)"
[[ -n "$EXP_OPERATOR" ]] || {
  echo "error: $OPERATOR_CONST not found in script/Config.sol - cannot grade the operator" >&2; exit 1; }
config_operator() { printf '%s' "$EXP_OPERATOR"; }
config_messenger() {
  grep -oE "^address constant $MESSENGER_CONST = 0x[0-9a-fA-F]{40}" script/Config.sol | grep -oE '0x[0-9a-fA-F]{40}' || true
}
config_u32() {
  grep -oE "^uint32 constant $1 = [0-9]+" script/Config.sol | grep -oE '[0-9]+$' || true
}

# ⚠️ An UNREADABLE field is a failure, not a blank. `probe` collapses every failure — a revert, a missing getter,
#    a rate-limited or flaky RPC — into the string "n/a". Treating that as "(no Config value)" would let this
#    script exit 0 having never checked the field, which is the opposite of what a pre-upgrade gate is for: one
#    throttled `cast call` against a public RPC and LOCAL_DOMAIN (the value deciding whether legitimate messages
#    are accepted at all) silently goes ungraded. Only a genuinely absent CONFIG side is a blank.
verdict() {
  local got="$1" want="$2"
  if [[ -z "$want" ]]; then printf '(no Config value)'
  elif [[ "$got" == "n/a" ]]; then printf 'UNREADABLE (could not read on-chain; expected %s)' "$want"
  elif [[ "$(lower "$got")" == "$(lower "$want")" ]]; then printf 'ok'
  else printf 'DRIFT (Config says %s)' "$want"
  fi
}

# Visible to a caller that only checks the exit status — the whole reason to run this before touching a live
# deployment. Appended to by each mode, evaluated once at the end.
VERDICTS=""

# ── which contract is this? ─────────────────────────────────────────────────
# An executor takes TWO getters to name: transmitter() separates it from the forwarder (which gave that up with
# the mint capability), and operator() separates it from the CCTPV2Relayer next door, which also exposes
# transmitter(). Either probe alone misidentifies a real contract sitting on the same chain.
if [[ "$(probe "$TARGET" 'beacon()(address)')" != "n/a" ]]; then
  KIND="factory"
elif [[ "$(probe "$TARGET" 'transmitter()(address)')" != "n/a" && "$(probe "$TARGET" 'operator()(address)')" != "n/a" ]]; then
  KIND="executor"
else
  echo "error: $TARGET is neither a TransitForwarderFactory (no beacon()) nor a TransitExecutor" >&2
  echo "       (needs both transmitter() and operator())." >&2
  echo "       Note a CCTPV2Relayer answers transmitter() too; inspect it with CCTPV2Relayer/script/inspect.sh." >&2
  exit 1
fi

# ════════════════════════════════════════════════════════════════════════════
# EXECUTOR
# ════════════════════════════════════════════════════════════════════════════
if [[ "$KIND" == "executor" ]]; then
  xcall() { probe "$TARGET" "$1"; }

  X_IMPL="$(impl_of "$TARGET")"
  X_OWNER="$(xcall 'owner()(address)')"
  # Ownable2Step: a transfer is only half-done until the new owner accepts. Invisible in owner() alone, and it
  # decides who can actually authorize the next upgrade.
  X_PENDING="$(xcall 'pendingOwner()(address)')"
  X_VERSION="$(xcall 'version()(uint256)')"
  X_USDC="$(xcall 'usdc()(address)')"
  X_TRANSMITTER="$(xcall 'transmitter()(address)')"
  X_OPERATOR="$(xcall 'operator()(address)')"
  X_FACTORY="$(xcall 'factory()(address)')"
  [[ "$(lower "$X_PENDING")" == "$ZERO" ]] && X_PENDING="none"

  # ⚠️ THE most damaging misconfiguration available in this subproject. An implementation address here works
  #    until the first UUPS upgrade, then every forwarder's authorized caller ceases to exist and in-flight
  #    messages become permanently unreceivable. The read-only twin of BaseScript._assertIsProxy.
  if [[ "$X_IMPL" == "n/a" || "$(lower "$X_IMPL")" == "$ZERO" ]]; then
    X_PROXY_V="NOT A PROXY - forwarders bound to this address would be orphaned at the first upgrade"
    X_IMPL="none"
  else
    X_PROXY_V="ok (ERC-1967 proxy)"
  fi

  # The last wiring step of DeployTransitFactory. Unset => a NEW route reverts FactoryNotSet. Not an error:
  # already-deployed routes keep working, so this is a warning, not a failed invariant.
  if [[ "$(lower "$X_FACTORY")" == "$ZERO" ]]; then
    X_FACTORY_V="UNSET - creating a NEW route reverts FactoryNotSet"; X_FACTORY="none"
  else
    X_FACTORY_V="set"
  fi

  V_USDC="$(verdict "$X_USDC" "$(config_addr USDC)")"
  V_TRANSMITTER="$(verdict "$X_TRANSMITTER" "$(config_addr TRANSMITTER)")"
  V_OPERATOR="$(verdict "$X_OPERATOR" "$(config_operator)")"
  VERDICTS="$V_USDC$V_TRANSMITTER$V_OPERATOR$X_PROXY_V"

  if [[ $JSON -eq 1 ]]; then
    cat <<EOF
{
  "chain": "$CHAIN",
  "env": "$ENVIRONMENT",
  "chainId": $GOT_ID,
  "kind": "TransitExecutor",
  "executor": {
    "address": "$TARGET",
    "implementation": "$X_IMPL",
    "owner": "$X_OWNER",
    "pendingOwner": "$X_PENDING",
    "version": "$X_VERSION",
    "usdc": "$X_USDC",
    "transmitter": "$X_TRANSMITTER",
    "operator": "$X_OPERATOR",
    "factory": "$X_FACTORY"
  },
  "configMatch": {
    "usdc": "$V_USDC",
    "transmitter": "$V_TRANSMITTER",
    "operator": "$V_OPERATOR"
  },
  "checks": {
    "isProxy": "$X_PROXY_V",
    "factory": "$X_FACTORY_V"
  }
}
EOF
  else
    echo "=========================================================="
    echo " $CHAIN [$ENVIRONMENT] (chain id $GOT_ID, verified) - TransitExecutor"
    echo "=========================================================="
    printf "   address        = %s\n" "$TARGET"
    printf "   implementation = %-42s %s\n" "$X_IMPL" "$X_PROXY_V"
    printf "   owner          = %s\n" "$X_OWNER"
    printf "   pendingOwner   = %s\n" "$X_PENDING"
    printf "   version        = %s\n" "$X_VERSION"
    echo "----------------------------------------------------------"
    echo "   -- immutables (rotated only by a UUPS upgrade) --"
    printf "   usdc           = %-42s %s\n" "$X_USDC" "$V_USDC"
    printf "   transmitter    = %-42s %s\n" "$X_TRANSMITTER" "$V_TRANSMITTER"
    printf "   operator       = %-42s %s\n" "$X_OPERATOR" "$V_OPERATOR"
    echo "----------------------------------------------------------"
    echo "   -- storage --"
    printf "   factory        = %-42s %s\n" "$X_FACTORY" "$X_FACTORY_V"
    echo "=========================================================="
  fi

  case "$X_FACTORY_V" in
    UNSET*)
      echo >&2
      echo "warning: this executor has no factory. Already-deployed routes still work; creating a NEW one" >&2
      echo "         reverts FactoryNotSet. Run 'executor.setFactory(<factory>)' as the owner ($X_OWNER)." >&2 ;;
  esac

# ════════════════════════════════════════════════════════════════════════════
# FACTORY  (+ beacon + forwarder implementation)
# ════════════════════════════════════════════════════════════════════════════
else
  fcall() { probe "$TARGET" "$1"; }

  F_OWNER="$(fcall 'owner()(address)')"
  F_PENDING="$(fcall 'pendingOwner()(address)')"
  F_VERSION="$(fcall 'version()(uint256)')"
  BEACON="$(fcall 'beacon()(address)')"
  INITCODEHASH="$(fcall 'beaconInitCodeHash()(bytes32)')"
  # Frozen at initialize from the first impl; upgradeForwarderImplementation refuses anything that disagrees.
  F_EXECUTOR="$(fcall 'executor()(address)')"
  [[ "$(lower "$F_PENDING")" == "$ZERO" ]] && F_PENDING="none"

  F_IMPL="$(impl_of "$TARGET")"
  [[ "$(lower "$F_IMPL")" == "$ZERO" ]] && F_IMPL="none (not an ERC-1967 proxy)"

  if [[ "$(lower "$BEACON")" == "$ZERO" ]]; then
    echo "error: the factory at $TARGET has a zero beacon - it was never initialized." >&2
    exit 1
  fi

  B_OWNER="$(probe "$BEACON" 'owner()(address)')"
  IMPL="$(probe "$BEACON" 'implementation()(address)')"

  # The factory (proxy) must own its beacon — that is what makes upgradeForwarderImplementation work. If
  # ownership ever moved, forwarder upgrades are dead and nothing else on the factory would show it.
  if [[ "$(lower "$B_OWNER")" == "$(lower "$TARGET")" ]]; then B_OWNER_V="ok (== factory)"
  else B_OWNER_V="MISMATCH (upgradeForwarderImplementation would revert)"; fi

  [[ "$IMPL" != "n/a" && "$(lower "$IMPL")" != "$ZERO" ]] || {
    echo "error: beacon $BEACON has no implementation." >&2; exit 1; }

  icall() { probe "$IMPL" "$1"; }

  # Kind check. usdc() also exists on the OutboundForwarder next door, so only these two separate a Transit impl
  # from it — and reading the fields below off the wrong contract is the failure mode. (Since forwarder v2 the
  # Transit impl no longer answers paymentContract() at all, which is what the sibling probes for Outbound.)
  FWD_EXECUTOR="$(icall 'executor()(address)')"
  ALLOWED_DOMAIN="$(icall 'ALLOWED_DESTINATION_DOMAIN()(uint32)')"
  if [[ "$FWD_EXECUTOR" == "n/a" || "$ALLOWED_DOMAIN" == "n/a" ]]; then
    echo "error: the impl at $IMPL is not a TransitForwarder (no executor()/ALLOWED_DESTINATION_DOMAIN())." >&2
    echo "       Is $TARGET an Inbound/Outbound factory? Use ForwarderFactory/script/inspect.sh for those." >&2
    exit 1
  fi

  FWD_VERSION="$(icall 'version()(uint256)')"
  USDC="$(icall 'usdc()(address)')"
  MESSENGER="$(icall 'messenger()(address)')"
  OPERATOR="$(icall 'operator()(address)')"
  LOCAL_DOMAIN="$(icall 'LOCAL_DOMAIN()(uint32)')"

  V_USDC="$(verdict "$USDC" "$(config_addr USDC)")"
  # ⚠️ An absent getter must NOT fall through to verdict(): it maps "n/a" to "(no Config value)", which is not
  #    counted as a failure, so a pre-v2 impl would be reported CLEAN with its burn leg never checked — during a
  #    v1 -> v2 migration, exactly when someone runs this to confirm what is live. Name it instead.
  if [[ "$MESSENGER" == "n/a" ]]; then
    V_MESSENGER="ABSENT - impl predates forwarder v2 (still delegates to a PaymentContract); check version()"
  else
    V_MESSENGER="$(verdict "$MESSENGER" "$(config_messenger)")"
  fi
  V_OPERATOR="$(verdict "$OPERATOR" "$(config_operator)")"
  V_LOCAL_DOMAIN="$(verdict "$LOCAL_DOMAIN" "$(config_u32 "$LOCAL_DOMAIN_CONST")")"
  V_ALLOWED_DOMAIN="$(verdict "$ALLOWED_DOMAIN" "$(config_u32 INJECTIVE_CCTP_DOMAIN)")"

  # The on-chain invariant upgradeForwarderImplementation enforces. If these ever diverged, the factory could no
  # longer install any impl at all. Both values are the factory's own business, so this belongs in factory mode.
  if [[ "$(lower "$F_EXECUTOR")" == "$(lower "$FWD_EXECUTOR")" ]]; then X_FROZEN_V="ok (== impl's executor)"
  else X_FROZEN_V="MISMATCH (upgradeForwarderImplementation would revert ExecutorMismatch)"; fi

  # ⚠️ GONE IN v2, deliberately: v1 cross-checked the forwarder's usdc against paymentContract.usdc(), both at
  #    deploy time (UsdcMismatch) and live here. Circle's TokenMessenger takes burnToken per call and exposes no
  #    usdc(), so there is nothing to compare against. What replaces it: `usdc` above is graded against Config, and
  #    the impl only ever passes that immutable as burnToken (pinned by TransitForwarder.t.sol T-33).

  # The constructor's SelfLoop guard, restated: a route to this very chain could never produce a usable transfer.
  if [[ "$LOCAL_DOMAIN" != "n/a" && "$LOCAL_DOMAIN" == "$ALLOWED_DOMAIN" ]]; then
    V_SELFLOOP="MISMATCH - LOCAL_DOMAIN == ALLOWED_DESTINATION_DOMAIN (SelfLoop)"
  else V_SELFLOOP="ok"; fi

  # beaconInitCodeHash was frozen in storage at deploy time, but a new factory impl builds proxies from ITS OWN
  # compile-time BeaconProxy creationCode. If those disagree, the upgrade succeeds and every later
  # createForwarder reverts AddressMismatch permanently. This is the read-only form of
  # BaseScript._assertFactoryUpgradeKeepsAddressSpace. It describes the LOCAL working tree, not the chain, so it
  # only ever warns.
  BUILD_CHECK="(skipped - could not build BeaconProxy creation code)"
  if CREATION="$(forge inspect BeaconProxy bytecode 2>/dev/null)" && [[ "$CREATION" == 0x* ]]; then
    FROM_BUILD="$(cast keccak "$(cast concat-hex "$CREATION" "$(cast abi-encode 'f(address,bytes)' "$BEACON" 0x)")")"
    if [[ "$(lower "$FROM_BUILD")" == "$(lower "$INITCODEHASH")" ]]; then
      BUILD_CHECK="ok - a factory upgrade from this tree keeps the address space"
    else
      BUILD_CHECK="BUILD DRIFT - this tree computes $FROM_BUILD; upgrading the factory from it would brick createForwarder"
    fi
  fi

  VERDICTS="$V_USDC$V_MESSENGER$V_OPERATOR$V_LOCAL_DOMAIN$V_ALLOWED_DOMAIN$B_OWNER_V$X_FROZEN_V$V_SELFLOOP"

  if [[ $JSON -eq 1 ]]; then
    cat <<EOF
{
  "chain": "$CHAIN",
  "env": "$ENVIRONMENT",
  "chainId": $GOT_ID,
  "kind": "TransitForwarderFactory",
  "factory": {
    "address": "$TARGET",
    "implementation": "$F_IMPL",
    "owner": "$F_OWNER",
    "pendingOwner": "$F_PENDING",
    "version": "$F_VERSION",
    "beacon": "$BEACON",
    "beaconInitCodeHash": "$INITCODEHASH",
    "executor": "$F_EXECUTOR"
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
    "messenger": "$MESSENGER",
    "operator": "$OPERATOR",
    "executor": "$FWD_EXECUTOR",
    "localDomain": "$LOCAL_DOMAIN",
    "allowedDestinationDomain": "$ALLOWED_DOMAIN"
  },
  "configMatch": {
    "usdc": "$V_USDC",
    "messenger": "$V_MESSENGER",
    "operator": "$V_OPERATOR",
    "localDomain": "$V_LOCAL_DOMAIN",
    "allowedDestinationDomain": "$V_ALLOWED_DOMAIN"
  },
  "checks": {
    "frozenExecutor": "$X_FROZEN_V",
    "selfLoop": "$V_SELFLOOP"
  },
  "beaconInitCodeHashVsLocalBuild": "$BUILD_CHECK"
}
EOF
  else
    echo "=========================================================="
    echo " $CHAIN [$ENVIRONMENT] (chain id $GOT_ID, verified) - TransitForwarderFactory"
    echo "=========================================================="
    echo " factory (proxy)"
    printf "   address        = %s\n" "$TARGET"
    printf "   implementation = %s\n" "$F_IMPL"
    printf "   owner          = %s\n" "$F_OWNER"
    printf "   pendingOwner   = %s\n" "$F_PENDING"
    printf "   version        = %s   (factory)\n" "$F_VERSION"
    printf "   beacon         = %s\n" "$BEACON"
    printf "   beaconInitCodeHash = %s\n" "$INITCODEHASH"
    printf "   executor (frozen) = %-39s %s\n" "$F_EXECUTOR" "$X_FROZEN_V"
    echo "----------------------------------------------------------"
    echo " beacon"
    printf "   owner          = %-42s %s\n" "$B_OWNER" "$B_OWNER_V"
    printf "   implementation = %s\n" "$IMPL"
    echo "----------------------------------------------------------"
    echo " forwarder impl   (forwarder version = $FWD_VERSION)"
    echo "   -- immutables baked into the impl, shared by every deployed forwarder --"
    printf "   usdc           = %-42s %s\n" "$USDC" "$V_USDC"
    printf "   messenger      = %-42s %s\n" "$MESSENGER" "$V_MESSENGER"
    printf "   operator       = %-42s %s\n" "$OPERATOR" "$V_OPERATOR"
    printf "   executor       = %s\n" "$FWD_EXECUTOR"
    printf "   LOCAL_DOMAIN               = %-29s %s\n" "$LOCAL_DOMAIN" "$V_LOCAL_DOMAIN"
    printf "   ALLOWED_DESTINATION_DOMAIN = %-29s %s\n" "$ALLOWED_DOMAIN" "$V_ALLOWED_DOMAIN"
    echo "----------------------------------------------------------"
    printf "   LOCAL_DOMAIN != ALLOWED_DESTINATION      : %s\n" "$V_SELFLOOP"
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
fi

case "$VERDICTS" in
  *DRIFT*|*MISMATCH*|*ABSENT*|*UNREADABLE*|*"NOT A PROXY"*)
    echo >&2
    echo "error: the live wiring does not match Config.sol for $CHAIN - see the marked lines above." >&2
    exit 1 ;;
esac
