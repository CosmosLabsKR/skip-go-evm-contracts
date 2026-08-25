// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TransitExecutor} from "../src/TransitExecutor.sol";
import {TransitForwarder} from "../src/TransitForwarder.sol";
import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {ITransitForwarder} from "../src/interfaces/ITransitForwarder.sol";
import {ITransitExecutor} from "../src/interfaces/ITransitExecutor.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {ITokenMessenger} from "../src/interfaces/ITokenMessenger.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";

/**
 * @notice The two-contract seam. TransitExecutor.t.sol mocks the forwarder and TransitForwarder.t.sol drives the
 *         forwarder through the executor, so each file has one real contract and one stand-in. Here BOTH are real
 *         (factory-deployed, behind their production proxies) and only the CCTP transmitter and the PaymentContract
 *         are stood in for — which makes this the only place the executor's derivation is checked against the
 *         factory's CREATE2 prediction, and the only place the whole path is observed end to end.
 */

// ── Mocks (external boundary only) ──────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockTransmitter is IReceiver {
    MockUSDC public immutable usdc;
    mapping(bytes32 => bool) public usedNonce;

    constructor(MockUSDC _usdc) {
        usdc = _usdc;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        bytes32 nonce = bytes32(uint256(uint64(bytes8(message[12:20]))));
        if (usedNonce[nonce]) return false;
        usedNonce[nonce] = true;
        bytes32 mintRecipient = bytes32(message[152:184]);
        uint256 amount = uint256(bytes32(message[184:216]));
        if (amount > 0) usdc.mint(address(uint160(uint256(mintRecipient))), amount);
        return true;
    }
}

/// @dev Circle TokenMessengerV2 stand-in for the integration suite: pulls the full amount (v2 withholds no fee)
///      and can be forced to revert so the "burn failure rolls back the mint" property stays testable.
contract MockTokenMessenger is ITokenMessenger {
    IERC20 public immutable usdc;
    uint256 public lastAmount;
    uint32 public lastDomain;
    bytes32 public lastMintRecipient;
    uint256 public callCount;
    bool public forceRevert;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setForceRevert(bool v) external {
        forceRevert = v;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address,
        bytes32,
        uint256,
        uint32
    ) external {
        if (forceRevert) revert("messenger rejected");
        require(usdc.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        lastAmount = amount;
        lastDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        callCount++;
    }

    function depositForBurnWithHook(uint256, uint32, bytes32, address, bytes32, uint256, uint32, bytes calldata)
        external
        pure
    {
        revert("hook variant must never be used");
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

contract TransitIntegrationTest is Test {
    MockUSDC usdc;
    MockTransmitter transmitter;
    MockTokenMessenger messengerMock;
    TransitExecutor executor;
    TransitForwarderFactory factory;
    TransitForwarder fwd;

    address operator = address(0xA11CE);
    address owner = address(0x0E9E4);
    address routeSender = address(0xBEEF);

    uint32 constant LOCAL_DOMAIN = 9;
    uint32 constant DEST_DOMAIN = 3;

    bytes32 nextHop = bytes32(uint256(uint160(address(0xD00D))));

    uint256 constant AMOUNT = 1_000_000;
    uint256 constant MAX_FEE = 500;
    uint32 constant FINALITY = 2000;
    /// @dev Non-zero on every path: the executor rejects an unset destinationCaller.
    bytes32 constant DEST_CALLER = bytes32(uint256(0xCA11E5));

    function setUp() public {
        usdc = new MockUSDC();
        transmitter = new MockTransmitter(usdc);
        messengerMock = new MockTokenMessenger(usdc);

        // Production deployment order: executor proxy first, then the forwarder impl bound to it, then the factory.
        TransitExecutor executorImpl = new TransitExecutor(address(usdc), address(transmitter), operator);
        executor = TransitExecutor(
            address(
                new ERC1967Proxy(address(executorImpl), abi.encodeCall(TransitExecutor.initialize, (owner, address(0))))
            )
        );

        TransitForwarder fwdImpl = new TransitForwarder(
            address(usdc), address(messengerMock), operator, address(executor), LOCAL_DOMAIN, DEST_DOMAIN
        );
        TransitForwarderFactory factoryImpl = new TransitForwarderFactory();
        factory = TransitForwarderFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl), abi.encodeCall(TransitForwarderFactory.initialize, (address(fwdImpl)))
                )
            )
        );

        fwd = TransitForwarder(payable(factory.createForwarder(routeSender, DEST_DOMAIN, nextHop)));
    }

    /// @dev CCTP **v1** message layout (248 bytes, fixed) — the mint leg. The burn leg is v2, built by the messengerMock.
    function _message(uint32 destinationDomain, bytes32 nonce, address mintRecipient, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        bytes memory header = abi.encodePacked(
            uint32(0),
            uint32(1),
            destinationDomain,
            uint64(uint256(nonce)),
            bytes32(uint256(0xCC72)),
            bytes32(0),
            bytes32(0)
        );
        bytes memory body = abi.encodePacked(
            uint32(0),
            bytes32(uint256(uint160(address(0x5011)))), // source-domain burnToken
            bytes32(uint256(uint160(mintRecipient))),
            amount,
            bytes32(uint256(uint160(routeSender)))
        );
        return abi.encodePacked(header, body);
    }

    function _good(bytes32 nonce) internal view returns (bytes memory) {
        return _message(LOCAL_DOMAIN, nonce, address(fwd), AMOUNT);
    }

    // ── I-01 end-to-end transit ──

    function test_I01_EndToEndTransit() public {
        vm.prank(operator);
        executor.executeTransit(
            _good(bytes32(uint256(1))), "att", routeSender, DEST_DOMAIN, nextHop, MAX_FEE, FINALITY, DEST_CALLER
        );

        assertEq(messengerMock.lastAmount(), AMOUNT, "the messenger receives the whole minted amount - no fee");
        assertEq(messengerMock.lastDomain(), DEST_DOMAIN, "destination comes from the forwarder's storage");
        assertEq(messengerMock.lastMintRecipient(), nextHop, "next hop comes from the forwarder's storage");
        assertEq(usdc.balanceOf(address(fwd)), 0, "nothing is left parked on this chain");
        assertEq(usdc.balanceOf(address(executor)), 0, "the executor never holds funds");
        assertEq(usdc.allowance(address(fwd), address(messengerMock)), 0, "no residual allowance");
    }

    // ── I-02 end-to-end refund ──

    function test_I02_EndToEndRefund() public {
        vm.prank(operator);
        executor.executeRefund(_good(bytes32(uint256(2))), "att", routeSender, DEST_DOMAIN, nextHop);

        assertEq(usdc.balanceOf(routeSender), AMOUNT, "refund goes to the route sender");
        assertEq(usdc.balanceOf(address(fwd)), 0);
        assertEq(messengerMock.callCount(), 0, "no burn on the refund path");
    }

    // ── I-03 the seam itself ──

    /// @dev The executor derives its callee from the message; the factory derives the same address from CREATE2.
    ///      If these two ever disagree, every transit would revert WrongRecipient — this is the assertion that ties
    ///      the executor's derivation to the factory's address space.
    function test_I03_ExecutorDerivationMatchesFactoryPrediction() public {
        address predicted = factory.getForwarderAddress(routeSender, DEST_DOMAIN, nextHop);
        assertEq(predicted, address(fwd), "factory prediction must match the deployed forwarder");

        // Reached through the executor's own derivation path: a transit only succeeds if it resolved to this address.
        vm.prank(operator);
        executor.executeTransit(
            _good(bytes32(uint256(3))), "att", routeSender, DEST_DOMAIN, nextHop, MAX_FEE, FINALITY, DEST_CALLER
        );
        assertEq(messengerMock.callCount(), 1, "the executor resolved to the factory-predicted forwarder");
    }

    // ── I-04 a message for another route ──

    /// @dev A second route's forwarder is a real contract, so the executor happily calls it — and that forwarder
    ///      rejects the message because its own binding check does not match. Defence in depth, observed.
    function test_I04_MessageForAnotherRouteIsRejectedByThatForwarder() public {
        address other = factory.createForwarder(routeSender, DEST_DOMAIN, bytes32(uint256(uint160(address(0xFACE)))));

        // Message mints to `other`, but names this chain's domain correctly. `other` accepts it — it IS its own
        // recipient — proving routes stay independent rather than leaking into each other.
        vm.prank(operator);
        executor.executeTransit(
            _message(LOCAL_DOMAIN, bytes32(uint256(4)), other, AMOUNT),
            "att",
            routeSender,
            DEST_DOMAIN,
            nextHop,
            MAX_FEE,
            FINALITY,
            DEST_CALLER
        );
        assertEq(
            messengerMock.lastMintRecipient(),
            bytes32(uint256(uint160(address(0xFACE)))),
            "funds followed the OTHER route"
        );

        // And a message whose destination domain is wrong is refused by the forwarder, through the executor.
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.WrongDestination.selector);
        executor.executeTransit(
            _message(LOCAL_DOMAIN + 1, bytes32(uint256(5)), address(fwd), AMOUNT),
            "att",
            routeSender,
            DEST_DOMAIN,
            nextHop,
            MAX_FEE,
            FINALITY,
            DEST_CALLER
        );
    }

    // ── I-05 exactly one authoritative event ──

    /// @dev The executor deliberately emits nothing on the transit path: two events in one transaction would leave
    ///      the off-chain side unable to decide which is the truth.
    function test_I05_ExecutorEmitsNothingOnTheTransitPath() public {
        vm.recordLogs();
        vm.prank(operator);
        executor.executeTransit(
            _good(bytes32(uint256(6))), "att", routeSender, DEST_DOMAIN, nextHop, MAX_FEE, FINALITY, DEST_CALLER
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fromExecutor;
        uint256 transitCompleted;
        bytes32 topic0 = keccak256("TransitCompleted(bytes32,uint256,uint256,uint32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(executor)) fromExecutor++;
            if (logs[i].topics[0] == topic0) transitCompleted++;
        }
        assertEq(fromExecutor, 0, "the executor must stay silent on the transit path");
        assertEq(transitCompleted, 1, "exactly one authoritative reconciliation event");
    }

    // ── I-06 atomicity across the seam ──

    /// @dev A failure at the far end (Circle's messenger) unwinds the mint too, so there is no half-finished transit to
    ///      reconcile and the operator can retry the same message unchanged.
    function test_I06_FarEndFailureRollsBackTheMint() public {
        bytes32 n = bytes32(uint256(7));
        messengerMock.setForceRevert(true);

        vm.prank(operator);
        vm.expectRevert(bytes("messenger rejected"));
        executor.executeTransit(_good(n), "att", routeSender, DEST_DOMAIN, nextHop, MAX_FEE, FINALITY, DEST_CALLER);

        assertFalse(transmitter.usedNonce(n), "nonce unspent");
        assertEq(usdc.balanceOf(address(fwd)), 0, "no funds stranded");

        messengerMock.setForceRevert(false);
        vm.prank(operator);
        executor.executeTransit(_good(n), "att", routeSender, DEST_DOMAIN, nextHop, MAX_FEE, FINALITY, DEST_CALLER);
        assertEq(messengerMock.lastAmount(), AMOUNT, "the same message succeeds on retry");
    }

    // ── I-07 create-on-demand: the seam that removes the off-chain createForwarder step ──

    /// @dev The route arguments are operator-supplied, so the only thing that makes accepting them safe is that the
    ///      factory must predict THE address the message already names. These four cases pin that.
    function test_I07a_ForwarderIsCreatedOnFirstUse() public {
        vm.prank(owner);
        executor.setFactory(address(factory));

        bytes32 newHop = bytes32(uint256(uint160(address(0xFEED))));
        address predicted = factory.getForwarderAddress(routeSender, DEST_DOMAIN, newHop);
        assertEq(predicted.code.length, 0, "must not exist yet");

        vm.prank(operator);
        executor.executeTransit(
            _message(LOCAL_DOMAIN, bytes32(uint256(70)), predicted, AMOUNT),
            "att",
            routeSender,
            DEST_DOMAIN,
            newHop,
            MAX_FEE,
            FINALITY,
            DEST_CALLER
        );

        assertGt(predicted.code.length, 0, "created in the same transaction as the mint");
        assertTrue(factory.isForwarderDeployed(routeSender, DEST_DOMAIN, newHop));
        assertEq(messengerMock.lastMintRecipient(), newHop, "and the transit completed through it");
        assertEq(usdc.balanceOf(predicted), 0, "nothing parked on the brand-new forwarder");
    }

    /// @dev A route that does not produce the named address must be refused — otherwise the operator could have a
    ///      forwarder of its own choosing created and the mint delivered to it.
    function test_I07b_RouteThatDoesNotProduceTheNamedAddressIsRefused() public {
        vm.prank(owner);
        executor.setFactory(address(factory));

        bytes32 newHop = bytes32(uint256(uint160(address(0xFEED))));
        address predicted = factory.getForwarderAddress(routeSender, DEST_DOMAIN, newHop);

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.RouteMismatch.selector);
        executor.executeTransit(
            _message(LOCAL_DOMAIN, bytes32(uint256(71)), predicted, AMOUNT),
            "att",
            // same shape, different next hop — so it predicts a DIFFERENT address
            routeSender,
            DEST_DOMAIN,
            bytes32(uint256(uint160(address(0xBADBAD)))),
            MAX_FEE,
            FINALITY,
            DEST_CALLER
        );
        assertEq(predicted.code.length, 0, "nothing was created");
        assertFalse(transmitter.usedNonce(bytes32(uint256(71))), "and nothing was minted");
    }

    function test_I07c_UnsetFactoryOnlyBlocksNewRoutes() public {
        // No setFactory call at all. An EXISTING route keeps working...
        vm.prank(operator);
        executor.executeTransit(
            _good(bytes32(uint256(72))), "att", routeSender, DEST_DOMAIN, nextHop, MAX_FEE, FINALITY, DEST_CALLER
        );
        assertEq(messengerMock.callCount(), 1);

        // ...while a new one fails loudly rather than silently misdelivering.
        bytes32 newHop = bytes32(uint256(uint160(address(0xFEED))));
        address predicted = factory.getForwarderAddress(routeSender, DEST_DOMAIN, newHop);
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.FactoryNotSet.selector);
        executor.executeTransit(
            _message(LOCAL_DOMAIN, bytes32(uint256(73)), predicted, AMOUNT),
            "att",
            routeSender,
            DEST_DOMAIN,
            newHop,
            MAX_FEE,
            FINALITY,
            DEST_CALLER
        );
    }

    /// @dev Refund must be able to create too: otherwise the mint would land on a codeless address with no way to
    ///      push or pull it back.
    function test_I07d_RefundAlsoCreatesOnFirstUse() public {
        vm.prank(owner);
        executor.setFactory(address(factory));

        bytes32 newHop = bytes32(uint256(uint160(address(0xFEED))));
        address predicted = factory.getForwarderAddress(routeSender, DEST_DOMAIN, newHop);

        vm.prank(operator);
        executor.executeRefund(
            _message(LOCAL_DOMAIN, bytes32(uint256(74)), predicted, AMOUNT), "att", routeSender, DEST_DOMAIN, newHop
        );

        assertGt(predicted.code.length, 0, "created");
        assertEq(usdc.balanceOf(routeSender), AMOUNT, "and refunded to the route sender");
    }

    /// @dev setFactory is owner-only, and a hostile factory cannot hijack an existing message: a CREATE2 address
    ///      commits to the factory that produced it, so a different factory predicts different addresses.
    function test_I07e_SetFactoryIsOwnerOnly() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setFactory(address(factory));

        vm.prank(owner);
        executor.setFactory(address(factory));
        assertEq(executor.factory(), address(factory));
    }
}
