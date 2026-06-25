// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {ICCTPV2Relayer} from "./interfaces/ICCTPV2Relayer.sol";

/**
 * @title OutboundForwarder
 * @notice Per-route fund conduit (logic impl behind a BeaconProxy), bound to (sender, destinationDomain, mintRecipient).
 *         - requestTransfer / requestTransferWithCaller: delegate held USDC to the PaymentContract (CCTPV2Relayer)
 *           via requestCCTPTransfer / requestCCTPTransferWithCaller (operator-only, fixed route).
 *           maxFee/minFinalityThreshold/hookData (+destinationCaller) are supplied by the operator per call.
 *         - recoverERC20: operator-only escape hatch (operator authority).
 * @dev config (usdc/paymentContract/operator) is impl immutable and shared by all instances (changed in bulk via
 *      a beacon upgrade). Per-instance values live in proxy storage. The reentrancy guard reuses the simple bool
 *      pattern from CCTPRelayer.
 */
contract OutboundForwarder is Initializable {
    using SafeERC20 for IERC20;

    // ── config (impl immutable, shared by all instances; injected by Deployment) ──
    IERC20 public immutable usdc;
    ICCTPV2Relayer public immutable paymentContract;
    /// @notice Address authorized to call requestTransfer (relayer/operator). To rotate, deploy a new impl and apply
    ///         it in bulk via beacon.upgradeTo.
    address public immutable operator;

    // ── per-instance (proxy storage) ──
    /// @notice Route identifier and fund owner / recovery recipient.
    address public sender;
    uint32 public destinationDomain;
    // Intentionally `bool` (not the uint256 1/2 pattern InboundForwarder uses): it packs into slot 0 alongside
    // sender + destinationDomain. Widening to uint256 would unpack it into its own slot and shift the proxy storage
    // layout — forbidden under the Beacon upgrade model. Keep as bool.
    bool private _reentrant;
    bytes32 public mintRecipient;

    // Storage reserved for future beacon upgrades (append-only). sender/domain/_reentrant pack + mintRecipient → 2 slots used.
    uint256[48] private __gap;

    error ZeroAddress();
    error UsdcMismatch(); // paymentContract.usdc() != usdc (blocks deploying a mismatched impl)
    error NotOperator();
    error ZeroAmount();
    error ZeroFee(); // CCTP v2 disallows feeAmount == 0
    error InvalidMaxFee(); // CCTP v2 requires maxFee < transferAmount
    error InvalidFinalityThreshold(); // minFinalityThreshold must be 1000 (fast) or 2000 (standard)
    error Reentrancy();
    error NativeNotAccepted();

    event TransferRequested(
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    );
    event Recovered(address indexed token, uint256 amount);

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
        // Enforce the OutboundForwarder.usdc == paymentContract.usdc == burnToken invariant at deploy time
        // (blocks an immutable+beacon mismatch).
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

    /// @notice operator-only escape hatch — recover the entire ERC20 balance to sender (default when no amount given).
    function recoverERC20(address token) external onlyOperator nonReentrant {
        _recover(token, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Recover a specific `amount` of `token` to sender (partial). amount==0 reverts ZeroAmount; an amount
    ///         exceeding the balance reverts inside safeTransfer.
    function recoverERC20(address token, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _recover(token, amount);
    }

    /// @dev Shared recovery core: transfer to sender + emit Recovered.
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
