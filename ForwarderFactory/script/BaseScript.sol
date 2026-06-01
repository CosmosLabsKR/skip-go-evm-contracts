// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./Config.sol";
import {Forwarder} from "../src/Forwarder.sol";

/**
 * @notice Deploy guard supporting only the two Injective EVM chains (mainnet 1776 / testnet 1439).
 * @dev ForwarderFactory has no external dependency addresses, so this is purely a chainid guard.
 */
contract BaseScript is Script {
    address public immutable usdc;
    address public immutable paymentContract;
    address public immutable operator;

    constructor() {
        if (block.chainid == CHAIN_INJECTIVE) {
            usdc = USDC_MAINNET;
            paymentContract = PAYMENT_CONTRACT_INJECTIVE;
            operator = OPERATOR_INJECTIVE;
        } else if (block.chainid == CHAIN_INJECTIVE_TESTNET) {
            usdc = USDC_INJECTIVE_TESTNET;
            paymentContract = PAYMENT_CONTRACT_INJECTIVE_TESTNET;
            operator = OPERATOR_INJECTIVE_TESTNET;
        } else {
            revert("Chain not supported.");
        }
    }

    /// @dev Deploy a new Forwarder beacon impl from USDC/PAYMENT_CONTRACT/OPERATOR.
    ///      Call within a broadcast context. (Shared by Deployment / UpgradeForwarder)
    function _deployForwarderImpl() internal returns (Forwarder) {
        return new Forwarder(usdc, paymentContract, operator);
    }
}
