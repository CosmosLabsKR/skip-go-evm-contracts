// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the OutboundForwarder: a per-route conduit that delegates its held USDC to the
 *      PaymentContract (CCTPV2Relayer) over a fixed route (destinationDomain, mintRecipient).
 */
interface IOutboundForwarder {
    // ── Errors ──
    error ZeroAddress();
    error UsdcMismatch(); // paymentContract.usdc() != usdc (blocks deploying a mismatched impl)
    error NotOperator();
    error ZeroAmount();
    error ZeroFee(); // CCTP v2 disallows feeAmount == 0
    error InvalidMaxFee(); // CCTP v2 requires maxFee < transferAmount
    error InvalidFinalityThreshold(); // must be 1000 (fast) or 2000 (standard)
    error Reentrancy();
    error NativeNotAccepted();

    // ── Events ──
    event TransferRequested(
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    );
    event Recovered(address indexed token, uint256 amount);

    // ── State-changing (operator-only) ──
    function requestTransfer(
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    function requestTransferWithCaller(
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external;

    function recoverERC20(address token) external;
    function recoverERC20(address token, uint256 amount) external;

    // ── Views ──
    function sender() external view returns (address);
    function destinationDomain() external view returns (uint32);
    function mintRecipient() external view returns (bytes32);
}
