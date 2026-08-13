// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

// ⚠️ TransitForwarder deploys to AVALANCHE C-Chain — NOT to Injective EVM like its ForwarderFactory siblings.
//
// That makes this file a genuinely independent config, not a copy: every address below is Avalanche's. The only
// values it shares with ForwarderFactory/script/Config.sol are the CCTP v2 contracts (Circle deploys those at the
// same addresses on every supported EVM chain) and the operator keys (deliberately reused).
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
// Mint-side config (CCTP v2 receive)
// ─────────────────────────────────────────────────────────────────────────────

// CCTP v2 MessageTransmitterV2. TransitForwarder calls transmitter.receiveMessage(message, attestation) to mint USDC.
// Circle deploys MessageTransmitterV2 at the SAME address on every supported EVM chain, which is why these match the
// Injective values in the sibling config — that is expected, not a copy-paste slip.
address constant TRANSMITTER_AVALANCHE = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
address constant TRANSMITTER_AVALANCHE_TESTNET = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;

// CCTP v2 TokenMessengerV2 — recorded for reference ONLY; TransitForwarder never calls it.
// The burn leg goes through PAYMENT_CONTRACT_* (CCTPV2Relayer), which holds its own messenger reference. Listing the
// addresses here keeps the deployment facts in one place without implying this project uses them.
//   mainnet: 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d
//   testnet: 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA

// ─────────────────────────────────────────────────────────────────────────────
// CCTP domains — both VERIFIED ON-CHAIN, not derived from documentation
// ─────────────────────────────────────────────────────────────────────────────
//
// Read directly from Circle's MessageTransmitterV2.localDomain() on each chain (2026-08-12):
//   Avalanche C-Chain 43114 · 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64 -> 1
//   Avalanche Fuji    43113 · 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275 -> 1
//   Injective EVM     1776  · 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64 -> 29
//   Injective testnet 1439  · 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275 -> 29
// Re-verify the same way if either address ever changes. CCTP domains identify the CHAIN, not the network, which is
// why mainnet and testnet share a value.

// This chain's domain. Used by TransitForwarder for the inbound binding check
// (message.destinationDomain == this) — a wrong value rejects every legitimate message with WrongDestination.
uint32 constant AVALANCHE_CCTP_DOMAIN = 1;

// The ONLY destination this deployment routes to. TransitForwarder exists for Avalanche -> Injective, so
// `initialize` refuses any other destinationDomain (UnsupportedDestination).
//
// ⚠️ This does NOT make the destination an implementation-level constant, and that distinction is the whole point:
//    destinationDomain stays in the CREATE2 salt and in proxy storage, so each forwarder's address still COMMITS
//    its destination. Making it an impl immutable instead would mean a single beacon upgrade could silently
//    redirect every already-deployed forwarder — including funds a source-chain burner has already committed to
//    that address. The value below only constrains which routes can be CREATED; it never affects an existing one.
uint32 constant INJECTIVE_CCTP_DOMAIN = 29;
