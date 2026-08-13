// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Minimal interface for the CCTP v2 MessageTransmitter receive path (locally copied for subproject
 *      self-containment — mirrors CCTPV2Relayer/src/interfaces/IReceiver.sol, only the function used here).
 *      `receiveMessage` validates the message header + attestation, enforces nonce replay protection, and
 *      mints to the burn message's mintRecipient.
 */
interface IReceiver {
    function receiveMessage(bytes calldata message, bytes calldata signature) external returns (bool success);
}
