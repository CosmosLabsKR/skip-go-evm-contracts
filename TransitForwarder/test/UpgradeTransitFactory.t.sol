// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";

import {TransitForwarder} from "../src/TransitForwarder.sol";
import {TransitForwarderFactory} from "../src/TransitForwarderFactory.sol";
import {ITokenMessenger} from "../src/interfaces/ITokenMessenger.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
}

/// @dev Inert TokenMessengerV2 stand-in. These suites never burn — they only need a typed, non-zero address to
///      put in the forwarder's `messenger` immutable.
contract MockMessengerStub is ITokenMessenger {
    function depositForBurn(uint256, uint32, bytes32, address, bytes32, uint256, uint32) external pure {}

    function depositForBurnWithHook(uint256, uint32, bytes32, address, bytes32, uint256, uint32, bytes calldata)
        external
        pure {}
}

/**
 * @notice Build-config drift guards for the frozen predicted-address space.
 * @dev Ported from ForwarderFactory/test/UpgradeForwarderFactory.t.sol. This project has its OWN foundry.toml and
 *      lib/, so it has its own address space — the guards must live here too, not be assumed from the sibling.
 */
contract UpgradeTransitFactoryTest is Test {
    TransitForwarderFactory factory;

    function setUp() public {
        MockUSDC usdc = new MockUSDC();
        MockMessengerStub messengerStub = new MockMessengerStub();
        TransitForwarder impl =
            new TransitForwarder(address(usdc), address(messengerStub), address(0xA11CE), address(0xE8EC00), 9, 29);

        TransitForwarderFactory factoryImpl = new TransitForwarderFactory();
        factory = TransitForwarderFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl), abi.encodeCall(TransitForwarderFactory.initialize, (address(impl)))
                )
            )
        );
    }

    // ── build-config drift guard (funds-critical) ──

    // GOLDEN VECTOR — pinned as a LITERAL on purpose. beaconInitCodeHash is frozen on-chain at deploy time while
    // createForwarder builds from compile-time type(BeaconProxy).creationCode, so anything feeding creationCode that
    // moves between those two points makes every later createForwarder revert AddressMismatch, permanently.
    // Recomputing here would be tautological (both sides move together), hence the literal.
    //
    // What moves it: solc, evm_version, optimizer/runs, via_ir, bytecode_hash, the openzeppelin pin — and the
    // REMAPPING LIST, which solc embeds in the metadata blob. That last one is why foundry.toml sets
    // auto_detect_remappings = false; while it was auto-detected, the hash depended on which nested submodules
    // happened to be checked out locally (one commit produced three different values).
    //
    // MEASURED, not assumed: this value was produced by test_PrintBeaconProxyCreationCodeHash below after pinning
    // foundry.toml + remappings.txt + all three lib/ submodules to the same commits ForwarderFactory uses. It came
    // out EQUAL to ForwarderFactory's own literal (0x6a40…6484), which is a useful cross-check that the build config
    // really was copied faithfully — but equality is NOT required. The two address spaces are independent; if a
    // future change makes them differ, re-measure and pin the new value here rather than trying to force a match.
    //
    // A failure here is safe ONLY while no factory is live; otherwise revert the change or redeploy the factory.
    // Regenerate with: forge test --match-test test_PrintBeaconProxyCreationCodeHash -vv
    bytes32 internal constant BEACON_PROXY_CREATION_CODE_HASH =
        0x6a40e73f88777784be75aec46298eb6c0acad0ec4e451bef31873c28d83d6484;

    function test_BeaconProxyCreationCode_FrozenAgainstGoldenVector() public {
        assertEq(
            keccak256(type(BeaconProxy).creationCode),
            BEACON_PROXY_CREATION_CODE_HASH,
            "BeaconProxy creationCode drifted -> live factories can no longer createForwarder (see foundry.toml)"
        );
    }

    /// @dev Not an assertion — the regeneration tool for the literal above.
    function test_PrintBeaconProxyCreationCodeHash() public pure {
        console2.log("keccak256(type(BeaconProxy).creationCode) =");
        console2.logBytes32(keccak256(type(BeaconProxy).creationCode));
    }

    // Complements the golden vector: pins the FORMULA (creationCode + abi.encode(beacon, "")) that the cached hash
    // must equal, so a change to how initialize composes the tail is caught even if creationCode is intact.
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
}
