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
import {ITokenMessenger} from "../src/interfaces/ITokenMessenger.sol";
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

/// @dev Simulates the CCTP v1 MessageTransmitter: parses the burn body (same offsets as the contract) and mints
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

/// @dev Circle TokenMessengerV2 mock: records the depositForBurn arguments and pulls USDC via transferFrom, the
///      way the real messenger does. depositForBurnWithHook is implemented ONLY so an accidental switch to the hook
///      variant is observable (hookCallCount) — the transit path must never take it.
contract MockTokenMessenger is ITokenMessenger {
    IERC20 public immutable usdc;
    uint256 public lastAmount;
    uint32 public lastDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastMinFinality;
    uint256 public callCount;
    uint256 public hookCallCount;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        lastAmount = amount;
        lastDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinality = minFinalityThreshold;
        callCount++;
    }

    function depositForBurnWithHook(uint256 amount, uint32, bytes32, address, bytes32, uint256, uint32, bytes calldata)
        external
    {
        require(usdc.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        hookCallCount++;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

contract TransitForwarderTest is Test {
    MockUSDC usdc;
    MockTransmitter transmitter;
    MockTokenMessenger messengerMock;
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
    uint256 constant MAX_FEE = 500;
    uint32 constant FINALITY = 2000;
    /// @dev Non-zero on every path: the executor rejects an unset destinationCaller.
    bytes32 constant DEST_CALLER = bytes32(uint256(0xCA11E5));

    // mirrors of the interface events, for expectEmit
    event TransitCompleted(
        bytes32 indexed sourceNonce,
        uint256 minted,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    );
    event Refunded(bytes32 indexed sourceNonce, address indexed to, uint256 amount);
    event Recovered(address indexed token, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();
        transmitter = new MockTransmitter(usdc);
        messengerMock = new MockTokenMessenger(usdc);

        // The executor is deployed FIRST and behind a proxy: the forwarder impl takes its address as an immutable,
        // and it must be the address that survives an executor upgrade. Mirrors the real deployment order.
        TransitExecutor executorImpl = new TransitExecutor(address(usdc), address(transmitter), operator);
        executor = TransitExecutor(
            address(
                new ERC1967Proxy(
                    address(executorImpl), abi.encodeCall(TransitExecutor.initialize, (address(this), address(0)))
                )
            )
        );

        impl = new TransitForwarder(
            address(usdc), address(messengerMock), operator, address(executor), LOCAL_DOMAIN, DEST_DOMAIN
        );

        TransitForwarderFactory factoryImpl = new TransitForwarderFactory();
        bytes memory initData = abi.encodeCall(TransitForwarderFactory.initialize, (address(impl)));
        factory = TransitForwarderFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));

        fwd = TransitForwarder(payable(factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient)));
    }

    // ── message builder (CCTP v1 offsets) ──

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

    function _transit(bytes memory message, uint256 maxFee, uint32 finality) internal {
        vm.prank(operator);
        executor.executeTransit(message, "att", routeSender, DEST_DOMAIN, mintRecipient, maxFee, finality, DEST_CALLER);
    }

    // ── T-01 정상 transit ──

    function test_T01_MintAndTransfer_Happy() public {
        bytes memory msg_ = _goodMessage(AMOUNT, _nonce(1));
        _transit(msg_, MAX_FEE, FINALITY);

        assertEq(usdc.balanceOf(address(fwd)), 0, "forwarder must hold nothing after transit");
        assertEq(messengerMock.callCount(), 1, "messenger called once");
        assertEq(messengerMock.lastAmount(), AMOUNT, "the WHOLE minted amount is burned - no fee is withheld");
        assertEq(messengerMock.lastMaxFee(), MAX_FEE);
        assertEq(messengerMock.lastMinFinality(), FINALITY);
        assertEq(messengerMock.lastBurnToken(), address(usdc), "burnToken must be THIS chain's usdc");
        assertEq(usdc.balanceOf(address(messengerMock)), AMOUNT, "messenger pulled exactly the minted amount");
    }

    // ── T-02 destinationCaller is always set ──

    /// @dev There is one transit entry point and it always carries destinationCaller, so the onward burn must ALWAYS
    ///      take the WithCaller path. An unrestricted next hop is the griefing path this design closes; there is no
    ///      variant that leaves it open, and this asserts the plain depositForBurn route is unreachable.
    function test_T02_OnwardBurnAlwaysRestrictsTheNextCaller() public {
        bytes32 destCaller = bytes32(uint256(uint160(address(0xCA11))));
        vm.prank(operator);
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(2)),
            "att",
            routeSender,
            DEST_DOMAIN,
            mintRecipient,
            MAX_FEE,
            FINALITY,
            destCaller
        );

        assertEq(messengerMock.lastDestinationCaller(), destCaller, "the onward burn must always restrict its caller");
        assertEq(messengerMock.lastAmount(), AMOUNT);
    }

    // ── T-03 route comes from storage, not from the operator's arguments ──

    function test_T03_RouteFromStorageNotArguments() public {
        _transit(_goodMessage(AMOUNT, _nonce(3)), MAX_FEE, FINALITY);
        (address s, uint32 d, bytes32 r) = fwd.getRoute();
        assertEq(s, routeSender);
        assertEq(d, DEST_DOMAIN);
        assertEq(r, mintRecipient);
        assertEq(messengerMock.lastDomain(), DEST_DOMAIN, "messenger got the stored domain");
        assertEq(messengerMock.lastMintRecipient(), mintRecipient, "messenger got the stored mintRecipient");
    }

    // ── T-04 hookData passthrough ──

    /// @dev T-04 used to assert hookData passed through byte-identical. The transit path no longer carries hookData
    ///      at all — this design has no use for a hook on the onward burn, and CCTP v1 has no such concept — so the
    ///      property worth pinning is the inverse: the burn must ALWAYS be the plain depositForBurn variant.
    ///      depositForBurnWithHook would change what arrives on Injective, and v2 calls the messenger directly, so
    ///      nothing between here and Circle would normalise a stray hook away.
    function test_T04_OnwardBurnCarriesNoHook() public {
        _transit(_goodMessage(AMOUNT, _nonce(4)), MAX_FEE, FINALITY);
        assertEq(messengerMock.callCount(), 1, "plain depositForBurn");
        assertEq(messengerMock.hookCallCount(), 0, "the onward burn must never take the hook variant");
    }

    // ── T-05 event ──

    function test_T05_TransitCompletedEvent() public {
        bytes32 n = _nonce(5);
        vm.expectEmit(true, false, false, true, address(fwd));
        emit TransitCompleted(n, AMOUNT, MAX_FEE, FINALITY, DEST_CALLER);
        _transit(_goodMessage(AMOUNT, n), MAX_FEE, FINALITY);
    }

    // ── T-06 no residual allowance ──

    function test_T06_NoResidualAllowance() public {
        _transit(_goodMessage(AMOUNT, _nonce(6)), MAX_FEE, FINALITY);
        assertEq(usdc.allowance(address(fwd), address(messengerMock)), 0, "messenger must consume the whole approval");
    }

    // ── T-07 pre-existing dust is excluded from the delta ──

    function test_T07_PreExistingDustExcluded() public {
        uint256 dust = 777;
        usdc.mint(address(fwd), dust);

        _transit(_goodMessage(AMOUNT, _nonce(7)), MAX_FEE, FINALITY);

        assertEq(messengerMock.lastAmount(), AMOUNT, "dust must not inflate the transit amount");
        assertEq(usdc.balanceOf(address(messengerMock)), AMOUNT, "messenger pulled exactly the minted amount");
        assertEq(usdc.balanceOf(address(fwd)), dust, "dust stays for recoverERC20");
    }

    // ── T-08 no fee is taken (the v2 change) ──

    /// @dev v1 forced a non-zero relayer fee (ZeroFee), because the PaymentContract rejected a zero one. v2 takes no
    ///      fee at all, so the conservation property is exact: every unit minted is burned onward, and NOTHING is
    ///      left behind on the forwarder or diverted anywhere else. A reintroduced fee would break this.
    function test_T08_NoFeeIsWithheldAnywhere() public {
        uint256 supplyBefore = usdc.totalSupply();
        _transit(_goodMessage(AMOUNT, _nonce(8)), MAX_FEE, FINALITY);

        assertEq(messengerMock.lastAmount(), AMOUNT, "the burned amount equals the minted amount exactly");
        assertEq(usdc.balanceOf(address(fwd)), 0, "nothing withheld on the forwarder");
        assertEq(usdc.balanceOf(address(executor)), 0, "nothing withheld on the executor");
        assertEq(usdc.balanceOf(operator), 0, "nothing diverted to the operator");
        assertEq(usdc.totalSupply() - supplyBefore, AMOUNT, "the mint is fully accounted for");
    }

    // ── T-09 / T-10 finality threshold ──

    function test_T09_InvalidFinalityReverts() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidFinalityThreshold.selector);
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(9)), "att", routeSender, DEST_DOMAIN, mintRecipient, MAX_FEE, 1500, DEST_CALLER
        );
    }

    function test_T09b_FinalityCheckedBeforeBinding() public {
        bytes memory badBinding = _buildMessage(
            WRONG_DOMAIN, _nonce(91), bytes32(uint256(uint160(routeSender))), address(0x5011), address(fwd), AMOUNT
        );
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidFinalityThreshold.selector);
        executor.executeTransit(badBinding, "att", routeSender, DEST_DOMAIN, mintRecipient, MAX_FEE, 1500, DEST_CALLER);
    }

    function test_T10_BothFinalityValuesAccepted() public {
        _transit(_goodMessage(AMOUNT, _nonce(101)), MAX_FEE, 1000);
        assertEq(messengerMock.lastMinFinality(), 1000);
        _transit(_goodMessage(AMOUNT, _nonce(102)), MAX_FEE, 2000);
        assertEq(messengerMock.lastMinFinality(), 2000);
    }

    // ── T-11 ~ T-14 maxFee boundaries (v2 bounds it against `minted`, since nothing is deducted first) ──

    function test_T11_MaxFeeEqualToMintedReverts() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidMaxFee.selector);
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(11)),
            "att",
            routeSender,
            DEST_DOMAIN,
            mintRecipient,
            AMOUNT,
            FINALITY,
            DEST_CALLER
        );
    }

    function test_T12_MaxFeeAboveMintedReverts() public {
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidMaxFee.selector);
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(12)),
            "att",
            routeSender,
            DEST_DOMAIN,
            mintRecipient,
            AMOUNT + 1,
            FINALITY,
            DEST_CALLER
        );
    }

    /// @dev The accepting side of the same strict boundary: maxFee == minted - 1 is the largest legal value.
    function test_T13_MaxFeeJustBelowMintedAccepted() public {
        _transit(_goodMessage(AMOUNT, _nonce(13)), AMOUNT - 1, FINALITY);
        assertEq(messengerMock.lastAmount(), AMOUNT, "the full amount is still burned");
        assertEq(messengerMock.lastMaxFee(), AMOUNT - 1);
    }

    /// @dev A one-unit transit: the smallest amount for which a legal maxFee (0) exists.
    function test_T14_MinimalTransitOfOneUnit() public {
        _transit(_goodMessage(1, _nonce(14)), 0, FINALITY);
        assertEq(messengerMock.lastAmount(), 1);
    }

    function test_T14b_MaxFeeZeroAccepted() public {
        _transit(_goodMessage(AMOUNT, _nonce(141)), 0, FINALITY);
        assertEq(messengerMock.lastMaxFee(), 0);
    }

    // ── T-15 a failed attempt leaves the nonce spendable ──

    function test_T15_RetryAfterFailedMaxFee() public {
        bytes32 n = _nonce(15);
        bytes memory msg_ = _goodMessage(AMOUNT, n);

        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.InvalidMaxFee.selector);
        executor.executeTransit(msg_, "att", routeSender, DEST_DOMAIN, mintRecipient, AMOUNT, FINALITY, DEST_CALLER);

        assertFalse(transmitter.usedNonce(n), "the whole tx rolled back, so the nonce is unspent");

        _transit(msg_, MAX_FEE, FINALITY); // same message, corrected parameters
        assertEq(messengerMock.lastAmount(), AMOUNT);
        assertTrue(transmitter.usedNonce(n));
    }

    // ── T-16 ~ T-21 binding / mint failures ──

    function test_T16_WrongDestinationDomain() public {
        bytes memory m = _buildMessage(
            WRONG_DOMAIN, _nonce(16), bytes32(uint256(uint160(routeSender))), address(0x5011), address(fwd), AMOUNT
        );
        vm.prank(operator);
        vm.expectRevert(ITransitForwarder.WrongDestination.selector);
        executor.executeTransit(m, "att", routeSender, DEST_DOMAIN, mintRecipient, MAX_FEE, FINALITY, DEST_CALLER);
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
        fwd.transferMinted(m, AMOUNT, MAX_FEE, FINALITY, DEST_CALLER);
    }

    function test_T18_ReceiveFailed() public {
        transmitter.setForceFail(true);
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
        executor.executeTransit(
            _goodMessage(AMOUNT, _nonce(18)),
            "att",
            routeSender,
            DEST_DOMAIN,
            mintRecipient,
            MAX_FEE,
            FINALITY,
            DEST_CALLER
        );
    }

    function test_T19_NothingMinted() public {
        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.NothingMinted.selector);
        executor.executeTransit(
            _goodMessage(0, _nonce(19)), "att", routeSender, DEST_DOMAIN, mintRecipient, MAX_FEE, FINALITY, DEST_CALLER
        );
    }

    /// @dev T-20 used to assert a named MalformedMessage on a short message. That gate is gone on purpose — the
    ///      message comes from the attested transmitter, and an out-of-range slice reverts by itself. What still
    ///      matters is that a short message CANNOT complete a transit, which is what this asserts.
    function test_T20_ShortMessageCannotTransit() public {
        bytes memory short_ = new bytes(247); // one byte below the end of a v1 burn body
        usdc.mint(address(fwd), AMOUNT);
        vm.prank(address(executor));
        vm.expectRevert();
        fwd.transferMinted(short_, AMOUNT, MAX_FEE, FINALITY, DEST_CALLER);
    }

    function test_T21_NonceReplayRejected() public {
        bytes32 n = _nonce(21);
        _transit(_goodMessage(AMOUNT, n), MAX_FEE, FINALITY);

        vm.prank(operator);
        vm.expectRevert(ITransitExecutor.ReceiveFailed.selector);
        executor.executeTransit(
            _goodMessage(AMOUNT, n), "att", routeSender, DEST_DOMAIN, mintRecipient, MAX_FEE, FINALITY, DEST_CALLER
        );
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
        fwd.transferMinted(m, AMOUNT, MAX_FEE, FINALITY, DEST_CALLER);

        vm.expectRevert(ITransitForwarder.NotExecutor.selector);
        fwd.transferMinted(m, AMOUNT, MAX_FEE, FINALITY, DEST_CALLER);

        vm.expectRevert(ITransitForwarder.NotExecutor.selector);
        fwd.refundMinted(m, AMOUNT);

        vm.expectRevert(ITransitExecutor.NotOperator.selector);
        executor.executeTransit(m, "att", routeSender, DEST_DOMAIN, mintRecipient, MAX_FEE, FINALITY, DEST_CALLER);

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
    /// @dev ⚠️ TransitCompleted's topic0 CHANGED in forwarder v2 (feeAmount and transferAmount removed) — that break
    ///      was deliberate and is announced in ITransitForwarder. Refunded and Recovered did NOT change, and this
    ///      test is what keeps the v2 signature frozen from here on.
    function test_T37_EventTopic0sAreUnchanged() public {
        assertEq(
            keccak256("TransitCompleted(bytes32,uint256,uint256,uint32,bytes32)"),
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
        fwd.transferMinted(m, AMOUNT, MAX_FEE, FINALITY, DEST_CALLER);

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

    // ── T-42 / T-43 the self-defence copies of the executor's two gates ──

    /// @dev Every other transit invariant is re-checked here because the executor is upgradeable. This one is the
    ///      reason the executor exists, so it must not be the exception — an upgraded executor that stopped
    ///      rejecting a zero destinationCaller would reopen the griefing hole one hop along.
    function test_T42_EmptyDestinationCallerRejectedByTheForwarderToo() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(42));
        usdc.mint(address(fwd), AMOUNT);

        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.EmptyDestinationCaller.selector);
        fwd.transferMinted(m, AMOUNT, MAX_FEE, FINALITY, bytes32(0));
    }

    /// @dev The forwarder holds the attested message, so it can check the reported amount against it rather than
    ///      only bounding it by its own balance. CCTP v1 deducts no destination-side fee, so the equality is exact.
    function test_T43_MintedMustEqualTheAttestedAmount() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(43));
        usdc.mint(address(fwd), AMOUNT);

        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.AmountMismatch.selector);
        fwd.transferMinted(m, AMOUNT - 1, MAX_FEE, FINALITY, DEST_CALLER);
    }

    // ── T-39 / T-40 the bound on the executor-reported amount ──

    function test_T39_MintedAboveBalanceReverts() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(39));
        usdc.mint(address(fwd), AMOUNT);

        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.MissingBalance.selector);
        fwd.transferMinted(m, AMOUNT + 1, MAX_FEE, FINALITY, DEST_CALLER);
    }

    function test_T40_ZeroMintedReverts() public {
        bytes memory m = _goodMessage(AMOUNT, _nonce(40));
        vm.prank(address(executor));
        vm.expectRevert(ITransitForwarder.ZeroAmount.selector);
        fwd.transferMinted(m, 0, MAX_FEE, FINALITY, DEST_CALLER);
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
        _transit(m, MAX_FEE, FINALITY);
        assertEq(messengerMock.lastAmount(), AMOUNT, "non-EVM source must transit normally");
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
        new TransitForwarder(address(0), address(messengerMock), operator, address(executor), LOCAL_DOMAIN, DEST_DOMAIN);

        vm.expectRevert(ITransitForwarder.ZeroAddress.selector);
        new TransitForwarder(address(usdc), address(0), operator, address(executor), LOCAL_DOMAIN, DEST_DOMAIN);

        vm.expectRevert(ITransitForwarder.ZeroAddress.selector);
        new TransitForwarder(
            address(usdc), address(messengerMock), address(0), address(executor), LOCAL_DOMAIN, DEST_DOMAIN
        );

        vm.expectRevert(ITransitForwarder.ZeroAddress.selector);
        new TransitForwarder(address(usdc), address(messengerMock), operator, address(0), LOCAL_DOMAIN, DEST_DOMAIN);
    }

    /// @dev v1 asserted `paymentContract.usdc() == usdc` in the constructor (UsdcMismatch). ITokenMessenger has no
    ///      such getter, so that guard is gone and THIS is what replaced it: burnToken is always the impl's own
    ///      `usdc` immutable, never a value read from the message. The message's burnToken is a SOURCE-domain
    ///      address (0x5011 here) and forwarding it would burn the wrong token — or nothing at all.
    function test_T33_BurnTokenIsAlwaysThisChainsUsdc() public {
        _transit(_goodMessage(AMOUNT, _nonce(33)), MAX_FEE, FINALITY);
        assertEq(messengerMock.lastBurnToken(), address(usdc), "burnToken must be the impl's usdc immutable");
        assertTrue(messengerMock.lastBurnToken() != address(0x5011), "never the message's source-domain burnToken");
    }

    /// @dev A deployment whose only allowed destination is its own chain could never produce a usable route.
    function test_T34_ConstructorRejectsSelfLoopConfig() public {
        vm.expectRevert(ITransitForwarder.SelfLoop.selector);
        new TransitForwarder(
            address(usdc), address(messengerMock), operator, address(executor), LOCAL_DOMAIN, LOCAL_DOMAIN
        );
    }

    /// @dev The destination is pinned at creation time: only ALLOWED_DESTINATION_DOMAIN can be initialized.
    function test_T35_InitializeRejectsForeignDestination() public {
        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.createForwarder(routeSender, OTHER_DEST_DOMAIN, mintRecipient);
        // The probe refuses the same route rather than reporting "not deployed" — see TF5b for why `false` would be
        // the more dangerous answer.
        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.isForwarderDeployed(routeSender, OTHER_DEST_DOMAIN, mintRecipient);
    }

    /// @dev ⚠️ The property that makes pinning safe: transfers read per-route STORAGE, never the immutable. A beacon
    ///      upgrade that moves ALLOWED_DESTINATION_DOMAIN must NOT redirect an already-deployed forwarder, because its
    ///      address (and the burner's committed mintRecipient) encode the original destination.
    function test_T36_BeaconUpgradeCannotRedirectExistingRoute() public {
        TransitForwarder movedAllowance = new TransitForwarder(
            address(usdc), address(messengerMock), operator, address(executor), LOCAL_DOMAIN, OTHER_DEST_DOMAIN
        );
        factory.upgradeForwarderImplementation(address(movedAllowance));

        assertEq(fwd.ALLOWED_DESTINATION_DOMAIN(), OTHER_DEST_DOMAIN, "the impl-level allowance did move");
        (, uint32 storedDomain,) = fwd.getRoute();
        assertEq(storedDomain, DEST_DOMAIN, "the route's own destination must be untouched");

        _transit(_goodMessage(AMOUNT, _nonce(36)), MAX_FEE, FINALITY);
        assertEq(messengerMock.lastDomain(), DEST_DOMAIN, "funds must still go where the address committed");
    }
}
