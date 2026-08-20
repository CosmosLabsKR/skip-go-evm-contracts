// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/**
 * @dev Minimal interface for delegating to the upstream CCTPV2Relayer (PaymentContract).
 *      Source: CCTPV2Relayer/src/interfaces/ICCTPV2Relayer.sol (locally copied for subproject self-containment,
 *      only the functions used for delegation).
 *
 *      Before calling, the caller (Forwarder) must approve this contract for USDC `transferAmount + feeAmount`
 *      (it is pulled internally via `usdc.safeTransferFrom(msg.sender, ...)`).
 *      CCTP v2 constraints: `feeAmount > 0`, `maxFee < transferAmount` (maxFee is deducted from the minted amount
 *      on the destination, not pulled here).
 */
interface ICCTPV2Relayer {
    /// @notice The USDC this relayer handles. Used by the Forwarder for the usdc-equality check (the real
    ///         CCTPV2Relayer exposes `IERC20 public usdc`).
    function usdc() external view returns (IERC20);

    /// @notice Default path with destinationCaller = bytes32(0) (any caller).
    function requestCCTPTransfer(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    /// @notice Path that explicitly restricts the destination receiver (destinationCaller).
    /// @dev Argument order matters: destinationCaller comes after minFinalityThreshold and before hookData.
    function requestCCTPTransferWithCaller(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external;
}
