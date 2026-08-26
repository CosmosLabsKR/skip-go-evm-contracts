// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
<<<<<<< HEAD
import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
=======
import {ERC1967Utils} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
>>>>>>> sungrak/cctp-v2-contracts

import {TransitExecutor} from "../src/TransitExecutor.sol";
import {ITransitExecutor} from "../src/interfaces/ITransitExecutor.sol";
import {ITransitForwarder} from "../src/interfaces/ITransitForwarder.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";

// ── Mocks ──────────────────────────────────────────────────────────────────
// Kept local to this file rather than shared, following the original convention of one mock set per test file.

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

<<<<<<< HEAD
/// @dev Simulates the CCTP v2 MessageTransmitter: parses the burn body and mints `amount` to `mintRecipient`.
=======
/// @dev Simulates the CCTP v1 MessageTransmitter: parses the burn body and mints `amount` to `mintRecipient`.
>>>>>>> sungrak/cctp-v2-contracts
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
        bytes32 nonce = bytes32(uint256(uint64(bytes8(message[12:20]))));
        if (usedNonce[nonce]) return false; // replay → fail
        usedNonce[nonce] = true;
        bytes32 mintRecipient = bytes32(message[152:184]);
        uint256 amount = uint256(bytes32(message[184:216]));
        if (amount > shortfall) usdc.mint(address(uint160(uint256(mintRecipient))), amount - shortfall);
        return true;
    }
}

/// @dev Stands in for TransitForwarder so this file tests the executor in isolation. Records every argument, and can
///      revert or re-enter on demand.
contract MockTransitForwarder {
    bytes public lastMessage;
    uint256 public lastMinted;
<<<<<<< HEAD
    uint256 public lastFeeAmount;
=======
>>>>>>> sungrak/cctp-v2-contracts
    uint256 public lastMaxFee;
    uint32 public lastMinFinality;
    bytes32 public lastDestinationCaller;
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
<<<<<<< HEAD
        uint256 feeAmount,
=======
>>>>>>> sungrak/cctp-v2-contracts
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    ) external {
        _reenterIfAsked(message);
        if (forceRevert) revert("forwarder rejected");
<<<<<<< HEAD
        _record(message, minted, feeAmount, maxFee, minFinalityThreshold, destinationCaller);
    }


=======
        _record(message, minted, maxFee, minFinalityThreshold, destinationCaller);
    }

>>>>>>> sungrak/cctp-v2-contracts
    function refundMinted(bytes calldata message, uint256 minted) external {
        _reenterIfAsked(message);
        if (forceRevert) revert("forwarder rejected");
        lastWasRefund = true;
<<<<<<< HEAD
        _record(message, minted, 0, 0, 0, bytes32(0));
=======
        _record(message, minted, 0, 0, bytes32(0));
>>>>>>> sungrak/cctp-v2-contracts
    }

    function _reenterIfAsked(bytes calldata message) private {
        if (reenterTarget == address(0)) return;
<<<<<<< HEAD
        ITransitExecutor(reenterTarget).executeTransit(
            message, "att", address(0xBEEF), 3, bytes32(uint256(1)), 1, 0, 2000, bytes32(uint256(0xCA11))
        );
=======
        ITransitExecutor(reenterTarget)
            .executeTransit(message, "att", address(0xBEEF), 3, bytes32(uint256(1)), 0, 2000, bytes32(uint256(0xCA11)));
>>>>>>> sungrak/cctp-v2-contracts
    }

    function _record(
        bytes memory message,
        uint256 minted,
<<<<<<< HEAD
        uint256 feeAmount,
=======
>>>>>>> sungrak/cctp-v2-contracts
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    ) private {
        lastMessage = message;
        lastMinted = minted;
<<<<<<< HEAD
        lastFeeAmount = feeAmount;
=======
>>>>>>> sungrak/cctp-v2-contracts
        lastMaxFee = maxFee;
        lastMinFinality = minFinalityThreshold;
        lastDestinationCaller = destinationCaller;
        callCount++;
    }
}

<<<<<<< HEAD
=======
/// @dev Bumped `version()` used to prove a UUPS upgrade actually swapped logic. Mirrors the factory suite's
///      TransitForwarderFactoryV2. The constructor re-declares the immutables because they live in the impl, which
///      is precisely what an upgrade replaces.
contract TransitExecutorV3 is TransitExecutor {
    constructor(address u, address t, address o) TransitExecutor(u, t, o) {}

    /// @dev 3, not 2: the real TransitExecutor is at 2 since the fee removal, and this must stay ahead of it.
    function version() external pure override returns (uint256) {
        return 3;
    }
}

>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
    uint256 constant FEE = 10_000;
=======
>>>>>>> sungrak/cctp-v2-contracts
    uint256 constant MAX_FEE = 500;
    uint32 constant FINALITY = 2000;

    event FactorySet(address indexed previous, address indexed current);
    /// @dev Non-zero on every path: the executor rejects an unset destinationCaller.
    bytes32 constant DEST_CALLER = bytes32(uint256(0xCA11E5));
<<<<<<< HEAD

=======
    /// @dev The mock forwarder's next hop. Only consulted on the create-on-demand path, which this file mocks out.
    bytes32 constant NEXT_HOP = bytes32(uint256(uint160(address(0xD00D))));
>>>>>>> sungrak/cctp-v2-contracts

    function setUp() public {
        usdc = new MockUSDC();
        transmitter = new MockTransmitter(usdc);
        forwarder = new MockTransitForwarder();

        TransitExecutor impl = new TransitExecutor(address(usdc), address(transmitter), operator);
<<<<<<< HEAD
        executor =
            TransitExecutor(address(new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (owner, address(0))))));
    }

    // ── message builder (CCTP v2 offsets) ──
=======
        executor = TransitExecutor(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (owner, address(0)))))
        );
    }

    // ── message builder (CCTP v1 offsets) ──
>>>>>>> sungrak/cctp-v2-contracts

    /// @dev CCTP **v1** message layout (248 bytes, fixed).
    function _buildMessage(uint32 destinationDomain, bytes32 nonce, bytes32 mintRecipient, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        bytes memory header = abi.encodePacked(
            uint32(0), // version — 0 for v1
            uint32(1), // sourceDomain
            destinationDomain, // [8:12]
            uint64(uint256(nonce)), // nonce, uint64 in v1 [12:20]
            bytes32(uint256(0xCC72)), // sender [20:52]
            bytes32(0), // recipient [52:84]
            bytes32(0) // destinationCaller [84:116]
        );
        bytes memory body = abi.encodePacked(
            uint32(0), // body version [116:120]
            bytes32(uint256(uint160(address(0x5011)))), // burnToken — a SOURCE-domain address [120:152]
            mintRecipient, // [152:184]
            amount, // [184:216]
            bytes32(uint256(uint160(routeSender))) // messageSender [216:248]
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

    // ── X-01 / X-02 / X-03 happy paths ──

    function test_X01_ExecuteTransit_Happy() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(1));

        vm.prank(operator);
<<<<<<< HEAD
        executor.executeTransit(m, "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);

        assertEq(forwarder.callCount(), 1);
        assertEq(forwarder.lastMinted(), AMOUNT, "minted must be the measured delta");
        assertEq(forwarder.lastFeeAmount(), FEE);
=======
        executor.executeTransit(m, "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER);

        assertEq(forwarder.callCount(), 1);
        assertEq(forwarder.lastMinted(), AMOUNT, "minted must be the measured delta");
>>>>>>> sungrak/cctp-v2-contracts
        assertEq(forwarder.lastMaxFee(), MAX_FEE);
        assertEq(forwarder.lastMinFinality(), FINALITY);
        assertEq(usdc.balanceOf(address(executor)), 0, "the executor must never hold funds");
    }

    /// @dev There is only one transit entry point and it always carries destinationCaller — leaving it open is the
    ///      griefing path this design closes, so no unrestricted variant exists to test.
    function test_X02_DestinationCallerPassesThrough() public {
        bytes32 destCaller = bytes32(uint256(0xCA11E5));
        vm.prank(operator);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(2)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, destCaller);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(2)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, destCaller
        );
>>>>>>> sungrak/cctp-v2-contracts

        assertEq(forwarder.lastDestinationCaller(), destCaller);
    }

<<<<<<< HEAD

    function test_X03_ExecuteRefund() public {
        vm.prank(operator);
        executor.executeRefund(
            _goodMessage(AMOUNT, _nonce(3)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D))))
        );
=======
    function test_X03_ExecuteRefund() public {
        vm.prank(operator);
        executor.executeRefund(_goodMessage(AMOUNT, _nonce(3)), "att", routeSender, 3, NEXT_HOP);
>>>>>>> sungrak/cctp-v2-contracts

        assertTrue(forwarder.lastWasRefund());
        assertEq(forwarder.lastMinted(), AMOUNT);
    }

    // ── X-04 the callee comes from the message, not from an argument ──

    function test_X04_ForwarderDerivedFromMintRecipient() public {
        MockTransitForwarder other = new MockTransitForwarder();
        bytes memory m = _buildMessage(LOCAL_DOMAIN, _nonce(4), _toB32(address(other)), AMOUNT);

        vm.prank(operator);
<<<<<<< HEAD
        executor.executeTransit(m, "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(m, "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER);
>>>>>>> sungrak/cctp-v2-contracts

        assertEq(other.callCount(), 1, "the message named `other`, so `other` must be called");
        assertEq(forwarder.callCount(), 0, "the default forwarder must not be involved");
    }

    // ── X-05 / X-06 the measurement ──

    function test_X05_PreExistingDustExcluded() public {
        usdc.mint(address(forwarder), 777); // dust from an earlier failure

        vm.prank(operator);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(5)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(5)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts

        assertEq(forwarder.lastMinted(), AMOUNT, "per-message accounting must exclude pre-existing balance");
    }

    /// @dev CCTP v1 mints the body's `amount` exactly, so a delta that differs means the bytes are not the burn
    ///      message we think they are, or something else moved USDC mid-transaction. Either way the figure would be
    ///      untrustworthy in TransitCompleted, so it must not proceed.
    ///
    ///      (A CCTP v2 fast transfer WOULD land short, deducting feeExecuted on the destination. That is why this
    ///      equality is v1-specific — see ITransitExecutor.AmountMismatch.)
    function test_X06_DeltaMustEqualTheAttestedAmount() public {
        transmitter.setShortfall(1234); // less arrives than the message says was burned

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.AmountMismatch.selector);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(6)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(6)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts

        assertEq(forwarder.callCount(), 0, "nothing reached the forwarder");
    }

    /// @dev The delta and the attested amount agree even when the forwarder already holds dust — the two properties
    ///      are independent, and this pins that they coexist.
    function test_X06b_DustDoesNotBreakTheEquality() public {
        usdc.mint(address(forwarder), 999);

        vm.prank(operator);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(61)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(61)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts

        assertEq(forwarder.lastMinted(), AMOUNT, "dust excluded, and still equal to the attested amount");
    }

    // ── X-07 / X-08 recipient derivation guards ──

    function test_X07_NonEvmMintRecipientReverts() public {
        // A full-width 32-byte recipient, as Solana/Sui/Aptos use. Truncating would call an arbitrary address.
        bytes32 nonEvm = bytes32(0x1122334455667788990011223344556677889900112233445566778899001122);
        bytes memory m = _buildMessage(LOCAL_DOMAIN, _nonce(7), nonEvm, AMOUNT);

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.NotEvmRecipient.selector);
<<<<<<< HEAD
        executor.executeTransit(m, "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(m, "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER);
>>>>>>> sungrak/cctp-v2-contracts

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
<<<<<<< HEAD
        executor.executeTransit(m, "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(m, "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER);
>>>>>>> sungrak/cctp-v2-contracts

        assertFalse(transmitter.usedNonce(_nonce(8)), "must fail before the mint");
    }

    // ── X-09 length validation precedes the offset read ──

    /// @dev No named error here any more: the length gate was removed deliberately. A message too short to hold a
    ///      mintRecipient reverts on the slice, before any mint — which is the property worth keeping.
    function test_X09_ShortMessageRevertsBeforeMint() public {
        bytes memory short_ = new bytes(247);
        vm.prank(operator);
        vm.expectRevert();
<<<<<<< HEAD
        executor.executeTransit(short_, "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(short_, "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER);
>>>>>>> sungrak/cctp-v2-contracts
        assertEq(forwarder.callCount(), 0, "nothing reached the forwarder");
    }

    // ── X-10 / X-11 / X-12 static params, checked before the expensive leg ──

<<<<<<< HEAD
    function test_X10_ZeroFeeRevertsBeforeMint() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.ZeroFee.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(10)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), 0, MAX_FEE, FINALITY, DEST_CALLER);

        assertFalse(transmitter.usedNonce(_nonce(10)), "nonce must be unspent: no signature-verification gas burned");
=======
    /// @dev v1 also gated feeAmount != 0 here (ZeroFee). v2 takes no fee, so finality is the ONLY static param left,
    ///      and `maxFee` deliberately did NOT take its place: it is bounded against `minted`, which is not known
    ///      until after the mint, so the executor must pass it through untouched — including 0.
    function test_X10_MaxFeeIsNotAStaticParamAndPassesThrough() public {
        vm.prank(operator);
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(10)), "att", routeSender, 3, NEXT_HOP, 0, FINALITY, DEST_CALLER
        );

        assertEq(forwarder.callCount(), 1, "the executor forwarded rather than gating");
        assertEq(forwarder.lastMaxFee(), 0, "maxFee reaches the forwarder unchanged");
        assertTrue(transmitter.usedNonce(_nonce(10)), "and the mint went through");
>>>>>>> sungrak/cctp-v2-contracts
    }

    function test_X11_InvalidFinalityRevertsBeforeMint() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidFinalityThreshold.selector);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(11)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, 1500, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(11)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, 1500, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts

        assertFalse(transmitter.usedNonce(_nonce(11)));
    }

    function test_X12_BothFinalityValuesAccepted() public {
        vm.prank(operator);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(121)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, 1000, DEST_CALLER);
        vm.prank(operator);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(122)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, 2000, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(121)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, 1000, DEST_CALLER
        );
        vm.prank(operator);
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(122)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, 2000, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts
        assertEq(forwarder.callCount(), 2);
    }

    // ── X-13 mint failures ──

    function test_X13a_ReceiveFailed() public {
        transmitter.setForceFail(true);
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(131)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(131)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts
    }

    function test_X13b_NothingMinted() public {
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.NothingMinted.selector);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(0, _nonce(132)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(0, _nonce(132)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts
    }

    function test_X13c_NonceReplayRejected() public {
        bytes32 n = _nonce(133);
        vm.prank(operator);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, n), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
        executor.executeTransit(
            _goodMessage(AMOUNT, n), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts
    }

    /// @dev An unset destinationCaller would leave the next hop callable by anyone — the same griefing path this
    ///      contract closes, one hop along. Rejected rather than forwarded, and before the mint.
    function test_X14b_EmptyDestinationCallerRejectedBeforeMint() public {
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.EmptyDestinationCaller.selector);
        executor.executeTransit(
<<<<<<< HEAD
            _goodMessage(AMOUNT, _nonce(142)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))),
            FEE, MAX_FEE, FINALITY, bytes32(0)
=======
            _goodMessage(AMOUNT, _nonce(142)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, bytes32(0)
>>>>>>> sungrak/cctp-v2-contracts
        );
        assertFalse(transmitter.usedNonce(_nonce(142)), "must fail before the mint");
    }

    // ── X-14 authority ──

    function test_X14_TransitEntryPointsAreOperatorOnly() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(14));
        vm.startPrank(address(0xBAD));

        vm.expectRevert(ITransitExecutor.NotOperator.selector);
<<<<<<< HEAD
        executor.executeTransit(m, "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);

        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeRefund(m, "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))));
=======
        executor.executeTransit(m, "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER);

        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeRefund(m, "att", routeSender, 3, NEXT_HOP);
>>>>>>> sungrak/cctp-v2-contracts
        vm.stopPrank();

        // The owner is not the operator either — the split runs in both directions.
        vm.prank(owner);
        vm.expectRevert(ITransitExecutor.NotOperator.selector);
<<<<<<< HEAD
        executor.executeTransit(m, "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }



=======
        executor.executeTransit(m, "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER);
    }

>>>>>>> sungrak/cctp-v2-contracts
    // ── X-16 atomicity: this is what the whole design buys ──

    /// @dev A forwarder-side failure rolls the mint back with it, so the CCTP nonce stays unspent and the operator
    ///      can simply retry. There is no "minted but not burned" state to clean up.
    function test_X16_ForwarderRevertRollsBackTheMint() public {
        bytes32 n = _nonce(16);
        forwarder.setForceRevert(true);

        vm.prank(operator);
        vm.expectRevert(bytes("forwarder rejected"));
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, n), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts

        assertFalse(transmitter.usedNonce(n), "the whole tx rolled back, so the nonce is unspent");
        assertEq(usdc.balanceOf(address(forwarder)), 0, "no funds were left anywhere");

        forwarder.setForceRevert(false);
        vm.prank(operator);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, n), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts
        assertTrue(transmitter.usedNonce(n), "the same message succeeds on retry");
    }

    // ── X-17 reentrancy ──

    /// @dev The operator gate already stops a stranger's callback, so to exercise the guard itself the re-entrant
    ///      caller has to BE the operator. Deploy an executor whose operator is the mock forwarder to get there.
    function test_X17_ForwarderCannotReenter() public {
        TransitExecutor impl = new TransitExecutor(address(usdc), address(transmitter), address(forwarder));
        TransitExecutor reentrant = TransitExecutor(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (owner, address(0)))))
        );
        forwarder.setReenterTarget(address(reentrant));

        vm.prank(address(forwarder));
        vm.expectRevert(ITransitExecutor.Reentrancy.selector);
<<<<<<< HEAD
        reentrant.executeTransit(_goodMessage(AMOUNT, _nonce(17)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        reentrant.executeTransit(
            _goodMessage(AMOUNT, _nonce(17)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts
    }

    /// @dev The ordinary case: a callback from anyone who is not the operator dies on the gate, one step earlier.
    function test_X17b_StrangerCallbackDiesOnTheOperatorGate() public {
        forwarder.setReenterTarget(address(executor));

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.NotOperator.selector);
<<<<<<< HEAD
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(171)), "att", routeSender, 3, bytes32(uint256(uint160(address(0xD00D)))), FEE, MAX_FEE, FINALITY, DEST_CALLER);
=======
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(171)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
>>>>>>> sungrak/cctp-v2-contracts
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
        impl.initialize(owner, address(0));
    }

    /// @dev initialize accepts the factory for deployment orders where it already exists. In the canonical order it
    ///      cannot — the factory needs a forwarder impl, which needs this contract — so zero is the normal value and
    ///      setFactory wires it afterwards.
    function test_X19e_InitializeCanWireTheFactory() public {
        TransitExecutor impl = new TransitExecutor(address(usdc), address(transmitter), operator);
        address fac = address(0xFAC7);

        vm.expectEmit(true, true, false, true);
        emit FactorySet(address(0), fac);
        TransitExecutor wired = TransitExecutor(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (owner, fac))))
        );
        assertEq(wired.factory(), fac);

        // ...and zero leaves it unset, exactly as the canonical order needs.
        assertEq(executor.factory(), address(0));
    }

    function test_X19b_ProxyCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        executor.initialize(address(0xFEED), address(0));
    }

    function test_X19c_InitializeRejectsZeroOwner() public {
        TransitExecutor impl = new TransitExecutor(address(usdc), address(transmitter), operator);
        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(TransitExecutor.initialize, (address(0), address(0))));
    }

    function test_X19d_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        new TransitExecutor(address(0), address(transmitter), operator);

        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        new TransitExecutor(address(usdc), address(0), operator);

        vm.expectRevert(ITransitExecutor.ZeroAddress.selector);
        new TransitExecutor(address(usdc), address(transmitter), address(0));
    }
<<<<<<< HEAD
=======

    // ── X-20 UUPS upgrade ──
    //
    // This contract's address is baked into every forwarder's `executor` immutable and into the destinationCaller of
    // messages already burned on other chains, so UUPS exists here for one reason: change behaviour, keep the
    // address. These two tests are the counterparts of the factory suite's TF8/TF9.

    /// @dev The upgrade must swap logic while leaving the address, the owner and — the one piece of executor state
    ///      that matters — `factory` untouched. The `factory()` assertion below is what proves the storage survived.
    ///      The transit at the end proves something different and still worth having: the whole path is intact
    ///      afterwards. It does NOT exercise the factory read — `_ensureForwarder` short-circuits on the mock
    ///      forwarder, which is already deployed.
    function test_X20_UUPSUpgradeKeepsAddressAndState() public {
        vm.prank(owner);
        executor.setFactory(address(0xFAC7));

        address addressBefore = address(executor);
        address implBefore = address(uint160(uint256(vm.load(addressBefore, ERC1967Utils.IMPLEMENTATION_SLOT))));
        assertEq(executor.version(), 2, "baseline");

        TransitExecutorV3 newImpl = new TransitExecutorV3(address(usdc), address(transmitter), operator);
        vm.prank(owner);
        executor.upgradeToAndCall(address(newImpl), "");

        assertEq(address(executor), addressBefore, "THE address must never change - forwarders bind to it");
        assertEq(executor.version(), 3, "executor logic swapped");
        assertTrue(
            address(uint160(uint256(vm.load(addressBefore, ERC1967Utils.IMPLEMENTATION_SLOT)))) != implBefore,
            "implementation slot must actually point somewhere new"
        );
        assertEq(executor.owner(), owner, "owner must survive the upgrade");
        assertEq(executor.factory(), address(0xFAC7), "factory storage must survive the upgrade");
        assertEq(address(executor.usdc()), address(usdc), "immutables come from the new impl and must match Config");
        assertEq(address(executor.transmitter()), address(transmitter), "transmitter must be re-injected identically");
        assertEq(executor.operator(), operator, "operator must be re-injected identically");

        // ...and the transit path still works end to end against the same forwarder.
        vm.prank(operator);
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(200)), "att", routeSender, 3, NEXT_HOP, MAX_FEE, FINALITY, DEST_CALLER
        );
        assertEq(forwarder.callCount(), 1, "transit still lands after the upgrade");
        assertEq(forwarder.lastMinted(), AMOUNT);
    }

    /// @dev A stranger must not be able to move this address's behaviour. `_authorizeUpgrade` is onlyOwner and the
    ///      operator is deliberately NOT the owner — the two roles stay separate through the upgrade path too.
    function test_X21_UpgradeIsOwnerOnly() public {
        address attacker = address(0xBAD);
        // Deploy before any prank: a CREATE consumes the pending prank, which would leave the upgrade call coming
        // from the owner and passing.
        address newImpl = address(new TransitExecutorV3(address(usdc), address(transmitter), operator));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        executor.upgradeToAndCall(newImpl, "");

        // Not even the operator — it drives transit, not upgrades.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, operator));
        executor.upgradeToAndCall(newImpl, "");

        // setFactory is on the same owner gate, and it is the one owner surface that changes routing.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        executor.setFactory(address(0xFAC7));

        // The owner succeeds.
        vm.prank(owner);
        executor.upgradeToAndCall(newImpl, "");
        assertEq(executor.version(), 3);
    }
>>>>>>> sungrak/cctp-v2-contracts
}
