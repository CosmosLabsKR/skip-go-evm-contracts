// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

// ⚠️ TransitForwarder deploys to AVALANCHE C-Chain and POLYGON PoS — NOT to Injective EVM like its ForwarderFactory
//    siblings. Both are SOURCE chains: they are where a transit deployment LIVES, never where it sends.
//
// That makes this file a genuinely independent config, not a copy: every address below is Avalanche's or Polygon's.
// The only values it shares with ForwarderFactory/script/Config.sol are the operator keys (deliberately reused).
// Even the transmitter differs — this project's mint leg is CCTP v1, whose addresses are per-chain.
//
// Consequence for `make check-transit-copies`: it no longer compares these constants against ForwarderFactory's —
// divergence here is CORRECT, so a value comparison would only produce noise. The verbatim-file check still applies
// to the Solidity sources that ARE copies.
//
// ── PROVENANCE: where each value comes from, and what corroborates it ─────────────────────────────────────────
//
// Independent config does not mean unverified. Two sibling projects in this monorepo already deploy to these same
// chains, so most values here have a second source to be graded against. CROSS-CHECKED 2026-08-24, all agreeing:
//
//   chain ids, USDC   CCTPRelayer/script/Config.sol AND CCTPV2Relayer/script/Config.sol (both agree)
//   TRANSMITTER_*     CCTPRelayer/script/Config.sol ONLY — that is the v1 project
//   OPERATOR_PROD/DEV ForwarderFactory/script/Config.sol (the same two keys, deliberately reused)
//
// ⚠️ THE TRANSMITTER ROW IS THE ONE THAT MATTERS, AND ITS TEST IS TWO-SIDED. A correct value MATCHES CCTPRelayer's
//    (v1) and DIFFERS from CCTPV2Relayer's (v2). Matching the v2 project would mean the mint leg had been pointed
//    at the wrong protocol — the exact mistake the version note further down describes, and the one place where
//    "it matches a sibling config" is evidence of a BUG rather than of correctness. Verified today:
//      v1 (correct, ours)   Avalanche 0x8186359a..  Fuji 0xa9fB1b30..  Polygon 0xF3be9355..  Amoy 0x7865fAfC..
//      v2 (must NOT match)  0x81D40F21.. on every mainnet, 0xE737e5cE.. on every testnet
//
// ⚠️ ONE VALUE HAS NO SIBLING TO CROSS-CHECK AGAINST — it rests on a direct on-chain read alone:
//      TRANSMITTER_POLYGON_TESTNET  CCTPRelayer predates Amoy and still carries MUMBAI (80001) instead. Its
//                                   address 0xe09A679F.. is CODELESS on Amoy (checked) — do not copy it here.
//
// (It was two until forwarder v2: PAYMENT_CONTRACT_* had no sibling either, and was checked against its own
//  usdc() getter. Both it and that check are gone — the burn leg is now MESSENGER_*, which CCTPV2Relayer's Config
//  does carry.)
//
// ⚠️ LOCAL_DOMAIN is the single most dangerous value in this file. It drives BOTH the inbound binding check
//    (message.destinationDomain == this, so a wrong value rejects every legitimate message) AND the SelfLoop guard
//    (destinationDomain != this). Nothing else cross-checks it — see the CCTP domain section at the bottom.
//
// ⚠️ EACH CHAIN IS AN INDEPENDENT DEPLOYMENT. Adding Polygon added constants, not a shared address space: the
//    factory, beacon, executor and every per-route forwarder on Polygon are distinct contracts from Avalanche's,
//    with their own TRANSIT_EXECUTOR_PROXY / TRANSIT_FORWARDER_FACTORY_PROXY. Nothing here is cross-chain, and the
//    two deployments cannot be mixed: BaseScript picks ONE row below from `block.chainid`, so pointing a script at
//    the wrong RPC binds the wrong chain's addresses. That is exactly what inspect.sh's chain-id preflight catches.

// ─────────────────────────────────────────────────────────────────────────────
// Avalanche C-Chain (Mainnet)
// ─────────────────────────────────────────────────────────────────────────────

// Chain ID
uint256 constant CHAIN_AVALANCHE = 43114;

// USDC address (Avalanche C-Chain native USDC).
// Named *_AVALANCHE, not *_MAINNET: sibling Config files in this monorepo declare USDC_MAINNET meaning ETHEREUM
// mainnet USDC (0xA0b86991...). Two identical names with different values across sibling Config files is a
// copy-paste accident waiting to happen, so this one carries the chain in its name.
// Corroborated by BOTH CCTPRelayer and CCTPV2Relayer Config (USDC_AVALANCHE).
address constant USDC_AVALANCHE = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

// ─────────────────────────────────────────────────────────────────────────────
// Avalanche Fuji (Testnet)
// ─────────────────────────────────────────────────────────────────────────────

// Chain ID
uint256 constant CHAIN_AVALANCHE_TESTNET = 43113;

// USDC address (Fuji USDC). Corroborated by both sibling Configs (USDC_AVALANCHE_FUJI there — this file spells
// every testnet *_TESTNET, so the names differ while the value must not).
address constant USDC_AVALANCHE_TESTNET = 0x5425890298aed601595a70AB815c96711a31Bc65;

// ─────────────────────────────────────────────────────────────────────────────
// Polygon PoS (Mainnet)
// ─────────────────────────────────────────────────────────────────────────────

// Chain ID
uint256 constant CHAIN_POLYGON = 137;

// USDC address (Polygon PoS native USDC, NOT the bridged USDC.e 0x2791Bca1...).
// VERIFIED ON-CHAIN (2026-08-24): symbol() = "USDC".
// Corroborated by BOTH sibling Configs (USDC_POLYGON in CCTPRelayer and CCTPV2Relayer).
// ⚠️ No on-chain contract cross-checks this any more. Until forwarder v2 the payment contract's usdc() getter
//    pinned it (and the constructor enforced the match); ITokenMessenger takes burnToken per call and is bound to
//    no token, so the two sibling Configs above are now the ONLY corroboration. Do not weaken them.
address constant USDC_POLYGON = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

// ─────────────────────────────────────────────────────────────────────────────
// Polygon Amoy (Testnet)
// ─────────────────────────────────────────────────────────────────────────────

// Chain ID. Amoy (80002), not the retired Mumbai (80001) — sibling configs in this monorepo still carry Mumbai
// constants, and its addresses do NOT work here (the Mumbai v1 transmitter is codeless on Amoy).
uint256 constant CHAIN_POLYGON_TESTNET = 80002;

// USDC address (Amoy USDC). VERIFIED ON-CHAIN (2026-08-24): symbol() = "USDC".
// Corroborated by CCTPV2Relayer Config (USDC_POLYGON_AMOY). NOT by CCTPRelayer — it predates Amoy and carries
// Mumbai's USDC_POLYGON_MUMBAI (0x9999f7Fe...) instead, which is a different token on a dead network.
address constant USDC_POLYGON_TESTNET = 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582;

// ─────────────────────────────────────────────────────────────────────────────
// Mint leg — CCTP v1 MessageTransmitter
// ─────────────────────────────────────────────────────────────────────────────
//
// ⚠️ THIS DEPLOYMENT MIXES CCTP VERSIONS:
//      mint (inbound)  = CCTP v1 -> the transmitter below, called directly by TransitExecutor
//      burn (outbound) = CCTP v2 -> MESSENGER_* (Circle TokenMessengerV2), called DIRECTLY by TransitForwarder
//
// Only the mint address belongs in THIS section; the v2 burn address is its own section below. Nothing infers the
// version at runtime — binding the right address is what makes the mint leg v1, and a MessageTransmitterV2 address
// here would point it at the wrong protocol entirely. _assertExecutorImmutablesMatch compares the live impl
// against this constant before any upgrade.
//
// Unlike v2 (one address on every EVM chain), v1 addresses are per-chain — do not assume they match a sibling config.
//
// ⚠️ SOURCE: CCTPRelayer/script/Config.sol — the v1 project, and the ONLY sibling whose transmitters belong here.
//    CCTPV2Relayer's TRANSMITTER_* are v2 and MUST NOT match any address below; if one ever does, the mint leg has
//    been repointed at the wrong protocol. Both directions were checked on 2026-08-24 (see PROVENANCE at the top).
//
// VERIFIED ON-CHAIN (2026-08-13, re-confirmed 2026-08-24): both answer localDomain() = 1 and version() = 0
// (v1; v2 answers 1). Matches CCTPRelayer's TRANSMITTER_AVALANCHE / TRANSMITTER_AVALANCHE_FUJI.
address constant TRANSMITTER_AVALANCHE = 0x8186359aF5F57FbB40c6b14A588d2A59C0C29880;
address constant TRANSMITTER_AVALANCHE_TESTNET = 0xa9fB1b3009DCb79E2fe346c16a604B8Fa8aE0a79;

// VERIFIED ON-CHAIN (2026-08-24): both answer localDomain() = 7 and version() = 0.
// ⚠️ The version() = 0 check is not ceremony on Amoy. Circle's v2 transmitter there (0xE737e5cE...) ALSO answers
//    localDomain() = 7, so the domain alone does not tell the two protocols apart — only version() does.
//
// Mainnet matches CCTPRelayer's TRANSMITTER_POLYGON. The TESTNET value has NO sibling to check against: CCTPRelayer
// stops at Mumbai (TRANSMITTER_POLYGON_MUMBAI = 0xe09A679F...), and that address is CODELESS on Amoy — copying it
// here would bind the mint leg to nothing. The on-chain probe above is this constant's only evidence; re-run it
// rather than trusting a sibling file.
address constant TRANSMITTER_POLYGON = 0xF3be9355363857F3e001be68856A2f96b4C39Ba9;
address constant TRANSMITTER_POLYGON_TESTNET = 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;

// ─────────────────────────────────────────────────────────────────────────────
// CCTP domains — all VERIFIED ON-CHAIN, not derived from documentation
// ─────────────────────────────────────────────────────────────────────────────
//
// Read from Circle's MessageTransmitter.localDomain() on each chain (v1 re-verified 2026-08-13, Polygon 2026-08-24):
//   Avalanche 43114 / Fuji 43113 -> 1     Polygon 137 / Amoy 80002 -> 7
//   Injective EVM 1776 / testnet 1439 -> 29
// Domains identify the CHAIN, not the network, which is why mainnet and testnet share a value.

// The deploying chain's own domain. Used by TransitForwarder for the inbound binding check
// (message.destinationDomain == this) — a wrong value rejects every legitimate message with WrongDestination.
// BaseScript selects ONE of these from block.chainid and exposes it as `localDomain`; nothing should read a
// chain-specific constant directly, or it silently hard-codes one chain again.
uint32 constant AVALANCHE_CCTP_DOMAIN = 1;
uint32 constant POLYGON_CCTP_DOMAIN = 7;

// ─────────────────────────────────────────────────────────────────────────────
// OPERATOR — keyed by ENVIRONMENT only, never by chain
// ─────────────────────────────────────────────────────────────────────────────
//
// Every other constant in this file is keyed by chain. The operator is the exception and the ONLY one: it is a
// key, and the same key drives every chain of a given environment. So there are exactly two values here, not one
// per chain — and adding a chain must never add a third.
//
// Both environments exist on EVERY supported chain, mainnet and testnet alike. `BaseScript` selects between them
// with `DEPLOY_ENV`; `inspect.sh` with `--env`.
//
// ⚠️ DEPLOY_ENV / --env is REQUIRED, with no default. A default would silently pick one deployment while the
//    operator meant the other, and the two sit on the SAME chain behind different addresses — nothing else in the
//    resolved config would look wrong, because everything else is chain-derived and therefore identical. Failing
//    with "which environment?" is the only honest behaviour.
//
// ⚠️ MODELLING THIS IS NOT COSMETIC. Without the axis the guards grade a perfectly correct DEV deployment against
//    the PROD key and report `DRIFT operator` every single run. A guard that always fails on a legitimate
//    configuration teaches operators to reach for ALLOW_IMMUTABLE_REBIND as routine — and that flag also waives
//    the `executor` check, which is the one guarding an unrecoverable cross-chain misbinding
//    (see BaseScript._settleDrift). The axis exists so the drift guard only ever fires on a real problem.
//
// VERIFIED ON-CHAIN (2026-08-26): PROD on Avalanche 43114 and Polygon 137; DEV on those two plus Fuji 43113 and
// Amoy 80002. Every deployment of an environment answers that environment's key, on every chain.
address constant OPERATOR_PROD = 0xfc05aD74C6FE2e7046E091D6Ad4F660D2A159762;
address constant OPERATOR_DEV = 0x257cac9aa58c17E09074d7089CA878167611fc00;

// ─────────────────────────────────────────────────────────────────────────────
// Burn leg — CCTP v2 TokenMessenger (called directly; NO relayer, NO fee)
// ─────────────────────────────────────────────────────────────────────────────
//
// TransitForwarder v2 calls depositForBurn on this contract itself. Until v1 it delegated to a CCTPV2Relayer,
// whose sole contribution here was collecting a relayer fee — and it rejects a zero fee, which forced this route
// to pay 1 unit of dust per transit. This route charges nothing, so the relayer was removed outright.
//
// ⚠️ NOT the same shape as the v1 constants above. v2 uses ONE address per NETWORK TIER, identical on every EVM
//    chain — so a wrong-chain deploy cannot be caught by eyeballing this value, exactly as with the old payment
//    contract. LOCAL_DOMAIN remains the field that actually distinguishes the chains.
//
// ⚠️ Do NOT confuse with TRANSMITTER_* above: a MessageTransmitter address here would bind the burn leg to a
//    contract with no depositForBurn at all.
//
// SOURCE: CCTPV2Relayer/script/Config.sol (MESSENGER_*) — the v2 project, matching all seven of its chains.
// VERIFIED ON-CHAIN (2026-08-24): all four networks answer localMinter() non-zero
//   mainnet tier (Avalanche 43114, Polygon 137)   -> localMinter 0xfd78EE91...
//   testnet tier (Fuji 43113, Amoy 80002)         -> localMinter 0xb43db544...
address constant MESSENGER_MAINNET_TIER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
address constant MESSENGER_TESTNET_TIER = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;

// The ONLY destination these deployments route to. TransitForwarder exists for <source> -> Injective, so
// `initialize` refuses any other destinationDomain (UnsupportedDestination).
//
// ⚠️ This does NOT make the destination an impl-level constant, and that distinction is the point:
//    destinationDomain stays in the CREATE2 salt and proxy storage, so each address still COMMITS its destination.
//    The value below only constrains which routes can be CREATED; it never affects an existing one.
uint32 constant INJECTIVE_CCTP_DOMAIN = 29;
