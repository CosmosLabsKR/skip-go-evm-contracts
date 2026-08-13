// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

import {TransitForwarder} from "../src/TransitForwarder.sol";
import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {ITransitForwarder} from "../src/interfaces/ITransitForwarder.sol";
import {ITransitForwarderFactory} from "../src/interfaces/ITransitForwarderFactory.sol";
import {ICCTPV2Relayer} from "../src/interfaces/ICCTPV2Relayer.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";

// ── Minimal mocks (the factory suite only needs the constructor guards to be satisfiable) ──

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
}

contract MockTransmitterStub is IReceiver {
    function receiveMessage(bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract MockRelayerStub is ICCTPV2Relayer {
    IERC20 public immutable usdc;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function requestCCTPTransfer(uint256, uint32, bytes32, address, uint256, uint256, uint32, bytes calldata)
        external
        pure
    {}

    function requestCCTPTransferWithCaller(
        uint256,
        uint32,
        bytes32,
        address,
        uint256,
        uint256,
        uint32,
        bytes32,
        bytes calldata
    ) external pure {}
}

/// @dev Bumped `version()` used to prove a beacon/UUPS upgrade actually swapped logic.
contract TransitForwarderV2 is TransitForwarder {
    constructor(address u, address p, address o, address e, uint32 l, uint32 dst) TransitForwarder(u, p, o, e, l, dst) {}

    function version() external pure override returns (uint256) {
        return 2;
    }
}

contract TransitForwarderFactoryV2 is TransitForwarderFactory {
    function version() external pure override returns (uint256) {
        return 2;
    }
}

contract TransitForwarderFactoryTest is Test {
    MockUSDC usdc;
    MockTransmitterStub transmitter;
    /// @dev The forwarder only stores this address and gates on it; the factory tests never call a transit entry
    ///      point, so a plain address stands in for the executor proxy here.
    address constant EXECUTOR = address(0xE8EC00);
    MockRelayerStub relayer;
    TransitForwarder impl;
    TransitForwarderFactory factory;

    address operator = address(0xA11CE);
    address routeSender = address(0xBEEF);
    uint32 constant LOCAL_DOMAIN = 9;
    uint32 constant DEST_DOMAIN = 3;
    bytes32 mintRecipient = bytes32(uint256(uint160(address(0xD00D))));

    event TransitForwarderDeployed(
        address indexed forwarder, address indexed sender, uint32 destinationDomain, bytes32 mintRecipient
    );

    function setUp() public {
        usdc = new MockUSDC();
        transmitter = new MockTransmitterStub();
        relayer = new MockRelayerStub(usdc);
        impl = new TransitForwarder(
            address(usdc), address(relayer), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN
        );

        TransitForwarderFactory factoryImpl = new TransitForwarderFactory();
        factory = TransitForwarderFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl), abi.encodeCall(TransitForwarderFactory.initialize, (address(impl)))
                )
            )
        );
    }

    function _newImpl() internal returns (TransitForwarderV2) {
        return new TransitForwarderV2(
            address(usdc), address(relayer), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN
        );
    }

    // ── T-F1 prediction == deployment ──

    function test_TF1_PredictedMatchesDeployed() public {
        address predicted = factory.getForwarderAddress(routeSender, DEST_DOMAIN, mintRecipient);

        vm.expectEmit(true, true, false, true, address(factory));
        emit TransitForwarderDeployed(predicted, routeSender, DEST_DOMAIN, mintRecipient);
        address deployed = factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient);

        assertEq(deployed, predicted, "CREATE2 landed off the prediction");

        (address s, uint32 d, bytes32 r) = TransitForwarder(payable(deployed)).getRoute();
        assertEq(s, routeSender);
        assertEq(d, DEST_DOMAIN);
        assertEq(r, mintRecipient);
    }

    // ── T-F2 duplicate route ──

    function test_TF2_DuplicateCreateReverts() public {
        address deployed = factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient);
        vm.expectRevert(
            abi.encodeWithSelector(ITransitForwarderFactory.ForwarderAlreadyDeployed.selector, deployed)
        );
        factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient);
    }

    // ── T-F3 deployment probe ──

    function test_TF3_IsForwarderDeployed() public {
        assertFalse(factory.isForwarderDeployed(routeSender, DEST_DOMAIN, mintRecipient));
        factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient);
        assertTrue(factory.isForwarderDeployed(routeSender, DEST_DOMAIN, mintRecipient));
        // A different route (different sender, same pinned destination) must stay undeployed.
        assertFalse(factory.isForwarderDeployed(address(0xC0DE), DEST_DOMAIN, mintRecipient));
    }

    // ── T-F4 route argument guards ──

    function test_TF4_RouteArgumentGuards() public {
        vm.expectRevert(ITransitForwarderFactory.ZeroAddress.selector);
        factory.createForwarder(address(0), DEST_DOMAIN, mintRecipient);

        vm.expectRevert(ITransitForwarderFactory.EmptyMintRecipient.selector);
        factory.createForwarder(routeSender, DEST_DOMAIN, bytes32(0));
    }

    // ── T-F5 a destination other than the allowed one bubbles up from the implementation ──

    function test_TF5_UnsupportedDestinationBubblesFromInitialize() public {
        // The local domain is just one instance of "not the allowed destination".
        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.createForwarder(routeSender, LOCAL_DOMAIN, mintRecipient);

        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.createForwarder(routeSender, DEST_DOMAIN + 1, mintRecipient);

        // Addresses were predictable but not deployable — the probe must still report false afterwards.
        assertFalse(factory.isForwarderDeployed(routeSender, LOCAL_DOMAIN, mintRecipient));
        assertFalse(factory.isForwarderDeployed(routeSender, DEST_DOMAIN + 1, mintRecipient));
    }

    // ── T-F6 topic0 separation rests on the event NAME, not on parameter types ──

    function test_TF6_DeployEventTopic0DiffersFromOutbound() public {
        // Same parameter shape as OutboundForwarderDeployed, so only the name separates them. If this contract's
        // event were ever renamed to match, indexers keyed on topic0 alone would silently conflate the two families.
        bytes32 transitTopic = keccak256("TransitForwarderDeployed(address,address,uint32,bytes32)");
        bytes32 outboundTopic = keccak256("OutboundForwarderDeployed(address,address,uint32,bytes32)");
        assertTrue(transitTopic != outboundTopic, "topic0 must distinguish the deploy events");
    }

    // ── T-F7 beacon upgrade: addresses stable, logic swapped ──

    function test_TF7_BeaconUpgradeKeepsAddressesSwapsLogic() public {
        address fwd = factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient);
        assertEq(TransitForwarder(payable(fwd)).version(), 1);

        address beaconBefore = factory.beacon();
        factory.upgradeForwarderImplementation(address(_newImpl()));

        assertEq(factory.beacon(), beaconBefore, "beacon address must not change");
        assertEq(TransitForwarder(payable(fwd)).version(), 2, "deployed forwarder must see new logic");

        // Route storage survives the logic swap.
        (address s, uint32 d, bytes32 r) = TransitForwarder(payable(fwd)).getRoute();
        assertEq(s, routeSender);
        assertEq(d, DEST_DOMAIN);
        assertEq(r, mintRecipient);

        // A route created after the upgrade still lands on its predicted address.
        address other = address(0xC0DE);
        assertEq(
            factory.createForwarder(other, DEST_DOMAIN, mintRecipient),
            factory.getForwarderAddress(other, DEST_DOMAIN, mintRecipient),
            "fresh route deploy == predict post-upgrade"
        );
    }

    // ── T-F8 factory UUPS upgrade ──

    /// @dev The factory adopts its forwarders' executor at initialize and never lets it move. That address is baked
    ///      into already-burned messages' destinationCaller, so an impl bound elsewhere would strand every route and
    ///      every in-flight message at once — this is the on-chain guard the deploy script alone used to provide.
    function test_TF7b_ExecutorIsAdoptedAndFrozen() public {
        assertEq(factory.executor(), EXECUTOR, "adopted from the first implementation");

        TransitForwarderV2 sameExecutor =
            new TransitForwarderV2(address(usdc), address(relayer), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN);
        factory.upgradeForwarderImplementation(address(sameExecutor)); // must not revert

        TransitForwarderV2 otherExecutor = new TransitForwarderV2(
            address(usdc), address(relayer), operator, address(0xBADE8EC), LOCAL_DOMAIN, DEST_DOMAIN
        );
        vm.expectRevert(TransitForwarderFactory.ExecutorMismatch.selector);
        factory.upgradeForwarderImplementation(address(otherExecutor));

        assertEq(factory.executor(), EXECUTOR, "still frozen");
    }

    function test_TF8_FactoryUUPSUpgradeKeepsBeaconAndAddresses() public {
        address fwd = factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient);
        address beaconBefore = factory.beacon();
        bytes32 hashBefore = factory.beaconInitCodeHash();

        factory.upgradeToAndCall(address(new TransitForwarderFactoryV2()), "");

        assertEq(factory.version(), 2, "factory logic swapped");
        assertEq(factory.beacon(), beaconBefore, "beacon must survive the factory upgrade");
        assertEq(factory.beaconInitCodeHash(), hashBefore, "frozen initCodeHash must survive");
        assertEq(
            factory.getForwarderAddress(routeSender, DEST_DOMAIN, mintRecipient), fwd, "prediction must be stable"
        );

        address other = address(0xFEED);
        assertEq(
            factory.createForwarder(other, DEST_DOMAIN, mintRecipient),
            factory.getForwarderAddress(other, DEST_DOMAIN, mintRecipient),
            "createForwarder must still work after the factory upgrade"
        );
    }

    // ── T-F9 owner-only upgrade paths ──

    function test_TF9_UpgradePathsAreOwnerOnly() public {
        address attacker = address(0xBAD);
        // Both deployments MUST happen before any vm.prank: a CREATE consumes the pending prank, which would leave
        // the upgrade call coming from the owner and passing.
        address newForwarderImpl = address(_newImpl());
        address newFactoryImpl = address(new TransitForwarderFactoryV2());

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        factory.upgradeForwarderImplementation(newForwarderImpl);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        factory.upgradeToAndCall(newFactoryImpl, "");

        // owner succeeds
        factory.upgradeForwarderImplementation(newForwarderImpl);
        factory.upgradeToAndCall(newFactoryImpl, "");
    }

    // ── T-F10 initialize guard + post-conditions the deploy script relies on ──

    function test_TF10_InitializeGuards() public {
        TransitForwarderFactory raw = new TransitForwarderFactory();
        vm.expectRevert(TransitForwarderFactory.ZeroImplementation.selector);
        new ERC1967Proxy(address(raw), abi.encodeCall(TransitForwarderFactory.initialize, (address(0))));
    }

    function test_TF10b_DeployPostConditions() public {
        assertEq(factory.owner(), address(this), "factory owner == deployer");
        assertTrue(factory.beaconInitCodeHash() != bytes32(0), "beaconInitCodeHash must be cached at initialize");
        assertTrue(factory.beacon() != address(0), "beacon must exist");
    }
}
