// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./Config.sol";
import {OutboundForwarder} from "../src/OutboundForwarder.sol";
import {InboundForwarder} from "../src/InboundForwarder.sol";

/**
 * @notice Deploy guard supporting only the two Injective EVM chains (mainnet 1776 / testnet 1439).
 * @dev Resolves every per-chain dependency address for both the outbound and inbound forwarders.
 *      INJECTIVE_CCTP_DOMAIN (29) identifies the chain, so it is shared across mainnet/testnet.
 */
contract BaseScript is Script {
    // outbound deps
    address public immutable usdc;
    address public immutable paymentContract;
    address public immutable operator;
    // inbound deps
    address public immutable transmitter; // CCTP v2 MessageTransmitter (receiveMessage)

    constructor() {
        if (block.chainid == CHAIN_INJECTIVE) {
            usdc = USDC_MAINNET;
            paymentContract = PAYMENT_CONTRACT_INJECTIVE;
            operator = OPERATOR_INJECTIVE;
            transmitter = TRANSMITTER_INJECTIVE;
        } else if (block.chainid == CHAIN_INJECTIVE_TESTNET) {
            usdc = USDC_INJECTIVE_TESTNET;
            paymentContract = PAYMENT_CONTRACT_INJECTIVE_TESTNET;
            operator = OPERATOR_INJECTIVE_TESTNET;
            transmitter = TRANSMITTER_INJECTIVE_TESTNET;
        } else {
            revert("Chain not supported.");
        }
    }

    /// @dev Deploy a new OutboundForwarder beacon impl from USDC/PAYMENT_CONTRACT/OPERATOR.
    ///      Call within a broadcast context. (Shared by Deployment / UpgradeOutboundForwarder)
    function _deployOutboundForwarderImpl() internal returns (OutboundForwarder) {
        return new OutboundForwarder(usdc, paymentContract, operator);
    }

    /// @dev Deploy a new InboundForwarder beacon impl from USDC/TRANSMITTER/OPERATOR/INJECTIVE_CCTP_DOMAIN.
    ///      Call within a broadcast context. (Used by InboundDeployment; reusable by a future inbound upgrade script.)
    function _deployInboundForwarderImpl() internal returns (InboundForwarder) {
        return new InboundForwarder(usdc, transmitter, operator, INJECTIVE_CCTP_DOMAIN);
    }
}
