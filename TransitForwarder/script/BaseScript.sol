// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./Config.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {TransitForwarder} from "../src/TransitForwarder.sol";
import {TransitExecutor} from "../src/TransitExecutor.sol";

/**
 * @notice Deploy guard supporting only the two Avalanche C-Chain networks (mainnet 43114 / Fuji 43113).
 *         ⚠️ Unlike its ForwarderFactory siblings this subproject targets AVALANCHE, not Injective EVM — Avalanche
 *         is where it is DEPLOYED (LOCAL_DOMAIN = 1); Injective is where it SENDS (INJECTIVE_CCTP_DOMAIN = 29).
 * @dev ⚠️ REDUCED COPY of ForwarderFactory/script/BaseScript.sol.
 *
 *      The original probes a kind-specific getter to tell Inbound from Outbound impls. There is only one kind of
 *      forwarder here, so LOCAL_DOMAIN() below is a plain sanity check, not a discriminator. `transmitter()` IS a
 *      real discriminator for an executor impl, since the forwarder gave it up with the mint capability.
 *
 *      (Residual risk in the OTHER project: its inbound upgrade script still accepts a Transit factory via the
 *      `paymentContract()` probe. One-line fix there, deliberately out of scope here.)
 */
abstract contract BaseScript is Script {
    address public immutable usdc;
    address public immutable transmitter; // CCTP v1 MessageTransmitter (mint leg, called by the executor)
    address public immutable paymentContract; // CCTPV2Relayer (burn leg, delegated)
    address public immutable operator;

    constructor() {
        if (block.chainid == CHAIN_AVALANCHE) {
            usdc = USDC_AVALANCHE;
            transmitter = TRANSMITTER_AVALANCHE;
            paymentContract = PAYMENT_CONTRACT_AVALANCHE;
            operator = OPERATOR_AVALANCHE;
        } else if (block.chainid == CHAIN_AVALANCHE_TESTNET) {
            usdc = USDC_AVALANCHE_TESTNET;
            transmitter = TRANSMITTER_AVALANCHE_TESTNET;
            paymentContract = PAYMENT_CONTRACT_AVALANCHE_TESTNET;
            operator = OPERATOR_AVALANCHE_TESTNET;
        } else {
            revert("Chain not supported.");
        }
    }

    /// @dev The TransitExecutor PROXY. Not a Config constant: the address is only known after deployment, and
    ///      baking it in would create a deploy → edit → recompile cycle. Always checked with _assertIsProxy.
    function _executorProxy() internal view returns (address) {
        return vm.envAddress("TRANSIT_EXECUTOR_PROXY");
    }

    /// @dev Deploy a new TransitForwarder beacon impl from Config + the executor proxy.
    ///      Call within a broadcast context. (Shared by DeployTransitFactory / UpgradeTransitForwarder)
    function _deployTransitForwarderImpl() internal returns (TransitForwarder) {
        address exec = _executorProxy();
        _assertIsProxy(exec, "TRANSIT_EXECUTOR_PROXY");
        return new TransitForwarder(
            usdc, paymentContract, operator, exec, AVALANCHE_CCTP_DOMAIN, INJECTIVE_CCTP_DOMAIN
        );
    }

    /// @dev Deploy a new TransitExecutor impl from Config. Call within a broadcast context.
    ///      (Shared by DeployTransitExecutor / UpgradeTransitExecutor)
    function _deployTransitExecutorImpl() internal returns (TransitExecutor) {
        return new TransitExecutor(usdc, transmitter, operator);
    }

    /// @dev ERC-1967 implementation slot. Reading it is the cheapest way to tell a proxy from a bare implementation.
    bytes32 private constant _ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev ⚠️ Guards the most damaging mistake available here. The executor address is baked into every
    ///      forwarder's `executor` immutable and into the `destinationCaller` of messages already burned elsewhere.
    ///      An IMPLEMENTATION address works until the first upgrade, then every forwarder's authorized caller
    ///      ceases to exist and in-flight messages become permanently unreceivable. No recovery.
    function _assertIsProxy(address a, string memory label) internal view {
        require(a.code.length != 0, string.concat("no code at ", label));
        require(
            uint256(vm.load(a, _ERC1967_IMPL_SLOT)) != 0,
            string.concat(label, " is an IMPLEMENTATION, not a proxy - forwarders would be permanently orphaned")
        );
    }

    /// @dev The implementation an ERC-1967 proxy currently points at. Call _assertIsProxy first.
    function _liveImplOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _ERC1967_IMPL_SLOT))));
    }

    // ── immutable drift guard ────────────────────────────────────────────────────────────────────────────────
    // `_deployTransitForwarderImpl` re-injects EVERY immutable from Config, so an upgrade meant to change logic
    // alone silently rebinds them whenever Config has moved. This compares Config against the live impl and
    // refuses unless the rebind was asked for. It assumes Config is exactly what the deploy helpers inject — keep
    // those in step or the guard checks something other than what will be deployed.
    uint256 private _driftCount;

    /// @dev factory proxy → beacon → the implementation currently installed for every deployed forwarder.
    function _liveForwarderImpl(address factoryProxy) internal view returns (address) {
        require(factoryProxy.code.length != 0, "no code at factory proxy");
        address beacon = TransitForwarderFactory(factoryProxy).beacon();
        require(beacon != address(0), "factory has no beacon (not initialized?)");
        return UpgradeableBeacon(beacon).implementation();
    }

    /// @dev Collects every mismatch instead of reverting on the first, so one run shows the whole picture.
    function _diff(string memory field, address live, address cfg) private {
        if (live != cfg) _recordDrift(field, vm.toString(live), vm.toString(cfg));
    }

    function _diff(string memory field, uint256 live, uint256 cfg) private {
        if (live != cfg) _recordDrift(field, vm.toString(live), vm.toString(cfg));
    }

    function _recordDrift(string memory field, string memory live, string memory cfg) private {
        _driftCount++;
        console2.log("  DRIFT", field);
        console2.log("    live:", live);
        console2.log("    cfg :", cfg);
    }

    /// @dev Whether an intentional rebind was authorised. `virtual` so tests can drive it deterministically —
    ///      vm.setEnv writes the real process environment, which is shared by every test running in parallel.
    function _rebindAllowed() internal view virtual returns (bool) {
        return vm.envOr("ALLOW_IMMUTABLE_REBIND", false);
    }

    function _settleDrift() private {
        if (_driftCount == 0) {
            console2.log("immutables match Config");
            return;
        }
        require(_rebindAllowed(), "immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)");
        console2.log("!! intentional rebind, fields changed:", _driftCount);
        _driftCount = 0;
    }

    /// @dev Call BEFORE startBroadcast: a failure here must cost nothing and leave no on-chain trace.
    ///      Add a `_diff` line here whenever TransitForwarder gains an immutable — nothing else will notice.
    function _assertTransitImmutablesMatch(address liveImpl) internal {
        // Sanity check, not a discriminator (see the contract-level note). A codeless address would report success
        // with empty returndata, hence the length check.
        require(liveImpl.code.length != 0, "no code at TransitForwarder impl");
        (bool ok, bytes memory data) = liveImpl.staticcall(abi.encodeWithSignature("LOCAL_DOMAIN()"));
        require(ok && data.length == 32, "impl is not a TransitForwarder (wrong TRANSIT_FORWARDER_FACTORY_PROXY?)");

        TransitForwarder live = TransitForwarder(payable(liveImpl));
        _diff("usdc", address(live.usdc()), usdc);
        _diff("paymentContract", address(live.paymentContract()), paymentContract);
        _diff("operator", live.operator(), operator);
        // The only field compared against an env var rather than a Config constant — see _executorProxy.
        _diff("executor", live.executor(), _executorProxy());
        _diff("LOCAL_DOMAIN", live.LOCAL_DOMAIN(), AVALANCHE_CCTP_DOMAIN);
        _diff("ALLOWED_DESTINATION_DOMAIN", live.ALLOWED_DESTINATION_DOMAIN(), INJECTIVE_CCTP_DOMAIN);
        _settleDrift();
    }

    /// @dev Call BEFORE startBroadcast, same contract as the forwarder guard above.
    ///      Add a `_diff` line here whenever TransitExecutor gains an immutable — nothing else will notice.
    function _assertExecutorImmutablesMatch(address liveImpl) internal {
        require(liveImpl.code.length != 0, "no code at TransitExecutor impl");
        // A real discriminator: only an executor answers this, since the forwarder gave up `transmitter()` with
        // the mint capability. If that is ever reverted, this stops discriminating — update it then.
        (bool ok, bytes memory data) = liveImpl.staticcall(abi.encodeWithSignature("transmitter()"));
        require(ok && data.length == 32, "impl is not a TransitExecutor (wrong TRANSIT_EXECUTOR_PROXY?)");

        TransitExecutor live = TransitExecutor(liveImpl);
        _diff("usdc", address(live.usdc()), usdc);
        _diff("transmitter", address(live.transmitter()), transmitter);
        _diff("operator", live.operator(), operator);
        _settleDrift();
    }

    /// @dev ⚠️ PRE-FLIGHT FOR FACTORY (UUPS) UPGRADES ONLY — call BEFORE startBroadcast.
    ///
    ///      `beaconInitCodeHash` was frozen in the live factory's storage at deploy time, but the new impl builds
    ///      proxies from its OWN type(BeaconProxy).creationCode. If they disagree the upgrade succeeds and every
    ///      createForwarder then reverts AddressMismatch — permanently. Deployed forwarders keep working, so nothing
    ///      looks broken until the next route is needed. A build-config change (solc/optimizer/via_ir/evm_version or
    ///      the OZ pin) is enough to trigger it, and the upgrade scripts never call createForwarder themselves.
    ///
    ///      If this reverts, DO NOT force the upgrade — deploy a fresh factory and migrate.
    function _assertFactoryUpgradeKeepsAddressSpace(address factoryProxy) internal view {
        bytes32 cached = TransitForwarderFactory(factoryProxy).beaconInitCodeHash();
        address beacon = TransitForwarderFactory(factoryProxy).beacon();
        bytes32 fromThisBuild =
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
        if (cached != fromThisBuild) {
            console2.log("  cached beaconInitCodeHash (live factory):");
            console2.logBytes32(cached);
            console2.log("  from this build:");
            console2.logBytes32(fromThisBuild);
            revert(
                "build drift: upgrading this factory would permanently brick createForwarder - deploy a new factory instead"
            );
        }
        console2.log("beaconInitCodeHash matches this build - createForwarder survives the upgrade");
    }
}
