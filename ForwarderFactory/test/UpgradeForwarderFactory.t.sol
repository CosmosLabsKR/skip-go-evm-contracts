// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
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

    // A factory UUPS upgrade must leave createForwarder WORKING, not merely leave getForwarderAddress stable.
    // getForwarderAddress reads the CACHED beaconInitCodeHash while createForwarder builds the proxy from the
    // compile-time creationCode, so only an actual deploy exercises the two against each other.
    function test_FactoryUUPSUpgrade_CreateForwarderStillWorks() public {
        address predictedBefore = factory.getForwarderAddress(sender, destChainId, destReceiver);

        factory.upgradeToAndCall(address(new InboundForwarderFactoryV2()), "");

        assertEq(factory.createForwarder(sender, destChainId, destReceiver), predictedBefore, "deploy == predict");
        address other = address(0x9999);
        assertEq(
            factory.createForwarder(other, destChainId, destReceiver),
            factory.getForwarderAddress(other, destChainId, destReceiver),
            "fresh route deploy == predict post-upgrade"
        );
    }

    // ── build-config drift guard (funds-critical) ──

    // GOLDEN VECTOR — pinned as a LITERAL on purpose. beaconInitCodeHash is frozen on-chain at deploy time while
    // _deployAndInit builds from compile-time type(BeaconProxy).creationCode, so anything feeding creationCode that
    // moves between those two points makes every later createForwarder revert AddressMismatch, permanently.
    // Recomputing here would be tautological (both sides move together), hence the literal.
    //
    // What moves it: solc, evm_version, optimizer/runs, via_ir, bytecode_hash, the openzeppelin pin — and the
    // REMAPPING LIST, which solc embeds in the metadata blob. That last one is why foundry.toml sets
    // auto_detect_remappings = false; while it was auto-detected, the hash depended on which nested submodules
    // happened to be checked out locally (one commit produced three different values).
    //
    // A failure here is safe ONLY while no factory is live; otherwise revert the change or redeploy the factory.
    // Regenerate with: console2.logBytes32(keccak256(type(BeaconProxy).creationCode))
    //   0xf420d459616cccfa040beb52c4b15054a0d9ef8f3415966d15bf73c50206e728  OZ 5.0.0 + shanghai + via_ir off
    //   0x8cc7e0f45ee8c5703c059388032f932c7af4fa6ebae8cbe10ea167f0384d1780  OZ 5.6.1 + cancun  + via_ir off
    bytes32 internal constant BEACON_PROXY_CREATION_CODE_HASH =
        0x6a40e73f88777784be75aec46298eb6c0acad0ec4e451bef31873c28d83d6484;

    function test_BeaconProxyCreationCode_FrozenAgainstGoldenVector() public {
        assertEq(
            keccak256(type(BeaconProxy).creationCode),
            BEACON_PROXY_CREATION_CODE_HASH,
            "BeaconProxy creationCode drifted -> live factories can no longer createForwarder (see foundry.toml)"
        );
    }

    // Complements the golden vector: pins the FORMULA (creationCode + abi.encode(beacon, "")) that the cached hash
    // must equal, so a change to how __ForwarderFactory_init composes the tail is caught even if creationCode is intact.
    function test_BeaconInitCodeHash_MatchesCompiledBeaconProxy() public {
        bytes32 recomputed =
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(factory.beacon(), bytes(""))));
        assertEq(factory.beaconInitCodeHash(), recomputed, "cached initCodeHash drifted from the documented formula");
    }

    // The formula guard must be sharp: a tail built against a DIFFERENT beacon must not match.
    function test_BeaconInitCodeHash_GuardIsSharp() public {
        bytes32 wrongBeacon =
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(0xDEAD), bytes(""))));
        assertTrue(factory.beaconInitCodeHash() != wrongBeacon, "guard must reject a foreign beacon");
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
