// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";

import {ITransitForwarderFactory} from "./interfaces/ITransitForwarderFactory.sol";
import {TransitForwarder} from "./TransitForwarder.sol";

/**
 * @title TransitForwarderFactory
 * @notice Deterministically deploys a TransitForwarder (BeaconProxy) from (sender, destinationDomain, mintRecipient).
 *         The BeaconProxy is deployed with empty constructor data, so its initCodeHash is a constant that depends
 *         only on the beacon address, and the predicted address becomes f(deployer, salt) → the address stays the
 *         same even when the forwarder logic changes. That determinism is a functional requirement, not a
 *         convenience: the source-chain burner has to know mintRecipient before this contract exists.
 *
 * @dev Two-layer upgrade: this factory is UUPS, the deployed TransitForwarders use a Beacon (upgraded in bulk by
 *      swapping the impl).
 *
 *      ⚠️ The BeaconProxy/CREATE2 machinery below is INLINED from ForwarderFactory's abstract `ForwarderFactoryBase`
 *      rather than inherited. That base exists so "the predicted-address invariant lives in one definition instead of
 *      two copies" — a rationale that only holds with two or more concrete factories. This subproject has exactly
 *      one, so inheriting would add a layer of indirection buying nothing. Every invariant comment came along with
 *      the code; do not trim them.
 *
 *      Storage: OZ v5 parents use ERC-7201 namespaced storage (no sequential slots), so `beacon` is slot 0,
 *      `beaconInitCodeHash` slot 1, `__gap[48]` slots 2..49.
 */
contract TransitForwarderFactory is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ITransitForwarderFactory
{
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
    ///         test/UpgradeTransitFactory.t.sol catches that before it reaches a live factory.
    bytes32 public beaconInitCodeHash;

    /// @notice The TransitExecutor every forwarder this factory produces answers to.
    /// @dev Read off the first implementation at initialize and then FROZEN: the executor address is baked into
    ///      already-burned messages' destinationCaller and can never be replaced, so a forwarder impl bound to a
    ///      different one would orphan every route the moment it was installed. upgradeForwarderImplementation
    ///      refuses such an impl — this is the on-chain half of the deploy script's _assertIsProxy check.
    address public executor;

    // append-only: add new state variables before __gap and shrink __gap (never prepend). Block = 50 slots.
    uint256[47] private __gap;

    /// @dev impl passed to initialize was the zero address.
    error ZeroImplementation();
    /// @dev The CREATE2 deploy did not land on the predicted address (initCodeHash/salt/deployer divergence).
    error AddressMismatch();
    /// @notice The implementation being installed answers to a different executor than this factory's forwarders.
    error ExecutorMismatch();

    constructor() {
        _disableInitializers();
    }

    /// @param forwarderImplementation Address of the TransitForwarder logic impl (pre-deployed by the deploy script).
    /// @dev Creates the factory-owned beacon and caches the empty-data BeaconProxy initCodeHash.
    function initialize(address forwarderImplementation) external initializer {
        if (forwarderImplementation == address(0)) revert ZeroImplementation();
        // Do NOT replace with a bare __Ownable2Step_init() — that is a no-op and would leave the factory ownerless
        // (owner == address(0)), permanently bricking every onlyOwner upgrade. Ownable2Step adds no init state.
        __Ownable_init(msg.sender);
        // The factory (proxy) is the beacon owner.
        beacon = address(new UpgradeableBeacon(forwarderImplementation, address(this)));
        // Adopt the implementation's executor as this factory's invariant. Every later impl must match it.
        executor = TransitForwarder(payable(forwarderImplementation)).executor();
        // Must match the empty-data BeaconProxy initcode tail abi.encode(beacon, "") for the address to line up.
        beaconInitCodeHash = keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    /// @dev Single definition of the CREATE2 salt preimage. The encoding MUST stay byte-identical across every call
    ///      site (predict/deploy) or the predicted-address invariant forks; centralizing it here removes that drift risk.
    ///
    ///      Note this preimage is byte-identical to OutboundForwarderFactory's. Addresses still cannot collide —
    ///      CREATE2 is f(deployer, salt, initCodeHash) and both differ — but off-chain consumers must key on the
    ///      factory address, never on the route tuple alone. See ITransitForwarderFactory's event note.
    function _salt(address sender, uint32 destinationDomain, bytes32 mintRecipient) private pure returns (bytes32) {
        return keccak256(abi.encode(sender, destinationDomain, mintRecipient));
    }

    /// @dev Prediction only: salt from the preimage above, initCodeHash from the frozen cache, deployer =
    ///      address(this) (the proxy).
    function _predict(bytes32 salt) private view returns (address) {
        return Create2.computeAddress(salt, beaconInitCodeHash, address(this));
    }

    /// @inheritdoc ITransitForwarderFactory
    function getForwarderAddress(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (address predicted)
    {
        predicted = _predict(_salt(sender, destinationDomain, mintRecipient));
    }

    /// @inheritdoc ITransitForwarderFactory
    /// @dev Authoritative: the forwarder address is bound to (this factory, salt, beacon initCodeHash), so a third
    ///      party cannot squat it — code existing at the predicted address means the canonical forwarder is deployed.
    function isForwarderDeployed(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (bool)
    {
        return _predict(_salt(sender, destinationDomain, mintRecipient)).code.length != 0;
    }

    /// @inheritdoc ITransitForwarderFactory
    function createForwarder(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        returns (address forwarder)
    {
        if (sender == address(0)) revert ZeroAddress();
        if (mintRecipient == bytes32(0)) revert EmptyMintRecipient();

        bytes32 salt = _salt(sender, destinationDomain, mintRecipient);
        address predicted = _predict(salt);
        if (predicted.code.length != 0) revert ForwarderAlreadyDeployed(predicted);

        forwarder = address(new BeaconProxy{salt: salt}(beacon, ""));
        // Guards the frozen-cache invariant: a mismatch means the compiled creationCode no longer matches
        // beaconInitCodeHash (build-config drift), so refuse rather than deploy to an unpredicted address.
        if (forwarder != predicted) revert AddressMismatch();

        // Bubbles the forwarder's revert reason on failure — notably SelfLoop() for a route aimed at this chain,
        // which only the impl can detect (FailedInnerCall when it reverted without data).
        Address.functionCall(
            forwarder, abi.encodeCall(TransitForwarder.initialize, (sender, destinationDomain, mintRecipient))
        );

        emit TransitForwarderDeployed(forwarder, sender, destinationDomain, mintRecipient);
    }

    /// @inheritdoc ITransitForwarderFactory
    /// @notice Swap the beacon impl to upgrade all deployed TransitForwarders' logic (and immutables such as
    ///         operator) in bulk. Applies to forwarders deployed later too — the BeaconProxy initcode holds only the
    ///         beacon address, never the impl.
    function upgradeForwarderImplementation(address newImplementation) external onlyOwner {
        // The one thing a beacon upgrade must never change. Every deployed forwarder gates its transit entry point
        // on this address, and it is also the destinationCaller of messages already burned on other chains — so an
        // impl bound elsewhere would silently strand every route and every in-flight message.
        if (TransitForwarder(payable(newImplementation)).executor() != executor) revert ExecutorMismatch();
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit ForwarderImplementationUpgraded(newImplementation);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
