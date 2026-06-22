// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Mock} from "openzeppelin-contracts/mocks/token/ERC20Mock.sol";

import {InboundForwarderFactory} from "../src/InboundForwarderFactory.sol";
import {InboundForwarder} from "../src/InboundForwarder.sol";

/// @dev Beacon-impl V2 for the InboundForwarder logic-upgrade test (same storage layout, bumped version()).
///      Same immutables re-injected, mirroring what UpgradeInboundForwarder.s.sol does on-chain.
contract InboundForwarderV2 is InboundForwarder {
    constructor(address u, address t, address o, uint32 d) InboundForwarder(u, t, o, d) {}

    function version() external pure override returns (uint256) {
        return 2;
    }
}

/// @dev Factory UUPS V2 for the factory-upgrade test (mirrors UpgradeInboundFactory.s.sol).
contract InboundForwarderFactoryV2 is InboundForwarderFactory {
    function factoryVersion() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Validates the address-preservation invariants the two new inbound upgrade scripts rely on:
///         (1) UpgradeInboundForwarder.s.sol — beacon impl swap; (2) UpgradeInboundFactory.s.sol — factory UUPS swap.
///         The outbound equivalents are covered in OutboundForwarderFactory.t.sol (TC-08/13/15/22).
contract UpgradeForwarderFactoryTest is Test {
    InboundForwarderFactory internal factory;
    InboundForwarderFactory internal impl;
    InboundForwarder internal forwarderImpl;

    ERC20Mock internal usdc;
    address internal transmitter = address(0x7777); // not called here; only address stability is under test
    address internal operator = address(0x09E2);
    uint32 internal injectiveDomain = 29;

    // route key (final intent)
    address internal sender = address(0xABCD);
    string internal destChainId = "dydx-mainnet-1";
    string internal destReceiver = "dydx1receiverxxxxxxxxxxxxxxxxxxxxxxxxxxx";

    function setUp() public {
        usdc = new ERC20Mock();
        forwarderImpl = new InboundForwarder(address(usdc), transmitter, operator, injectiveDomain);
        impl = new InboundForwarderFactory();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(InboundForwarderFactory.initialize, (address(forwarderImpl))));
        factory = InboundForwarderFactory(address(proxy));
    }

    // ── beacon impl upgrade (UpgradeInboundForwarder.s.sol path) ──

    // Addresses stay put across a beacon impl swap; existing instances pick up V2 logic; route state persists.
    function test_BeaconUpgrade_AddressesStableAndLogicSwapped() public {
        address predictedBefore = factory.getForwarderAddress(sender, destChainId, destReceiver);
        address beaconBefore = factory.beacon();
        address deployed = factory.createForwarder(sender, destChainId, destReceiver);
        assertEq(deployed, predictedBefore, "predicted == deployed");
        assertEq(InboundForwarder(payable(deployed)).version(), 1, "pre-upgrade version");

        InboundForwarderV2 v2 = new InboundForwarderV2(address(usdc), transmitter, operator, injectiveDomain);
        factory.upgradeForwarderImplementation(address(v2));

        assertEq(factory.beacon(), beaconBefore, "beacon immutable across impl swap");
        assertEq(factory.getForwarderAddress(sender, destChainId, destReceiver), predictedBefore, "existing route addr stable");
        assertEq(InboundForwarder(payable(deployed)).version(), 2, "deployed instance uses V2 logic");
        // route state preserved through the upgrade
        assertEq(InboundForwarder(payable(deployed)).sender(), sender, "route key #1 persists");
        assertEq(InboundForwarder(payable(deployed)).destinationChainId(), destChainId, "route key #2 persists");
        assertEq(InboundForwarder(payable(deployed)).destinationReceiver(), destReceiver, "route key #3 persists");

        // new routes still predict == deploy after the upgrade
        assertEq(
            factory.createForwarder(address(0x9999), destChainId, destReceiver),
            factory.getForwarderAddress(address(0x9999), destChainId, destReceiver),
            "new route predict == deploy post-upgrade"
        );
    }

    // beacon impl swap is owner-only (the script asserts caller == factory owner).
    function test_BeaconUpgrade_OnlyOwner() public {
        InboundForwarderV2 v2 = new InboundForwarderV2(address(usdc), transmitter, operator, injectiveDomain);
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        factory.upgradeForwarderImplementation(address(v2));
        factory.upgradeForwarderImplementation(address(v2)); // owner succeeds
    }

    // ── factory UUPS upgrade (UpgradeInboundFactory.s.sol path) ──

    // Factory proxy, beacon, and predicted forwarder addresses all survive a factory implementation swap.
    function test_FactoryUUPSUpgrade_BeaconAndAddressesStable() public {
        address predictedBefore = factory.getForwarderAddress(sender, destChainId, destReceiver);
        address beaconBefore = factory.beacon();
        address proxyAddr = address(factory);

        InboundForwarderFactoryV2 newImpl = new InboundForwarderFactoryV2();
        factory.upgradeToAndCall(address(newImpl), "");

        assertEq(address(factory), proxyAddr, "proxy address unchanged");
        assertEq(factory.beacon(), beaconBefore, "beacon persists across factory upgrade");
        assertEq(factory.getForwarderAddress(sender, destChainId, destReceiver), predictedBefore, "predicted addr stable");
        assertEq(InboundForwarderFactoryV2(address(factory)).factoryVersion(), 2, "factory runs V2 logic");
    }

    // factory UUPS upgrade is owner-only.
    function test_FactoryUUPSUpgrade_OnlyOwner() public {
        InboundForwarderFactoryV2 newImpl = new InboundForwarderFactoryV2();
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        factory.upgradeToAndCall(address(newImpl), "");
        factory.upgradeToAndCall(address(newImpl), ""); // owner succeeds
    }
}
