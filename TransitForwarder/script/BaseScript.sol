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
 *      One difference is worth calling out, because it is the reason a whole class of bug cannot occur here: the
 *      original has to tell an InboundForwarder impl from an OutboundForwarder one, and does so by probing for a
 *      kind-specific getter. In THIS project there is only one kind of forwarder, so the ambiguity cannot arise and
 *      the LOCAL_DOMAIN() check below is a plain sanity check rather than a discriminator.
 *
 *      Since the executor migration, TransitForwarder no longer exposes `transmitter()` — the mint capability moved
 *      to TransitExecutor. That makes `transmitter()` a clean discriminator for an EXECUTOR impl (see
 *      _assertExecutorImmutablesMatch), and it also removes half of the cross-project ambiguity noted below.
 *
 *      (The residual risk lives in the OTHER project: pointing its inbound upgrade script at a Transit factory
 *      address still passes its `paymentContract()` probe. That is a one-line fix there — swap the probe to
 *      `INJECTIVE_DOMAIN()` — and is deliberately kept out of this subproject, which shares no code with it.)
 */
abstract contract BaseScript is Script {
    address public immutable usdc;
    address public immutable transmitter; // CCTP v2 MessageTransmitter (mint leg, called directly)
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

    /// @dev The TransitExecutor PROXY address. Not a Config constant: the proxy address is only known after
    ///      deployment (`new ERC1967Proxy`, not CREATE2), and baking it into Config would create a
    ///      deploy → edit → recompile cycle with a window in which forwarder impls get the wrong value.
    ///      Always validated with _assertIsProxy before use.
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

    /// @dev ⚠️ Guards the single most damaging deployment mistake available here.
    ///
    ///      The executor address is baked into (a) every forwarder's `executor` immutable and (b) the
    ///      `destinationCaller` of messages already burned on other chains. If an IMPLEMENTATION address is used
    ///      instead of the proxy, everything works until the first executor upgrade — at which point every deployed
    ///      forwarder's authorized caller ceases to exist, and in-flight messages naming that impl as
    ///      destinationCaller become permanently unreceivable. There is no recovery.
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
    // Why this exists: `_deployTransitForwarderImpl` above re-injects EVERY immutable from Config, so an upgrade
    // meant to change logic alone silently rebinds usdc/transmitter/paymentContract/operator/LOCAL_DOMAIN whenever
    // Config has moved. The guard compares Config against the impl that is live right now and refuses to proceed
    // unless the rebind was asked for. It therefore leans on Config being exactly what
    // `_deployTransitForwarderImpl` injects — keep those two in step, or the guard starts checking something other
    // than what will be deployed.
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
        // A real discriminator, not just a sanity check: TransitForwarder gave up `transmitter()` when the mint
        // capability moved here, so only an executor answers this. If that removal is ever reverted, this stops
        // discriminating and starts merely sanity-checking — update it then.
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
    ///      `beaconInitCodeHash` was frozen in the live factory's storage at deploy time, but the NEW implementation
    ///      about to be installed builds proxies from ITS OWN compile-time type(BeaconProxy).creationCode. If the two
    ///      disagree, the upgrade succeeds and then every createForwarder reverts AddressMismatch — permanently, with
    ///      no way back except deploying a whole new factory. Deployed forwarders keep working, so nothing looks
    ///      broken until the next route is needed.
    ///
    ///      A build-config change (optimizer/runs/via_ir/solc/evm_version, or the openzeppelin-contracts pin) between
    ///      the factory's deployment and now is enough to trigger it, which is exactly why the upgrade scripts cannot
    ///      be trusted to fail on their own: they never call createForwarder.
    ///
    ///      If this reverts, DO NOT force the upgrade. Deploy a fresh factory instead (DeployTransitFactory) and migrate.
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
