// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CCTPV2Relayer} from "src/CCTPV2Relayer.sol";
import {ICCTPV2Relayer} from "src/interfaces/ICCTPV2Relayer.sol";
import {MockERC20, MockTokenMessengerV2, MockMessageTransmitterV2, MockSwapRouter} from "./mocks/Mocks.sol";

/// @dev Aggregator-style router: performs the swap AND an arbitrary call chosen by the caller, which is what
///      0x / LiFi / Odos style routers do. Used to point the router back at the relayer mid-swap.
contract ReentrantAggregatorRouter {
    MockERC20 public immutable usdc;
    MockERC20 public immutable tokenIn;

    /// @dev The inner call's outcome is recorded rather than bubbled, so the swap itself still succeeds and the
    ///      test can assert both *why* the reentry failed and that the output accounting stayed honest.
    bool public innerSucceeded;
    bytes public innerRevert;

    constructor(MockERC20 _usdc, MockERC20 _tokenIn) {
        usdc = _usdc;
        tokenIn = _tokenIn;
    }

    function execute(uint256 amountIn, uint256 amountOut, address target, bytes calldata data) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        usdc.mint(msg.sender, amountOut);
        if (target != address(0)) {
            (bool ok, bytes memory ret) = target.call(data);
            innerSucceeded = ok;
            innerRevert = ret;
        }
    }
}

/// @dev Regression tests for the swap output accounting in `_executeSwap`, which measures output as a USDC balance
///      delta across the router call — only valid while nothing else can move that balance in the same window.
///      Previously `preOutputBalance` was snapshotted before the input `transferFrom`, so `inputToken == usdc` let a
///      caller count their own deposit as output, take it back as dust, and bridge out the fee reserve for free.
contract SwapAccountingTest is Test {
    CCTPV2Relayer public relayer;
    MockERC20 public usdc;
    MockERC20 public tokenIn;
    MockTokenMessengerV2 public messenger;
    MockMessageTransmitterV2 public transmitter;
    MockSwapRouter public router;

    address public attacker = makeAddr("attacker");

    uint256 internal constant RESERVE = 100_000e6;
    uint32 internal constant DEST_DOMAIN = 7;
    uint32 internal constant FINALITY_STANDARD = 2000;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        tokenIn = new MockERC20("Wrapped Ether", "WETH", 18);
        messenger = new MockTokenMessengerV2();
        transmitter = new MockMessageTransmitterV2();
        router = new MockSwapRouter(usdc);

        CCTPV2Relayer impl = new CCTPV2Relayer();
        relayer = CCTPV2Relayer(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeWithSignature(
                            "initialize(address,address,address)",
                            address(usdc),
                            address(messenger),
                            address(transmitter)
                        )
                    )
                )
            )
        );
        relayer.setSwapRouter(address(router));

        // Relay fees accumulated by earlier transfers, held by the contract.
        usdc.mint(address(relayer), RESERVE);
    }

    function _recipient(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// USDC as the swap input is rejected outright.
    function test_swapAndRequestCCTPTransfer_revertUsdcAsInputToken() public {
        uint256 inputAmount = RESERVE + 1e6;
        usdc.mint(attacker, inputAmount);

        // A router call that succeeds without swapping anything.
        router.configure(0, 0, address(0), 0);

        vm.startPrank(attacker);
        usdc.approve(address(relayer), inputAmount);
        vm.expectRevert(ICCTPV2Relayer.InvalidInputToken.selector);
        relayer.swapAndRequestCCTPTransfer(
            address(usdc),
            inputAmount,
            abi.encodeWithSelector(MockSwapRouter.swap.selector),
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            1e6,
            0,
            FINALITY_STANDARD,
            ""
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(relayer)), RESERVE, "reserve untouched");
        assertEq(messenger.callCount(), 0, "no burn dispatched");
    }

    /// The WithCaller variant shares `_executeSwap`, so it is covered by the same guard.
    function test_swapAndRequestCCTPTransferWithCaller_revertUsdcAsInputToken() public {
        uint256 inputAmount = RESERVE + 1e6;
        usdc.mint(attacker, inputAmount);
        router.configure(0, 0, address(0), 0);

        vm.startPrank(attacker);
        usdc.approve(address(relayer), inputAmount);
        vm.expectRevert(ICCTPV2Relayer.InvalidInputToken.selector);
        relayer.swapAndRequestCCTPTransferWithCaller(
            address(usdc),
            inputAmount,
            abi.encodeWithSelector(MockSwapRouter.swap.selector),
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            1e6,
            0,
            FINALITY_STANDARD,
            _recipient(attacker),
            ""
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(relayer)), RESERVE, "reserve untouched");
        assertEq(messenger.callCount(), 0, "no burn dispatched");
    }

    /// A router call that swaps nothing must not produce a positive output amount.
    function test_noopSwapCannotFabricateOutput() public {
        tokenIn.mint(attacker, 10e18);
        router.configure(0, 0, address(0), 0); // pulls nothing, mints no USDC

        vm.startPrank(attacker);
        tokenIn.approve(address(relayer), 10e18);
        vm.expectRevert(ICCTPV2Relayer.InsufficientSwapOutput.selector);
        relayer.swapAndRequestCCTPTransfer(
            address(tokenIn),
            10e18,
            abi.encodeWithSelector(MockSwapRouter.swap.selector),
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            1e6,
            0,
            FINALITY_STANDARD,
            ""
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(relayer)), RESERVE, "reserve untouched");
    }

    /// A legitimate swap still bridges exactly the swap proceeds minus the fee, with the pre-existing
    /// reserve excluded from the delta and left in place.
    function test_legitimateSwapIgnoresPreExistingReserve() public {
        uint256 swapOut = 3_000e6;
        uint256 feeAmount = 1e6;

        tokenIn.mint(attacker, 1e18);
        router.configure(swapOut, 0, address(tokenIn), 1e18);

        vm.startPrank(attacker);
        tokenIn.approve(address(relayer), 1e18);
        relayer.swapAndRequestCCTPTransfer(
            address(tokenIn),
            1e18,
            abi.encodeWithSelector(MockSwapRouter.swap.selector),
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            feeAmount,
            0,
            FINALITY_STANDARD,
            ""
        );
        vm.stopPrank();

        (uint256 burnedAmount,,,,,,,,) = messenger.last();
        assertEq(burnedAmount, swapOut - feeAmount, "only the swap proceeds minus fee are bridged");
        assertEq(usdc.balanceOf(address(relayer)), RESERVE + feeAmount, "reserve intact, fee retained");
        assertEq(tokenIn.balanceOf(attacker), 0, "input fully consumed by the swap");
    }

    /// Unconsumed input is still refunded as dust, and only the unconsumed part.
    function test_partialSwapRefundsOnlyUnconsumedInput() public {
        uint256 swapOut = 3_000e6;
        uint256 feeAmount = 1e6;

        tokenIn.mint(attacker, 1e18);
        // The contract already holds some of the input token; it must not be swept into the refund.
        tokenIn.mint(address(relayer), 5e18);
        router.configure(swapOut, 0, address(tokenIn), 0.6e18); // consumes 0.6, leaves 0.4

        vm.startPrank(attacker);
        tokenIn.approve(address(relayer), 1e18);
        relayer.swapAndRequestCCTPTransfer(
            address(tokenIn),
            1e18,
            abi.encodeWithSelector(MockSwapRouter.swap.selector),
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            feeAmount,
            0,
            FINALITY_STANDARD,
            ""
        );
        vm.stopPrank();

        assertEq(tokenIn.balanceOf(attacker), 0.4e18, "only the unconsumed input is refunded");
        assertEq(tokenIn.balanceOf(address(relayer)), 5e18, "pre-existing input holdings untouched");
        assertEq(usdc.balanceOf(address(relayer)), RESERVE + feeAmount, "reserve intact, fee retained");
    }

    // ── swap-window reentrancy ──
    //
    // `swapCalldata` is caller-supplied, so an aggregator-style router can be pointed back at the relayer mid-swap.
    // Any entry point moving the relayer's USDC inside that window would be credited as swap output — all are guarded.

    uint256 internal constant SWAP_OUT = 3_000e6;

    /// @dev Runs a swap whose router reenters the relayer with `innerCall`, then asserts the reentry was rejected
    ///      by the guard and that the swap output was not inflated by it.
    function _assertReentryBlocked(bytes memory innerCall) internal {
        ReentrantAggregatorRouter agg = new ReentrantAggregatorRouter(usdc, tokenIn);
        relayer.setSwapRouter(address(agg));

        tokenIn.mint(attacker, 1e18);
        bytes memory swapCalldata =
            abi.encodeCall(ReentrantAggregatorRouter.execute, (1e18, SWAP_OUT, address(relayer), innerCall));

        vm.startPrank(attacker);
        tokenIn.approve(address(relayer), 1e18);
        relayer.swapAndRequestCCTPTransfer(
            address(tokenIn),
            1e18,
            swapCalldata,
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            1e6,
            0,
            FINALITY_STANDARD,
            ""
        );
        vm.stopPrank();

        assertFalse(agg.innerSucceeded(), "reentry must not succeed");
        assertEq(bytes4(agg.innerRevert()), ICCTPV2Relayer.Reentrancy.selector, "rejected by the reentrancy guard");

        (uint256 burned,,,,,,,,) = messenger.last();
        assertEq(burned, SWAP_OUT - 1e6, "output not inflated by the reentry");
        assertEq(usdc.balanceOf(address(relayer)), RESERVE + 1e6, "reserve intact");
    }

    /// batchReceiveMessage mints USDC into the relayer — the zero-cost inflation path. Must not be reachable.
    function test_windowReentrancy_batchReceiveMessageBlocked() public {
        ICCTPV2Relayer.ReceiveCall[] memory calls = new ICCTPV2Relayer.ReceiveCall[](1);
        calls[0] = ICCTPV2Relayer.ReceiveCall({message: hex"00", attestation: hex"00"});
        _assertReentryBlocked(abi.encodeCall(CCTPV2Relayer.batchReceiveMessage, (calls)));
    }

    /// makePaymentForRelay pulls USDC into the relayer.
    function test_windowReentrancy_makePaymentForRelayBlocked() public {
        _assertReentryBlocked(abi.encodeCall(CCTPV2Relayer.makePaymentForRelay, (bytes32(uint256(1)), 1e6)));
    }

    /// requestCCTPTransfer nets +feeAmount into the relayer.
    function test_windowReentrancy_requestCCTPTransferBlocked() public {
        _assertReentryBlocked(
            abi.encodeCall(
                CCTPV2Relayer.requestCCTPTransfer,
                (10e6, DEST_DOMAIN, _recipient(attacker), address(usdc), 1e6, 0, FINALITY_STANDARD, "")
            )
        );
    }

    /// requestCCTPTransferWithCaller shares the guard.
    function test_windowReentrancy_requestCCTPTransferWithCallerBlocked() public {
        _assertReentryBlocked(
            abi.encodeCall(
                CCTPV2Relayer.requestCCTPTransferWithCaller,
                (
                    10e6,
                    DEST_DOMAIN,
                    _recipient(attacker),
                    address(usdc),
                    1e6,
                    0,
                    FINALITY_STANDARD,
                    _recipient(attacker),
                    ""
                )
            )
        );
    }

    /// Sequential (non-nested) calls must keep working — the guard resets between top-level calls.
    function test_guardDoesNotBlockSequentialCalls() public {
        usdc.mint(attacker, 100e6);
        vm.startPrank(attacker);
        usdc.approve(address(relayer), type(uint256).max);
        relayer.makePaymentForRelay(bytes32(uint256(1)), 1e6);
        relayer.makePaymentForRelay(bytes32(uint256(2)), 1e6);
        relayer.requestCCTPTransfer(
            10e6, DEST_DOMAIN, _recipient(attacker), address(usdc), 1e6, 0, FINALITY_STANDARD, ""
        );
        vm.stopPrank();
        assertEq(messenger.callCount(), 1, "sequential calls unaffected by the guard");
    }

    // ── L-1: router allowance is always closed ──

    /// The router allowance must be revoked even when the swap consumed the input exactly (dust == 0), since
    /// `dust` is a balance delta and carries no information about how much allowance was actually used.
    function test_routerAllowanceRevokedWhenNoDust() public {
        tokenIn.mint(attacker, 1e18);
        router.configure(3_000e6, 0, address(tokenIn), 1e18); // consumes the full input → dust == 0

        vm.startPrank(attacker);
        tokenIn.approve(address(relayer), 1e18);
        relayer.swapAndRequestCCTPTransfer(
            address(tokenIn),
            1e18,
            abi.encodeWithSelector(MockSwapRouter.swap.selector),
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            1e6,
            0,
            FINALITY_STANDARD,
            ""
        );
        vm.stopPrank();

        assertEq(tokenIn.balanceOf(attacker), 0, "input fully consumed (dust == 0)");
        assertEq(tokenIn.allowance(address(relayer), address(router)), 0, "allowance closed anyway");
    }

    /// A router that pulls nothing leaves the whole input as dust; allowance must still end at zero.
    function test_routerAllowanceRevokedWhenNothingPulled() public {
        tokenIn.mint(attacker, 1e18);
        router.configure(3_000e6, 0, address(tokenIn), 0); // pulls nothing, still mints USDC

        vm.startPrank(attacker);
        tokenIn.approve(address(relayer), 1e18);
        relayer.swapAndRequestCCTPTransfer(
            address(tokenIn),
            1e18,
            abi.encodeWithSelector(MockSwapRouter.swap.selector),
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            1e6,
            0,
            FINALITY_STANDARD,
            ""
        );
        vm.stopPrank();

        assertEq(tokenIn.balanceOf(attacker), 1e18, "unpulled input refunded");
        assertEq(tokenIn.allowance(address(relayer), address(router)), 0, "allowance closed");
    }

    // ── L-3 / L-4: observability ──

    function test_setSwapRouterEmitsTransition() public {
        address previous = address(router);
        address next = makeAddr("newRouter");

        vm.expectEmit(true, true, false, false);
        emit ICCTPV2Relayer.SwapRouterUpdated(previous, next);
        relayer.setSwapRouter(next);

        assertEq(relayer.swapRouter(), next, "router updated");
    }

    function test_withdrawEmitsAndRejectsZeroReceiver() public {
        address to = makeAddr("treasury");

        vm.expectEmit(true, false, false, true);
        emit ICCTPV2Relayer.Withdrawn(to, 1_000e6);
        relayer.withdraw(to, 1_000e6);
        assertEq(usdc.balanceOf(to), 1_000e6, "fees withdrawn");

        vm.expectRevert(ICCTPV2Relayer.ZeroAddress.selector);
        relayer.withdraw(address(0), 1e6);
    }

    /// The native path is unaffected by the guard and still measures the delta correctly.
    function test_nativeSwapUnaffected() public {
        uint256 swapOut = 3_000e6;
        uint256 feeAmount = 1e6;

        vm.deal(attacker, 1 ether);
        router.configure(swapOut, 0, address(0), 0);

        vm.prank(attacker);
        relayer.swapAndRequestCCTPTransfer{value: 1 ether}(
            address(0),
            1 ether,
            abi.encodeWithSelector(MockSwapRouter.swap.selector),
            DEST_DOMAIN,
            _recipient(attacker),
            address(usdc),
            feeAmount,
            0,
            FINALITY_STANDARD,
            ""
        );

        (uint256 burnedAmount,,,,,,,,) = messenger.last();
        assertEq(burnedAmount, swapOut - feeAmount, "only the swap proceeds minus fee are bridged");
        assertEq(usdc.balanceOf(address(relayer)), RESERVE + feeAmount, "reserve intact, fee retained");
    }
}
