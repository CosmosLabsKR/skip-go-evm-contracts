// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";

/**
 * @title ForwarderFactoryBase
 * @notice Shared, funds-critical base for the Inbound/Outbound forwarder factories. Centralizes the BeaconProxy
 *         CREATE2 machinery so the predicted-address invariant lives in a single definition instead of being
 *         copy-pasted across two factories.
 * @dev Template method: this base owns the invariant skeleton (beacon creation, the `beaconInitCodeHash` formula,
 *      CREATE2 prediction, deploy+init, and the UUPS authorize hook). Each concrete factory supplies the variable
 *      hooks (typed salt preimage, typed `initialize` encoding, and its own errors/events).
 *
 *      Storage layout is identical to the pre-abstraction factories: OZ v5 parents use ERC-7201 namespaced storage
 *      (no sequential slots), so `beacon` stays at slot 0, `beaconInitCodeHash` at slot 1, and `__gap[48]` at
 *      slots 2..49 — the base block is exactly 50 slots. Concrete factories append their own storage (and their own
 *      `__gap`) starting at slot 50; the base may grow into its gap without shifting them.
 *
 *      Deployment stays separated: each concrete factory creates and owns its OWN beacon in `initialize`, so the
 *      inbound/outbound upgrade lifecycles remain independent even though they share this source.
 */
abstract contract ForwarderFactoryBase is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice UpgradeableBeacon shared by all forwarders this factory deploys (the factory is its owner).
    address public beacon;
    /// @notice BeaconProxy initCodeHash — a constant depending only on the beacon address and the compiled BeaconProxy
    ///         creation code. ⚠️ FROZEN INVARIANT: computed and cached ONCE in initialize, then read from storage
    ///         forever. Never recompute it inline (e.g. inside _predict): a future factory-logic upgrade that changes
    ///         the embedded `type(BeaconProxy).creationCode` would then silently fork the predicted-address space and
    ///         orphan the funds of every already-deployed forwarder. The cached value must outlive such upgrades.
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
    /// @dev Creates the factory-owned beacon and caches the empty-data BeaconProxy initCodeHash. Byte-identical
    ///      across both factories, hence centralized here. Each concrete factory keeps a thin `initialize` that
    ///      calls this (so `Factory.initialize` stays resolvable for deploy scripts via the concrete name).
    function __ForwarderFactory_init(address forwarderImplementation) internal onlyInitializing {
        if (forwarderImplementation == address(0)) revert ZeroImplementation();
        // Establishes ownership (owner = deployer). __Ownable_init is the canonical OZ initializer and sets the owner
        // directly. Do NOT replace it with a bare __Ownable2Step_init() — that one is a no-op and would leave the
        // factory ownerless (owner == address(0)), permanently bricking every onlyOwner upgrade. Ownable2Step adds no
        // init state of its own.
        __Ownable_init(msg.sender);
        // The factory (proxy) is the beacon owner. address(this) = proxy.
        beacon = address(new UpgradeableBeacon(forwarderImplementation, address(this)));
        // Must structurally match the empty-data BeaconProxy initcode tail abi.encode(beacon, "") for the address to line up.
        beaconInitCodeHash = keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
    }

    /// @dev Prediction only. salt from the concrete's preimage, initCodeHash from the cached constant. Uses
    ///      address(this) (= proxy) as the deployer, hence view.
    function _predict(bytes32 salt) internal view returns (address) {
        return Create2.computeAddress(salt, beaconInitCodeHash, address(this));
    }

    /// @dev Deploys the BeaconProxy via CREATE2 (empty data → constant initCodeHash) and atomically initializes it
    ///      in the same tx. `initData` is built by the concrete with abi.encodeCall, preserving compile-time typing.
    /// @param salt The CREATE2 salt (concrete-built preimage).
    /// @param predicted The address the concrete already predicted for this salt (re-verified post-deploy).
    /// @param initData abi.encodeCall(Forwarder.initialize, (...)) for the per-route init.
    function _deployAndInit(bytes32 salt, address predicted, bytes memory initData)
        internal
        returns (address forwarder)
    {
        forwarder = address(new BeaconProxy{salt: salt}(beacon, ""));
        if (forwarder != predicted) revert AddressMismatch();

        (bool ok, bytes memory ret) = forwarder.call(initData);
        if (!ok) {
            // Bubble the forwarder's revert reason, matching the prior typed-call behavior.
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev Swap the beacon impl to upgrade all deployed forwarders' logic (and immutables) in bulk. The concrete
    ///      wraps this with its own typed function + event so the external ABI is unchanged.
    function _upgradeForwarderImpl(address newImplementation) internal {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
