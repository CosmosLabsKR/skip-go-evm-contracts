// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

// Address constants are declared as `address` because BaseScript uses them as addresses.
// WARNING: PAYMENT_CONTRACT_* are placeholders (address(0)) — replace with real addresses after CCTPV2Relayer is deployed.
//    If a deploy script runs while they are address(0), the OutboundForwarder constructor reverts with ZeroAddress (unset-value safeguard).

// Injective EVM (Mainnet)

// Chain ID
uint256 constant CHAIN_INJECTIVE = 1776;

// USDC address (Injective mainnet USDC — confirmed).
// Named *_INJECTIVE, not *_MAINNET: CCTPV2Relayer/script/Config.sol also declares USDC_MAINNET, but there it means
// ETHEREUM mainnet USDC (0xA0b86991...). Two identical names with different values across sibling Config files is a
// copy-paste accident waiting to happen, so this one carries the chain in its name.
address constant USDC_INJECTIVE = 0xa00C59fF5a080D2b954d0c75e46E22a0c371235a;

// Payment Contract (CCTPV2Relayer) address (WARNING: to be filled after deployment — placeholder)
// ⚠️ address(0) placeholder until the real CCTPV2Relayer is deployed on Injective mainnet.
//    A mainnet (1776) deploy reverts with ZeroAddress while this is unset — an intentional safeguard.
//    testnet (1439) deploys are unaffected (they use PAYMENT_CONTRACT_INJECTIVE_TESTNET).
address constant PAYMENT_CONTRACT_INJECTIVE = address(0);

// Relayer/Operator address
address constant OPERATOR_INJECTIVE = 0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3;

// Injective Testnet

// Chain ID
uint256 constant CHAIN_INJECTIVE_TESTNET = 1439;

// USDC address (Injective testnet USDC, from the monorepo CCTPV2Relayer/script/Config.sol)
address constant USDC_INJECTIVE_TESTNET = 0x0C382e685bbeeFE5d3d9C29e29E341fEE8E84C5d;

// Payment Contract (CCTPV2Relayer) address (WARNING: to be filled after deployment — placeholder)
address constant PAYMENT_CONTRACT_INJECTIVE_TESTNET = 0x364e4b2C10F9c3409C40289B98BfA5590603C804;

// Relayer/Operator address
address constant OPERATOR_INJECTIVE_TESTNET = 0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3;

// ─────────────────────────────────────────────────────────────────────────────
// Inbound (CCTP v2 receive → Injective IBC) config
// ─────────────────────────────────────────────────────────────────────────────

// CCTP v2 MessageTransmitter on Injective EVM (source: CCTPV2Relayer/script/Config.sol — confirmed).
// InboundForwarder calls transmitter.receiveMessage(message, attestation) to mint USDC.
address constant TRANSMITTER_INJECTIVE = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
address constant TRANSMITTER_INJECTIVE_TESTNET = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;

// Injective's CCTP domain (binding check: message.destinationDomain == this).
// Confirmed from cctp-integration-harness/internal/config/validate.go (InjectiveCCTPDomain = 29).
// CCTP domains identify the chain, not the network → same value for mainnet (1776) and testnet (1439).
uint32 constant INJECTIVE_CCTP_DOMAIN = 29;
