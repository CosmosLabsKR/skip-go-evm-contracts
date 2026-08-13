// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";

import {TransitForwarder} from "../src/TransitForwarder.sol";
import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {TransitExecutor} from "../src/TransitExecutor.sol";
import {ITransitForwarder} from "../src/interfaces/ITransitForwarder.sol";
import {ITransitExecutor} from "../src/interfaces/ITransitExecutor.sol";
import {ICCTPV2Relayer} from "../src/interfaces/ICCTPV2Relayer.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";

// ── Mocks ──────────────────────────────────────────────────────────────────
// Ported from ForwarderFactory/test/{InboundForwarder,OutboundForwarderFactory}.t.sol. Kept local to this file
// rather than shared, following the original convention of one mock set per test file.

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Simulates the CCTP v2 MessageTransmitter: parses the burn body (same offsets as the contract) and mints
///      `amount` USDC to `mintRecipient`. Tracks nonce replay and supports a forced-failure flag.
contract MockTransmitter is IReceiver {
    MockUSDC public immutable usdc;
    mapping(bytes32 => bool) public usedNonce;
    bool public forceFail;

    constructor(MockUSDC _usdc) {
        usdc = _usdc;
    }

    function setForceFail(bool v) external {
        forceFail = v;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        if (forceFail) return false;
        bytes32 nonce = bytes32(uint256(uint64(bytes8(message[12:20]))));
        if (usedNonce[nonce]) return false; // replay → fail
        usedNonce[nonce] = true;
        bytes32 mintRecipient = bytes32(message[152:184]);
        uint256 amount = uint256(bytes32(message[184:216]));
        if (amount > 0) usdc.mint(address(uint160(uint256(mintRecipient))), amount);
        return true;
    }
}

/// @dev PaymentContract mock that records CCTP v2 requestCCTPTransfer / requestCCTPTransferWithCaller and pulls USDC
///      via transferFrom.
contract MockCCTPV2Relayer is ICCTPV2Relayer {
    IERC20 public immutable usdc;
    uint256 public lastTransferAmount;
    uint32 public lastDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    uint256 public lastFeeAmount;
    uint256 public lastMaxFee;
    uint32 public lastMinFinality;
    bytes32 public lastDestinationCaller;
    bytes public lastHookData;
    bool public lastWasWithCaller;
    uint256 public callCount;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
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
        require(usdc.transferFrom(msg.sender, address(this), transferAmount + feeAmount), "transferFrom failed");
        _record(
            transferAmount,
            destinationDomain,
            mintRecipient,
            burnToken,
            feeAmount,
            maxFee,
            minFinalityThreshold,
            bytes32(0),
            hookData,
            false
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
        require(usdc.transferFrom(msg.sender, address(this), transferAmount + feeAmount), "transferFrom failed");
        _record(
            transferAmount,
            destinationDomain,
            mintRecipient,
            burnToken,
            feeAmount,
            maxFee,
            minFinalityThreshold,
            destinationCaller,
            hookData,
            true
        );
    }

    function _record(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient_,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData,
        bool withCaller
    ) private {
        lastTransferAmount = transferAmount;
        lastDomain = destinationDomain;
        lastMintRecipient = mintRecipient_;
        lastBurnToken = burnToken;
        lastFeeAmount = feeAmount;
        lastMaxFee = maxFee;
        lastMinFinality = minFinalityThreshold;
        lastDestinationCaller = destinationCaller;
        lastHookData = hookData;
        lastWasWithCaller = withCaller;
        callCount++;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

contract TransitForwarderTest is Test {
    MockUSDC usdc;
    MockTransmitter transmitter;
    MockCCTPV2Relayer relayer;
    TransitExecutor executor;
    TransitForwarder impl;
    TransitForwarderFactory factory;
    TransitForwarder fwd;

    address operator = address(0xA11CE);
    address routeSender = address(0xBEEF); // route key #1 / refund + recovery recipient

    uint32 constant LOCAL_DOMAIN = 9; // arbitrary test value for this chain
    uint32 constant DEST_DOMAIN = 3; // the one allowed next hop
    uint32 constant OTHER_DEST_DOMAIN = 4; // a different, disallowed destination
    uint32 constant WRONG_DOMAIN = 7; // a wrong LOCAL domain on an inbound message

    bytes32 mintRecipient = bytes32(uint256(uint160(address(0xD00D))));

    uint256 constant AMOUNT = 1_000_000; // 1 USDC (6dp)
    uint256 constant FEE = 10_000;
    uint256 constant MAX_FEE = 500;
    uint32 constant FINALITY = 2000;
    /// @dev Non-zero on every path: the executor rejects an unset destinationCaller.
    bytes32 constant DEST_CALLER = bytes32(uint256(0xCA11E5));

    // mirrors of the interface events, for expectEmit
    event TransitCompleted(
        bytes32 indexed sourceNonce,
        uint256 minted,
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    );
    event Refunded(bytes32 indexed sourceNonce, address indexed to, uint256 amount);
    event Recovered(address indexed token, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();
        transmitter = new MockTransmitter(usdc);
        relayer = new MockCCTPV2Relayer(usdc);

        // The executor is deployed FIRST and behind a proxy: the forwarder impl takes its address as an immutable,
        // and it must be the address that survives an executor upgrade. Mirrors the real deployment order.
        TransitExecutor executorImpl = new TransitExecutor(address(usdc), address(transmitter), operator);
        executor = TransitExecutor(
            address(new ERC1967Proxy(address(executorImpl), abi.encodeCall(TransitExecutor.initialize, (address(this)))))
        );

        impl = new TransitForwarder(
            address(usdc), address(relayer), operator, address(executor), LOCAL_DOMAIN, DEST_DOMAIN
        );

        TransitForwarderFactory factoryImpl = new TransitForwarderFactory();
        bytes memory initData = abi.encodeCall(TransitForwarderFactory.initialize, (address(impl)));
        factory = TransitForwarderFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));

        fwd = TransitForwarder(payable(factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient)));
    }

    // ── message builder (CCTP v2 offsets) ──

    /// @dev CCTP **v1** message layout (248 bytes, fixed). Header 116 + burn body 132 — no maxFee/feeExecuted/
    ///      expirationBlock/hookData, which v1 simply does not have.
    function _buildMessage(
        uint32 destinationDomain,
        bytes32 nonce,
        bytes32 messageSender,
        address burnToken,
        address mintRecipient_,
        uint256 amount
    ) internal pure returns (bytes memory) {
        bytes memory header = abi.encodePacked(
            uint32(0), // version — 0 for v1 [0:4]
            uint32(1), // sourceDomain [4:8]
            destinationDomain, // [8:12]
            uint64(uint256(nonce)), // nonce, uint64 in v1 [12:20]
            bytes32(uint256(0xCC72)), // sender [20:52]
            bytes32(0), // recipient [52:84]
            bytes32(0) // destinationCaller [84:116]
        );
        bytes memory body = abi.encodePacked(
            uint32(0), // body version [116:120]
            bytes32(uint256(uint160(burnToken))), // burnToken [120:152]
            bytes32(uint256(uint160(mintRecipient_))), // mintRecipient [152:184]
            amount, // [184:216]
            messageSender // [216:248]
        );
        return abi.encodePacked(header, body);
    }

    /// @dev Well-formed message minting `amount` to the forwarder on the local domain.
    function _goodMessage(uint256 amount, bytes32 nonce) internal view returns (bytes memory) {
        return _buildMessage(
            LOCAL_DOMAIN,
            nonce,
            bytes32(uint256(uint160(routeSender))),
            address(0x5011), // source-domain burnToken — deliberately NOT this chain's usdc
            address(fwd),
            amount
        );
    }

    function _nonce(uint256 n) internal pure returns (bytes32) {
        return bytes32(n);
    }

    function _transit(bytes memory message, uint256 fee, uint256 maxFee, uint32 finality) internal {
        vm.prank(operator);
        executor.executeTransit(message, "att", routeSender, DEST_DOMAIN, mintRecipient, fee, maxFee, finality, DEST_CALLER);
    }

    // ── T-01 정상 transit ──

    function test_T01_MintAndTransfer_Happy() public {
        bytes memory msg_ = _goodMessage(AMOUNT, _nonce(1));
        _transit(msg_, FEE, MAX_FEE, FINALITY);

        assertEq(usdc.balanceOf(address(fwd)), 0, "forwarder must hold nothing after transit");
        assertEq(relayer.callCount(), 1, "relayer called once");
        assertEq(relayer.lastTransferAmount(), AMOUNT - FEE, "transferAmount = minted - feeAmount");
        assertEq(relayer.lastFeeAmount(), FEE);
        assertEq(relayer.lastMaxFee(), MAX_FEE);
        assertEq(relayer.lastMinFinality(), FINALITY);
        assertEq(relayer.lastBurnToken(), address(usdc), "burnToken must be THIS chain's usdc");
        assertEq(usdc.balanceOf(address(relayer)), AMOUNT, "relayer pulled transferAmount + feeAmount");
    }

    // ── T-02 destinationCaller is always set ──

    /// @dev There is one transit entry point and it always carries destinationCaller, so the onward burn must ALWAYS
    ///      take the WithCaller path. An unrestricted next hop is the griefing path this design closes; there is no
    ///      variant that leaves it open, and this asserts the plain depositForBurn route is unreachable.
    function test_T02_OnwardBurnAlwaysRestrictsTheNextCaller() public {
        bytes32 destCaller = bytes32(uint256(uint160(address(0xCA11))));
        vm.prank(operator);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(2)), "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, MAX_FEE, FINALITY, destCaller);

        assertTrue(relayer.lastWasWithCaller(), "the onward burn must always restrict its caller");
        assertEq(relayer.lastDestinationCaller(), destCaller);
        assertEq(relayer.lastTransferAmount(), AMOUNT - FEE);
    }

    // ── T-03 route comes from storage, not from the operator's arguments ──

    function test_T03_RouteFromStorageNotArguments() public {
        _transit(_goodMessage(AMOUNT, _nonce(3)), FEE, MAX_FEE, FINALITY);
        (address s, uint32 d, bytes32 r) = fwd.getRoute();
        assertEq(s, routeSender);
        assertEq(d, DEST_DOMAIN);
        assertEq(r, mintRecipient);
        assertEq(relayer.lastDomain(), DEST_DOMAIN, "relayer got the stored domain");
        assertEq(relayer.lastMintRecipient(), mintRecipient, "relayer got the stored mintRecipient");
    }

    // ── T-04 hookData passthrough ──

    /// @dev T-04 used to assert hookData passed through byte-identical. The transit path no longer carries hookData
    ///      at all — this design has no use for a hook on the onward burn, and CCTP v1 has no such concept — so the
    ///      property worth pinning is the inverse: the burn must ALWAYS be the plain depositForBurn variant.
    ///      A non-empty hook would make the relayer call depositForBurnWithHook and change what arrives on Injective.
    function test_T04_OnwardBurnCarriesNoHook() public {
        _transit(_goodMessage(AMOUNT, _nonce(4)), FEE, MAX_FEE, FINALITY);
        assertEq(relayer.lastHookData().length, 0, "the onward burn must carry no hook");
    }

    // ── T-05 event ──

    function test_T05_TransitCompletedEvent() public {
        bytes32 n = _nonce(5);
        vm.expectEmit(true, false, false, true, address(fwd));
        emit TransitCompleted(n, AMOUNT, AMOUNT - FEE, FEE, MAX_FEE, FINALITY, DEST_CALLER);
        _transit(_goodMessage(AMOUNT, n), FEE, MAX_FEE, FINALITY);
    }

    // ── T-06 no residual allowance ──

    function test_T06_NoResidualAllowance() public {
        _transit(_goodMessage(AMOUNT, _nonce(6)), FEE, MAX_FEE, FINALITY);
        assertEq(usdc.allowance(address(fwd), address(relayer)), 0, "relayer must consume the whole approval");
    }

    // ── T-07 pre-existing dust is excluded from the delta ──

    function test_T07_PreExistingDustExcluded() public {
        uint256 dust = 777;
        usdc.mint(address(fwd), dust);

        _transit(_goodMessage(AMOUNT, _nonce(7)), FEE, MAX_FEE, FINALITY);

        assertEq(relayer.lastTransferAmount(), AMOUNT - FEE, "dust must not inflate the transit amount");
        assertEq(usdc.balanceOf(address(relayer)), AMOUNT, "relayer pulled exactly the minted amount");
        assertEq(usdc.balanceOf(address(fwd)), dust, "dust stays for recoverERC20");
    }

    // ── T-08 feeAmount == 0 ──

    function test_T08_ZeroFeeReverts() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.ZeroFee.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(8)), "att", routeSender, DEST_DOMAIN, mintRecipient, 0, MAX_FEE, FINALITY, DEST_CALLER);
    }

    /// @dev Ordering proof for _checkStaticParams running BEFORE the mint. A revert rolls back either way, so state
    ///      cannot distinguish the two orderings — but the ERROR can: pair feeAmount == 0 with a message that would
    ///      also fail the binding check. Getting ZeroFee (not WrongDestination) proves the static check came first.
    function test_T08b_StaticParamsCheckedBeforeBinding() public {
        bytes memory badBinding = _buildMessage(
            WRONG_DOMAIN, _nonce(81), bytes32(uint256(uint160(routeSender))), address(0x5011), address(fwd), AMOUNT
        );
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.ZeroFee.selector);
        executor.executeTransit(badBinding, "att", routeSender, DEST_DOMAIN, mintRecipient, 0, MAX_FEE, FINALITY, DEST_CALLER);
    }

    // ── T-09 / T-10 finality threshold ──

    function test_T09_InvalidFinalityReverts() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidFinalityThreshold.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(9)), "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, MAX_FEE, 1500, DEST_CALLER);
    }

    function test_T09b_FinalityCheckedBeforeBinding() public {
        bytes memory badBinding = _buildMessage(
            WRONG_DOMAIN, _nonce(91), bytes32(uint256(uint160(routeSender))), address(0x5011), address(fwd), AMOUNT
        );
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidFinalityThreshold.selector);
        executor.executeTransit(badBinding, "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, MAX_FEE, 1500, DEST_CALLER);
    }

    function test_T10_BothFinalityValuesAccepted() public {
        _transit(_goodMessage(AMOUNT, _nonce(101)), FEE, MAX_FEE, 1000);
        assertEq(relayer.lastMinFinality(), 1000);
        _transit(_goodMessage(AMOUNT, _nonce(102)), FEE, MAX_FEE, 2000);
        assertEq(relayer.lastMinFinality(), 2000);
    }

    // ── T-11 ~ T-14 _split boundaries ──

    function test_T11_FeeEqualsMintedReverts() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.FeeExceedsMinted.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(11)), "att", routeSender, DEST_DOMAIN, mintRecipient, AMOUNT, 0, FINALITY, DEST_CALLER);
    }

    function test_T12_FeeAboveMintedReverts() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.FeeExceedsMinted.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(12)), "att", routeSender, DEST_DOMAIN, mintRecipient, AMOUNT + 1, 0, FINALITY, DEST_CALLER);
    }

    function test_T13_MinimalTransferAmountOfOne() public {
        _transit(_goodMessage(AMOUNT, _nonce(13)), AMOUNT - 1, 0, FINALITY);
        assertEq(relayer.lastTransferAmount(), 1, "transferAmount == 1 is valid");
        assertEq(relayer.lastFeeAmount(), AMOUNT - 1);
    }

    function test_T14_MaxFeeEqualToTransferAmountReverts() public {
        // transferAmount would be AMOUNT - FEE; maxFee equal to it must fail (v2 requires strict <).
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidMaxFee.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(14)), "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, AMOUNT - FEE, FINALITY, DEST_CALLER);
    }

    function test_T14b_MaxFeeZeroAccepted() public {
        _transit(_goodMessage(AMOUNT, _nonce(141)), FEE, 0, FINALITY);
        assertEq(relayer.lastMaxFee(), 0);
    }

    // ── T-15 a failed attempt leaves the nonce spendable ──

    function test_T15_RetryAfterFailedSplit() public {
        bytes32 n = _nonce(15);
        bytes memory msg_ = _goodMessage(AMOUNT, n);

        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.FeeExceedsMinted.selector);
        executor.executeTransit(msg_, "att", routeSender, DEST_DOMAIN, mintRecipient, AMOUNT, 0, FINALITY, DEST_CALLER);

        assertFalse(transmitter.usedNonce(n), "the whole tx rolled back, so the nonce is unspent");

        _transit(msg_, FEE, MAX_FEE, FINALITY); // same message, corrected parameters
        assertEq(relayer.lastTransferAmount(), AMOUNT - FEE);
        assertTrue(transmitter.usedNonce(n));
    }

    // ── T-16 ~ T-21 binding / mint failures ──

    function test_T16_WrongDestinationDomain() public {
        bytes memory m = _buildMessage(
            WRONG_DOMAIN, _nonce(16), bytes32(uint256(uint160(routeSender))), address(0x5011), address(fwd), AMOUNT
        );
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.WrongDestination.selector);
        executor.executeTransit(m, "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }

    /// @dev Reached by calling the forwarder DIRECTLY as the executor, because the honest path cannot produce it:
    ///      the executor derives its callee FROM mintRecipient, so via executeTransit this message would be routed
    ///      to 0xDEAD instead (which fails earlier, as NotContract — covered in TransitExecutor.t.sol).
    ///
    ///      That is exactly why the check must stay. The executor sits behind an upgradeable proxy; an upgrade could
    ///      change the derivation without touching forwarder code, and this is the forwarder's own defence.
    function test_T17_WrongMintRecipient() public {
        bytes memory m = _buildMessage(
            LOCAL_DOMAIN,
            _nonce(17),
            bytes32(uint256(uint160(routeSender))),
            address(0x5011),
            address(0xDEAD), // not this forwarder
            AMOUNT
        );
        usdc.mint(address(fwd), AMOUNT); // the balance bound must not be what rejects this
        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.WrongRecipient.selector);
        fwd.transferMinted(m, AMOUNT, FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }

    function test_T18_ReceiveFailed() public {
        transmitter.setForceFail(true);
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
        executor.executeTransit(_goodMessage(AMOUNT, _nonce(18)), "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }

    function test_T19_NothingMinted() public {
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.NothingMinted.selector);
        executor.executeTransit(_goodMessage(0, _nonce(19)), "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }

    /// @dev T-20 used to assert a named MalformedMessage on a short message. That gate is gone on purpose — the
    ///      message comes from the attested transmitter, and an out-of-range slice reverts by itself. What still
    ///      matters is that a short message CANNOT complete a transit, which is what this asserts.
    function test_T20_ShortMessageCannotTransit() public {
        bytes memory short_ = new bytes(247); // one byte below the end of a v1 burn body
        usdc.mint(address(fwd), AMOUNT);
        vm.prank(address(executor));
        vm.expectRevert();
        fwd.transferMinted(short_, AMOUNT, FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }

    function test_T21_NonceReplayRejected() public {
        bytes32 n = _nonce(21);
        _transit(_goodMessage(AMOUNT, n), FEE, MAX_FEE, FINALITY);

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
        executor.executeTransit(_goodMessage(AMOUNT, n), "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }


    // ── T-22 refund at mint time ──

    function test_T22_RefundGoesToTheRouteSender() public {
        bytes32 n = _nonce(22);
        vm.expectEmit(true, true, false, true, address(fwd));
        emit Refunded(n, routeSender, AMOUNT);

        vm.prank(operator);
        executor.executeRefund(_goodMessage(AMOUNT, n), "att", routeSender, DEST_DOMAIN, mintRecipient);

        assertEq(usdc.balanceOf(routeSender), AMOUNT, "refund goes to the route sender");
        assertEq(usdc.balanceOf(address(fwd)), 0);
    }

    // ── T-23 ~ T-25 recovery ──

    function test_T23_RecoverFullBalance() public {
        usdc.mint(address(fwd), 5_000);
        vm.expectEmit(true, false, false, true, address(fwd));
        emit Recovered(address(usdc), 5_000);
        vm.prank(operator);
        fwd.recoverERC20(address(usdc));
        assertEq(usdc.balanceOf(routeSender), 5_000);
        assertEq(usdc.balanceOf(address(fwd)), 0);
    }

    function test_T24_RecoverPartialAndBoundaries() public {
        usdc.mint(address(fwd), 5_000);

        vm.prank(operator);
        fwd.recoverERC20(address(usdc), 2_000);
        assertEq(usdc.balanceOf(routeSender), 2_000);
        assertEq(usdc.balanceOf(address(fwd)), 3_000);

        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.ZeroAmount.selector);
        fwd.recoverERC20(address(usdc), 0);

        vm.prank(operator);
        vm.expectRevert(); // ERC20InsufficientBalance, raised inside safeTransfer
        fwd.recoverERC20(address(usdc), 3_001);
    }

    function test_T25_RecoverForeignToken() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(fwd), 42);
        vm.prank(operator);
        fwd.recoverERC20(address(other));
        assertEq(other.balanceOf(routeSender), 42);
    }

    // ── T-26 access control across every entry point ──

    function test_T26_AllEntryPointsRejectStrangers() public {
        address attacker = address(0xBAD);
        bytes memory m = _goodMessage(AMOUNT, _nonce(26));

        vm.startPrank(attacker);
        // Transit surface: executor-gated on the forwarder, operator-gated on the executor in front of it.
        vm.expectRevert(ITransitForwarder.NotExecutor.selector);
        fwd.transferMinted(m, AMOUNT, FEE, MAX_FEE, FINALITY, DEST_CALLER);

        vm.expectRevert(ITransitForwarder.NotExecutor.selector);
        fwd.transferMinted(m, AMOUNT, FEE, MAX_FEE, FINALITY, DEST_CALLER);

        vm.expectRevert(ITransitForwarder.NotExecutor.selector);
        fwd.refundMinted(m, AMOUNT);

        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeTransit(m, "att", routeSender, DEST_DOMAIN, mintRecipient, FEE, MAX_FEE, FINALITY, DEST_CALLER);

        // Recovery surface: operator-gated.
        vm.expectRevert(ITransitForwarder.NotOperator.selector);
        fwd.recoverERC20(address(usdc));

        vm.expectRevert(ITransitForwarder.NotOperator.selector);
        fwd.recoverERC20(address(usdc), 1);
        vm.stopPrank();
    }

    // ── T-37 the off-chain contract: event topic0s must survive the executor migration ──

    /// @dev Computed from string literals, not from the interface, so a signature edit cannot silently move the
    ///      target along with the assertion. Any change here breaks every deployed log consumer.
    function test_T37_EventTopic0sAreUnchanged() public {
        assertEq(
            keccak256("TransitCompleted(bytes32,uint256,uint256,uint256,uint256,uint32,bytes32)"),
            TransitCompleted.selector,
            "TransitCompleted signature drifted"
        );
        assertEq(keccak256("Refunded(bytes32,address,uint256)"), Refunded.selector, "Refunded signature drifted");
        assertEq(keccak256("Recovered(address,uint256)"), Recovered.selector, "Recovered signature drifted");
    }

    // ── T-38 least-privilege split: neither authority can do the other's job ──

    /// @dev The whole point of splitting executor (push along the engraved route) from operator (pull back to
    ///      `sender`): a leak of either key cannot produce a withdrawal to an arbitrary address.
    function test_T38_AuthoritySplitIsEnforcedBothWays() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(38));
        usdc.mint(address(fwd), AMOUNT);

        // The operator cannot push funds, even along the legitimate route.
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.NotExecutor.selector);
        fwd.transferMinted(m, AMOUNT, FEE, MAX_FEE, FINALITY, DEST_CALLER);

        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.NotExecutor.selector);
        fwd.refundMinted(m, AMOUNT);

        // The executor cannot pull funds back, not even to `sender`.
        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.NotOperator.selector);
        fwd.recoverERC20(address(usdc));

        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.NotOperator.selector);
        fwd.recoverERC20(address(usdc), 1);
    }

    // ── T-39 / T-40 the bound on the executor-reported amount ──

    function test_T39_MintedAboveBalanceReverts() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(39));
        usdc.mint(address(fwd), AMOUNT);

        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.MissingBalance.selector);
        fwd.transferMinted(m, AMOUNT + 1, FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }

    function test_T40_ZeroMintedReverts() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(40));
        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.ZeroAmount.selector);
        fwd.transferMinted(m, 0, FEE, MAX_FEE, FINALITY, DEST_CALLER);
    }

    // ── T-41 ABI generation marker ──

    function test_T41_VersionMarksTheExecutorGeneration() public {
        assertEq(fwd.version(), 2, "entry points changed; version must mark the new ABI generation");
    }

    // ── T-27 native coin rejected ──

    function test_T27_NativeTransfersRejected() public {
        vm.deal(operator, 1 ether);

        vm.prank(operator);
        (bool okReceive,) = address(fwd).call{value: 1}("");
        assertFalse(okReceive, "receive() must revert");

        vm.prank(operator);
        (bool okFallback,) = address(fwd).call{value: 1}(hex"12345678");
        assertFalse(okFallback, "fallback() must revert");
    }

    // ── T-28 / T-29 initializer discipline ──

    function test_T28_ImplementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(routeSender, DEST_DOMAIN, mintRecipient);
    }

    function test_T29_ProxyCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fwd.initialize(routeSender, DEST_DOMAIN, mintRecipient);
    }

    // ── T-30 non-EVM source: a full 32-byte messageSender must NOT be rejected ──

    function test_T30_FullWidthMessageSenderAccepted() public {
        bytes memory m = _buildMessage(
            LOCAL_DOMAIN,
            _nonce(30),
            // A Solana-style 32-byte sender. Binding must ignore it entirely; comparing it against the 20-byte
            // `sender` would reject every non-EVM source domain.
            bytes32(0x1122334455667788990011223344556677889900112233445566778899001122),
            address(0x5011),
            address(fwd),
            AMOUNT
        );
        _transit(m, FEE, MAX_FEE, FINALITY);
        assertEq(relayer.lastTransferAmount(), AMOUNT - FEE, "non-EVM source must transit normally");
    }

    // ── T-31 storage layout (packing is a beacon-upgrade invariant) ──

    function test_T31_StorageLayoutPacking() public {
        // slot 0: sender (bytes 0..19) | destinationDomain (20..23) | _reentrant (24)
        bytes32 slot0 = vm.load(address(fwd), bytes32(uint256(0)));
        uint256 expected0 = uint256(uint160(routeSender)) | (uint256(DEST_DOMAIN) << 160);
        assertEq(uint256(slot0), expected0, "slot 0 packing drifted");

        // slot 1: mintRecipient
        assertEq(vm.load(address(fwd), bytes32(uint256(1))), mintRecipient, "mintRecipient must occupy slot 1");

        // slot 2 is the first __gap word and must be untouched.
        assertEq(vm.load(address(fwd), bytes32(uint256(2))), bytes32(0), "__gap must start at slot 2");
    }

    // ── constructor guards (not in the design matrix; added because they are funds-critical) ──

    function test_T32_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(ITransitForwarder.ZeroAddress.selector);
        new TransitForwarder(address(0), address(relayer), operator, address(executor), LOCAL_DOMAIN, DEST_DOMAIN);

        vm.expectRevert(ITransitForwarder.ZeroAddress.selector);
        new TransitForwarder(address(usdc), address(0), operator, address(executor), LOCAL_DOMAIN, DEST_DOMAIN);

        vm.expectRevert(ITransitForwarder.ZeroAddress.selector);
        new TransitForwarder(address(usdc), address(relayer), address(0), address(executor), LOCAL_DOMAIN, DEST_DOMAIN);

        vm.expectRevert(ITransitForwarder.ZeroAddress.selector);
        new TransitForwarder(
            address(usdc), address(relayer), operator, address(0), LOCAL_DOMAIN, DEST_DOMAIN
        );
    }

    function test_T33_ConstructorRejectsUsdcMismatch() public {
        MockUSDC otherUsdc = new MockUSDC();
        MockCCTPV2Relayer wrongRelayer = new MockCCTPV2Relayer(otherUsdc);
        vm.expectRevert(ITransitForwarder.UsdcMismatch.selector);
        new TransitForwarder(
            address(usdc), address(wrongRelayer), operator, address(executor), LOCAL_DOMAIN, DEST_DOMAIN
        );
    }

    /// @dev A deployment whose only allowed destination is its own chain could never produce a usable route.
    function test_T34_ConstructorRejectsSelfLoopConfig() public {
        vm.expectRevert(ITransitForwarder.SelfLoop.selector);
        new TransitForwarder(
            address(usdc), address(relayer), operator, address(executor), LOCAL_DOMAIN, LOCAL_DOMAIN
        );
    }

    /// @dev The destination is pinned at creation time: only ALLOWED_DESTINATION_DOMAIN can be initialized.
    function test_T35_InitializeRejectsForeignDestination() public {
        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.createForwarder(routeSender, OTHER_DEST_DOMAIN, mintRecipient);
        assertFalse(factory.isForwarderDeployed(routeSender, OTHER_DEST_DOMAIN, mintRecipient));
    }

    /// @dev ⚠️ The property that makes pinning safe: transfers read per-route STORAGE, never the immutable. A beacon
    ///      upgrade that moves ALLOWED_DESTINATION_DOMAIN must NOT redirect an already-deployed forwarder, because its
    ///      address (and the burner's committed mintRecipient) encode the original destination.
    function test_T36_BeaconUpgradeCannotRedirectExistingRoute() public {
        TransitForwarder movedAllowance = new TransitForwarder(
            address(usdc), address(relayer), operator, address(executor), LOCAL_DOMAIN, OTHER_DEST_DOMAIN
        );
        factory.upgradeForwarderImplementation(address(movedAllowance));

        assertEq(fwd.ALLOWED_DESTINATION_DOMAIN(), OTHER_DEST_DOMAIN, "the impl-level allowance did move");
        (, uint32 storedDomain,) = fwd.getRoute();
        assertEq(storedDomain, DEST_DOMAIN, "the route's own destination must be untouched");

        _transit(_goodMessage(AMOUNT, _nonce(36)), FEE, MAX_FEE, FINALITY);
        assertEq(relayer.lastDomain(), DEST_DOMAIN, "funds must still go where the address committed");
    }
}
