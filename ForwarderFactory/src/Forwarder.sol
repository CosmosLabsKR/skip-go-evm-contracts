// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {ICCTPV2Relayer} from "./interfaces/ICCTPV2Relayer.sol";

/**
 * @title Forwarder
 * @notice Per-route fund conduit (logic impl behind a BeaconProxy), bound to (sender, destinationDomain, mintRecipient).
 *         - requestTransfer / requestTransferWithCaller: delegate held USDC to the PaymentContract (CCTPV2Relayer)
 *           via requestCCTPTransfer / requestCCTPTransferWithCaller (operator-only, fixed route).
 *           maxFee/minFinalityThreshold/hookData (+destinationCaller) are supplied by the operator per call.
 *         - recoverERC20/recoverNative: sender-only escape hatch (sender = fund owner / recovery authority).
 * @dev config (usdc/paymentContract/operator) is impl immutable and shared by all instances (changed in bulk via
 *      a beacon upgrade). Per-instance values live in proxy storage. The reentrancy guard reuses the simple bool
 *      pattern from CCTPRelayer.
 */
contract Forwarder is Initializable {
    using SafeERC20 for IERC20;

    // ── config (impl immutable, shared by all instances; injected by Deployment) ──
    IERC20 public immutable usdc;
    ICCTPV2Relayer public immutable paymentContract;
    /// @notice Address authorized to call requestTransfer (relayer/operator). To rotate, deploy a new impl and apply
    ///         it in bulk via beacon.upgradeTo.
    address public immutable operator;

    // ── per-instance (proxy storage) ──
    /// @notice Route identifier and fund owner / recovery authority (merged the former recover role). Authorizes
    ///         recoverERC20/Native.
    address public sender;
    uint32 public destinationDomain;
    bool private _reentrant;
    bytes32 public mintRecipient;

    // Storage reserved for future beacon upgrades (append-only). sender/domain/_reentrant pack + mintRecipient → 2 slots used.
    uint256[48] private __gap;

    error ZeroAddress();
    error UsdcMismatch(); // paymentContract.usdc() != usdc (blocks deploying a mismatched impl)
    error NotSender();
    error NotOperator();
    error ZeroAmount();
    error ZeroFee(); // CCTP v2 disallows feeAmount == 0
    error InvalidMaxFee(); // CCTP v2 requires maxFee < transferAmount
    error InvalidFinalityThreshold(); // minFinalityThreshold must be 1000 (fast) or 2000 (standard)
    error Reentrancy();
    error NativeSendFailed();

    event TransferRequested(
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    );
    event Recovered(address indexed token, uint256 amount); // token == address(0) means native

    modifier nonReentrant() {
        if (_reentrant) revert Reentrancy();
        _reentrant = true;
        _;
        _reentrant = false;
    }

    modifier onlySender() {
        if (msg.sender != sender) revert NotSender();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address usdc_, address paymentContract_, address operator_) {
        if (usdc_ == address(0) || paymentContract_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        // Enforce the Forwarder.usdc == paymentContract.usdc == burnToken invariant at deploy time
        // (blocks an immutable+beacon mismatch).
        if (address(ICCTPV2Relayer(paymentContract_).usdc()) != usdc_) revert UsdcMismatch();
        usdc = IERC20(usdc_);
        paymentContract = ICCTPV2Relayer(paymentContract_);
        operator = operator_;
        _disableInitializers();
    }

    /// @notice Called once by the factory right after deployment to inject the identity values.
    function initialize(address _sender, uint32 _destinationDomain, bytes32 _mintRecipient) external initializer {
        sender = _sender;
        destinationDomain = _destinationDomain;
        mintRecipient = _mintRecipient;
    }

    /// @dev Shared by both transfer functions: v2 validity checks + forceApprove to the PaymentContract.
    ///      maxFee is not included in the approval (it is deducted from the minted amount on the destination, not pulled here).
    function _prepare(uint256 transferAmount, uint256 feeAmount, uint256 maxFee, uint32 minFinalityThreshold) internal {
        if (transferAmount == 0) revert ZeroAmount();
        if (feeAmount == 0) revert ZeroFee();
        if (maxFee >= transferAmount) revert InvalidMaxFee();
        // Only CCTP v2 standard finality values are allowed: 1000 (fast/soft) or 2000 (standard/hard).
        if (minFinalityThreshold != 1000 && minFinalityThreshold != 2000) revert InvalidFinalityThreshold();
        usdc.forceApprove(address(paymentContract), transferAmount + feeAmount);
    }

    /// @notice Send held USDC over the fixed route (destinationDomain/mintRecipient) via CCTP v2. destinationCaller = any. Operator-only.
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

    /// @notice Same as above but restricts the destination receiver (destinationCaller). Operator-only.
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

    /// @notice sender-only escape hatch — recover the entire ERC20 balance.
    function recoverERC20(address token) external onlySender nonReentrant {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(sender, bal);
        emit Recovered(token, bal);
    }

    /// @notice sender-only escape hatch — recover the entire native balance.
    function recoverNative() external onlySender nonReentrant {
        uint256 bal = address(this).balance;
        (bool ok,) = sender.call{value: bal}("");
        if (!ok) revert NativeSendFailed();
        emit Recovered(address(0), bal);
    }

    receive() external payable {}
}
