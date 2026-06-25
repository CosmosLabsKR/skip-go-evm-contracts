// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";

import {ICCTPV2Relayer} from "./interfaces/ICCTPV2Relayer.sol";
import {ITokenMessenger} from "./interfaces/ITokenMessenger.sol";
import {IMessageTransmitter} from "./interfaces/IMessageTransmitter.sol";

import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract CCTPV2Relayer is ICCTPV2Relayer, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    ITokenMessenger public messenger;
    IMessageTransmitter public transmitter;
    address public swapRouter;
    bool internal reentrant;

    /// @dev The only CCTP v2 finality thresholds accepted by depositForBurn: fast/soft (1000) and standard/hard (2000).
    uint32 internal constant FINALITY_FAST = 1000;
    uint32 internal constant FINALITY_STANDARD = 2000;

    modifier nonReentrant() {
        if (reentrant) revert Reentrancy();
        reentrant = true;
        _;
        reentrant = false;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address usdc_, address messenger_, address transmitter_) external initializer {
        __Ownable2Step_init();

        if (usdc_ == address(0)) revert ZeroAddress();
        if (messenger_ == address(0)) revert ZeroAddress();
        if (transmitter_ == address(0)) revert ZeroAddress();

        usdc = IERC20(usdc_);
        messenger = ITokenMessenger(messenger_);
        transmitter = IMessageTransmitter(transmitter_);

        _transferOwnership(msg.sender);
    }

    function setSwapRouter(address _swapRouter) external onlyOwner {
        if (_swapRouter == address(0)) revert ZeroAddress();

        swapRouter = _swapRouter;
    }

    /// @notice Pays a relayer-service fee for an already-dispatched CCTP v2 message.
    /// @param messageHash keccak256 of the v2 message bytes (from the MessageSent event), computed off-chain.
    function makePaymentForRelay(bytes32 messageHash, uint256 paymentAmount) external {
        if (paymentAmount == 0) revert PaymentCannotBeZero();
        // Transfer the funds from the user into the contract.
        usdc.safeTransferFrom(msg.sender, address(this), paymentAmount);

        // If the transfer succeeds, emit the payment event.
        emit PaymentForRelay(msg.sender, messageHash, paymentAmount);
    }

    function requestCCTPTransfer(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        // destinationCaller = bytes32(0) => any caller may receive.
        _requestForward(
            transferAmount,
            destinationDomain,
            mintRecipient,
            burnToken,
            feeAmount,
            maxFee,
            minFinalityThreshold,
            bytes32(0),
            hookData
        );
    }

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
    ) external {
        _requestForward(
            transferAmount,
            destinationDomain,
            mintRecipient,
            burnToken,
            feeAmount,
            maxFee,
            minFinalityThreshold,
            destinationCaller,
            hookData
        );
    }

    /// @dev Shared core for both request* entry points: validate, pull (transfer + fee) once, approve the messenger
    ///      for the transfer amount only, depositForBurn (v2), and emit. `destinationCaller` is the sole variable.
    function _requestForward(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) internal {
        if (transferAmount == 0) revert PaymentCannotBeZero();
        if (feeAmount == 0) revert PaymentCannotBeZero();
        // CCTP v2 requires maxFee < amount (the fee is taken from the minted amount on the destination).
        if (maxFee >= transferAmount) revert InvalidMaxFee();
        // In order to save gas do the transfer only once, of both transfer amount and fee amount.
        // Note: maxFee is NOT pulled here; it is deducted from the burned amount on the destination domain.
        usdc.safeTransferFrom(msg.sender, address(this), transferAmount + feeAmount);

        // Only give allowance of the transfer amount, as we want the fee amount to stay in the contract.
        usdc.forceApprove(address(messenger), transferAmount);

        _depositForBurn(
            transferAmount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            maxFee,
            minFinalityThreshold,
            hookData
        );

        // v2 has no synchronous nonce; the off-chain relayer correlates via MessageSent in this tx.
        emit PaymentForRelay(msg.sender, bytes32(0), feeAmount);
    }

    function swapAndRequestCCTPTransfer(
        address inputToken,
        uint256 inputAmount,
        bytes calldata swapCalldata,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external payable nonReentrant {
        // destinationCaller = bytes32(0) => any caller may receive.
        _swapAndForward(
            inputToken,
            inputAmount,
            swapCalldata,
            destinationDomain,
            mintRecipient,
            burnToken,
            feeAmount,
            maxFee,
            minFinalityThreshold,
            bytes32(0),
            hookData
        );
    }

    function swapAndRequestCCTPTransferWithCaller(
        address inputToken,
        uint256 inputAmount,
        bytes calldata swapCalldata,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external payable nonReentrant {
        _swapAndForward(
            inputToken,
            inputAmount,
            swapCalldata,
            destinationDomain,
            mintRecipient,
            burnToken,
            feeAmount,
            maxFee,
            minFinalityThreshold,
            destinationCaller,
            hookData
        );
    }

    /// @dev Swaps `inputAmount` of `inputToken` (native when address(0), else ERC20) into USDC via swapRouter and
    ///      returns the USDC output, measured as the contract's USDC balance delta (the router's return value is not
    ///      trusted). Any leftover input (dust) is refunded to msg.sender; for ERC20 the router allowance is revoked.
    function _executeSwap(address inputToken, uint256 inputAmount, bytes calldata swapCalldata)
        internal
        returns (uint256 outputAmount)
    {
        // Cache storage reads (usdc/swapRouter) to locals: each is read twice below, so this saves an SLOAD per swap.
        IERC20 outputToken = usdc;
        address router = swapRouter;
        uint256 preOutputBalance = outputToken.balanceOf(address(this));

        if (inputToken == address(0)) {
            // Native Token
            if (inputAmount != msg.value) revert InsufficientNativeToken();

            // Balance previous to the swap (subtract the value just received with this call).
            uint256 preInputBalance = address(this).balance - inputAmount;

            // Call the swap router and perform the swap
            (bool success,) = router.call{value: inputAmount}(swapCalldata);
            if (!success) revert SwapFailed();

            // Check that the contract's USDC balance has increased
            uint256 postOutputBalance = outputToken.balanceOf(address(this));
            if (preOutputBalance >= postOutputBalance) revert InsufficientSwapOutput();
            outputAmount = postOutputBalance - preOutputBalance;

            // Refund the remaining ETH
            uint256 dust = address(this).balance - preInputBalance;
            if (dust != 0) {
                (bool ethSuccess,) = msg.sender.call{value: dust}("");
                if (!ethSuccess) revert ETHSendFailed();
            }
        } else {
            IERC20 token = IERC20(inputToken);

            // Balance previous to the swap
            uint256 preInputBalance = token.balanceOf(address(this));

            // Transfer input ERC20 tokens to the contract
            token.safeTransferFrom(msg.sender, address(this), inputAmount);

            // Approve the swap router to spend the input tokens
            token.forceApprove(router, inputAmount);

            // Call the swap router and perform the swap
            (bool success,) = router.call(swapCalldata);
            if (!success) revert SwapFailed();

            // Check that the contract's USDC balance has increased
            uint256 postOutputBalance = outputToken.balanceOf(address(this));
            if (preOutputBalance >= postOutputBalance) revert InsufficientSwapOutput();
            outputAmount = postOutputBalance - preOutputBalance;

            // Refund the remaining input amount
            uint256 dust = token.balanceOf(address(this)) - preInputBalance;
            if (dust != 0) {
                token.safeTransfer(msg.sender, dust);

                // Revoke Approval
                token.forceApprove(router, 0);
            }
        }
    }

    /// @dev Shared core for both swap entry points: validate inputs, swap to USDC, deduct the fee, approve the
    ///      messenger for the transfer amount only, depositForBurn (v2), and emit. `destinationCaller` is the sole
    ///      variable between the two callers.
    function _swapAndForward(
        address inputToken,
        uint256 inputAmount,
        bytes calldata swapCalldata,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) internal {
        if (inputAmount == 0) revert PaymentCannotBeZero();
        if (feeAmount == 0) revert PaymentCannotBeZero();

        uint256 outputAmount = _executeSwap(inputToken, inputAmount, swapCalldata);

        // Check that output amount is enough to cover the fee
        if (outputAmount <= feeAmount) revert InsufficientSwapOutput();
        uint256 transferAmount = outputAmount - feeAmount;
        if (maxFee >= transferAmount) revert InvalidMaxFee();

        // Only give allowance of the transfer amount, as we want the fee amount to stay in the contract.
        usdc.forceApprove(address(messenger), transferAmount);

        _depositForBurn(
            transferAmount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            maxFee,
            minFinalityThreshold,
            hookData
        );

        // v2 has no synchronous nonce; the off-chain relayer correlates via MessageSent in this tx.
        emit PaymentForRelay(msg.sender, bytes32(0), feeAmount);
    }

    function batchReceiveMessage(ICCTPV2Relayer.ReceiveCall[] memory receiveCalls) external {
        // Save gas by not retrieving the length on each loop.
        uint256 length = receiveCalls.length;

        for (uint256 i; i < length;) {
            // Save the message and the attestation.
            bytes memory message = receiveCalls[i].message;
            bytes memory attestation = receiveCalls[i].attestation;

            // Call the transmitter, if fails, emit the event, otherwise skip to the next pair in the array.
            if (!transmitter.receiveMessage(message, attestation)) {
                emit FailedReceiveMessage(message, attestation);
            }

            unchecked {
                ++i;
            }
        }
    }

    function withdraw(address receiver, uint256 amount) external onlyOwner {
        // Check that the contract has enough balance.
        if (usdc.balanceOf(address(this)) < amount) revert MissingBalance();

        // Transfer the amount to the receiver.
        usdc.safeTransfer(receiver, amount);
    }

    /// @dev Routes the burn to the CCTP v2 messenger: when `hookData` is non-empty it uses
    /// `depositForBurnWithHook` (forwarding the hook to the destination), otherwise the plain
    /// `depositForBurn`. Both v2 calls return nothing.
    function _depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) internal {
        // Only CCTP v2 standard finality values are allowed: 1000 (fast/soft) or 2000 (standard/hard).
        if (minFinalityThreshold != FINALITY_FAST && minFinalityThreshold != FINALITY_STANDARD) {
            revert InvalidFinalityThreshold();
        }
        if (hookData.length > 0) {
            messenger.depositForBurnWithHook(
                amount,
                destinationDomain,
                mintRecipient,
                burnToken,
                destinationCaller,
                maxFee,
                minFinalityThreshold,
                hookData
            );
        } else {
            messenger.depositForBurn(
                amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold
            );
        }
    }

    fallback() external payable {}

    receive() external payable {}

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
