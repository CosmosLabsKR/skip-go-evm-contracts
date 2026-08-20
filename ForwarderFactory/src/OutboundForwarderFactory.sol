// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForwarderFactoryBase} from "./ForwarderFactoryBase.sol";
import {IOutboundForwarderFactory} from "./interfaces/IOutboundForwarderFactory.sol";
import {OutboundForwarder} from "./OutboundForwarder.sol";

/**
 * @title OutboundForwarderFactory
 * @notice Deterministically deploys a OutboundForwarder (BeaconProxy) from (sender, destinationDomain, mintRecipient).
 *         The BeaconProxy is deployed with empty constructor data, so its initCodeHash is a constant that depends
 *         only on the beacon address, and the predicted address becomes f(deployer, salt) → the address stays the
 *         same even when the forwarder logic changes.
 * @dev Two-layer upgrade: the factory itself is UUPS, the deployed OutboundForwarders use a Beacon (upgraded in bulk by
 *      swapping the impl). The shared CREATE2/beacon machinery lives in ForwarderFactoryBase; this contract only
 *      builds the typed salt preimage, encodes the per-route initialize, and owns its errors/events.
 */
contract OutboundForwarderFactory is ForwarderFactoryBase, IOutboundForwarderFactory {
    /// @param forwarderImplementation Address of the OutboundForwarder logic impl (pre-deployed by the deploy script).
    function initialize(address forwarderImplementation) external initializer {
        __ForwarderFactory_init(forwarderImplementation);
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    /// @dev Single definition of the CREATE2 salt preimage. The encoding MUST stay byte-identical across every call
    ///      site (predict/deploy) or the predicted-address invariant forks; centralizing it here removes that drift risk.
    function _salt(address sender, uint32 destinationDomain, bytes32 mintRecipient) private pure returns (bytes32) {
        return keccak256(abi.encode(sender, destinationDomain, mintRecipient));
    }

    /// @inheritdoc IOutboundForwarderFactory
    function getForwarderAddress(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (address predicted)
    {
        predicted = _predict(_salt(sender, destinationDomain, mintRecipient));
    }

    /// @inheritdoc IOutboundForwarderFactory
    /// @dev Authoritative: the forwarder address is bound to (this factory, salt, beacon initCodeHash), so a third
    ///      party cannot squat it — code existing at the predicted address means the canonical forwarder is deployed.
    function isForwarderDeployed(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        view
        returns (bool)
    {
        return _predict(_salt(sender, destinationDomain, mintRecipient)).code.length != 0;
    }

    /// @inheritdoc IOutboundForwarderFactory
    function createForwarder(address sender, uint32 destinationDomain, bytes32 mintRecipient)
        external
        returns (address forwarder)
    {
        if (sender == address(0)) revert ZeroAddress();
        if (mintRecipient == bytes32(0)) revert EmptyMintRecipient();

        bytes32 salt = _salt(sender, destinationDomain, mintRecipient);
        address predicted = _predict(salt);
        if (predicted.code.length != 0) revert ForwarderAlreadyDeployed(predicted);

        forwarder = _deployAndInit(
            salt, predicted, abi.encodeCall(OutboundForwarder.initialize, (sender, destinationDomain, mintRecipient))
        );

        emit OutboundForwarderDeployed(forwarder, sender, destinationDomain, mintRecipient);
    }

    /// @inheritdoc IOutboundForwarderFactory
    /// @notice Swap the beacon impl to upgrade all deployed OutboundForwarders' logic (and immutables such as operator) in bulk.
    function upgradeForwarderImplementation(address newImplementation) external onlyOwner {
        _upgradeForwarderImpl(newImplementation);
        emit ForwarderImplementationUpgraded(newImplementation);
    }
}
