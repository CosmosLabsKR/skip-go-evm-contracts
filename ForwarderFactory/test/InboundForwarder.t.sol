// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";

import {InboundForwarder} from "../src/InboundForwarder.sol";
import {InboundForwarderFactory} from "../src/InboundForwarderFactory.sol";
import {IInboundForwarder} from "../src/interfaces/IInboundForwarder.sol";
import {IInboundForwarderFactory} from "../src/interfaces/IInboundForwarderFactory.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";

// ── Mocks ──────────────────────────────────────────────────────────────────

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
        bytes32 nonce = bytes32(message[12:44]);
        if (usedNonce[nonce]) return false; // replay → fail
        usedNonce[nonce] = true;
        bytes32 mintRecipient = bytes32(message[184:216]);
        uint256 amount = uint256(bytes32(message[216:248]));
        if (amount > 0) usdc.mint(address(uint160(uint256(mintRecipient))), amount);
        return true;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

contract InboundForwarderTest is Test {
    MockUSDC usdc;
    MockTransmitter transmitter;
    InboundForwarder impl;
    InboundForwarderFactory factory;

    address operator = address(0xA11CE);
    uint32 constant INJ_DOMAIN = 9; // arbitrary test value for Injective domain
    uint32 constant WRONG_DOMAIN = 7;

    address sourceSender = address(0xBEEF); // source-EVM burn depositor

    // Route key = the stable final intent (sender, destinationChainId, destinationReceiver). destinationReceiver is
    // the FINAL-hop recipient; in multi-hop it is generally NOT equal to the next-hop hookReceiver below.
    string destinationChainId = "dydx-mainnet-1";
    string destinationReceiver = "dydx1finalreceiverxxxxxxxxxxxxxxxxxxxxxxx";

    // Per-transfer IBC route carried in hookData (decoded on-chain at mintAndRoute). channelId is volatile; receiver
    // is the next-hop recipient (a PFM intermediate in multi-hop).
    string hookChannelId = "channel-126";
    string hookReceiver = "inj1nexthopxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

    // hookData envelope discovery tag (= CCTP_RELAYER_ADDRESS, injected by cctpd). On-chain it is read but
    // deliberately ignored — never used, validated, or stored — so its value never affects routing.
    address constant RELAYER_TAG = address(0xC0FFEE);

    // canonical event (must match injective-event/src/IBCTransferEmitter.sol)
    event IBCTransferRequested(
        string sourcePort,
        string sourceChannel,
        string tokenDenom,
        uint256 tokenAmount,
        address sender,
        string receiver,
        string memo,
        uint64 timeoutTimestamp
    );
    event Refunded(bytes32 indexed sourceNonce, address indexed to, uint256 amount, IInboundForwarder.RefundKind kind);

    InboundForwarder fwd;

    function setUp() public {
        usdc = new MockUSDC();
        transmitter = new MockTransmitter(usdc);
        impl = new InboundForwarder(address(usdc), address(transmitter), operator, INJ_DOMAIN);

        InboundForwarderFactory factoryImpl = new InboundForwarderFactory();
        bytes memory initData = abi.encodeCall(InboundForwarderFactory.initialize, (address(impl)));
        factory = InboundForwarderFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));

        fwd = InboundForwarder(payable(factory.createForwarder(sourceSender, destinationChainId, destinationReceiver)));
    }

    // ── helpers ──

    /// @dev inner route payload: abi.encode(string channelId, string receiver, bytes memo).
    function _innerHook(string memory channelId, string memory receiver, bytes memory memo)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(channelId, receiver, memo);
    }

    /// @dev hookData envelope (D-3): abi.encode(address relayer, bytes inner). relayer is a monitor-only discovery
    ///      tag ignored on-chain; wraps the canonical RELAYER_TAG so existing cases exercise the envelope path.
    function _hook(string memory channelId, string memory receiver, bytes memory memo)
        internal
        pure
        returns (bytes memory)
    {
        return _envelope(RELAYER_TAG, _innerHook(channelId, receiver, memo));
    }

    /// @dev Wrap an inner route payload with an explicit relayer discovery tag.
    function _envelope(address relayer, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encode(relayer, inner);
    }

    /// @dev Well-formed hookData with the canonical next-hop route and the given memo.
    function _validHook(bytes memory memo) internal view returns (bytes memory) {
        return _hook(hookChannelId, hookReceiver, memo);
    }

    // ── message builder (CCTP v2 offsets) ──
    function _buildMessage(
        uint32 destinationDomain,
        bytes32 nonce,
        bytes32 messageSender,
        address burnToken,
        address mintRecipient,
        uint256 amount,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        bytes memory header = abi.encodePacked(
            uint32(1), // version
            uint32(1), // sourceDomain
            destinationDomain, // [8:12]
            nonce, // [12:44]
            bytes32(uint256(0xCC72)), // outer sender [44:76]
            bytes32(0), // recipient [76:108]
            bytes32(0), // destinationCaller [108:140]
            uint32(2000), // minFinalityThreshold [140:144]
            uint32(2000) // finalityThresholdExecuted [144:148]
        );
        bytes memory body = abi.encodePacked(
            uint32(1), // body version [148:152]
            bytes32(uint256(uint160(burnToken))), // burnToken [152:184]
            bytes32(uint256(uint160(mintRecipient))), // mintRecipient [184:216]
            amount, // [216:248]
            messageSender, // [248:280]
            uint256(0), // maxFee [280:312]
            uint256(0), // feeExecuted [312:344]
            uint256(0) // expirationBlock [344:376]
        );
        return abi.encodePacked(header, body, hookData);
    }

    function _goodMessage(uint256 amount, bytes memory hookData, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        return _buildMessage(
            INJ_DOMAIN,
            nonce,
            bytes32(uint256(uint160(sourceSender))),
            address(usdc),
            address(fwd),
            amount,
            hookData
        );
    }

    /// @dev Independent reimplementation of the memo rendering (0x-prefixed lowercase hex). Hand-written on purpose:
    ///      an oracle calling Strings.toHexString would pass whatever that library did, and the IRIS listener
    ///      depends on this exact representation.
    function _hex(bytes memory data) internal pure returns (string memory) {
        bytes16 sym = "0123456789abcdef";
        bytes memory out = new bytes(2 + data.length * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            out[2 + i * 2] = sym[uint8(data[i]) >> 4];
            out[3 + i * 2] = sym[uint8(data[i]) & 0x0f];
        }
        return string(out);
    }

    /// @dev Mirror of the on-chain timeout: now + 1 day, in unix nanoseconds.
    function _expectedTimeout() internal view returns (uint64) {
        return uint64((block.timestamp + 1 days) * 1e9);
    }

    // ── T13/T14/T16: CREATE2 determinism ──
    function test_AddressIsDeterministic() public {
        address predicted = factory.getForwarderAddress(sourceSender, destinationChainId, destinationReceiver);
        assertEq(predicted, address(fwd));
    }

    // GOLDEN VECTOR (funds-critical): freezes the salt PREIMAGE (the abi.encode arg order/types) against an
    // externally-computed literal, so a reorder/retype of (sender, destinationChainId, destinationReceiver) that would
    // silently move every predicted address — orphaning already-deployed forwarders' funds — fails loudly here. The
    // literal was computed independently of this source:
    //   cast keccak $(cast abi-encode "f(address,string,string)" 0xA1 "injective-1" "inj1recipient")
    function test_GoldenVector_SaltPreimageFrozen() public {
        bytes32 frozenSalt = 0x8fbdbfdf257ad8b4b64635f0b7fff33c4c885752636f069828557b569d9b50f8;
        address fromFrozenSalt = Create2.computeAddress(frozenSalt, factory.beaconInitCodeHash(), address(factory));
        assertEq(
            factory.getForwarderAddress(address(0xA1), "injective-1", "inj1recipient"),
            fromFrozenSalt,
            "salt preimage drifted from frozen golden vector"
        );
    }

    function test_RedeployReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IInboundForwarderFactory.ForwarderAlreadyDeployed.selector, address(fwd))
        );
        factory.createForwarder(sourceSender, destinationChainId, destinationReceiver);
    }

    // ── T16: same sender, different final intent → distinct address (address-binding integrity) ──
    // destinationChainId/destinationReceiver are salt inputs, so the forwarder address commits to the FINAL intent.
    // A route differing only in destinationReceiver (or destinationChainId) MUST map to a different CREATE2 address;
    // otherwise final-intent integrity (which rides on mintRecipient == this address) would collapse. The per-transfer
    // IBC route (channelId/receiver) is NOT part of the key — it comes from hookData and never affects the address.
    function test_DifferentDestination_DifferentAddress() public {
        string memory otherReceiver = "dydx1otheryyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy";
        address predictedOther = factory.getForwarderAddress(sourceSender, destinationChainId, otherReceiver);
        assertTrue(predictedOther != address(fwd), "different destinationReceiver must yield different address");

        // changing only destinationChainId must also diverge
        address predictedChain = factory.getForwarderAddress(sourceSender, "noble-1", destinationReceiver);
        assertTrue(predictedChain != address(fwd), "different destinationChainId must yield different address");
        assertTrue(predictedChain != predictedOther, "distinct salts must not collide");

        // the divergent route is itself deployable at exactly its predicted address (determinism holds per-route)
        address deployedOther = factory.createForwarder(sourceSender, destinationChainId, otherReceiver);
        assertEq(deployedOther, predictedOther, "divergent route deploys at its predicted address");
    }

    // ── T17 + initialize ──
    function test_RouteAndRefundRecipientDefault() public {
        (address s, string memory c, string memory r, address refund) = fwd.getRoute();
        assertEq(s, sourceSender);
        assertEq(c, destinationChainId);
        assertEq(r, destinationReceiver);
        assertEq(refund, sourceSender); // D-20: default refund = sender
    }

    // ── T1: mintAndRoute happy path + T18 dynamic hookData (channelId/receiver from hookData, memo = hex) ──
    function test_MintAndRoute_EmitsCanonicalEvent() public {
        uint256 amount = 1_000_000;
        bytes memory memo = bytes("{\"forward\":{\"receiver\":\"dydx1...\"}}");
        bytes memory hookData = _validHook(memo);
        bytes memory message = _goodMessage(amount, hookData, keccak256("n1"));

        // channelId/receiver are emitted from the DECODED hookData, not from proxy storage.
        vm.expectEmit(true, true, true, true, address(fwd));
        emit IBCTransferRequested(
            "transfer", hookChannelId, fwd.DENOM(), amount, address(fwd), hookReceiver, _hex(memo), _expectedTimeout()
        );
        vm.prank(operator);
        fwd.mintAndRoute(message, "");

        // funds remain on the forwarder (synchronous hook would consume them in the same tx)
        assertEq(usdc.balanceOf(address(fwd)), amount);
    }

    // ── Funds-critical: decoded channelId/receiver + hex memo + on-chain timeout vs hardcoded literals ──
    function test_MintAndRoute_HexAndTimeout_KnownVectors() public {
        vm.warp(1_000_000_000); // fixed now → timeout = (1e9 + 86400) * 1e9 = 1_000_086_400_000_000_000 ns
        uint256 amount = 1_000_000;
        bytes memory memo = hex"deadbeef"; // raw bytes → memo must be exactly "0xdeadbeef"
        bytes memory hookData = _hook("channel-126", "inj1nexthopxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", memo);
        bytes memory message = _goodMessage(amount, hookData, keccak256("nKV"));

        vm.expectEmit(true, true, true, true, address(fwd));
        emit IBCTransferRequested(
            "transfer",
            "channel-126",
            fwd.DENOM(),
            amount,
            address(fwd),
            "inj1nexthopxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            "0xdeadbeef",
            uint64(1_000_086_400_000_000_000)
        );
        vm.prank(operator);
        fwd.mintAndRoute(message, "");
    }

    // ── EmptyHookRoute: decoded hookData channel or receiver is empty → revert ──
    function test_MintAndRoute_RevertsOnEmptyHookChannel() public {
        bytes memory message = _goodMessage(1_000_000, _hook("", hookReceiver, bytes("m")), keccak256("ehc"));
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.EmptyHookRoute.selector);
        fwd.mintAndRoute(message, "");
    }

    function test_MintAndRoute_RevertsOnEmptyHookReceiver() public {
        bytes memory message = _goodMessage(1_000_000, _hook(hookChannelId, "", bytes("m")), keccak256("ehr"));
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.EmptyHookRoute.selector);
        fwd.mintAndRoute(message, "");
    }

    // ── Malformed hookData (neither the envelope nor the inner tail decodes) → abi.decode reverts → whole tx reverts ──
    function test_MintAndRoute_RevertsOnMalformedHookData() public {
        bytes memory message = _goodMessage(1_000_000, hex"deadbeef", keccak256("mal"));
        vm.prank(operator);
        vm.expectRevert(); // low-level abi.decode revert (no named selector)
        fwd.mintAndRoute(message, "");
    }

    // ── Envelope: hookData wrapped as abi.encode(address relayer, bytes inner) decodes to the inner route ──
    //    Vector mirrors the cctpd encoder: inner = f(string,string,bytes) "channel-01"/"inj1recv"/0x, then f(address,bytes).
    function test_MintAndRoute_EnvelopeDecodesInnerRoute() public {
        uint256 amount = 1_000_000;
        bytes memory memo = bytes(""); // 0x
        bytes memory inner = _innerHook("channel-01", "inj1recv", memo);
        bytes memory hookData = _envelope(RELAYER_TAG, inner);
        bytes memory message = _goodMessage(amount, hookData, keccak256("env"));

        vm.expectEmit(true, true, true, true, address(fwd));
        emit IBCTransferRequested(
            "transfer", "channel-01", fwd.DENOM(), amount, address(fwd), "inj1recv", _hex(memo), _expectedTimeout()
        );
        vm.prank(operator);
        fwd.mintAndRoute(message, "");
    }

    // ── relayer tag is discovery-only: two different relayer addresses over the same inner route emit identical events ──
    function test_MintAndRoute_IgnoresRelayerTag() public {
        uint256 amount = 1_000_000;
        bytes memory memo = hex"beef";
        bytes memory inner = _innerHook(hookChannelId, hookReceiver, memo);

        // relayer #1
        bytes memory msg1 = _goodMessage(amount, _envelope(address(0x1111), inner), keccak256("rly1"));
        vm.expectEmit(true, true, true, true, address(fwd));
        emit IBCTransferRequested(
            "transfer", hookChannelId, fwd.DENOM(), amount, address(fwd), hookReceiver, _hex(memo), _expectedTimeout()
        );
        vm.prank(operator);
        fwd.mintAndRoute(msg1, "");

        // relayer #2 (different address, same inner) → identical routing, unaffected by the tag
        bytes memory msg2 = _goodMessage(amount, _envelope(address(0x2222), inner), keccak256("rly2"));
        vm.expectEmit(true, true, true, true, address(fwd));
        emit IBCTransferRequested(
            "transfer", hookChannelId, fwd.DENOM(), amount, address(fwd), hookReceiver, _hex(memo), _expectedTimeout()
        );
        vm.prank(operator);
        fwd.mintAndRoute(msg2, "");
    }

    // ── Event ABI must equal the canonical IBCTransferEmitter listener ABI ──
    function test_EventSignatureMatchesCanonical() public {
        bytes32 expected = keccak256("IBCTransferRequested(string,string,string,uint256,address,string,string,uint64)");
        assertEq(IBCTransferRequested.selector, expected);
    }

    // ── DENOM is derived as erc20:<EIP-55 checksummed usdc address> (funds-critical: must match Injective bank) ──
    function test_DenomDerivation_RealAddresses() public {
        // Real Injective USDC addresses (Config.sol). The Solidity literals are themselves EIP-55 checksummed,
        // so the derived denom must reproduce them verbatim — matching the cctp harness `erc20:0x...` bank denom.
        InboundForwarder mainnetFwd =
            new InboundForwarder(0xa00C59fF5a080D2b954d0c75e46E22a0c371235a, address(transmitter), operator, INJ_DOMAIN);
        assertEq(mainnetFwd.DENOM(), "erc20:0xa00C59fF5a080D2b954d0c75e46E22a0c371235a");

        InboundForwarder testnetFwd =
            new InboundForwarder(0x0C382e685bbeeFE5d3d9C29e29E341fEE8E84C5d, address(transmitter), operator, INJ_DOMAIN);
        assertEq(testnetFwd.DENOM(), "erc20:0x0C382e685bbeeFE5d3d9C29e29E341fEE8E84C5d");
    }

    // No fuzz companion on purpose: DENOM() renders straight from `usdc`, so a fuzzed comparison against
    // "erc20:" ++ toChecksumHexString would restate the implementation and could never fail. The hardcoded vectors
    // above are the real check — this repo does not compute those strings.

    // ── T2: mintAndRefund (no hookData decode on the refund path) ──
    function test_MintAndRefund() public {
        uint256 amount = 500_000;
        bytes memory message = _goodMessage(amount, bytes(""), keccak256("n2"));

        vm.expectEmit(true, true, false, true, address(fwd));
        emit Refunded(keccak256("n2"), sourceSender, amount, IInboundForwarder.RefundKind.MintTime);
        vm.prank(operator);
        fwd.mintAndRefund(message, "");

        assertEq(usdc.balanceOf(sourceSender), amount);
        assertEq(usdc.balanceOf(address(fwd)), 0);
    }

    // ── T3: refund(amount) post-route ──
    function test_RefundPostRoute() public {
        usdc.mint(address(fwd), 300_000); // simulate IBC-returned funds
        vm.expectEmit(true, true, false, true, address(fwd));
        emit Refunded(bytes32(0), sourceSender, 300_000, IInboundForwarder.RefundKind.PostRoute);
        vm.prank(operator);
        fwd.refund(300_000);
        assertEq(usdc.balanceOf(sourceSender), 300_000);
    }

    function test_RefundRevertsOnMissingBalance() public {
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.MissingBalance.selector);
        fwd.refund(1);
    }

    // ── T3b: refund() refunds the full held balance ──
    function test_RefundAll_FullBalance() public {
        usdc.mint(address(fwd), 250_000); // simulate IBC-returned funds
        vm.expectEmit(true, true, false, true, address(fwd));
        emit Refunded(bytes32(0), sourceSender, 250_000, IInboundForwarder.RefundKind.PostRoute);
        vm.prank(operator);
        fwd.refund();
        assertEq(usdc.balanceOf(sourceSender), 250_000);
        assertEq(usdc.balanceOf(address(fwd)), 0);
    }

    function test_RefundAll_RevertsOnZeroBalance() public {
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.ZeroAmount.selector);
        fwd.refund();
    }

    function test_RefundAll_OnlyOperator() public {
        usdc.mint(address(fwd), 1);
        vm.prank(address(0xDEAD));
        vm.expectRevert(IInboundForwarder.NotOperator.selector);
        fwd.refund();
    }

    // ── T9: residual balance — mintAndRoute uses delta, not full balance ──
    function test_MintAndRoute_UsesDeltaNotBalance() public {
        usdc.mint(address(fwd), 777); // pre-existing residual
        uint256 amount = 1_000_000;
        bytes memory memo = bytes("m");
        bytes memory message = _goodMessage(amount, _validHook(memo), keccak256("n3"));

        vm.expectEmit(true, true, true, true, address(fwd));
        emit IBCTransferRequested(
            "transfer", hookChannelId, fwd.DENOM(), amount, address(fwd), hookReceiver, _hex(memo), _expectedTimeout()
        );
        vm.prank(operator);
        fwd.mintAndRoute(message, "");
    }

    // ── T5/T6/T7: binding rejections (revert in _validateBinding, before hookData decode) ──
    function test_RejectsWrongDestination() public {
        bytes memory message = _buildMessage(
            WRONG_DOMAIN, keccak256("n4"), bytes32(uint256(uint160(sourceSender))),
            address(usdc), address(fwd), 1_000_000, _validHook(bytes("m"))
        );
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.WrongDestination.selector);
        fwd.mintAndRoute(message, "");
    }

    function test_RejectsWrongRecipient() public {
        bytes memory message = _buildMessage(
            INJ_DOMAIN, keccak256("n5"), bytes32(uint256(uint160(sourceSender))),
            address(usdc), address(0xDEAD), 1_000_000, _validHook(bytes("m"))
        );
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.WrongRecipient.selector);
        fwd.mintAndRoute(message, "");
    }

    function test_RejectsWrongSender() public {
        bytes memory message = _buildMessage(
            INJ_DOMAIN, keccak256("n7"), bytes32(uint256(uint160(address(0x9999)))),
            address(usdc), address(fwd), 1_000_000, _validHook(bytes("m"))
        );
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.WrongSender.selector);
        fwd.mintAndRoute(message, "");
    }

    // timeout is computed on-chain (now + 1 day, ns), never sourced from hookData → the old RejectsZeroTimeout case
    // is obsolete and removed.

    // ── NothingMinted: amount 0 (reverts before hookData decode) ──
    function test_RejectsNothingMinted() public {
        bytes memory message = _goodMessage(0, _validHook(bytes("m")), keccak256("n9"));
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.NothingMinted.selector);
        fwd.mintAndRoute(message, "");
    }

    // ── T8: replay → transmitter returns false → ReceiveFailed ──
    function test_ReplayReverts() public {
        bytes memory message = _goodMessage(1_000_000, _validHook(bytes("m")), keccak256("dup"));
        vm.prank(operator);
        fwd.mintAndRoute(message, "");
        vm.prank(operator);
        vm.expectRevert(IInboundForwarder.ReceiveFailed.selector);
        fwd.mintAndRoute(message, ""); // same nonce → mock returns false
    }

    // ── onlyOperator ──
    function test_OnlyOperator() public {
        bytes memory message = _goodMessage(1_000_000, _validHook(bytes("m")), keccak256("n10"));
        vm.expectRevert(IInboundForwarder.NotOperator.selector);
        fwd.mintAndRoute(message, "");
    }

    // ── native reject ──
    function test_RejectsNative() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(fwd).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ── isForwarderDeployed ──
    function test_IsForwarderDeployed_TrueForSetupRoute() public {
        // setUp() already deployed `fwd` for the default route.
        assertTrue(factory.isForwarderDeployed(sourceSender, destinationChainId, destinationReceiver), "deployed in setUp");
        assertEq(
            factory.getForwarderAddress(sourceSender, destinationChainId, destinationReceiver),
            address(fwd),
            "predicted == fwd"
        );
    }

    function test_IsForwarderDeployed_FalseThenTrue() public {
        assertFalse(factory.isForwarderDeployed(sourceSender, "noble-1", destinationReceiver), "false pre-deploy");
        address deployed = factory.createForwarder(sourceSender, "noble-1", destinationReceiver);
        assertEq(
            deployed, factory.getForwarderAddress(sourceSender, "noble-1", destinationReceiver), "predicted == deployed"
        );
        assertTrue(factory.isForwarderDeployed(sourceSender, "noble-1", destinationReceiver), "true post-deploy");
    }

    function test_IsForwarderDeployed_RouteSensitive() public {
        assertFalse(factory.isForwarderDeployed(address(0x1234), destinationChainId, destinationReceiver), "other sender");
        assertFalse(factory.isForwarderDeployed(sourceSender, "noble-1", destinationReceiver), "other chain");
        assertFalse(factory.isForwarderDeployed(sourceSender, destinationChainId, "inj1other"), "other receiver");
    }

    // front-run is harmless — a third party calling createForwarder deploys the canonical forwarder
    // bound to the route key, so isForwarderDeployed stays an authoritative proof.
    function test_IsForwarderDeployed_FrontRunDeploysCanonical() public {
        vm.prank(address(0xDEAD));
        InboundForwarder f =
            InboundForwarder(payable(factory.createForwarder(sourceSender, "noble-1", destinationReceiver)));
        assertTrue(factory.isForwarderDeployed(sourceSender, "noble-1", destinationReceiver), "deployed");
        assertEq(f.sender(), sourceSender, "sender bound to route key");
        assertEq(f.destinationChainId(), "noble-1", "chain bound to route key");
        assertEq(f.destinationReceiver(), destinationReceiver, "receiver bound to route key");
    }
}
