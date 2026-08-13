// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import "../script/BaseScript.sol";
import {TransitForwarder} from "../src/TransitForwarder.sol";
import {TransitExecutor} from "../src/TransitExecutor.sol";
import {ICCTPV2Relayer} from "../src/interfaces/ICCTPV2Relayer.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";

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

    function assertTransit(address impl) external {
        _assertTransitImmutablesMatch(impl);
    }

    function liveImpl(address factoryProxy) external view returns (address) {
        return _liveForwarderImpl(factoryProxy);
    }

    function assertExecutor(address impl) external {
        _assertExecutorImmutablesMatch(impl);
    }

    function assertIsProxy(address a) external view {
        _assertIsProxy(a, "TRANSIT_EXECUTOR_PROXY");
    }
}

contract MockRelayerStub is ICCTPV2Relayer {
    IERC20 public immutable usdc;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function requestCCTPTransfer(uint256, uint32, bytes32, address, uint256, uint256, uint32, bytes calldata)
        external
        pure
    {}

    function requestCCTPTransferWithCaller(
        uint256,
        uint32,
        bytes32,
        address,
        uint256,
        uint256,
        uint32,
        bytes32,
        bytes calldata
    ) external pure {}
}

contract MockTransmitterStub is IReceiver {
    function receiveMessage(bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/**
 * @notice Regression tests for the deploy-script guards.
 * @dev These protect the property that a "logic-only" upgrade cannot silently rebind the forwarder immutables when
 *      Config has moved — the failure mode that makes an incident-time key rotation rebind paymentContract.
 */
contract ScriptGuardsTest is Test {
    address constant OTHER_OPERATOR = address(0xBADB0B);
    address constant OTHER_USDC = address(0xDEAD01);
    address constant OTHER_TRANSMITTER = address(0xDEAD02);
    address constant OTHER_EXECUTOR = address(0xDEAD03);
    address constant EXECUTOR_PROXY = address(0xE8EC00);
    uint32 constant OTHER_DOMAIN = 31;
    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    Harness harness;

    function setUp() public {
        // vm.setEnv writes the real process environment and is NOT rolled back between tests, so a flag set by one
        // test would leak into the next. Normalise it here (setUp runs before every test).
        vm.setEnv("ALLOW_IMMUTABLE_REBIND", "false");

        // BaseScript resolves Config in its constructor, so the chain id must be set first.
        vm.chainId(CHAIN_AVALANCHE_TESTNET);
        harness = new Harness();

        // TransitForwarder's constructor calls paymentContract.usdc(); give the configured address code + answer.
        MockRelayerStub relayerCode = new MockRelayerStub(IERC20(USDC_AVALANCHE_TESTNET));
        vm.etch(PAYMENT_CONTRACT_AVALANCHE_TESTNET, address(relayerCode).code);
        // The etched copy has no immutable storage of its own, so make usdc() answer the configured value.
        vm.mockCall(
            PAYMENT_CONTRACT_AVALANCHE_TESTNET,
            abi.encodeWithSignature("usdc()"),
            abi.encode(IERC20(USDC_AVALANCHE_TESTNET))
        );

        // The forwarder guard now compares `executor` against this env var, and _deployTransitForwarderImpl refuses
        // anything that is not a proxy. Give the address code and a non-zero ERC-1967 implementation slot.
        vm.setEnv("TRANSIT_EXECUTOR_PROXY", vm.toString(EXECUTOR_PROXY));
        vm.etch(EXECUTOR_PROXY, hex"600160005260206000f3");
        vm.store(EXECUTOR_PROXY, ERC1967_IMPL_SLOT, bytes32(uint256(uint160(address(0xBEEF1E)))));
    }

    function _impl(
        address usdc_,
        address paymentContract_,
        address operator_,
        address executor_,
        uint32 localDomain_,
        uint32 allowedDestination_
    ) internal returns (TransitForwarder) {
        return new TransitForwarder(usdc_, paymentContract_, operator_, executor_, localDomain_, allowedDestination_);
    }

    /// @dev The impl the current Config would produce — no drift.
    function _configImpl() internal returns (TransitForwarder) {
        return _impl(
            USDC_AVALANCHE_TESTNET,
            PAYMENT_CONTRACT_AVALANCHE_TESTNET,
            OPERATOR_AVALANCHE_TESTNET,
            EXECUTOR_PROXY,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
    }

    function test_MatchingImmutablesPass() public {
        harness.assertTransit(address(_configImpl()));
    }

    function test_OperatorDriftBlocked() public {
        TransitForwarder drifted = _impl(
            USDC_AVALANCHE_TESTNET,
            PAYMENT_CONTRACT_AVALANCHE_TESTNET,
            OTHER_OPERATOR,
            EXECUTOR_PROXY,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)"));
        harness.assertTransit(address(drifted));
    }

    /// @dev S-02. The forwarder guard no longer watches `transmitter` (the forwarder does not have one); it watches
    ///      `executor` instead, and that is the field whose drift would orphan every deployed forwarder.
    function test_ExecutorDriftBlocked() public {
        TransitForwarder drifted = _impl(
            USDC_AVALANCHE_TESTNET,
            PAYMENT_CONTRACT_AVALANCHE_TESTNET,
            OPERATOR_AVALANCHE_TESTNET,
            OTHER_EXECUTOR,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)"));
        harness.assertTransit(address(drifted));
    }

    function test_LocalDomainDriftBlocked() public {
        TransitForwarder drifted = _impl(
            USDC_AVALANCHE_TESTNET,
            PAYMENT_CONTRACT_AVALANCHE_TESTNET,
            OPERATOR_AVALANCHE_TESTNET,
            EXECUTOR_PROXY,
            OTHER_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)"));
        harness.assertTransit(address(drifted));
    }

    /// @dev usdc and paymentContract cannot drift independently — the constructor's UsdcMismatch check ties them
    ///      together — so a usdc rebind necessarily arrives as a matched pair, which the guard still reports.
    function test_UsdcAndPaymentContractPairDriftBlocked() public {
        MockRelayerStub otherRelayer = new MockRelayerStub(IERC20(OTHER_USDC));
        TransitForwarder drifted = _impl(
            OTHER_USDC,
            address(otherRelayer),
            OPERATOR_AVALANCHE_TESTNET,
            EXECUTOR_PROXY,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)"));
        harness.assertTransit(address(drifted));
    }

    function test_IntentionalRebindAllowed() public {
        TransitForwarder drifted = _impl(
            USDC_AVALANCHE_TESTNET,
            PAYMENT_CONTRACT_AVALANCHE_TESTNET,
            OTHER_OPERATOR,
            EXECUTOR_PROXY,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        harness.setRebindAllowed(true);
        harness.assertTransit(address(drifted)); // must not revert
    }

    /// @dev The sanity check must reject something that is not a TransitForwarder at all. A missing selector hits the
    ///      forwarder-less target's fallback (or returns nothing), so the staticcall fails the length test.
    function test_NonTransitImplRejected() public {
        MockTransmitterStub notAForwarder = new MockTransmitterStub();
        vm.expectRevert(bytes("impl is not a TransitForwarder (wrong TRANSIT_FORWARDER_FACTORY_PROXY?)"));
        harness.assertTransit(address(notAForwarder));
    }

    function test_CodelessImplRejected() public {
        vm.expectRevert(bytes("no code at TransitForwarder impl"));
        harness.assertTransit(address(0xC0DE1E55));
    }

    function test_LiveImplRequiresFactoryCode() public {
        vm.expectRevert(bytes("no code at factory proxy"));
        harness.liveImpl(address(0xF00D1E55));
    }

    // ── S-01 the executor's own drift guard ──

    function _executorImpl(address usdc_, address transmitter_, address operator_)
        internal
        returns (TransitExecutor)
    {
        return new TransitExecutor(usdc_, transmitter_, operator_);
    }

    function test_ExecutorGuardAcceptsConfigImpl() public {
        harness.assertExecutor(
            address(_executorImpl(USDC_AVALANCHE_TESTNET, TRANSMITTER_AVALANCHE_TESTNET, OPERATOR_AVALANCHE_TESTNET))
        );
    }

    function test_ExecutorGuardBlocksTransmitterDrift() public {
        // Construct BEFORE arming expectRevert: it would otherwise be consumed by this CREATE.
        address drifted =
            address(_executorImpl(USDC_AVALANCHE_TESTNET, OTHER_TRANSMITTER, OPERATOR_AVALANCHE_TESTNET));
        vm.expectRevert(bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)"));
        harness.assertExecutor(drifted);
    }

    function test_ExecutorGuardBlocksOperatorDrift() public {
        address drifted =
            address(_executorImpl(USDC_AVALANCHE_TESTNET, TRANSMITTER_AVALANCHE_TESTNET, OTHER_OPERATOR));
        vm.expectRevert(bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)"));
        harness.assertExecutor(drifted);
    }

    function test_ExecutorGuardIntentionalRebindAllowed() public {
        harness.setRebindAllowed(true);
        harness.assertExecutor(
            address(_executorImpl(USDC_AVALANCHE_TESTNET, TRANSMITTER_AVALANCHE_TESTNET, OTHER_OPERATOR))
        );
    }

    /// @dev The discriminator is sharp because the forwarder gave up transmitter(): a forwarder impl must NOT pass.
    function test_ExecutorGuardRejectsAForwarderImpl() public {
        address forwarderImpl = address(_configImpl());
        vm.expectRevert(bytes("impl is not a TransitExecutor (wrong TRANSIT_EXECUTOR_PROXY?)"));
        harness.assertExecutor(forwarderImpl);
    }

    function test_ExecutorGuardRejectsCodelessImpl() public {
        vm.expectRevert(bytes("no code at TransitExecutor impl"));
        harness.assertExecutor(address(0xC0DE1E56));
    }

    // ── S-03 proxy-vs-implementation, the unrecoverable deployment mistake ──

    function test_AssertIsProxyAcceptsAProxy() public view {
        harness.assertIsProxy(EXECUTOR_PROXY);
    }

    function test_AssertIsProxyRejectsAnImplementation() public {
        // Same code, but no ERC-1967 implementation slot — i.e. a bare implementation address.
        address bareImpl = address(0xB4BE1);
        vm.etch(bareImpl, hex"600160005260206000f3");
        vm.expectRevert(
            bytes(
                "TRANSIT_EXECUTOR_PROXY is an IMPLEMENTATION, not a proxy - forwarders would be permanently orphaned"
            )
        );
        harness.assertIsProxy(bareImpl);
    }

    function test_AssertIsProxyRejectsCodelessAddress() public {
        vm.expectRevert(bytes("no code at TRANSIT_EXECUTOR_PROXY"));
        harness.assertIsProxy(address(0xC0DE1E57));
    }

    function test_UnsupportedChainRejected() public {
        vm.chainId(1); // Ethereum mainnet — not an Avalanche network
        vm.expectRevert(bytes("Chain not supported."));
        new Harness();
    }
}
