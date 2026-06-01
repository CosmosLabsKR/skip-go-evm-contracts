// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

// Address constants are declared as `address` because BaseScript uses them as addresses.
// WARNING: PAYMENT_CONTRACT_* are placeholders (address(0)) — replace with real addresses after CCTPV2Relayer is deployed.
//    If a deploy script runs while they are address(0), the Forwarder constructor reverts with ZeroAddress (unset-value safeguard).

// Injective EVM (Mainnet)

// Chain ID
uint256 constant CHAIN_INJECTIVE = 1776;

// USDC address (Injective mainnet USDC — confirmed)
address constant USDC_MAINNET = 0xa00C59fF5a080D2b954d0c75e46E22a0c371235a;

// Payment Contract (CCTPV2Relayer) address (WARNING: to be filled after deployment — placeholder)
address constant PAYMENT_CONTRACT_INJECTIVE = address(0);

// Relayer/Operator address
address constant OPERATOR_INJECTIVE = 0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3;

// Injective Testnet

// Chain ID
uint256 constant CHAIN_INJECTIVE_TESTNET = 1439;

// USDC address (Injective testnet USDC, from the monorepo CCTPV2Relayer/script/Config.sol)
address constant USDC_INJECTIVE_TESTNET = 0x0C382e685bbeeFE5d3d9C29e29E341fEE8E84C5d;

// Payment Contract (CCTPV2Relayer) address (WARNING: to be filled after deployment — placeholder)
address constant PAYMENT_CONTRACT_INJECTIVE_TESTNET = address(0);

// Relayer/Operator address
address constant OPERATOR_INJECTIVE_TESTNET = 0xd706c3F4aD08F695ddC8a301a6a63B263a0A3Ac3;
