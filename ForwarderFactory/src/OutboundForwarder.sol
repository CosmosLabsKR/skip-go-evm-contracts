// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {ICCTPV2Relayer} from "./interfaces/ICCTPV2Relayer.sol";
import {IOutboundForwarder} from "./interfaces/IOutboundForwarder.sol";

/**
 * @title OutboundForwarder
 * @notice Per-route fund conduit (logic impl behind a BeaconProxy), bound to (sender, destinationDomain,
 *         mintRecipient). Delegates held USDC to the PaymentContract (CCTPV2Relayer) over that fixed route;
 *         the operator supplies maxFee/minFinalityThreshold/hookData (+destinationCaller) per call.
 * @dev config (usdc/paymentContract/operator) is impl immutable and shared by all instances (rotated in bulk via a
 *      beacon upgrade). Per-route values live in proxy storage. All entry points are operator-only and non-reentrant.
 */
contract OutboundForwarder is IOutboundForwarder, Initializable {
    using SafeERC20 for IERC20;

    // ── config (impl immutable, shared by all instances; injected by Deployment) ──
    IERC20 public immutable usdc;
    ICCTPV2Relayer public immutable paymentContract;
    /// @notice Authorized caller. To rotate, deploy a new impl and apply it in bulk via beacon.upgradeTo.
    address public immutable operator;

    // ── per-route (proxy storage) ──
    /// @notice Route identifier and fund owner / recovery recipient.
    address public sender;
    uint32 public destinationDomain;
    // Intentionally `bool`, not InboundForwarder's uint256 1/2 pattern: it packs into slot 0 alongside sender +
    // destinationDomain. Widening it would claim its own slot and shift the layout — forbidden under the beacon
    // upgrade model, since every deployed proxy already holds this layout.
    bool private _reentrant;
    bytes32 public mintRecipient;

    // append-only: add new state variables before __gap and shrink __gap (never prepend). 2 slots used above.
    uint256[48] private __gap;

    modifier nonReentrant() {
        if (_reentrant) revert Reentrancy();
        _reentrant = true;
        _;
        _reentrant = false;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address usdc_, address paymentContract_, address operator_) {
        if (usdc_ == address(0) || paymentContract_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        // Enforce usdc == paymentContract.usdc == burnToken at deploy time (blocks an immutable+beacon mismatch).
        if (address(ICCTPV2Relayer(paymentContract_).usdc()) != usdc_) revert UsdcMismatch();
        usdc = IERC20(usdc_);
        paymentContract = ICCTPV2Relayer(paymentContract_);
        operator = operator_;
        _disableInitializers();
    }

    /// @notice Called once by the factory right after deployment to inject the identity values.
    function initialize(address _sender, uint32 _destinationDomain, bytes32 _mintRecipient) external initializer {
        if (_sender == address(0)) revert ZeroAddress();
        if (_mintRecipient == bytes32(0)) revert ZeroAddress();
        sender = _sender;
        destinationDomain = _destinationDomain;
        mintRecipient = _mintRecipient;
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    /// @dev Shared by both transfer entry points: v2 validity checks + approval to the PaymentContract.
    ///      maxFee is excluded from the approval — it is deducted from the minted amount on the destination, not pulled here.
    function _prepare(uint256 transferAmount, uint256 feeAmount, uint256 maxFee, uint32 minFinalityThreshold) internal {
        if (transferAmount == 0) revert ZeroAmount();
        if (feeAmount == 0) revert ZeroFee();
        if (maxFee >= transferAmount) revert InvalidMaxFee();
        // CCTP v2 accepts only 1000 (fast/soft) or 2000 (standard/hard).
        if (minFinalityThreshold != 1000 && minFinalityThreshold != 2000) revert InvalidFinalityThreshold();
        usdc.forceApprove(address(paymentContract), transferAmount + feeAmount);
    }

    /// @notice Send held USDC over the fixed route via CCTP v2. destinationCaller = any.
    function requestTransfer(
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external onlyOperator nonReentrant {
        _prepare(transferAmount, feeAmount, maxFee, minFinalityThreshold);
        paymentContract.requestCCTPTransfer(
            transferAmount,
            destinationDomain,
            mintRecipient,
            address(usdc),
            feeAmount,
            maxFee,
            minFinalityThreshold,
            hookData
        );
        emit TransferRequested(transferAmount, feeAmount, maxFee, minFinalityThreshold, bytes32(0));
    }

    /// @notice Same as above but restricts who may call receiveMessage on the destination (destinationCaller).
    function requestTransferWithCaller(
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external onlyOperator nonReentrant {
        _prepare(transferAmount, feeAmount, maxFee, minFinalityThreshold);
        paymentContract.requestCCTPTransferWithCaller(
            transferAmount,
            destinationDomain,
            mintRecipient,
            address(usdc),
            feeAmount,
            maxFee,
            minFinalityThreshold,
            destinationCaller,
            hookData
        );
        emit TransferRequested(transferAmount, feeAmount, maxFee, minFinalityThreshold, destinationCaller);
    }

    /// @notice Escape hatch — recover the entire `token` balance to sender.
    function recoverERC20(address token) external onlyOperator nonReentrant {
        _recover(token, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Partial recovery to sender. An amount exceeding the balance reverts inside safeTransfer.
    function recoverERC20(address token, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _recover(token, amount);
    }

    /// @dev Shared recovery core — prevents drift between the two entry points.
    function _recover(address token, uint256 amount) private {
        IERC20(token).safeTransfer(sender, amount);
        emit Recovered(token, amount);
    }

    /// @notice Reject direct native transfers; this forwarder only accepts ERC20 deposits.
    receive() external payable {
        revert NativeNotAccepted();
    }

    fallback() external payable {
        revert NativeNotAccepted();
    }
}
