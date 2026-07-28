// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

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

    /// @dev Must stay on EVERY entry point that moves this contract's USDC, not just the swap paths. `_executeSwap`
    ///      measures swap output as a balance delta across `router.call` and `swapCalldata` is caller-supplied, so an
    ///      aggregator-style router can be pointed back here — any unguarded balance move inside that window is
    ///      credited as swap output and bridged to the caller.
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
        __UUPSUpgradeable_init();
        __Ownable2Step_init();

        if (usdc_ == address(0)) revert ZeroAddress();
        if (messenger_ == address(0)) revert ZeroAddress();
        if (transmitter_ == address(0)) revert ZeroAddress();

        usdc = IERC20(usdc_);
        messenger = ITokenMessenger(messenger_);
        transmitter = IMessageTransmitter(transmitter_);

        _transferOwnership(msg.sender);
    }

    /// @notice Implementation revision behind this proxy; bump on every upgrade that changes behaviour.
    /// @dev Lets an operator confirm on-chain which implementation is live. `virtual` so the next impl overrides it.
    function version() external pure virtual returns (uint256) {
        return 1;
    }

    function setSwapRouter(address _swapRouter) external onlyOwner {
        if (_swapRouter == address(0)) revert ZeroAddress();

        address previousRouter = swapRouter;
        swapRouter = _swapRouter;

        emit SwapRouterUpdated(previousRouter, _swapRouter);
    }

    /// @notice Pays a relayer-service fee for an already-dispatched CCTP v2 message.
    /// @param messageHash keccak256 of the v2 message bytes (from the MessageSent event), computed off-chain.
    function makePaymentForRelay(bytes32 messageHash, uint256 paymentAmount) external nonReentrant {
        if (paymentAmount == 0) revert PaymentCannotBeZero();
        usdc.safeTransferFrom(msg.sender, address(this), paymentAmount);

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
    ) external nonReentrant {
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
    ) external nonReentrant {
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
    ///      trusted). `inputToken` may not be USDC. Leftover input is refunded to msg.sender; for ERC20 the router
    ///      allowance is always closed afterwards.
    function _executeSwap(address inputToken, uint256 inputAmount, bytes calldata swapCalldata)
        internal
        returns (uint256 outputAmount)
    {
        // Cache the storage reads used repeatedly below.
        IERC20 outputToken = usdc;
        address router = swapRouter;

        // The balance delta only measures the swap if the input cannot move the output balance itself: with
        // inputToken == usdc the caller's deposit would count as output AND be refunded as dust, draining the reserve.
        if (inputToken == address(outputToken)) revert InvalidInputToken();

        if (inputToken == address(0)) {
            // Native Token
            if (inputAmount != msg.value) revert InsufficientNativeToken();

            // Balance previous to the swap (subtract the value just received with this call).
            uint256 preInputBalance = address(this).balance - inputAmount;

            // Snapshot the output balance immediately before the swap, so the delta below covers the swap only.
            uint256 preOutputBalance = outputToken.balanceOf(address(this));

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

            // Balance previous to the swap: pre-existing holdings only, so `dust` below is the unconsumed
            // part of `inputAmount` and never touches tokens the contract already held.
            uint256 preInputBalance = token.balanceOf(address(this));

            // Transfer input ERC20 tokens to the contract
            token.safeTransferFrom(msg.sender, address(this), inputAmount);

            // Approve the swap router to spend the input tokens
            token.forceApprove(router, inputAmount);

            // Snapshot the output balance after the input has been pulled in and immediately before the swap,
            // so the delta below covers the swap only and never the caller's own deposit.
            uint256 preOutputBalance = outputToken.balanceOf(address(this));

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
            }

            // Always close the router allowance: `dust` is a balance delta and says nothing about how much allowance
            // the router consumed. A router sourcing the input elsewhere (Permit2, own inventory) can leave dust == 0
            // with the approval still standing, and `swapCalldata` is caller-supplied — close it rather than infer.
            token.forceApprove(router, 0);
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

    /// @dev `calldata` (not `memory`) so the blobs are read in place rather than memcopied on entry and again per
    ///      iteration. Same selector, so the external ABI is unchanged.
    function batchReceiveMessage(ICCTPV2Relayer.ReceiveCall[] calldata receiveCalls) external nonReentrant {
        uint256 length = receiveCalls.length;

        for (uint256 i; i < length; ++i) {
            bytes calldata message = receiveCalls[i].message;
            bytes calldata attestation = receiveCalls[i].attestation;

            // Only a `false` return is tolerated and skipped. A transmitter revert (replayed nonce, bad attestation)
            // still reverts the whole batch — wrap in try/catch if per-item isolation is ever needed.
            if (!transmitter.receiveMessage(message, attestation)) {
                emit FailedReceiveMessage(message, attestation);
            }
        }
    }

    function withdraw(address receiver, uint256 amount) external onlyOwner nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        if (usdc.balanceOf(address(this)) < amount) revert MissingBalance();

        usdc.safeTransfer(receiver, amount);

        emit Withdrawn(receiver, amount);
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

    /// @dev Required by the native swap path: the router refunds unspent ETH here and `_executeSwap` accounts for it
    ///      as dust. Do not drop it alongside `fallback()` — native swaps with a refund would revert.
    receive() external payable {}

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
