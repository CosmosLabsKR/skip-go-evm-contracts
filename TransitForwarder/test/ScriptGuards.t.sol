// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import "../script/BaseScript.sol";
import {ERC1967Utils} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TransitForwarder} from "../src/TransitForwarder.sol";
import {ITransitForwarder} from "../src/interfaces/ITransitForwarder.sol";
import {TransitExecutor} from "../src/TransitExecutor.sol";
import {ITokenMessenger} from "../src/interfaces/ITokenMessenger.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";

/// @dev Exposes BaseScript's internal guards so they can be exercised directly.
contract Harness is BaseScript {
    bool private _override;
    bool private _allow;

    bool private _v1Override;
    bool private _v1Allow;

    /// @dev Drive the rebind decision without touching the process environment, which forge shares across the
    ///      test contracts it runs in parallel (an env-based test is inherently racy).
    function setRebindAllowed(bool v) external {
        _override = true;
        _allow = v;
    }

    function setV1ToV2Allowed(bool v) external {
        _v1Override = true;
        _v1Allow = v;
    }

    function _rebindAllowed() internal view override returns (bool) {
        return _override ? _allow : super._rebindAllowed();
    }

    function _v1ToV2Allowed() internal view override returns (bool) {
        return _v1Override ? _v1Allow : super._v1ToV2Allowed();
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

/// @dev Inert TokenMessengerV2 stand-in — these guards never burn, they only compare immutables.
contract MockMessengerStub is ITokenMessenger {
    function depositForBurn(uint256, uint32, bytes32, address, bytes32, uint256, uint32) external pure {}

    function depositForBurnWithHook(uint256, uint32, bytes32, address, bytes32, uint256, uint32, bytes calldata)
        external
        pure {}
}

/// @dev A LIVE pre-v2 forwarder impl as the upgrade scripts would find it on-chain: it answers the whole v1
///      immutable surface (including the discriminator LOCAL_DOMAIN(), so the guard does proceed) but has no
///      `messenger()`, and its fallback reverts exactly as the real TransitForwarder's does.
contract V1ImplStandIn {
    address public immutable usdc;
    address public immutable paymentContract;
    address public immutable operator;
    address public immutable executor;
    uint32 public immutable LOCAL_DOMAIN;
    uint32 public immutable ALLOWED_DESTINATION_DOMAIN;

    constructor(address usdc_, address operator_, address executor_) {
        usdc = usdc_;
        paymentContract = address(0xBA5EC0);
        operator = operator_;
        executor = executor_;
        LOCAL_DOMAIN = AVALANCHE_CCTP_DOMAIN;
        ALLOWED_DESTINATION_DOMAIN = INJECTIVE_CCTP_DOMAIN;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    receive() external payable {
        revert ITransitForwarder.NativeNotAccepted();
    }

    fallback() external payable {
        revert ITransitForwarder.NativeNotAccepted();
    }
}

contract MockTransmitterStub is IReceiver {
    function receiveMessage(bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/**
 * @notice Regression tests for the deploy-script guards.
 * @dev These protect the property that a "logic-only" upgrade cannot silently rebind the forwarder immutables when
 *      Config has moved — the failure mode that makes an incident-time key rotation rebind the messenger.
 */
contract ScriptGuardsTest is Test {
    address constant OTHER_OPERATOR = address(0xBADB0B);
    address constant OTHER_USDC = address(0xDEAD01);
    address constant OTHER_TRANSMITTER = address(0xDEAD02);
    address constant OTHER_EXECUTOR = address(0xDEAD03);
    address constant EXECUTOR_PROXY = address(0xE8EC00);
    uint32 constant OTHER_DOMAIN = 31;

    /// @dev Owned by BaseScript._settleDrift; restated once here rather than in each expectRevert.
    bytes constant DRIFT_REVERT =
        bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)");

    Harness harness;

    function setUp() public {
        // vm.setEnv writes the real process environment and is NOT rolled back between tests, so a flag set by one
        // test would leak into the next. Normalise it here (setUp runs before every test).
        vm.setEnv("ALLOW_IMMUTABLE_REBIND", "false");

        // BaseScript resolves Config in its constructor, so the chain id must be set first.
        vm.chainId(CHAIN_AVALANCHE_TESTNET);
        harness = new Harness();

        // v2 needs no mocking of the burn target: the constructor no longer calls into it (the old
        // paymentContract.usdc() cross-check went away with the relayer), and these guards only read immutables.

        // The forwarder guard now compares `executor` against this env var, and _deployTransitForwarderImpl refuses
        // anything that is not a proxy. Give the address code and a non-zero ERC-1967 implementation slot.
        vm.setEnv("TRANSIT_EXECUTOR_PROXY", vm.toString(EXECUTOR_PROXY));
        vm.etch(EXECUTOR_PROXY, hex"600160005260206000f3");
        vm.store(EXECUTOR_PROXY, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(0xBEEF1E)))));
    }

    function _impl(
        address usdc_,
        address messenger_,
        address operator_,
        address executor_,
        uint32 localDomain_,
        uint32 allowedDestination_
    ) internal returns (TransitForwarder) {
        return new TransitForwarder(usdc_, messenger_, operator_, executor_, localDomain_, allowedDestination_);
    }

    /// @dev The impl the current Config would produce — no drift.
    function _configImpl() internal returns (TransitForwarder) {
        return _impl(
            USDC_AVALANCHE_TESTNET,
            MESSENGER_TESTNET_TIER,
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
            MESSENGER_TESTNET_TIER,
            OTHER_OPERATOR,
            EXECUTOR_PROXY,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(DRIFT_REVERT);
        harness.assertTransit(address(drifted));
    }

    /// @dev S-02. The forwarder guard no longer watches `transmitter` (the forwarder does not have one); it watches
    ///      `executor` instead, and that is the field whose drift would orphan every deployed forwarder.
    function test_ExecutorDriftBlocked() public {
        TransitForwarder drifted = _impl(
            USDC_AVALANCHE_TESTNET,
            MESSENGER_TESTNET_TIER,
            OPERATOR_AVALANCHE_TESTNET,
            OTHER_EXECUTOR,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(DRIFT_REVERT);
        harness.assertTransit(address(drifted));
    }

    function test_LocalDomainDriftBlocked() public {
        TransitForwarder drifted = _impl(
            USDC_AVALANCHE_TESTNET,
            MESSENGER_TESTNET_TIER,
            OPERATOR_AVALANCHE_TESTNET,
            EXECUTOR_PROXY,
            OTHER_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(DRIFT_REVERT);
        harness.assertTransit(address(drifted));
    }

    /// @dev v1 tied usdc and paymentContract together through the constructor's UsdcMismatch check, so they could
    ///      only ever drift as a matched pair. v2 has no such coupling — ITokenMessenger exposes no usdc() — which
    ///      makes an INDEPENDENT usdc rebind newly possible, and this guard the only thing that would report it.
    function test_UsdcDriftBlocked() public {
        TransitForwarder drifted = _impl(
            OTHER_USDC,
            MESSENGER_TESTNET_TIER,
            OPERATOR_AVALANCHE_TESTNET,
            EXECUTOR_PROXY,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        vm.expectRevert(DRIFT_REVERT);
        harness.assertTransit(address(drifted));
    }

    function test_IntentionalRebindAllowed() public {
        TransitForwarder drifted = _impl(
            USDC_AVALANCHE_TESTNET,
            MESSENGER_TESTNET_TIER,
            OTHER_OPERATOR,
            EXECUTOR_PROXY,
            AVALANCHE_CCTP_DOMAIN,
            INJECTIVE_CCTP_DOMAIN
        );
        harness.setRebindAllowed(true);
        harness.assertTransit(address(drifted)); // must not revert
    }

    // ── the v1 -> v2 boundary: the one upgrade that must cross it is the fee removal itself ──

    bytes constant V1_REVERT = bytes(
        "pre-v2 impl detected (set ALLOW_V1_TO_V2=true for the fee-removal upgrade - it does NOT waive other drift)"
    );

    function _v1Impl(address executor_) internal returns (address) {
        return address(new V1ImplStandIn(USDC_AVALANCHE_TESTNET, OPERATOR_AVALANCHE_TESTNET, executor_));
    }

    /// @dev ⚠️ REGRESSION. A pre-v2 impl has no `messenger()`, and TransitForwarder's fallback REVERTS
    ///      (NativeNotAccepted) rather than returning empty — so a typed read would abort the guard with an error
    ///      naming the wrong problem, before _settleDrift ever runs, and no flag could get past it. The guard must
    ///      instead recognise the shape change, so the upgrade is refused by default with a message that says so...
    function test_V1ImplReportedNotAMisleadingRevert() public {
        // Construct BEFORE arming expectRevert: the CREATE would otherwise consume it (see the note on
        // test_ExecutorGuardBlocksTransmitterDrift).
        address v1 = _v1Impl(EXECUTOR_PROXY);
        vm.expectRevert(V1_REVERT);
        harness.assertTransit(v1);
    }

    /// @dev ...and permitted by its OWN flag, which is what the v1 -> v2 fee-removal upgrade is.
    function test_V1ImplUpgradeableWithItsOwnFlag() public {
        harness.setV1ToV2Allowed(true);
        harness.assertTransit(_v1Impl(EXECUTOR_PROXY)); // must not revert
    }

    /// @dev ⚠️ THE REGRESSION THAT MATTERS MOST. ALLOW_V1_TO_V2 is MANDATORY on the migration run, so it must not
    ///      be able to waive anything else. Here the impl is pre-v2 AND bound to another chain's executor — the
    ///      two supported chains are independent deployments sharing one unbound TRANSIT_EXECUTOR_PROXY env var,
    ///      so this is the realistic operator slip. A single conflated flag would install a forwarder bound to the
    ///      wrong executor, which runbook §3.1 calls unfixable.
    function test_V1FlagDoesNotWaiveExecutorDrift() public {
        harness.setV1ToV2Allowed(true);
        address v1 = _v1Impl(OTHER_EXECUTOR); // construct before arming expectRevert
        vm.expectRevert(DRIFT_REVERT);
        harness.assertTransit(v1);
    }

    /// @dev And symmetrically: the ordinary rebind flag must not wave a pre-v2 impl through on its own.
    function test_RebindFlagDoesNotWaiveTheV1ShapeChange() public {
        harness.setRebindAllowed(true);
        address v1 = _v1Impl(EXECUTOR_PROXY); // construct before arming expectRevert
        vm.expectRevert(V1_REVERT);
        harness.assertTransit(v1);
    }

    /// @dev Both problems at once need both flags — neither substitutes for the other.
    function test_BothFlagsTogetherAllowBoth() public {
        harness.setV1ToV2Allowed(true);
        harness.setRebindAllowed(true);
        harness.assertTransit(_v1Impl(OTHER_EXECUTOR)); // must not revert
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

    function _executorImpl(address usdc_, address transmitter_, address operator_) internal returns (TransitExecutor) {
        return new TransitExecutor(usdc_, transmitter_, operator_);
    }

    function test_ExecutorGuardAcceptsConfigImpl() public {
        harness.assertExecutor(
            address(_executorImpl(USDC_AVALANCHE_TESTNET, TRANSMITTER_AVALANCHE_TESTNET, OPERATOR_AVALANCHE_TESTNET))
        );
    }

    function test_ExecutorGuardBlocksTransmitterDrift() public {
        // Construct BEFORE arming expectRevert: it would otherwise be consumed by this CREATE.
        address drifted = address(_executorImpl(USDC_AVALANCHE_TESTNET, OTHER_TRANSMITTER, OPERATOR_AVALANCHE_TESTNET));
        vm.expectRevert(DRIFT_REVERT);
        harness.assertExecutor(drifted);
    }

    function test_ExecutorGuardBlocksOperatorDrift() public {
        address drifted = address(_executorImpl(USDC_AVALANCHE_TESTNET, TRANSMITTER_AVALANCHE_TESTNET, OTHER_OPERATOR));
        vm.expectRevert(DRIFT_REVERT);
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
            bytes("TRANSIT_EXECUTOR_PROXY is an IMPLEMENTATION, not a proxy - forwarders would be permanently orphaned")
        );
        harness.assertIsProxy(bareImpl);
    }

    function test_AssertIsProxyRejectsCodelessAddress() public {
        vm.expectRevert(bytes("no code at TRANSIT_EXECUTOR_PROXY"));
        harness.assertIsProxy(address(0xC0DE1E57));
    }

    function test_UnsupportedChainRejected() public {
        vm.chainId(1); // Ethereum mainnet — not one of the supported source networks
        vm.expectRevert(bytes("Chain not supported."));
        new Harness();
    }

    /// @dev Mumbai (80001) was Polygon's testnet before Amoy (80002) and still appears in sibling Config files.
    ///      Its addresses do not work here, so the deprecated chain id must not resolve to the Polygon row.
    function test_PolygonMumbaiRejected() public {
        vm.chainId(80001);
        vm.expectRevert(bytes("Chain not supported."));
        new Harness();
    }
}

/**
 * @notice The same guards, resolved against the POLYGON rows of Config.
 * @dev Its own contract because BaseScript resolves Config in its constructor: one chain id per deployed Harness,
 *      so per-chain coverage cannot share the Avalanche fixture above.
 *
 *      ⚠️ The test that matters most here is test_AvalancheDomainOnPolygonBlocked. The burn-leg address does NOT
 *      distinguish the chains: MESSENGER_*_TIER is one address for every chain of a network tier (Circle deploys
 *      it that way), so an impl built on the wrong chain is not obviously wrong on sight — LOCAL_DOMAIN is what
 *      separates them, and a wrong one rejects every legitimate message with WrongDestination.
 */
contract ScriptGuardsPolygonTest is Test {
    /// @dev Deliberately the SAME address the Avalanche suite uses. TRANSIT_EXECUTOR_PROXY is read from the real
    ///      process environment, which forge shares across test contracts running in parallel — two suites writing
    ///      DIFFERENT values race, and whichever loses sees `executor` drift. Identical values cannot race.
    address constant EXECUTOR_PROXY = address(0xE8EC00);

    bytes constant DRIFT_REVERT =
        bytes("immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)");

    Harness harness;

    function setUp() public {
        vm.setEnv("ALLOW_IMMUTABLE_REBIND", "false");

        vm.chainId(CHAIN_POLYGON_TESTNET);
        harness = new Harness();

        vm.setEnv("TRANSIT_EXECUTOR_PROXY", vm.toString(EXECUTOR_PROXY));
        vm.etch(EXECUTOR_PROXY, hex"600160005260206000f3");
        vm.store(EXECUTOR_PROXY, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(0xBEEF1E)))));
    }

    function _impl(uint32 localDomain_) internal returns (TransitForwarder) {
        return new TransitForwarder(
            USDC_POLYGON_TESTNET,
            MESSENGER_TESTNET_TIER,
            OPERATOR_POLYGON_TESTNET,
            EXECUTOR_PROXY,
            localDomain_,
            INJECTIVE_CCTP_DOMAIN
        );
    }

    /// @dev The whole point of the per-chain row: Amoy must resolve to Polygon's values, not Avalanche's.
    function test_ResolvesPolygonTestnetConfig() public {
        assertEq(harness.usdc(), USDC_POLYGON_TESTNET);
        assertEq(harness.transmitter(), TRANSMITTER_POLYGON_TESTNET);
        assertEq(harness.messenger(), MESSENGER_TESTNET_TIER);
        assertEq(harness.operator(), OPERATOR_POLYGON_TESTNET);
        assertEq(uint256(harness.localDomain()), uint256(POLYGON_CCTP_DOMAIN));
    }

    function test_ResolvesPolygonMainnetConfig() public {
        vm.chainId(CHAIN_POLYGON);
        Harness mainnetHarness = new Harness();
        assertEq(mainnetHarness.usdc(), USDC_POLYGON);
        assertEq(mainnetHarness.transmitter(), TRANSMITTER_POLYGON);
        assertEq(mainnetHarness.messenger(), MESSENGER_MAINNET_TIER);
        assertEq(mainnetHarness.operator(), OPERATOR_POLYGON);
        assertEq(uint256(mainnetHarness.localDomain()), uint256(POLYGON_CCTP_DOMAIN));
    }

    function test_MatchingImmutablesPass() public {
        harness.assertTransit(address(_impl(POLYGON_CCTP_DOMAIN)));
    }

    /// @dev The cross-chain mix-up this multi-chain config makes possible: an impl carrying Avalanche's domain,
    ///      deployed on Polygon. Everything else matches, so nothing but this guard would catch it.
    function test_AvalancheDomainOnPolygonBlocked() public {
        TransitForwarder drifted = _impl(AVALANCHE_CCTP_DOMAIN);
        vm.expectRevert(DRIFT_REVERT);
        harness.assertTransit(address(drifted));
    }

    function test_ExecutorGuardAcceptsConfigImpl() public {
        harness.assertExecutor(
            address(new TransitExecutor(USDC_POLYGON_TESTNET, TRANSMITTER_POLYGON_TESTNET, OPERATOR_POLYGON_TESTNET))
        );
    }

    /// @dev Fuji's v1 transmitter on an Amoy deployment: a plausible copy-paste, and the mint leg would be bound to
    ///      a contract that does not exist on this chain.
    function test_ExecutorGuardBlocksForeignTransmitter() public {
        address drifted =
            address(new TransitExecutor(USDC_POLYGON_TESTNET, TRANSMITTER_AVALANCHE_TESTNET, OPERATOR_POLYGON_TESTNET));
        vm.expectRevert(DRIFT_REVERT);
        harness.assertExecutor(drifted);
    }
}
