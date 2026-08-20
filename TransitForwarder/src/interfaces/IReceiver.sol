// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Minimal interface for the CCTP **v1** MessageTransmitter receive path — this subproject's mint leg.
 *      `receiveMessage` validates the message header + attestation, enforces nonce replay protection, enforces
 *      destinationCaller, and mints to the burn message's mintRecipient.
 *
 *      The signature is identical in v1 and v2, so this file looks like its v2 siblings; the difference is entirely
 *      in WHICH contract it is pointed at (TransitExecutor.transmitter, a v1 MessageTransmitter) and in the message
 *      layout that comes back (CCTPV1Message, not the siblings' v2 parser). That is why it is no longer part of the
 *      frozen-copy set — see the Makefile's check-transit-copies.
 */
interface IReceiver {
    function receiveMessage(bytes calldata message, bytes calldata signature) external returns (bool success);
}
