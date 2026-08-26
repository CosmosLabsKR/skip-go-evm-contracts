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
<<<<<<< HEAD
import {ICCTPV2Relayer} from "../src/interfaces/ICCTPV2Relayer.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
=======
import {ITokenMessenger} from "../src/interfaces/ITokenMessenger.sol";
>>>>>>> sungrak/cctp-v2-contracts

// ── Minimal mocks (the factory suite only needs the constructor guards to be satisfiable) ──

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
}

<<<<<<< HEAD
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
=======
/// @dev Inert TokenMessengerV2 stand-in. These suites never burn — they only need a typed, non-zero address to
///      put in the forwarder's `messenger` immutable.
contract MockMessengerStub is ITokenMessenger {
    function depositForBurn(uint256, uint32, bytes32, address, bytes32, uint256, uint32) external pure {}

    function depositForBurnWithHook(uint256, uint32, bytes32, address, bytes32, uint256, uint32, bytes calldata)
        external
        pure {}
}

/// @dev Bumped `version()` used to prove a beacon/UUPS upgrade actually swapped logic. It is 3 because the real
///      TransitForwarder is now at 2 (the fee removal) — this must stay strictly ahead of it to keep proving that
///      the upgrade, and not the baseline, is what the deployed proxies observe.
contract TransitForwarderV3 is TransitForwarder {
    constructor(address u, address m, address o, address e, uint32 l, uint32 dst)
        TransitForwarder(u, m, o, e, l, dst)
    {}

    function version() external pure override returns (uint256) {
        return 3;
>>>>>>> sungrak/cctp-v2-contracts
    }
}

contract TransitForwarderFactoryV2 is TransitForwarderFactory {
    function version() external pure override returns (uint256) {
        return 2;
    }
}

contract TransitForwarderFactoryTest is Test {
    MockUSDC usdc;
<<<<<<< HEAD
    MockTransmitterStub transmitter;
    /// @dev The forwarder only stores this address and gates on it; the factory tests never call a transit entry
    ///      point, so a plain address stands in for the executor proxy here.
    address constant EXECUTOR = address(0xE8EC00);
    MockRelayerStub relayer;
=======
    /// @dev The forwarder only stores this address and gates on it; the factory tests never call a transit entry
    ///      point, so a plain address stands in for the executor proxy here.
    address constant EXECUTOR = address(0xE8EC00);
    MockMessengerStub messengerStub;
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
        transmitter = new MockTransmitterStub();
        relayer = new MockRelayerStub(usdc);
        impl = new TransitForwarder(
            address(usdc), address(relayer), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN
        );
=======
        messengerStub = new MockMessengerStub();
        impl =
            new TransitForwarder(address(usdc), address(messengerStub), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN);
>>>>>>> sungrak/cctp-v2-contracts

        TransitForwarderFactory factoryImpl = new TransitForwarderFactory();
        factory = TransitForwarderFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl), abi.encodeCall(TransitForwarderFactory.initialize, (address(impl)))
                )
            )
        );
    }

<<<<<<< HEAD
    function _newImpl() internal returns (TransitForwarderV2) {
        return new TransitForwarderV2(
            address(usdc), address(relayer), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN
=======
    function _newImpl() internal returns (TransitForwarderV3) {
        return
            new TransitForwarderV3(address(usdc), address(messengerStub), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN);
    }

    /// @dev Same executor (so upgradeForwarderImplementation accepts it), different allowed destination.
    function _newImplWithDestination(uint32 allowedDestination) internal returns (TransitForwarder) {
        return new TransitForwarder(
            address(usdc), address(messengerStub), operator, EXECUTOR, LOCAL_DOMAIN, allowedDestination
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
        vm.expectRevert(
            abi.encodeWithSelector(ITransitForwarderFactory.ForwarderAlreadyDeployed.selector, deployed)
        );
=======
        vm.expectRevert(abi.encodeWithSelector(ITransitForwarderFactory.ForwarderAlreadyDeployed.selector, deployed));
>>>>>>> sungrak/cctp-v2-contracts
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

<<<<<<< HEAD
    // ── T-F5 a destination other than the allowed one bubbles up from the implementation ──

    function test_TF5_UnsupportedDestinationBubblesFromInitialize() public {
=======
    // ── T-F5 a destination other than the allowed one is refused ──

    function test_TF5_UnsupportedDestinationIsRefused() public {
>>>>>>> sungrak/cctp-v2-contracts
        // The local domain is just one instance of "not the allowed destination".
        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.createForwarder(routeSender, LOCAL_DOMAIN, mintRecipient);

        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.createForwarder(routeSender, DEST_DOMAIN + 1, mintRecipient);
<<<<<<< HEAD

        // Addresses were predictable but not deployable — the probe must still report false afterwards.
        assertFalse(factory.isForwarderDeployed(routeSender, LOCAL_DOMAIN, mintRecipient));
        assertFalse(factory.isForwarderDeployed(routeSender, DEST_DOMAIN + 1, mintRecipient));
=======
    }

    // ── T-F5b the READ path fails closed too — the guard that actually protects funds ──

    /// @dev ⚠️ FUNDS-CRITICAL. A source-chain burner reads getForwarderAddress and burns to whatever it returns,
    ///      before any forwarder exists. CREATE2 predicts an address for an undeployable route just as happily as for
    ///      a real one, and nothing about it looks wrong — so if prediction answered, a mistyped destinationDomain
    ///      would only surface AFTER the funds were burned, with no way back (executeTransit and executeRefund both
    ///      need the forwarder created, and it never can be).
    function test_TF5b_PredictionRefusesRoutesThatCanNeverBeCreated() public {
        uint32[2] memory badDomains = [LOCAL_DOMAIN, DEST_DOMAIN + 1];

        for (uint256 i; i < badDomains.length; ++i) {
            vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
            factory.getForwarderAddress(routeSender, badDomains[i], mintRecipient);

            // `false` here would read as "not yet, but you could" — the exact misunderstanding that burns funds.
            vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
            factory.isForwarderDeployed(routeSender, badDomains[i], mintRecipient);
        }

        // The other two creation guards cover the read path as well.
        vm.expectRevert(ITransitForwarderFactory.ZeroAddress.selector);
        factory.getForwarderAddress(address(0), DEST_DOMAIN, mintRecipient);

        vm.expectRevert(ITransitForwarderFactory.EmptyMintRecipient.selector);
        factory.getForwarderAddress(routeSender, DEST_DOMAIN, bytes32(0));

        vm.expectRevert(ITransitForwarderFactory.ZeroAddress.selector);
        factory.isForwarderDeployed(address(0), DEST_DOMAIN, mintRecipient);

        vm.expectRevert(ITransitForwarderFactory.EmptyMintRecipient.selector);
        factory.isForwarderDeployed(routeSender, DEST_DOMAIN, bytes32(0));

        // The allowed route still answers, so the guard rejects only what creation would reject.
        assertTrue(factory.getForwarderAddress(routeSender, DEST_DOMAIN, mintRecipient) != address(0));
        assertFalse(factory.isForwarderDeployed(routeSender, DEST_DOMAIN, mintRecipient));
    }

    /// @dev The guard reads ALLOWED_DESTINATION_DOMAIN off the beacon's CURRENT impl, so a beacon upgrade that moves
    ///      it moves what NEW routes may be created — in step with what `initialize` will accept. The two cannot
    ///      disagree. Scope matters: this governs undeployed routes only, see TF5d.
    function test_TF5c_PredictionGuardFollowsTheBeaconImplementation() public {
        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.getForwarderAddress(routeSender, DEST_DOMAIN + 1, mintRecipient);

        factory.upgradeForwarderImplementation(address(_newImplWithDestination(DEST_DOMAIN + 1)));

        // The formerly-refused destination is now the allowed one...
        assertTrue(factory.getForwarderAddress(routeSender, DEST_DOMAIN + 1, mintRecipient) != address(0));
        // ...and a NEW route to the formerly-allowed one is refused.
        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.getForwarderAddress(address(0xC0DE), DEST_DOMAIN, mintRecipient);
    }

    /// @dev ⚠️ REGRESSION GUARD. The destination gate reads the beacon's CURRENT impl, but a DEPLOYED forwarder keeps
    ///      its destination in proxy storage forever and goes on transiting regardless (test_T36). So the gate must
    ///      never apply to a route that already exists: if it did, one legitimate allowance move would make every
    ///      live, funded route unresolvable through this factory — indexers, ops tooling and the create script all
    ///      lose the ability to look up an address that is still receiving money. Code at the predicted address is
    ///      itself proof the route was creatable, which is the only thing this gate has anything to say about.
    function test_TF5d_DeployedRoutesStayResolvableAfterAnAllowanceMove() public {
        address fwd = factory.createForwarder(routeSender, DEST_DOMAIN, mintRecipient);

        factory.upgradeForwarderImplementation(address(_newImplWithDestination(DEST_DOMAIN + 1)));

        // The live forwarder is untouched — still deployed, still routing to its ORIGINAL destination.
        (, uint32 storedDomain,) = TransitForwarder(payable(fwd)).getRoute();
        assertEq(storedDomain, DEST_DOMAIN, "an existing route keeps its destination");

        // ...so the factory must still resolve it, even though DEST_DOMAIN is no longer creatable.
        assertEq(factory.getForwarderAddress(routeSender, DEST_DOMAIN, mintRecipient), fwd, "live route must resolve");
        assertTrue(factory.isForwarderDeployed(routeSender, DEST_DOMAIN, mintRecipient), "and report as deployed");

        // Creating a NEW route to that destination is still refused — the gate did not go soft.
        vm.expectRevert(ITransitForwarder.UnsupportedDestination.selector);
        factory.createForwarder(address(0xC0DE), DEST_DOMAIN, mintRecipient);
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
        assertEq(TransitForwarder(payable(fwd)).version(), 1);
=======
        assertEq(TransitForwarder(payable(fwd)).version(), 2);
>>>>>>> sungrak/cctp-v2-contracts

        address beaconBefore = factory.beacon();
        factory.upgradeForwarderImplementation(address(_newImpl()));

        assertEq(factory.beacon(), beaconBefore, "beacon address must not change");
<<<<<<< HEAD
        assertEq(TransitForwarder(payable(fwd)).version(), 2, "deployed forwarder must see new logic");
=======
        assertEq(TransitForwarder(payable(fwd)).version(), 3, "deployed forwarder must see new logic");
>>>>>>> sungrak/cctp-v2-contracts

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

<<<<<<< HEAD
        TransitForwarderV2 sameExecutor =
            new TransitForwarderV2(address(usdc), address(relayer), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN);
        factory.upgradeForwarderImplementation(address(sameExecutor)); // must not revert

        TransitForwarderV2 otherExecutor = new TransitForwarderV2(
            address(usdc), address(relayer), operator, address(0xBADE8EC), LOCAL_DOMAIN, DEST_DOMAIN
=======
        TransitForwarderV3 sameExecutor = new TransitForwarderV3(
            address(usdc), address(messengerStub), operator, EXECUTOR, LOCAL_DOMAIN, DEST_DOMAIN
        );
        factory.upgradeForwarderImplementation(address(sameExecutor)); // must not revert

        TransitForwarderV3 otherExecutor = new TransitForwarderV3(
            address(usdc), address(messengerStub), operator, address(0xBADE8EC), LOCAL_DOMAIN, DEST_DOMAIN
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
        assertEq(
            factory.getForwarderAddress(routeSender, DEST_DOMAIN, mintRecipient), fwd, "prediction must be stable"
        );
=======
        assertEq(factory.getForwarderAddress(routeSender, DEST_DOMAIN, mintRecipient), fwd, "prediction must be stable");
>>>>>>> sungrak/cctp-v2-contracts

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
