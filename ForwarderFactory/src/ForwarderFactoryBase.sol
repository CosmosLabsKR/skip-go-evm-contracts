// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";

/**
 * @title ForwarderFactoryBase
 * @notice Shared, funds-critical base for the Inbound/Outbound forwarder factories. Centralizes the BeaconProxy
 *         CREATE2 machinery so the predicted-address invariant lives in one definition instead of two copies.
 * @dev Template method: the base owns the invariant skeleton (beacon creation, the `beaconInitCodeHash` formula,
 *      CREATE2 prediction, deploy+init, UUPS authorize hook); each concrete factory supplies the typed salt preimage,
 *      the typed `initialize` encoding, and its own errors/events.
 *
 *      Storage: OZ v5 parents use ERC-7201 namespaced storage (no sequential slots), so `beacon` is slot 0,
 *      `beaconInitCodeHash` slot 1, `__gap[48]` slots 2..49 — a 50-slot base block. Concrete factories append from
 *      slot 50; the base may grow into its gap without shifting them.
 *
 *      Each concrete factory creates and owns its OWN beacon in `initialize`, so the inbound/outbound upgrade
 *      lifecycles stay independent despite sharing this source.
 */
abstract contract ForwarderFactoryBase is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice UpgradeableBeacon shared by all forwarders this factory deploys (the factory is its owner).
    address public beacon;
    /// @notice BeaconProxy initCodeHash, derived from the beacon address and the compiled BeaconProxy creation code.
    ///         ⚠️ FROZEN INVARIANT: cached ONCE in initialize, read from storage forever. Never recompute it inline
    ///         (e.g. in _predict) — a factory upgrade carrying different `type(BeaconProxy).creationCode` would fork
    ///         the predicted-address space and orphan every deployed forwarder's funds.
    ///
    ///         Consequence: since _deployAndInit builds from compile-time creationCode, any build-config drift (see
    ///         foundry.toml) after deployment makes every later createForwarder revert AddressMismatch permanently.
    ///         Deployed forwarders keep working; only new routes die. The golden vector in
    ///         test/UpgradeForwarderFactory.t.sol catches that before it reaches a live factory.
    bytes32 public beaconInitCodeHash;

    // append-only: add new state variables before __gap and shrink __gap (never prepend). Base block = 50 slots.
    uint256[48] private __gap;

    /// @dev impl passed to initialize was the zero address. (Concrete-facing route errors such as ZeroAddress live
    ///      on the concrete's interface; this is the base-owned init guard.)
    error ZeroImplementation();
    /// @dev The CREATE2 deploy did not land on the predicted address (initCodeHash/salt/deployer divergence).
    error AddressMismatch();

    constructor() {
        _disableInitializers();
    }

    /// @param forwarderImplementation Address of the forwarder logic impl (pre-deployed by the deploy script).
    /// @dev Creates the factory-owned beacon and caches the empty-data BeaconProxy initCodeHash. Each concrete factory
    ///      keeps a thin `initialize` calling this, so `Factory.initialize` stays resolvable via the concrete name.
    function __ForwarderFactory_init(address forwarderImplementation) internal onlyInitializing {
        if (forwarderImplementation == address(0)) revert ZeroImplementation();
        // Do NOT replace with a bare __Ownable2Step_init() — that is a no-op and would leave the factory ownerless
        // (owner == address(0)), permanently bricking every onlyOwner upgrade. Ownable2Step adds no init state.
        __Ownable_init(msg.sender);
        // The factory (proxy) is the beacon owner.
        beacon = address(new UpgradeableBeacon(forwarderImplementation, address(this)));
        // Must match the empty-data BeaconProxy initcode tail abi.encode(beacon, "") for the address to line up.
        beaconInitCodeHash = keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
    }

    /// @dev Prediction only: salt from the concrete's preimage, initCodeHash from the frozen cache, deployer =
    ///      address(this) (the proxy).
    function _predict(bytes32 salt) internal view returns (address) {
        return Create2.computeAddress(salt, beaconInitCodeHash, address(this));
    }

    /// @dev Deploys the BeaconProxy via CREATE2 and initializes it atomically in the same tx.
    /// @param salt The CREATE2 salt (concrete-built preimage).
    /// @param predicted The address the concrete predicted for this salt (re-verified post-deploy).
    /// @param initData abi.encodeCall(Forwarder.initialize, (...)) for the per-route init.
    function _deployAndInit(bytes32 salt, address predicted, bytes memory initData)
        internal
        returns (address forwarder)
    {
        forwarder = address(new BeaconProxy{salt: salt}(beacon, ""));
        // Guards the frozen-cache invariant: a mismatch means the compiled creationCode no longer matches
        // beaconInitCodeHash (build-config drift), so refuse rather than deploy to an unpredicted address.
        if (forwarder != predicted) revert AddressMismatch();

        // Bubbles the forwarder's revert reason on failure (FailedInnerCall when it reverted without data).
        Address.functionCall(forwarder, initData);
    }

    /// @dev Swap the beacon impl to upgrade all deployed forwarders' logic (and immutables) in bulk. Applies to
    ///      forwarders deployed later too — the BeaconProxy initcode holds only the beacon address, never the impl.
    function _upgradeForwarderImpl(address newImplementation) internal {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
