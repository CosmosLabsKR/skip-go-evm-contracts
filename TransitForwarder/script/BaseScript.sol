// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./Config.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
<<<<<<< HEAD
=======
import {ERC1967Utils} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
>>>>>>> sungrak/cctp-v2-contracts
import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {TransitForwarder} from "../src/TransitForwarder.sol";
import {TransitExecutor} from "../src/TransitExecutor.sol";

/**
<<<<<<< HEAD
 * @notice Deploy guard supporting only the two Avalanche C-Chain networks (mainnet 43114 / Fuji 43113).
 *         ⚠️ Unlike its ForwarderFactory siblings this subproject targets AVALANCHE, not Injective EVM — Avalanche
 *         is where it is DEPLOYED (LOCAL_DOMAIN = 1); Injective is where it SENDS (INJECTIVE_CCTP_DOMAIN = 29).
=======
 * @notice Deploy guard supporting the four supported SOURCE networks: Avalanche C-Chain (43114 / Fuji 43113) and
 *         Polygon PoS (137 / Amoy 80002).
 *         ⚠️ Unlike its ForwarderFactory siblings this subproject targets those chains, not Injective EVM — they are
 *         where it is DEPLOYED (LOCAL_DOMAIN = 1 or 7); Injective is where it SENDS (INJECTIVE_CCTP_DOMAIN = 29).
 *
 *         ⚠️ Each chain is a SEPARATE deployment with its own executor proxy, factory and forwarders. This contract
 *         resolves exactly one row from `block.chainid`, so the chain the RPC actually serves — not an env var, not
 *         a flag — decides which addresses get baked into an implementation. Note the messenger address is IDENTICAL
 *         on every chain of a network tier, so a wrong-RPC run cannot be caught by eyeballing it — LOCAL_DOMAIN is
 *         the immutable that actually differs.
 *
 *         ⚠️ Each chain then hosts TWO deployments, PROD and DEV, differing only in `operator`. DEPLOY_ENV picks
 *         one and is REQUIRED — see _isDevEnv.
>>>>>>> sungrak/cctp-v2-contracts
 * @dev ⚠️ REDUCED COPY of ForwarderFactory/script/BaseScript.sol.
 *
 *      The original probes a kind-specific getter to tell Inbound from Outbound impls. There is only one kind of
 *      forwarder here, so LOCAL_DOMAIN() below is a plain sanity check, not a discriminator. `transmitter()` IS a
 *      real discriminator for an executor impl, since the forwarder gave it up with the mint capability.
 *
<<<<<<< HEAD
 *      (Residual risk in the OTHER project: its inbound upgrade script still accepts a Transit factory via the
 *      `paymentContract()` probe. One-line fix there, deliberately out of scope here.)
=======
 *      (That residual risk in the OTHER project is now GONE: its outbound upgrade guard discriminates on a
 *      `paymentContract()` probe, and a v2 Transit impl no longer answers it.)
>>>>>>> sungrak/cctp-v2-contracts
 */
abstract contract BaseScript is Script {
    address public immutable usdc;
    address public immutable transmitter; // CCTP v1 MessageTransmitter (mint leg, called by the executor)
<<<<<<< HEAD
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
=======
    address public immutable messenger; // Circle TokenMessengerV2 (burn leg, called directly — no relayer, no fee)
    address public immutable operator;
    /// @notice The deploying chain's own CCTP domain — injected as TransitForwarder.LOCAL_DOMAIN.
    /// @dev Resolved here rather than read from Config at the use site: with more than one supported chain, a
    ///      chain-specific constant used directly is a silent single-chain hard-code. See the SelfLoop note below.
    uint32 public immutable localDomain;
    /// @notice Which of the two deployments on this chain this run targets: PROD or DEV.
    /// @dev Both exist on EVERY supported chain, mainnet and testnet alike, and `operator` is the only value that
    ///      differs between them — see the OPERATOR section in Config.
    bool public immutable isDev;

    constructor() {
        // Environment first, and it is REQUIRED: it decides the operator key, and nothing else in the resolved
        // config would look wrong if it were guessed — every other value is chain-derived, so PROD and DEV on the
        // same chain resolve identically apart from this one field.
        isDev = _isDevEnv();
        operator = isDev ? OPERATOR_DEV : OPERATOR_PROD;

        if (block.chainid == CHAIN_AVALANCHE) {
            usdc = USDC_AVALANCHE;
            transmitter = TRANSMITTER_AVALANCHE;
            messenger = MESSENGER_MAINNET_TIER;
            localDomain = AVALANCHE_CCTP_DOMAIN;
        } else if (block.chainid == CHAIN_AVALANCHE_TESTNET) {
            usdc = USDC_AVALANCHE_TESTNET;
            transmitter = TRANSMITTER_AVALANCHE_TESTNET;
            messenger = MESSENGER_TESTNET_TIER;
            localDomain = AVALANCHE_CCTP_DOMAIN;
        } else if (block.chainid == CHAIN_POLYGON) {
            usdc = USDC_POLYGON;
            transmitter = TRANSMITTER_POLYGON;
            messenger = MESSENGER_MAINNET_TIER;
            localDomain = POLYGON_CCTP_DOMAIN;
        } else if (block.chainid == CHAIN_POLYGON_TESTNET) {
            usdc = USDC_POLYGON_TESTNET;
            transmitter = TRANSMITTER_POLYGON_TESTNET;
            messenger = MESSENGER_TESTNET_TIER;
            localDomain = POLYGON_CCTP_DOMAIN;
        } else {
            revert("Chain not supported.");
        }

        // Cheap, but it is the one thing no per-chain row can get wrong on its own: a source chain that IS the
        // destination could never produce a usable transfer, and TransitForwarder's constructor would revert
        // SelfLoop at deploy time anyway. Failing in the constructor names the cause instead.
        require(localDomain != INJECTIVE_CCTP_DOMAIN, "localDomain == INJECTIVE_CCTP_DOMAIN (SelfLoop)");
    }

    /// @dev Which of the two deployments on this chain to target. REQUIRED — there is deliberately no default:
    ///      PROD and DEV differ only in the operator key, so a wrong guess produces a config that looks entirely
    ///      correct while binding the wrong key.
    ///
    ///      ⚠️ `virtual`, and it MUST stay free of derived state: it is called from this constructor, so an
    ///      override may only return a compile-time constant or read the environment. Tests override it with a
    ///      constant instead of using vm.setEnv, which writes the real process environment that forge shares
    ///      across the test contracts it runs in parallel.
    function _isDevEnv() internal view virtual returns (bool) {
        return _parseEnv(vm.envOr("DEPLOY_ENV", string("")));
    }

    /// @dev Split out and `pure` so the accept/reject rules are testable without touching the process environment.
    function _parseEnv(string memory env) internal pure returns (bool dev) {
        bytes32 h = keccak256(bytes(env));
        if (h == keccak256(bytes("dev"))) return true;
        if (h == keccak256(bytes("prod"))) return false;
        revert("DEPLOY_ENV is required and must be 'prod' or 'dev' - it selects the operator key");
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
        return new TransitForwarder(
            usdc, paymentContract, operator, exec, AVALANCHE_CCTP_DOMAIN, INJECTIVE_CCTP_DOMAIN
        );
=======
        return _deployTransitForwarderImpl(exec);
    }

    /// @dev Overload for callers that already validated the proxy BEFORE startBroadcast. Re-running the guard
    ///      inside a broadcast would contradict the rule stated on _assertTransitImmutablesMatch below.
    function _deployTransitForwarderImpl(address exec) internal returns (TransitForwarder) {
        return new TransitForwarder(usdc, messenger, operator, exec, localDomain, INJECTIVE_CCTP_DOMAIN);
>>>>>>> sungrak/cctp-v2-contracts
    }

    /// @dev Deploy a new TransitExecutor impl from Config. Call within a broadcast context.
    ///      (Shared by DeployTransitExecutor / UpgradeTransitExecutor)
    function _deployTransitExecutorImpl() internal returns (TransitExecutor) {
        return new TransitExecutor(usdc, transmitter, operator);
    }

<<<<<<< HEAD
    /// @dev ERC-1967 implementation slot. Reading it is the cheapest way to tell a proxy from a bare implementation.
    bytes32 private constant _ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

=======
>>>>>>> sungrak/cctp-v2-contracts
    /// @dev ⚠️ Guards the most damaging mistake available here. The executor address is baked into every
    ///      forwarder's `executor` immutable and into the `destinationCaller` of messages already burned elsewhere.
    ///      An IMPLEMENTATION address works until the first upgrade, then every forwarder's authorized caller
    ///      ceases to exist and in-flight messages become permanently unreceivable. No recovery.
    function _assertIsProxy(address a, string memory label) internal view {
        require(a.code.length != 0, string.concat("no code at ", label));
        require(
<<<<<<< HEAD
            uint256(vm.load(a, _ERC1967_IMPL_SLOT)) != 0,
=======
            uint256(vm.load(a, ERC1967Utils.IMPLEMENTATION_SLOT)) != 0,
>>>>>>> sungrak/cctp-v2-contracts
            string.concat(label, " is an IMPLEMENTATION, not a proxy - forwarders would be permanently orphaned")
        );
    }

    /// @dev The implementation an ERC-1967 proxy currently points at. Call _assertIsProxy first.
    function _liveImplOf(address proxy) internal view returns (address) {
<<<<<<< HEAD
        return address(uint160(uint256(vm.load(proxy, _ERC1967_IMPL_SLOT))));
=======
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
>>>>>>> sungrak/cctp-v2-contracts
    }

    // ── immutable drift guard ────────────────────────────────────────────────────────────────────────────────
    // `_deployTransitForwarderImpl` re-injects EVERY immutable from Config, so an upgrade meant to change logic
    // alone silently rebinds them whenever Config has moved. This compares Config against the live impl and
    // refuses unless the rebind was asked for. It assumes Config is exactly what the deploy helpers inject — keep
    // those in step or the guard checks something other than what will be deployed.
    uint256 private _driftCount;
<<<<<<< HEAD
=======
    /// @dev Counted apart from _driftCount so its authorisation cannot waive an ordinary drift. See _settleDrift.
    uint256 private _v1ToV2Count;
>>>>>>> sungrak/cctp-v2-contracts

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

<<<<<<< HEAD
    function _settleDrift() private {
        if (_driftCount == 0) {
            console2.log("immutables match Config");
            return;
        }
        require(_rebindAllowed(), "immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)");
        console2.log("!! intentional rebind, fields changed:", _driftCount);
        _driftCount = 0;
=======
    /// @dev Authorises ONLY the v1 -> v2 shape change (see _diffMessenger). Deliberately a SEPARATE flag from
    ///      ALLOW_IMMUTABLE_REBIND — see _settleDrift for why conflating them would be dangerous.
    function _v1ToV2Allowed() internal view virtual returns (bool) {
        return vm.envOr("ALLOW_V1_TO_V2", false);
    }

    /// @dev ⚠️ TWO INDEPENDENT AUTHORISATIONS, and keeping them independent is the whole point.
    ///
    ///      Each counter is all-or-nothing: one flag waives every drift it covers. That is acceptable for ordinary
    ///      rebinds, which an operator inspects one at a time. It is NOT acceptable for the v1 -> v2 migration,
    ///      because that migration MANDATES its flag on every run — so if the two shared one flag, the mandatory
    ///      one would also disarm the `executor` check for that run.
    ///
    ///      That check guards the most damaging mistake available here (see _assertIsProxy): the executor comes
    ///      from an env var with NO chain binding, and the supported chains are independent deployments. An
    ///      operator upgrading Polygon with Avalanche's TRANSIT_EXECUTOR_PROXY still exported would be refused on
    ///      `DRIFT executor` — and then waved straight through by the very flag the migration required, installing
    ///      a forwarder impl bound to the other chain's executor. Runbook §3.1: unfixable.
    function _settleDrift() private {
        if (_driftCount == 0 && _v1ToV2Count == 0) {
            console2.log("immutables match Config");
            return;
        }
        if (_v1ToV2Count != 0) {
            require(
                _v1ToV2Allowed(),
                "pre-v2 impl detected (set ALLOW_V1_TO_V2=true for the fee-removal upgrade - it does NOT waive other drift)"
            );
            console2.log("!! authorised v1 -> v2 shape change");
            _v1ToV2Count = 0;
        }
        if (_driftCount != 0) {
            require(
                _rebindAllowed(), "immutable drift vs Config (set ALLOW_IMMUTABLE_REBIND=true to rebind intentionally)"
            );
            console2.log("!! intentional rebind, fields changed:", _driftCount);
            _driftCount = 0;
        }
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
        _diff("paymentContract", address(live.paymentContract()), paymentContract);
        _diff("operator", live.operator(), operator);
        // The only field compared against an env var rather than a Config constant — see _executorProxy.
        _diff("executor", live.executor(), _executorProxy());
        _diff("LOCAL_DOMAIN", live.LOCAL_DOMAIN(), AVALANCHE_CCTP_DOMAIN);
=======
        _diffMessenger(liveImpl);
        _diff("operator", live.operator(), operator);
        // The only field compared against an env var rather than a Config constant — see _executorProxy.
        _diff("executor", live.executor(), _executorProxy());
        _diff("LOCAL_DOMAIN", live.LOCAL_DOMAIN(), localDomain);
>>>>>>> sungrak/cctp-v2-contracts
        _diff("ALLOWED_DESTINATION_DOMAIN", live.ALLOWED_DESTINATION_DOMAIN(), INJECTIVE_CCTP_DOMAIN);
        _settleDrift();
    }

<<<<<<< HEAD
=======
    /// @dev ⚠️ `messenger` DID NOT EXIST before forwarder v2 (it replaced `paymentContract` when the relayer fee was
    ///      removed), and a pre-v2 impl does not merely return nothing for it — TransitForwarder's fallback reverts
    ///      NativeNotAccepted, so a typed `live.messenger()` would abort this whole guard with an error naming the
    ///      wrong problem entirely, and ALLOW_IMMUTABLE_REBIND could not get past it because the revert happens
    ///      before _settleDrift. Since the ONE upgrade that must cross this boundary is the v1 -> v2 upgrade itself,
    ///      that would brick the exact path it is meant to protect. So probe it defensively and report an absent
    ///      getter as drift — which is honestly what it is: v1 -> v2 genuinely rebinds this slot.
    ///
    ///      It is counted under its OWN authorisation (ALLOW_V1_TO_V2), never under ALLOW_IMMUTABLE_REBIND: this
    ///      drift is unavoidable on the migration run, and a mandatory flag must not be able to waive anything
    ///      else. See _settleDrift.
    function _diffMessenger(address liveImpl) private {
        (bool ok, bytes memory data) = liveImpl.staticcall(abi.encodeWithSignature("messenger()"));
        if (!ok || data.length != 32) {
            _v1ToV2Count++;
            console2.log("  V1->V2  messenger");
            console2.log("    live: ABSENT - this impl predates forwarder v2");
            console2.log("    cfg :", vm.toString(messenger));
            return;
        }
        _diff("messenger", abi.decode(data, (address)), messenger);
    }

>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
    function _assertFactoryUpgradeKeepsAddressSpace(address factoryProxy) internal view {
        bytes32 cached = TransitForwarderFactory(factoryProxy).beaconInitCodeHash();
        address beacon = TransitForwarderFactory(factoryProxy).beacon();
=======
    function _assertFactoryUpgradeKeepsAddressSpace(address factoryProxy, address beacon) internal view {
        bytes32 cached = TransitForwarderFactory(factoryProxy).beaconInitCodeHash();
>>>>>>> sungrak/cctp-v2-contracts
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
