// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";

import {IForwarderFactory} from "./interfaces/IForwarderFactory.sol";
import {Forwarder} from "./Forwarder.sol";

/**
 * @title ForwarderFactory
 * @notice Deterministically deploys a Forwarder (BeaconProxy) from (sender, destinationDomain, mintRecipient).
 *         The BeaconProxy is deployed with empty constructor data, so its initCodeHash is a constant that depends
 *         only on the beacon address, and the predicted address becomes f(deployer, salt) → the address stays the
 *         same even when the forwarder logic changes.
 * @dev Two-layer upgrade: the factory itself is UUPS, the deployed Forwarders use a Beacon (upgraded in bulk by
 *      swapping the impl). The deployer is the factory proxy (address(this)). The factory owns the beacon.
 */
contract ForwarderFactory is IForwarderFactory, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice UpgradeableBeacon shared by all Forwarders (the factory is its owner).
    address public beacon;
    /// @notice BeaconProxy initCodeHash. A constant that depends only on the beacon address, so it is computed and
    ///         cached once in initialize.
    bytes32 public beaconInitCodeHash;

    // append-only: add new state variables before __gap and shrink __gap (never prepend).
    uint256[48] private __gap;

    constructor() {
        _disableInitializers();
    }

    /// @param forwarderImplementation Address of the Forwarder logic impl (pre-deployed by the deploy script).
    function initialize(address forwarderImplementation) external initializer {
        if (forwarderImplementation == address(0)) revert ZeroAddress();
        __Ownable2Step_init();
        _transferOwnership(msg.sender);
        // The factory (proxy) is the beacon owner. address(this) = proxy.
        beacon = address(new UpgradeableBeacon(forwarderImplementation, address(this)));
        // Must structurally match the empty-data BeaconProxy initcode tail abi.encode(beacon, "") for the address to line up.
        beaconInitCodeHash = keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
    }

    /// @inheritdoc IForwarderFactory
    function getForwarderAddress(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (address predicted)
    {
        (predicted,) = _computeAddress(sender, destinationDomain, mintRecipient);
    }

    /// @inheritdoc IForwarderFactory
    function createForwarder(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        returns (address forwarder)
    {
        if (sender == address(0)) revert ZeroAddress();
        if (mintRecipient == bytes32(0)) revert EmptyMintRecipient();

        (address predicted, bytes32 salt) = _computeAddress(sender, destinationDomain, mintRecipient);
        if (predicted.code.length != 0) revert ForwarderAlreadyDeployed(predicted);

        // CREATE2 with empty data → keeps initCodeHash constant (design §2.2). Atomically initialize right after.
        forwarder = address(new BeaconProxy{salt: salt}(beacon, ""));
        if (forwarder != predicted) revert AddressMismatch();

        Forwarder(payable(forwarder)).initialize(sender, destinationDomain, mintRecipient);

        emit ForwarderDeployed(forwarder, sender, destinationDomain, mintRecipient);
    }

    /// @inheritdoc IForwarderFactory
    /// @notice Swap the beacon impl to upgrade all deployed Forwarders' logic (and immutables such as operator) in bulk.
    function upgradeForwarderImplementation(address newImplementation) external onlyOwner {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit ForwarderImplementationUpgraded(newImplementation);
    }

    /// @dev Prediction only. salt from args, initCodeHash from the cached constant (beaconInitCodeHash). Shared by
    ///      getter/deploy. Uses address(this) (= proxy) as the deployer, hence view.
    function _computeAddress(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        internal
        view
        returns (address predicted, bytes32 salt)
    {
        salt = keccak256(abi.encode(sender, destinationDomain, mintRecipient));
        predicted = Create2.computeAddress(salt, beaconInitCodeHash, address(this));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
