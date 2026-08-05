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
    ///      measures output as a balance delta across `router.call`, and `swapCalldata` is caller-supplied, so an
    ///      aggregator-style router can be pointed back here — any unguarded balance move inside that window would be
    ///      credited as swap output and bridged to the caller.
    ///
    ///      Related standing invariant: this contract must never be a CCTP mintRecipient. Anyone can name it as one
    ///      (via requestCCTPTransfer, or by calling Circle's TokenMessenger directly), and USDC minted inside the
    ///      window would land in the same delta. No flow mints here today; adding one would break that accounting.
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

    /// @dev Shared core for both request* entry points; `destinationCaller` is the sole variable between them.
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
        // CCTP v2 requires maxFee < amount (it is deducted from the minted amount on the destination).
        if (maxFee >= transferAmount) revert InvalidMaxFee();
        // Single transfer of both amounts to save gas. maxFee is NOT pulled — the destination domain takes it.
        usdc.safeTransferFrom(msg.sender, address(this), transferAmount + feeAmount);

        // Approve the transfer amount only, so the fee stays in this contract.
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
    ///      returns the output measured as this contract's USDC balance delta — the router's return value is not
    ///      trusted. Leftover input is refunded to msg.sender.
    function _executeSwap(address inputToken, uint256 inputAmount, bytes calldata swapCalldata)
        internal
        returns (uint256 outputAmount)
    {
        IERC20 outputToken = usdc;
        address router = swapRouter;

        // The delta only measures the swap if the input cannot move the output balance itself: with
        // inputToken == usdc the caller's deposit would count as output AND be refunded as dust, draining the reserve.
        if (inputToken == address(outputToken)) revert InvalidInputToken();

        if (inputToken == address(0)) {
            if (inputAmount != msg.value) revert InsufficientNativeToken();

            // Pre-existing holdings only (subtract the value just received), so `dust` below is the unconsumed part
            // of `inputAmount` and never touches ETH the contract already held.
            uint256 preInputBalance = address(this).balance - inputAmount;
            uint256 preOutputBalance = outputToken.balanceOf(address(this));

            (bool success,) = router.call{value: inputAmount}(swapCalldata);
            if (!success) revert SwapFailed();

            uint256 postOutputBalance = outputToken.balanceOf(address(this));
            if (preOutputBalance >= postOutputBalance) revert InsufficientSwapOutput();
            outputAmount = postOutputBalance - preOutputBalance;

            uint256 dust = address(this).balance - preInputBalance;
            if (dust != 0) {
                (bool ethSuccess,) = msg.sender.call{value: dust}("");
                if (!ethSuccess) revert ETHSendFailed();
            }
        } else {
            IERC20 token = IERC20(inputToken);

            // Pre-existing holdings only — see the native branch.
            uint256 preInputBalance = token.balanceOf(address(this));

            token.safeTransferFrom(msg.sender, address(this), inputAmount);
            token.forceApprove(router, inputAmount);

            // Snapshotted AFTER the input is pulled in and immediately before the swap, so the delta covers the swap
            // only and never the caller's own deposit.
            uint256 preOutputBalance = outputToken.balanceOf(address(this));

            (bool success,) = router.call(swapCalldata);
            if (!success) revert SwapFailed();

            uint256 postOutputBalance = outputToken.balanceOf(address(this));
            if (preOutputBalance >= postOutputBalance) revert InsufficientSwapOutput();
            outputAmount = postOutputBalance - preOutputBalance;

            uint256 dust = token.balanceOf(address(this)) - preInputBalance;
            if (dust != 0) {
                token.safeTransfer(msg.sender, dust);
            }

            // Always close the allowance: `dust` is a balance delta and says nothing about how much the router
            // consumed. A router sourcing input elsewhere (Permit2, own inventory) leaves dust == 0 with the approval
            // still standing, and `swapCalldata` is caller-supplied — close it rather than infer.
            token.forceApprove(router, 0);
        }
    }

    /// @dev Shared core for both swap entry points; `destinationCaller` is the sole variable between them.
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

        // The swap succeeded but did not clear the relay fee.
        if (outputAmount <= feeAmount) revert InsufficientSwapOutput();
        uint256 transferAmount = outputAmount - feeAmount;
        if (maxFee >= transferAmount) revert InvalidMaxFee();

        // Approve the transfer amount only, so the fee stays in this contract.
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

    /// @dev Routes the burn to the CCTP v2 messenger: non-empty `hookData` selects `depositForBurnWithHook`
    ///      (forwarding the hook to the destination), otherwise plain `depositForBurn`. Both return nothing in v2.
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
