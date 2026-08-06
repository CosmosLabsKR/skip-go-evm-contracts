// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./Config.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import {ForwarderFactoryBase} from "../src/ForwarderFactoryBase.sol";
import {OutboundForwarder} from "../src/OutboundForwarder.sol";
import {InboundForwarder} from "../src/InboundForwarder.sol";

/**
 * @notice Deploy guard supporting only the two Injective EVM chains (mainnet 1776 / testnet 1439).
 * @dev Resolves every per-chain dependency address for both the outbound and inbound forwarders.
 *      INJECTIVE_CCTP_DOMAIN (29) identifies the chain, so it is shared across mainnet/testnet.
 */
abstract contract BaseScript is Script {
    // outbound deps
    address public immutable usdc;
    address public immutable paymentContract;
    address public immutable operator;
    // inbound deps
    address public immutable transmitter; // CCTP v2 MessageTransmitter (receiveMessage)

    constructor() {
        if (block.chainid == CHAIN_INJECTIVE) {
            usdc = USDC_INJECTIVE;
            paymentContract = PAYMENT_CONTRACT_INJECTIVE;
            operator = OPERATOR_INJECTIVE;
            transmitter = TRANSMITTER_INJECTIVE;
        } else if (block.chainid == CHAIN_INJECTIVE_TESTNET) {
            usdc = USDC_INJECTIVE_TESTNET;
            paymentContract = PAYMENT_CONTRACT_INJECTIVE_TESTNET;
            operator = OPERATOR_INJECTIVE_TESTNET;
            transmitter = TRANSMITTER_INJECTIVE_TESTNET;
        } else {
            revert("Chain not supported.");
        }
    }

    /// @dev Deploy a new OutboundForwarder beacon impl from USDC/PAYMENT_CONTRACT/OPERATOR.
    ///      Call within a broadcast context. (Shared by DeployOutboundFactory / UpgradeOutboundForwarder)
    function _deployOutboundForwarderImpl() internal returns (OutboundForwarder) {
        return new OutboundForwarder(usdc, paymentContract, operator);
    }

    /// @dev Deploy a new InboundForwarder beacon impl from USDC/TRANSMITTER/OPERATOR/INJECTIVE_CCTP_DOMAIN.
    ///      Call within a broadcast context. (Shared by DeployInboundFactory / UpgradeInboundForwarder)
    function _deployInboundForwarderImpl() internal returns (InboundForwarder) {
        return new InboundForwarder(usdc, transmitter, operator, INJECTIVE_CCTP_DOMAIN);
    }

    // ── immutable drift guard ────────────────────────────────────────────────────────────────────────────────
    // Why this exists: `_deploy*ForwarderImpl` above re-injects EVERY immutable from Config, so an upgrade meant to
    // change logic alone silently rebinds usdc/transmitter/paymentContract/operator/domain whenever Config has moved.
    // The guard compares Config against the impl that is live right now and refuses to proceed unless the rebind was
    // asked for. It therefore leans on Config being exactly what `_deploy*ForwarderImpl` injects — keep those two in
    // step, or the guard starts checking something other than what will be deployed.
    uint256 private _driftCount;

    /// @dev factory proxy → beacon → the implementation currently installed for every deployed forwarder.
    function _liveForwarderImpl(address factoryProxy) internal view returns (address) {
        require(factoryProxy.code.length != 0, "no code at factory proxy");
        address beacon = ForwarderFactoryBase(factoryProxy).beacon();
        require(beacon != address(0), "factory has no beacon (not initialized?)");
        return UpgradeableBeacon(beacon).implementation();
    }

    /// @dev Confirms `impl` really is the forwarder kind the caller expects before its getters are trusted.
    ///      Without this, pointing the inbound script at the outbound factory (or vice versa) fails deep inside the
    ///      comparison with `NativeNotAccepted()` — the forwarders' `fallback` swallowing a selector they don't have.
    ///      `usdc()` exists on both kinds, so only the kind-specific getter can tell them apart.
    function _requireForwarderKind(address impl, string memory getter, string memory kind) private view {
        require(impl.code.length != 0, string.concat("no code at ", kind, " impl"));
        (bool ok, bytes memory data) = impl.staticcall(abi.encodeWithSignature(getter));
        // A codeless address would report success with empty returndata, hence the length check.
        require(ok && data.length == 32, string.concat("impl is not an ", kind, " (wrong *_FACTORY_PROXY?)"));
    }

    /// @dev Collects every mismatch instead of reverting on the first, so one run shows the whole picture.
    function _diff(string memory field, address live, address cfg) private {
        if (live != cfg) _recordDrift(field, vm.toString(live), vm.toString(cfg));
    }

    function _diff(string memory field, uint256 live, uint256 cfg) private {
        if (live != cfg) _recordDrift(field, vm.toString(live), vm.toString(cfg));
    }

    /// @dev Separate name rather than a third `_diff` overload: `string` and `address` literals are not distinct
    ///      enough at the call site for overload resolution to be obvious to a reader.
    function _diffStr(string memory field, string memory live, string memory cfg) private {
        if (keccak256(bytes(live)) != keccak256(bytes(cfg))) _recordDrift(field, live, cfg);
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
    ///      Add a `_diff` line here whenever InboundForwarder gains an immutable — nothing else will notice.
    ///      The DENOM() assert below is not an immutable check: the denom is derived from `usdc` on every call, so
    ///      the `usdc` line already covers the value. It is here to catch a change to the RENDERING (prefix, EIP-55
    ///      casing) between the live impl and this build, which comparing raw addresses cannot see.
    function _assertInboundImmutablesMatch(address liveImpl) internal {
        _requireForwarderKind(liveImpl, "transmitter()", "InboundForwarder");
        InboundForwarder live = InboundForwarder(payable(liveImpl));
        _diff("usdc", address(live.usdc()), usdc);
        _diffStr("DENOM", live.DENOM(), string.concat("erc20:", Strings.toChecksumHexString(usdc)));
        _diff("transmitter", address(live.transmitter()), transmitter);
        _diff("operator", live.operator(), operator);
        _diff("INJECTIVE_DOMAIN", live.INJECTIVE_DOMAIN(), INJECTIVE_CCTP_DOMAIN);
        _settleDrift();
    }

    /// @dev Add a `_diff` line here whenever OutboundForwarder gains an immutable — nothing else will notice.
    function _assertOutboundImmutablesMatch(address liveImpl) internal {
        _requireForwarderKind(liveImpl, "paymentContract()", "OutboundForwarder");
        OutboundForwarder live = OutboundForwarder(payable(liveImpl));
        _diff("usdc", address(live.usdc()), usdc);
        _diff("paymentContract", address(live.paymentContract()), paymentContract);
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
    ///      If this reverts, DO NOT force the upgrade. Deploy a fresh factory instead (Deploy*Factory) and migrate.
    function _assertFactoryUpgradeKeepsAddressSpace(address factoryProxy) internal view {
        bytes32 cached = ForwarderFactoryBase(factoryProxy).beaconInitCodeHash();
        address beacon = ForwarderFactoryBase(factoryProxy).beacon();
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
