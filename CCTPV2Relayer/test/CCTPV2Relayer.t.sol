// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CCTPV2Relayer} from "src/CCTPV2Relayer.sol";
import {ICCTPV2Relayer} from "src/interfaces/ICCTPV2Relayer.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20, MockTokenMessengerV2, MockMessageTransmitterV2, MockSwapRouter} from "./mocks/Mocks.sol";

contract CCTPV2RelayerTest is Test {
    CCTPV2Relayer public relayer;
    MockERC20 public usdc;
    MockERC20 public wETH;
    MockTokenMessengerV2 public messenger;
    MockMessageTransmitterV2 public transmitter;
    MockSwapRouter public router;

    address public ACTOR_1 = makeAddr("ACTOR 1");

    uint32 constant DOMAIN = 7; // arbitrary destination domain
    uint32 constant THRESHOLD_STANDARD = 2000;
    uint32 constant THRESHOLD_FAST = 1000;
    bytes32 constant CALLER = keccak256("random caller");
    bytes constant NO_HOOK = hex"";
    bytes constant HOOK = hex"deadbeef";

    event PaymentForRelay(address indexed payer, bytes32 indexed messageHash, uint256 paymentAmount);
    event FailedReceiveMessage(bytes message, bytes attestation);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wETH = new MockERC20("Wrapped Ether", "WETH", 18);
        messenger = new MockTokenMessengerV2();
        transmitter = new MockMessageTransmitterV2();
        router = new MockSwapRouter(usdc);

        CCTPV2Relayer impl = new CCTPV2Relayer();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSignature(
                "initialize(address,address,address)", address(usdc), address(messenger), address(transmitter)
            )
        );
        relayer = CCTPV2Relayer(payable(address(proxy)));
        relayer.setSwapRouter(address(router));
    }

    function _mintRecipient() internal view returns (bytes32) {
        return bytes32(uint256(uint160(ACTOR_1)));
    }

    /// @dev version() must be readable through the proxy — that is the point of it (confirming which
    ///      implementation is live). Reading it off the impl directly would not prove that.
    function test_version() public {
        assertEq(relayer.version(), 1, "initial implementation revision");
    }

    // --------------------------------------------------------------------- //
    //                          makePaymentForRelay                          //
    // --------------------------------------------------------------------- //

    function test_makePaymentForRelay() public {
        uint256 amount = 10 * 1e6;
        bytes32 messageHash = keccak256("some-v2-message");

        usdc.mint(ACTOR_1, amount);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), amount);

        vm.expectEmit(true, true, true, true);
        emit PaymentForRelay(ACTOR_1, messageHash, amount);
        relayer.makePaymentForRelay(messageHash, amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(relayer)), amount, "fee not received");
        assertEq(usdc.balanceOf(ACTOR_1), 0, "balance remaining");
    }

    function test_makePaymentForRelay_revertZero() public {
        vm.expectRevert(ICCTPV2Relayer.PaymentCannotBeZero.selector);
        relayer.makePaymentForRelay(bytes32(0), 0);
    }

    // --------------------------------------------------------------------- //
    //                           requestCCTPTransfer                         //
    // --------------------------------------------------------------------- //

    function test_requestCCTPTransfer_standard() public {
        uint256 transferAmount = 1_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 total = transferAmount + feeAmount;

        usdc.mint(ACTOR_1, total);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), total);

        vm.expectEmit(true, true, true, true);
        emit PaymentForRelay(ACTOR_1, bytes32(0), feeAmount);
        relayer.requestCCTPTransfer(
            transferAmount, DOMAIN, _mintRecipient(), address(usdc), feeAmount, 0, THRESHOLD_STANDARD, NO_HOOK
        );
        vm.stopPrank();

        // Messenger received exactly the burn amount with standard params and no caller.
        (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destinationCaller,
            uint256 maxFee,
            uint32 minFinalityThreshold,
            bool withHook,
        ) = messenger.last();
        assertEq(amount, transferAmount, "burn amount");
        assertEq(destinationDomain, DOMAIN, "domain");
        assertEq(mintRecipient, _mintRecipient(), "recipient");
        assertEq(burnToken, address(usdc), "burn token");
        assertEq(destinationCaller, bytes32(0), "caller should be zero");
        assertEq(maxFee, 0, "maxFee");
        assertEq(uint256(minFinalityThreshold), uint256(THRESHOLD_STANDARD), "threshold");
        assertEq(withHook, false, "no hook -> plain depositForBurn");
        assertEq(messenger.callCount(), 1, "one burn");

        // Fee retained, burn amount left the contract, allowances cleared.
        assertEq(usdc.balanceOf(address(relayer)), feeAmount, "fee retained");
        assertEq(usdc.balanceOf(address(messenger)), transferAmount, "burned amount");
        assertEq(usdc.allowance(address(relayer), address(messenger)), 0, "messenger allowance");
        assertEq(usdc.allowance(ACTOR_1, address(relayer)), 0, "relayer allowance");
        assertEq(usdc.balanceOf(ACTOR_1), 0, "user balance");
    }

    function test_requestCCTPTransfer_fast() public {
        uint256 transferAmount = 1_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 maxFee = 1 * 1e6;
        uint256 total = transferAmount + feeAmount;

        usdc.mint(ACTOR_1, total);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), total);
        relayer.requestCCTPTransfer(
            transferAmount, DOMAIN, _mintRecipient(), address(usdc), feeAmount, maxFee, THRESHOLD_FAST, NO_HOOK
        );
        vm.stopPrank();

        (,,,,, uint256 recordedMaxFee, uint32 threshold,,) = messenger.last();
        assertEq(recordedMaxFee, maxFee, "maxFee forwarded");
        assertEq(uint256(threshold), uint256(THRESHOLD_FAST), "fast threshold");
        assertEq(usdc.balanceOf(address(relayer)), feeAmount, "fee retained");
    }

    function test_requestCCTPTransfer_withHook() public {
        uint256 transferAmount = 1_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 total = transferAmount + feeAmount;

        usdc.mint(ACTOR_1, total);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), total);
        relayer.requestCCTPTransfer(
            transferAmount, DOMAIN, _mintRecipient(), address(usdc), feeAmount, 0, THRESHOLD_STANDARD, HOOK
        );
        vm.stopPrank();

        (,,,,,,, bool withHook,) = messenger.last();
        assertEq(withHook, true, "non-empty hook -> depositForBurnWithHook");
        assertEq(messenger.lastHookData(), HOOK, "hookData forwarded");
        assertEq(usdc.balanceOf(address(relayer)), feeAmount, "fee retained");
    }

    function test_requestCCTPTransfer_revertInvalidMaxFee() public {
        uint256 transferAmount = 1_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 total = transferAmount + feeAmount;

        usdc.mint(ACTOR_1, total);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), total);
        vm.expectRevert(ICCTPV2Relayer.InvalidMaxFee.selector);
        relayer.requestCCTPTransfer(
            transferAmount, DOMAIN, _mintRecipient(), address(usdc), feeAmount, transferAmount, THRESHOLD_FAST, NO_HOOK
        );
        vm.stopPrank();
    }

    function test_requestCCTPTransfer_revertZeroTransfer() public {
        vm.expectRevert(ICCTPV2Relayer.PaymentCannotBeZero.selector);
        relayer.requestCCTPTransfer(0, DOMAIN, _mintRecipient(), address(usdc), 1, 0, THRESHOLD_STANDARD, NO_HOOK);
    }

    function test_requestCCTPTransfer_revertZeroFee() public {
        vm.expectRevert(ICCTPV2Relayer.PaymentCannotBeZero.selector);
        relayer.requestCCTPTransfer(
            1_000 * 1e6, DOMAIN, _mintRecipient(), address(usdc), 0, 0, THRESHOLD_STANDARD, NO_HOOK
        );
    }

    function test_requestCCTPTransfer_revertInvalidFinality() public {
        uint256 transferAmount = 1_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 total = transferAmount + feeAmount;

        usdc.mint(ACTOR_1, total);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), total);
        // Values other than 1000/2000 revert with InvalidFinalityThreshold
        vm.expectRevert(ICCTPV2Relayer.InvalidFinalityThreshold.selector);
        relayer.requestCCTPTransfer(
            transferAmount, DOMAIN, _mintRecipient(), address(usdc), feeAmount, 0, 1500, NO_HOOK
        );
        vm.stopPrank();
    }

    function test_requestCCTPTransferWithCaller() public {
        uint256 transferAmount = 1_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 maxFee = 2 * 1e6;
        uint256 total = transferAmount + feeAmount;

        usdc.mint(ACTOR_1, total);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), total);

        vm.expectEmit(true, true, true, true);
        emit PaymentForRelay(ACTOR_1, bytes32(0), feeAmount);
        relayer.requestCCTPTransferWithCaller(
            transferAmount, DOMAIN, _mintRecipient(), address(usdc), feeAmount, maxFee, THRESHOLD_FAST, CALLER, NO_HOOK
        );
        vm.stopPrank();

        (uint256 amount,,,, bytes32 destinationCaller, uint256 recordedMaxFee, uint32 threshold,,) = messenger.last();
        assertEq(amount, transferAmount, "burn amount");
        assertEq(destinationCaller, CALLER, "caller forwarded");
        assertEq(recordedMaxFee, maxFee, "maxFee forwarded");
        assertEq(uint256(threshold), uint256(THRESHOLD_FAST), "threshold");
        assertEq(usdc.balanceOf(address(relayer)), feeAmount, "fee retained");
    }

    function test_requestCCTPTransferWithCaller_withHook() public {
        uint256 transferAmount = 1_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 total = transferAmount + feeAmount;

        usdc.mint(ACTOR_1, total);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), total);
        relayer.requestCCTPTransferWithCaller(
            transferAmount, DOMAIN, _mintRecipient(), address(usdc), feeAmount, 0, THRESHOLD_STANDARD, CALLER, HOOK
        );
        vm.stopPrank();

        (,,,, bytes32 destinationCaller,,, bool withHook,) = messenger.last();
        assertEq(destinationCaller, CALLER, "caller forwarded");
        assertEq(withHook, true, "hook path");
        assertEq(messenger.lastHookData(), HOOK, "hookData forwarded");
    }

    function test_requestCCTPTransferWithCaller_revertInvalidMaxFee() public {
        uint256 transferAmount = 1_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 total = transferAmount + feeAmount;

        usdc.mint(ACTOR_1, total);
        vm.startPrank(ACTOR_1);
        usdc.approve(address(relayer), total);
        vm.expectRevert(ICCTPV2Relayer.InvalidMaxFee.selector);
        relayer.requestCCTPTransferWithCaller(
            transferAmount,
            DOMAIN,
            _mintRecipient(),
            address(usdc),
            feeAmount,
            transferAmount + 1,
            THRESHOLD_FAST,
            CALLER,
            NO_HOOK
        );
        vm.stopPrank();
    }

    // --------------------------------------------------------------------- //
    //                       swapAndRequestCCTPTransfer                      //
    // --------------------------------------------------------------------- //

    function test_swapAndRequestCCTPTransfer_ETH() public {
        uint256 inputAmount = 1 ether;
        uint256 usdcOut = 2_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        uint256 ethRefund = 0.1 ether;
        router.configure(usdcOut, ethRefund, address(0), 0);
        // Fund the router so it can refund ETH.
        vm.deal(address(router), ethRefund);

        vm.deal(ACTOR_1, inputAmount);
        bytes memory swapCalldata = abi.encodeWithSelector(MockSwapRouter.swap.selector);

        vm.startPrank(ACTOR_1);
        vm.expectEmit(true, true, true, true);
        emit PaymentForRelay(ACTOR_1, bytes32(0), feeAmount);
        relayer.swapAndRequestCCTPTransfer{value: inputAmount}(
            address(0),
            inputAmount,
            swapCalldata,
            DOMAIN,
            _mintRecipient(),
            address(usdc),
            feeAmount,
            0,
            THRESHOLD_STANDARD,
            NO_HOOK
        );
        vm.stopPrank();

        (uint256 amount,,,,,,,,) = messenger.last();
        assertEq(amount, usdcOut - feeAmount, "burn = output - fee");
        assertEq(usdc.balanceOf(address(relayer)), feeAmount, "fee retained");
        assertEq(ACTOR_1.balance, ethRefund, "eth refunded");
        assertEq(address(relayer).balance, 0, "no eth leftover");
    }

    function test_swapAndRequestCCTPTransfer_Token() public {
        uint256 inputAmount = 1 ether;
        uint256 pulled = 0.8 ether; // leaves dust to refund
        uint256 usdcOut = 2_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        router.configure(usdcOut, 0, address(wETH), pulled);

        wETH.mint(ACTOR_1, inputAmount);
        bytes memory swapCalldata = abi.encodeWithSelector(MockSwapRouter.swap.selector);

        vm.startPrank(ACTOR_1);
        wETH.approve(address(relayer), inputAmount);
        relayer.swapAndRequestCCTPTransfer(
            address(wETH),
            inputAmount,
            swapCalldata,
            DOMAIN,
            _mintRecipient(),
            address(usdc),
            feeAmount,
            0,
            THRESHOLD_STANDARD,
            NO_HOOK
        );
        vm.stopPrank();

        (uint256 amount,,,,,,,,) = messenger.last();
        assertEq(amount, usdcOut - feeAmount, "burn = output - fee");
        assertEq(usdc.balanceOf(address(relayer)), feeAmount, "fee retained");
        // Dust (inputAmount - pulled) refunded to user; none left in contract.
        assertEq(wETH.balanceOf(ACTOR_1), inputAmount - pulled, "dust refunded");
        assertEq(wETH.balanceOf(address(relayer)), 0, "no token leftover");
        assertEq(wETH.allowance(address(relayer), address(router)), 0, "router allowance revoked");
    }

    function test_swapAndRequestCCTPTransferWithCaller_ETH() public {
        uint256 inputAmount = 1 ether;
        uint256 usdcOut = 2_000 * 1e6;
        uint256 feeAmount = 10 * 1e6;
        router.configure(usdcOut, 0, address(0), 0);

        vm.deal(ACTOR_1, inputAmount);
        bytes memory swapCalldata = abi.encodeWithSelector(MockSwapRouter.swap.selector);

        vm.startPrank(ACTOR_1);
        relayer.swapAndRequestCCTPTransferWithCaller{value: inputAmount}(
            address(0),
            inputAmount,
            swapCalldata,
            DOMAIN,
            _mintRecipient(),
            address(usdc),
            feeAmount,
            0,
            THRESHOLD_STANDARD,
            CALLER,
            HOOK
        );
        vm.stopPrank();

        (uint256 amount,,,, bytes32 destinationCaller,,, bool withHook,) = messenger.last();
        assertEq(amount, usdcOut - feeAmount, "burn = output - fee");
        assertEq(destinationCaller, CALLER, "caller forwarded");
        assertEq(withHook, true, "hook path");
        assertEq(messenger.lastHookData(), HOOK, "hookData forwarded");
        assertEq(usdc.balanceOf(address(relayer)), feeAmount, "fee retained");
    }

    // --------------------------------------------------------------------- //
    //                          batchReceiveMessage                          //
    // --------------------------------------------------------------------- //

    function test_batchReceiveMessage_success() public {
        ICCTPV2Relayer.ReceiveCall[] memory calls = new ICCTPV2Relayer.ReceiveCall[](2);
        calls[0] = ICCTPV2Relayer.ReceiveCall(bytes("msg1"), bytes("att1"));
        calls[1] = ICCTPV2Relayer.ReceiveCall(bytes("msg2"), bytes("att2"));

        relayer.batchReceiveMessage(calls);
        assertEq(transmitter.received(), 2, "both received");
    }

    function test_batchReceiveMessage_failureEmitsEvent() public {
        transmitter.setNextSuccess(false);
        ICCTPV2Relayer.ReceiveCall[] memory calls = new ICCTPV2Relayer.ReceiveCall[](1);
        calls[0] = ICCTPV2Relayer.ReceiveCall(bytes("bad"), bytes("att"));

        vm.expectEmit(true, true, true, true);
        emit FailedReceiveMessage(bytes("bad"), bytes("att"));
        relayer.batchReceiveMessage(calls);
    }

    // --------------------------------------------------------------------- //
    //                                withdraw                               //
    // --------------------------------------------------------------------- //

    function test_withdraw() public {
        uint256 amount = 50 * 1e6;
        usdc.mint(address(relayer), amount);
        address receiver = makeAddr("RECEIVER");

        relayer.withdraw(receiver, amount);
        assertEq(usdc.balanceOf(receiver), amount, "withdrawn");
    }

    function test_withdraw_revertMissingBalance() public {
        vm.expectRevert(ICCTPV2Relayer.MissingBalance.selector);
        relayer.withdraw(ACTOR_1, 1);
    }

    function test_withdraw_revertNotOwner() public {
        usdc.mint(address(relayer), 1e6);
        vm.prank(ACTOR_1);
        vm.expectRevert();
        relayer.withdraw(ACTOR_1, 1e6);
    }

    fallback() external payable {}
    receive() external payable {}
}
