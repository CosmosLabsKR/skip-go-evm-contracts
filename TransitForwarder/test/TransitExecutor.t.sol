// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

import {TransitExecutor} from "../src/TransitExecutor.sol";
import {ITransitExecutor} from "../src/interfaces/ITransitExecutor.sol";
import {ITransitForwarder} from "../src/interfaces/ITransitForwarder.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
import {CCTPV2Message} from "../src/libraries/CCTPV2Message.sol";

// ── Mocks ──────────────────────────────────────────────────────────────────
// Kept local to this file rather than shared, following the original convention of one mock set per test file.

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Simulates the CCTP v2 MessageTransmitter: parses the burn body and mints `amount` to `mintRecipient`.
contract MockTransmitter is IReceiver {
    MockUSDC public immutable usdc;
    mapping(bytes32 => bool) public usedNonce;
    bool public forceFail;
    /// @dev Mints less than the body's `amount`, exactly as a CCTP v2 fast transfer does after deducting
    ///      feeExecuted on the destination chain.
    uint256 public shortfall;

    constructor(MockUSDC _usdc) {
        usdc = _usdc;
    }

    function setForceFail(bool v) external {
        forceFail = v;
    }

    function setShortfall(uint256 v) external {
        shortfall = v;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        if (forceFail) return false;
        bytes32 nonce = bytes32(message[12:44]);
        if (usedNonce[nonce]) return false; // replay → fail
        usedNonce[nonce] = true;
        bytes32 mintRecipient = bytes32(message[184:216]);
        uint256 amount = uint256(bytes32(message[216:248]));
        if (amount > shortfall) usdc.mint(address(uint160(uint256(mintRecipient))), amount - shortfall);
        return true;
    }
}

/// @dev Stands in for TransitForwarder so this file tests the executor in isolation. Records every argument, and can
///      revert or re-enter on demand.
contract MockTransitForwarder {
    bytes public lastMessage;
    uint256 public lastMinted;
    uint256 public lastFeeAmount;
    uint256 public lastMaxFee;
    uint32 public lastMinFinality;
    bytes32 public lastDestinationCaller;
    bytes public lastHookData;
    bool public lastWasWithCaller;
    bool public lastWasRefund;
    uint256 public callCount;

    bool public forceRevert;
    address public reenterTarget;

    function setForceRevert(bool v) external {
        forceRevert = v;
    }

    function setReenterTarget(address t) external {
        reenterTarget = t;
    }

    function transferMinted(
        bytes calldata message,
        uint256 minted,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        _reenterIfAsked(message);
        if (forceRevert) revert("forwarder rejected");
        _record(message, minted, feeAmount, maxFee, minFinalityThreshold, bytes32(0), hookData, false, false);
    }

    function transferMintedWithCaller(
        bytes calldata message,
        uint256 minted,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external {
        _reenterIfAsked(message);
        if (forceRevert) revert("forwarder rejected");
        _record(message, minted, feeAmount, maxFee, minFinalityThreshold, destinationCaller, hookData, true, false);
    }

    function refundMinted(bytes calldata message, uint256 minted) external {
        _reenterIfAsked(message);
        if (forceRevert) revert("forwarder rejected");
        _record(message, minted, 0, 0, 0, bytes32(0), "", false, true);
    }

    function _reenterIfAsked(bytes calldata message) private {
        if (reenterTarget == address(0)) return;
        ITransitExecutor(reenterTarget).executeTransit(
            message, "att", ITransitExecutor.Route(address(0xBEEF), 3, bytes32(uint256(1))), 1, 0, 2000, ""
        );
    }

    function _record(
        bytes memory message,
        uint256 minted,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes memory hookData,
        bool withCaller,
        bool isRefund
    ) private {
        lastMessage = message;
        lastMinted = minted;
        lastFeeAmount = feeAmount;
        lastMaxFee = maxFee;
        lastMinFinality = minFinalityThreshold;
        lastDestinationCaller = destinationCaller;
        lastHookData = hookData;
        lastWasWithCaller = withCaller;
        lastWasRefund = isRefund;
        callCount++;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

contract TransitExecutorTest is Test {
    MockUSDC usdc;
    MockTransmitter transmitter;
    MockTransitForwarder forwarder;
    TransitExecutor executor;

    address operator = address(0xA11CE);
    address owner = address(0x0E9E4);
    address routeSender = address(0xBEEF);

    uint32 constant LOCAL_DOMAIN = 9;
    uint256 constant AMOUNT = 1_000_000;
    uint256 constant FEE = 10_000;
    uint256 constant MAX_FEE = 500;
    uint32 constant FINALITY = 2000;

    event Recovered(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();
        transmitter = new MockTransmitter(usdc);
        forwarder = new MockTransitForwarder();

        TransitExecutor impl = new TransitExecutor(address(usdc), address(transmitter), operator);
        executor =
            TransitExecutor(address(new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (owner)))));
    }

    // ── message builder (CCTP v2 offsets) ──

    function _buildMessage(uint32 destinationDomain, bytes32 nonce, bytes32 mintRecipient, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        bytes memory header = abi.encodePacked(
            uint32(1), // version
            uint32(1), // sourceDomain
            destinationDomain, // [8:12]
            nonce, // [12:44]
            bytes32(uint256(0xCC72)), // outer sender [44:76]
            bytes32(0), // recipient [76:108]
            bytes32(0), // destinationCaller [108:140]
            uint32(2000),
            uint32(2000)
        );
        bytes memory body = abi.encodePacked(
            uint32(1), // body version [148:152]
            bytes32(uint256(uint160(address(0x5011)))), // burnToken [152:184] — a SOURCE-domain address
            mintRecipient, // [184:216]
            amount, // [216:248]
            bytes32(uint256(uint160(routeSender))), // messageSender [248:280]
            uint256(0),
            uint256(0),
            uint256(0)
        );
        return abi.encodePacked(header, body);
    }

    function _toB32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev Well-formed message minting `amount` to the mock forwarder.
    function _goodMessage(uint256 amount, bytes32 nonce) internal view returns (bytes memory) {
        return _buildMessage(LOCAL_DOMAIN, nonce, _toB32(address(forwarder)), amount);
    }

    function _nonce(uint256 n) internal pure returns (bytes32) {
        return bytes32(n);
    }

    /// @dev A placeholder route. Every test in this file targets a forwarder that already has code (the mock), so
    ///      the executor never consults it — that path is covered by X-20~X-25 with a real factory.
    function _route() internal view returns (ITransitExecutor.Route memory) {
        return ITransitExecutor.Route(routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))));
    }

    // ── X-01 / X-02 / X-03 happy paths ──

    function test_X01_ExecuteTransit_Happy() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(1));

        vm.prank(operator);
        executor.executeTransit(m, "att", _route(), FEE, MAX_FEE, FINALITY, hex"aabb");

        assertEq(forwarder.callCount(), 1);
        assertEq(forwarder.lastMinted(), AMOUNT, "minted must be the measured delta");
        assertEq(forwarder.lastFeeAmount(), FEE);
        assertEq(forwarder.lastMaxFee(), MAX_FEE);
        assertEq(forwarder.lastMinFinality(), FINALITY);
        assertEq(forwarder.lastHookData(), hex"aabb", "hookData must pass through byte-identical");
        assertFalse(forwarder.lastWasWithCaller());
        assertEq(usdc.balanceOf(address(executor)), 0, "the executor must never hold funds");
    }

    function test_X02_ExecuteTransitWithCaller() public {
        bytes32 destCaller = bytes32(uint256(0xCA11E5));
        vm.prank(operator);
        executor.executeTransitWithCaller(_goodMessage(AMOUNT, _nonce(2)), "att", _route(), FEE, MAX_FEE, FINALITY, destCaller, "");

        assertTrue(forwarder.lastWasWithCaller());
        assertEq(forwarder.lastDestinationCaller(), destCaller);
    }

    function test_X03_ExecuteRefund() public {
        vm.prank(operator);
        executor.executeRefund(_goodMessage(AMOUNT, _nonce(3)), "att", _route());

        assertTrue(forwarder.lastWasRefund());
        assertEq(forwarder.lastMinted(), AMOUNT);
    }

    // ── X-04 the callee comes from the message, not from an argument ──

    function test_X04_ForwarderDerivedFromMintRecipient() public {
        MockTransitForwarder other = new MockTransitForwarder();
        bytes memory m = _buildMessage(LOCAL_DOMAIN, _nonce(4), _toB32(address(other)), AMOUNT);

        vm.prank(operator);
        executor.executeTransit(m, "att", _route(), FEE, MAX_FEE, FINALITY, "");

        assertEq(other.callCount(), 1, "the message named `other`, so `other` must be called");
        assertEq(forwarder.callCount(), 0, "the default forwarder must not be involved");
    }

    // ── X-05 / X-06 the measurement ──

    function test_X05_PreExistingDustExcluded() public {
        usdc.mint(address(forwarder), 777); // dust from an earlier failure

        vm.prank(operator);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(5)), "att", _route(), FEE, MAX_FEE, FINALITY, "");

        assertEq(forwarder.lastMinted(), AMOUNT, "per-message accounting must exclude pre-existing balance");
    }

    /// @dev The mock mints less than the body's `amount`, exactly as a CCTP v2 fast transfer does after deducting
    ///      feeExecuted on the destination. Reporting the body's number would over-state what actually arrived.
    function test_X06_MintedIsTheDeltaNotTheBodyAmount() public {
        transmitter.setShortfall(1234); // feeExecuted taken on the destination

        vm.prank(operator);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(6)), "att", _route(), FEE, MAX_FEE, FINALITY, "");

        assertEq(forwarder.lastMinted(), AMOUNT - 1234, "must report what arrived, not what the body claimed");
    }

    // ── X-07 / X-08 recipient derivation guards ──

    function test_X07_NonEvmMintRecipientReverts() public {
        // A full-width 32-byte recipient, as Solana/Sui/Aptos use. Truncating would call an arbitrary address.
        bytes32 nonEvm = bytes32(0x1122334455667788990011223344556677889900112233445566778899001122);
        bytes memory m = _buildMessage(LOCAL_DOMAIN, _nonce(7), nonEvm, AMOUNT);

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.NotEvmRecipient.selector);
        executor.executeTransit(m, "att", _route(), FEE, MAX_FEE, FINALITY, "");

        assertFalse(transmitter.usedNonce(_nonce(7)), "must fail before the mint, leaving the nonce unspent");
    }

    /// @dev An EOA recipient is codeless, so it now takes the create-on-demand branch and dies there. Before the
    ///      factory is configured that is FactoryNotSet; with one configured it is RouteMismatch (X-22), because no
    ///      route can predict an address the factory did not produce. Either way the mint never happens — and
    ///      NotContract survives as the post-condition for the case creation silently produced no code.
    function test_X08_EoaMintRecipientReverts() public {
        bytes memory m = _buildMessage(LOCAL_DOMAIN, _nonce(8), _toB32(address(0xDEAD)), AMOUNT);

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.FactoryNotSet.selector);
        executor.executeTransit(m, "att", _route(), FEE, MAX_FEE, FINALITY, "");

        assertFalse(transmitter.usedNonce(_nonce(8)), "must fail before the mint");
    }

    // ── X-09 length validation precedes the offset read ──

    /// @dev Without validateLength the mintRecipient slice would panic (0x32) instead of producing the error the
    ///      off-chain decoder expects.
    function test_X09_MalformedMessageNotPanic() public {
        bytes memory short_ = new bytes(375); // one byte below HOOK_DATA_OFFSET (376)
        vm.prank(operator);
        vm.expectRevert(CCTPV2Message.MalformedMessage.selector);
        executor.executeTransit(short_, "att", _route(), FEE, MAX_FEE, FINALITY, "");
    }

    // ── X-10 / X-11 / X-12 static params, checked before the expensive leg ──

    function test_X10_ZeroFeeRevertsBeforeMint() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.ZeroFee.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(10)), "att", _route(), 0, MAX_FEE, FINALITY, "");

        assertFalse(transmitter.usedNonce(_nonce(10)), "nonce must be unspent: no signature-verification gas burned");
    }

    function test_X11_InvalidFinalityRevertsBeforeMint() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidFinalityThreshold.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(11)), "att", _route(), FEE, MAX_FEE, 1500, "");

        assertFalse(transmitter.usedNonce(_nonce(11)));
    }

    function test_X12_BothFinalityValuesAccepted() public {
        vm.prank(operator);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(121)), "att", _route(), FEE, MAX_FEE, 1000, "");
        vm.prank(operator);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(122)), "att", _route(), FEE, MAX_FEE, 2000, "");
        assertEq(forwarder.callCount(), 2);
    }

    // ── X-13 mint failures ──

    function test_X13a_ReceiveFailed() public {
        transmitter.setForceFail(true);
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(131)), "att", _route(), FEE, MAX_FEE, FINALITY, "");
    }

    function test_X13b_NothingMinted() public {
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.NothingMinted.selector);
        executor.executeTransit(_goodMessage(0, _nonce(132)), "att", _route(), FEE, MAX_FEE, FINALITY, "");
    }

    function test_X13c_NonceReplayRejected() public {
        bytes32 n = _nonce(133);
        vm.prank(operator);
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", _route(), FEE, MAX_FEE, FINALITY, "");

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", _route(), FEE, MAX_FEE, FINALITY, "");
    }

    // ── X-14 / X-15 authority ──

    function test_X14_TransitEntryPointsAreOperatorOnly() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(14));
        vm.startPrank(address(0xBAD));

        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeTransit(m, "att", _route(), FEE, MAX_FEE, FINALITY, "");

        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeTransitWithCaller(m, "att", _route(), FEE, MAX_FEE, FINALITY, bytes32(0), "");

        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeRefund(m, "att", _route());
        vm.stopPrank();

        // The owner is not the operator either — the split runs in both directions.
        vm.prank(owner);
        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeTransit(m, "att", _route(), FEE, MAX_FEE, FINALITY, "");
    }

    function test_X15_RecoverIsOwnerOnly() public {
        usdc.mint(address(executor), 500); // a third-party mis-send

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.recoverERC20(address(usdc), operator);

        vm.expectEmit(true, true, false, true, address(executor));
        emit Recovered(address(usdc), routeSender, 500);
        vm.prank(owner);
        executor.recoverERC20(address(usdc), routeSender);

        assertEq(usdc.balanceOf(routeSender), 500);
        assertEq(usdc.balanceOf(address(executor)), 0);
    }

    function test_X15b_RecoverRejectsZeroDestination() public {
        vm.prank(owner);
        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        executor.recoverERC20(address(usdc), address(0));
    }

    // ── X-16 atomicity: this is what the whole design buys ──

    /// @dev A forwarder-side failure rolls the mint back with it, so the CCTP nonce stays unspent and the operator
    ///      can simply retry. There is no "minted but not burned" state to clean up.
    function test_X16_ForwarderRevertRollsBackTheMint() public {
        bytes32 n = _nonce(16);
        forwarder.setForceRevert(true);

        vm.prank(operator);
        vm.expectRevert(bytes("forwarder rejected"));
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", _route(), FEE, MAX_FEE, FINALITY, "");

        assertFalse(transmitter.usedNonce(n), "the whole tx rolled back, so the nonce is unspent");
        assertEq(usdc.balanceOf(address(forwarder)), 0, "no funds were left anywhere");

        forwarder.setForceRevert(false);
        vm.prank(operator);
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", _route(), FEE, MAX_FEE, FINALITY, "");
        assertTrue(transmitter.usedNonce(n), "the same message succeeds on retry");
    }

    // ── X-17 reentrancy ──

    /// @dev The operator gate already stops a stranger's callback, so to exercise the guard itself the re-entrant
    ///      caller has to BE the operator. Deploy an executor whose operator is the mock forwarder to get there.
    function test_X17_ForwarderCannotReenter() public {
        TransitExecutor impl = new TransitExecutor(address(usdc), address(transmitter), address(forwarder));
        TransitExecutor reentrant = TransitExecutor(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (owner))))
        );
        forwarder.setReenterTarget(address(reentrant));

        vm.prank(address(forwarder));
        vm.expectRevert(ITransitExecutor.Reentrancy.selector);
        reentrant.executeTransit(_goodMessage(AMOUNT, _nonce(17)), "att", _route(), FEE, MAX_FEE, FINALITY, "");
    }

    /// @dev The ordinary case: a callback from anyone who is not the operator dies on the gate, one step earlier.
    function test_X17b_StrangerCallbackDiesOnTheOperatorGate() public {
        forwarder.setReenterTarget(address(executor));

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(171)), "att", _route(), FEE, MAX_FEE, FINALITY, "");
    }

    // ── X-18 storage layout ──

    /// @dev Proves the OZ parents (Initializable / UUPSUpgradeable / Ownable2StepUpgradeable) use ERC-7201
    ///      namespaced storage and therefore claim no sequential slot — otherwise `_reentrant` would not be at 0 and
    ///      the __gap would not start at 1.
    function test_X18_StorageLayoutIsOwnedByThisContract() public {
        // Slot 0 packs factory (bytes 0..19) + _reentrant (byte 20). Idle and unset, that is zero.
        assertEq(uint256(vm.load(address(executor), bytes32(uint256(0)))), 0, "slot 0 is factory+_reentrant");
        vm.prank(owner);
        executor.setFactory(address(0xFAC7));
        assertEq(
            uint256(vm.load(address(executor), bytes32(uint256(0)))),
            uint256(uint160(address(0xFAC7))),
            "factory must occupy slot 0 offset 0"
        );
        assertEq(uint256(vm.load(address(executor), bytes32(uint256(1)))), 0, "__gap must start at slot 1");
        assertEq(uint256(vm.load(address(executor), bytes32(uint256(2)))), 0, "__gap must stay clear");
        assertEq(executor.owner(), owner, "...yet the owner is set, so it lives in a namespaced slot");
    }

    // ── X-19 initializer discipline ──

    function test_X19a_ImplementationCannotBeInitialized() public {
        TransitExecutor impl = new TransitExecutor(address(usdc), address(transmitter), operator);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner);
    }

    function test_X19b_ProxyCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        executor.initialize(address(0xFEED));
    }

    function test_X19c_InitializeRejectsZeroOwner() public {
        TransitExecutor impl = new TransitExecutor(address(usdc), address(transmitter), operator);
        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (address(0))));
    }

    function test_X19d_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        new TransitExecutor(address(0), address(transmitter), operator);

        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        new TransitExecutor(address(usdc), address(0), operator);

        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        new TransitExecutor(address(usdc), address(transmitter), address(0));
    }
}
