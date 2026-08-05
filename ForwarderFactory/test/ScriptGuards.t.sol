// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../script/BaseScript.sol";
import {InboundForwarder} from "../src/InboundForwarder.sol";
import {OutboundForwarder} from "../src/OutboundForwarder.sol";
import {InboundForwarderFactory} from "../src/InboundForwarderFactory.sol";

/// @dev Exposes BaseScript's internal guards so they can be exercised directly.
contract Harness is BaseScript {
    bool private _override;
    bool private _allow;

    /// @dev Drive the rebind decision without touching the process environment, which forge shares across the
    ///      test contracts it runs in parallel (an env-based test is inherently racy).
    function setRebindAllowed(bool v) external {
        _override = true;
        _allow = v;
    }

    function _rebindAllowed() internal view override returns (bool) {
        return _override ? _allow : super._rebindAllowed();
    }

    function assertInbound(address impl) external {
        _assertInboundImmutablesMatch(impl);
    }

    function assertOutbound(address impl) external {
        _assertOutboundImmutablesMatch(impl);
    }

    function liveImpl(address factoryProxy) external view returns (address) {
        return _liveForwarderImpl(factoryProxy);
    }
}

/**
 * @notice Regression tests for the deploy-script guards.
 * @dev These protect the property that a "logic-only" upgrade cannot silently rebind the forwarder immutables
 *      when Config has moved — the failure mode that makes an incident-time key rotation rebind paymentContract.
 */
contract ScriptGuardsTest is Test {
    address constant OTHER_OPERATOR = address(0xBADB0B);
    address constant OTHER_USDC = address(0xDEAD01);

    Harness harness;

    function setUp() public {
        // vm.setEnv writes the real process environment and is NOT rolled back between tests, so a flag set by one
        // test would leak into the next. Normalise it here (setUp runs before every test).
        vm.setEnv("ALLOW_IMMUTABLE_REBIND", "false");

        // BaseScript resolves Config in its constructor, so the chain id must be set first.
        vm.chainId(CHAIN_INJECTIVE_TESTNET);
        harness = new Harness();
        // OutboundForwarder's constructor calls paymentContract.usdc(); give the configured address code + answer.
        vm.etch(PAYMENT_CONTRACT_INJECTIVE_TESTNET, hex"00");
        vm.mockCall(
            PAYMENT_CONTRACT_INJECTIVE_TESTNET,
            abi.encodeWithSignature("usdc()"),
            abi.encode(USDC_INJECTIVE_TESTNET)
        );
    }

    function _inbound(address usdc_, address transmitter_, address operator_, uint32 domain_)
        internal
        returns (address)
    {
        return address(new InboundForwarder(usdc_, transmitter_, operator_, domain_));
    }

    // ── T1: Config resolution ──
    function test_T1_resolvesTestnetConfig() public {
        assertEq(harness.usdc(), USDC_INJECTIVE_TESTNET);
        assertEq(harness.transmitter(), TRANSMITTER_INJECTIVE_TESTNET);
        assertEq(harness.operator(), OPERATOR_INJECTIVE_TESTNET);
        assertEq(harness.paymentContract(), PAYMENT_CONTRACT_INJECTIVE_TESTNET);
    }

    // ── T2: unsupported chain ──
    function test_T2_unsupportedChainReverts() public {
        vm.chainId(1); // Ethereum mainnet — this stack is Injective-only
        vm.expectRevert("Chain not supported.");
        new Harness();
    }

    // ── T3: no drift ──
    function test_T3_matchingImmutablesPass() public {
        address impl = _inbound(
            USDC_INJECTIVE_TESTNET, TRANSMITTER_INJECTIVE_TESTNET, OPERATOR_INJECTIVE_TESTNET, INJECTIVE_CCTP_DOMAIN
        );
        harness.assertInbound(impl); // must not revert
    }

    // ── T4: operator drift is refused by default ──
    function test_T4_operatorDriftReverts() public {
        harness.setRebindAllowed(false);
        address impl =
            _inbound(USDC_INJECTIVE_TESTNET, TRANSMITTER_INJECTIVE_TESTNET, OTHER_OPERATOR, INJECTIVE_CCTP_DOMAIN);
        vm.expectRevert(
            bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)")
        );
        harness.assertInbound(impl);
    }

    // ── T5: explicit opt-in allows the rebind ──
    function test_T5_rebindFlagAllowsDrift() public {
        harness.setRebindAllowed(true);
        address impl =
            _inbound(USDC_INJECTIVE_TESTNET, TRANSMITTER_INJECTIVE_TESTNET, OTHER_OPERATOR, INJECTIVE_CCTP_DOMAIN);
        harness.assertInbound(impl); // must not revert
    }

    /// @dev The real env path, exercised once. Kept separate so no other test depends on process env state.
    function test_T5b_envFlagIsHonoured() public {
        Harness envHarness = new Harness(); // no override → reads ALLOW_IMMUTABLE_REBIND
        vm.setEnv("ALLOW_IMMUTABLE_REBIND", "true");
        address impl =
            _inbound(USDC_INJECTIVE_TESTNET, TRANSMITTER_INJECTIVE_TESTNET, OTHER_OPERATOR, INJECTIVE_CCTP_DOMAIN);
        envHarness.assertInbound(impl); // must not revert
        vm.setEnv("ALLOW_IMMUTABLE_REBIND", "false");
    }

    // ── T6: multiple drifting fields are all reported, then a single failure ──
    function test_T6_multiFieldDriftReverts() public {
        harness.setRebindAllowed(false);
        address impl = _inbound(OTHER_USDC, TRANSMITTER_INJECTIVE_TESTNET, OTHER_OPERATOR, INJECTIVE_CCTP_DOMAIN);
        vm.expectRevert(
            bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)")
        );
        harness.assertInbound(impl);
    }

    // ── T6b: domain drift is caught too (uint field) ──
    function test_T6b_domainDriftReverts() public {
        harness.setRebindAllowed(false);
        address impl = _inbound(
            USDC_INJECTIVE_TESTNET, TRANSMITTER_INJECTIVE_TESTNET, OPERATOR_INJECTIVE_TESTNET, INJECTIVE_CCTP_DOMAIN + 1
        );
        vm.expectRevert(
            bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)")
        );
        harness.assertInbound(impl);
    }

    // ── T6c: outbound path (paymentContract is the field that silently rebinds) ──
    function test_T6c_outboundPaymentContractDriftReverts() public {
        harness.setRebindAllowed(false);
        address otherPayment = address(0xFEED01);
        vm.etch(otherPayment, hex"00");
        vm.mockCall(otherPayment, abi.encodeWithSignature("usdc()"), abi.encode(USDC_INJECTIVE_TESTNET));

        address impl = address(new OutboundForwarder(USDC_INJECTIVE_TESTNET, otherPayment, OPERATOR_INJECTIVE_TESTNET));
        vm.expectRevert(
            bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)")
        );
        harness.assertOutbound(impl);
    }

    // ── T7: factory → beacon → impl resolution ──
    function test_T7_liveImplResolution() public {
        address impl = _inbound(
            USDC_INJECTIVE_TESTNET, TRANSMITTER_INJECTIVE_TESTNET, OPERATOR_INJECTIVE_TESTNET, INJECTIVE_CCTP_DOMAIN
        );
        InboundForwarderFactory factory = InboundForwarderFactory(
            address(
                new ERC1967Proxy(
                    address(new InboundForwarderFactory()),
                    abi.encodeCall(InboundForwarderFactory.initialize, (impl))
                )
            )
        );
        assertEq(harness.liveImpl(address(factory)), impl, "beacon impl resolved");
    }

    function test_T7b_liveImplRejectsCodelessFactory() public {
        vm.expectRevert(bytes("no code at factory proxy"));
        harness.liveImpl(address(0xABC0DE));
    }

    // ── T9: outbound happy path (T3's counterpart — without it a broken outbound compare goes unnoticed) ──
    function test_T9_outboundMatchingImmutablesPass() public {
        address impl = address(
            new OutboundForwarder(USDC_INJECTIVE_TESTNET, PAYMENT_CONTRACT_INJECTIVE_TESTNET, OPERATOR_INJECTIVE_TESTNET)
        );
        harness.assertOutbound(impl); // must not revert
    }

    // ── T10: swapped *_FACTORY_PROXY env vars must say so, not "NativeNotAccepted" ──
    function test_T10_outboundImplIntoInboundAssertIsDiagnosed() public {
        address outImpl = address(
            new OutboundForwarder(USDC_INJECTIVE_TESTNET, PAYMENT_CONTRACT_INJECTIVE_TESTNET, OPERATOR_INJECTIVE_TESTNET)
        );
        vm.expectRevert(bytes("impl is not an InboundForwarder (wrong *_FACTORY_PROXY?)"));
        harness.assertInbound(outImpl);
    }

    function test_T10b_inboundImplIntoOutboundAssertIsDiagnosed() public {
        address inImpl = _inbound(
            USDC_INJECTIVE_TESTNET, TRANSMITTER_INJECTIVE_TESTNET, OPERATOR_INJECTIVE_TESTNET, INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(bytes("impl is not an OutboundForwarder (wrong *_FACTORY_PROXY?)"));
        harness.assertOutbound(inImpl);
    }

    // ── T11: a codeless address reaches the assert (staticcall on an EOA "succeeds" — must still be caught) ──
    function test_T11_codelessImplRejected() public {
        vm.expectRevert(bytes("no code at InboundForwarder impl"));
        harness.assertInbound(address(0xE0A));
    }
}
