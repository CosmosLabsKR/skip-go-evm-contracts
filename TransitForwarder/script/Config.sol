// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

// ⚠️ TransitForwarder deploys to AVALANCHE C-Chain — NOT to Injective EVM like its ForwarderFactory siblings.
//
// That makes this file a genuinely independent config, not a copy: every address below is Avalanche's. The only
// values it shares with ForwarderFactory/script/Config.sol are the operator keys (deliberately reused). Even the
// transmitter differs — this project's mint leg is CCTP v1, whose addresses are per-chain.
//
// Consequence for `make check-transit-copies`: it no longer compares these constants against ForwarderFactory's —
// divergence here is CORRECT, so a value comparison would only produce noise. The verbatim-file check still applies
// to the Solidity sources that ARE copies.
//
// ⚠️ LOCAL_DOMAIN is the single most dangerous value in this file. It drives BOTH the inbound binding check
//    (message.destinationDomain == this, so a wrong value rejects every legitimate message) AND the SelfLoop guard
//    (destinationDomain != this). Nothing else cross-checks it — see AVALANCHE_CCTP_DOMAIN below.

// ─────────────────────────────────────────────────────────────────────────────
// Avalanche C-Chain (Mainnet)
// ─────────────────────────────────────────────────────────────────────────────

// Chain ID
uint256 constant CHAIN_AVALANCHE = 43114;

// USDC address (Avalanche C-Chain native USDC).
// Named *_AVALANCHE, not *_MAINNET: sibling Config files in this monorepo declare USDC_MAINNET meaning ETHEREUM
// mainnet USDC (0xA0b86991...). Two identical names with different values across sibling Config files is a
// copy-paste accident waiting to happen, so this one carries the chain in its name.
address constant USDC_AVALANCHE = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

// Payment Contract (CCTPV2Relayer) on Avalanche — the burn leg is delegated to this.
// Note this happens to be the same address as PAYMENT_CONTRACT_INJECTIVE in the sibling config; same deployer and
// nonce on a different chain. It is NOT the same deployment — do not treat the coincidence as a cross-check.
address constant PAYMENT_CONTRACT_AVALANCHE = 0x400BB58033a7763A834199190B68F66A2661aE73;

// Relayer/Operator address — reused from the Injective operator (same key, different chain).
address constant OPERATOR_AVALANCHE = 0xfc05aD74C6FE2e7046E091D6Ad4F660D2A159762;

// ─────────────────────────────────────────────────────────────────────────────
// Avalanche Fuji (Testnet)
// ─────────────────────────────────────────────────────────────────────────────

// Chain ID
uint256 constant CHAIN_AVALANCHE_TESTNET = 43113;

// USDC address (Fuji USDC)
address constant USDC_AVALANCHE_TESTNET = 0x5425890298aed601595a70AB815c96711a31Bc65;

// Payment Contract (CCTPV2Relayer) on Fuji
address constant PAYMENT_CONTRACT_AVALANCHE_TESTNET = 0xd704Dc9A8DE1a82C674452192717DEE531751818;

// Relayer/Operator address — reused from the Injective testnet operator (same key, different chain).
address constant OPERATOR_AVALANCHE_TESTNET = 0x257cac9aa58c17E09074d7089CA878167611fc00;

// ─────────────────────────────────────────────────────────────────────────────
// Mint leg — CCTP v1 MessageTransmitter
// ─────────────────────────────────────────────────────────────────────────────
//
// ⚠️ THIS DEPLOYMENT MIXES CCTP VERSIONS:
//      mint (inbound)  = CCTP v1 -> the transmitter below, called directly by TransitExecutor
//      burn (outbound) = CCTP v2 -> PAYMENT_CONTRACT_* (CCTPV2Relayer), which owns that leg and its own messenger
//
// Only the mint address belongs here; a v2 constant would be an unread, unenforced second copy of the relayer's
// wiring. Nothing infers the version at runtime — binding the right address is what makes the mint leg v1, and a
// MessageTransmitterV2 address here would point it at the wrong protocol entirely. _assertExecutorImmutablesMatch
// compares the live impl against this constant before any upgrade.
//
// Unlike v2 (one address on every EVM chain), v1 addresses are per-chain — do not assume they match a sibling config.
//
// VERIFIED ON-CHAIN (2026-08-13): both answer localDomain() = 1 and version() = 0 (v1; v2 answers 1).
address constant TRANSMITTER_AVALANCHE = 0x8186359aF5F57FbB40c6b14A588d2A59C0C29880;
address constant TRANSMITTER_AVALANCHE_TESTNET = 0xa9fB1b3009DCb79E2fe346c16a604B8Fa8aE0a79;

// ─────────────────────────────────────────────────────────────────────────────
// CCTP domains — both VERIFIED ON-CHAIN, not derived from documentation
// ─────────────────────────────────────────────────────────────────────────────
//
// Read from Circle's MessageTransmitter.localDomain() on each chain (v1 re-verified 2026-08-13):
//   Avalanche 43114 / Fuji 43113 -> 1     Injective EVM 1776 / testnet 1439 -> 29
// Domains identify the CHAIN, not the network, which is why mainnet and testnet share a value.

// This chain's domain. Used by TransitForwarder for the inbound binding check
// (message.destinationDomain == this) — a wrong value rejects every legitimate message with WrongDestination.
uint32 constant AVALANCHE_CCTP_DOMAIN = 1;

// The ONLY destination this deployment routes to. TransitForwarder exists for Avalanche -> Injective, so
// `initialize` refuses any other destinationDomain (UnsupportedDestination).
//
// ⚠️ This does NOT make the destination an impl-level constant, and that distinction is the point:
//    destinationDomain stays in the CREATE2 salt and proxy storage, so each address still COMMITS its destination.
//    The value below only constrains which routes can be CREATED; it never affects an existing one.
uint32 constant INJECTIVE_CCTP_DOMAIN = 29;
