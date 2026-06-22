// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForwarderFactoryBase} from "./ForwarderFactoryBase.sol";
import {IInboundForwarderFactory} from "./interfaces/IInboundForwarderFactory.sol";
import {InboundForwarder} from "./InboundForwarder.sol";

/**
 * @title InboundForwarderFactory
 * @notice Deterministically deploys an InboundForwarder (BeaconProxy) from the route key (sender,
 *         destinationChainId, destinationReceiver) — the stable final intent. The BeaconProxy is deployed with
 *         empty constructor data, so its initCodeHash is a constant depending only on the beacon address, and the
 *         predicted address is f(deployer, salt) — stable across forwarder logic upgrades. The source burner sets
 *         mintRecipient = this predicted address, which is how the final intent is cryptographically committed.
 *         (The per-transfer IBC route channelId/receiver is not part of the key — it rides in hookData; see
 *         InboundForwarder dynamic-route model.)
 * @dev Two-layer upgrade: the factory is UUPS, the deployed forwarders use a Beacon (upgraded in bulk). The shared
 *      CREATE2/beacon machinery lives in ForwarderFactoryBase; this contract only builds the typed salt preimage,
 *      encodes the per-route initialize, and owns its errors/events.
 */
contract InboundForwarderFactory is ForwarderFactoryBase, IInboundForwarderFactory {
    /// @param forwarderImplementation Address of the InboundForwarder logic impl (pre-deployed by the deploy script).
    function initialize(address forwarderImplementation) external initializer {
        __ForwarderFactory_init(forwarderImplementation);
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    /// @inheritdoc IInboundForwarderFactory
    function getForwarderAddress(
        address sender,
        string calldata destinationChainId,
        string calldata destinationReceiver
    ) external view returns (address predicted) {
        predicted = _predict(keccak256(abi.encode(sender, destinationChainId, destinationReceiver)));
    }

    /// @inheritdoc IInboundForwarderFactory
    /// @dev Authoritative: the forwarder address is bound to (this factory, salt, beacon initCodeHash), so a third
    ///      party cannot squat it — code existing at the predicted address means the canonical forwarder is deployed.
    function isForwarderDeployed(
        address sender,
        string calldata destinationChainId,
        string calldata destinationReceiver
    ) external view returns (bool) {
        return _predict(keccak256(abi.encode(sender, destinationChainId, destinationReceiver))).code.length != 0;
    }

    /// @inheritdoc IInboundForwarderFactory
    function createForwarder(address sender, string calldata destinationChainId, string calldata destinationReceiver)
        external
        returns (address forwarder)
    {
        if (sender == address(0)) revert ZeroAddress();
        if (bytes(destinationChainId).length == 0 || bytes(destinationReceiver).length == 0) revert EmptyRoute();

        bytes32 salt = keccak256(abi.encode(sender, destinationChainId, destinationReceiver));
        address predicted = _predict(salt);
        if (predicted.code.length != 0) revert ForwarderAlreadyDeployed(predicted);

        forwarder = _deployAndInit(
            salt,
            predicted,
            abi.encodeCall(InboundForwarder.initialize, (sender, destinationChainId, destinationReceiver))
        );

        emit InboundForwarderDeployed(forwarder, sender, destinationChainId, destinationReceiver);
    }

    /// @inheritdoc IInboundForwarderFactory
    /// @notice Swap the beacon impl to upgrade all deployed InboundForwarders' logic (and immutables) in bulk.
    function upgradeForwarderImplementation(address newImplementation) external onlyOwner {
        _upgradeForwarderImpl(newImplementation);
        emit ForwarderImplementationUpgraded(newImplementation);
    }
}
