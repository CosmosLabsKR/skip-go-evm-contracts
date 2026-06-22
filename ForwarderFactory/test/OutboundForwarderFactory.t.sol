// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "openzeppelin-contracts/mocks/token/ERC20Mock.sol";

import {OutboundForwarderFactory} from "../src/OutboundForwarderFactory.sol";
import {IOutboundForwarderFactory} from "../src/interfaces/IOutboundForwarderFactory.sol";
import {OutboundForwarder} from "../src/OutboundForwarder.sol";
import {ICCTPV2Relayer} from "../src/interfaces/ICCTPV2Relayer.sol";

/// @dev PaymentContract mock that records CCTP v2 requestCCTPTransfer / requestCCTPTransferWithCaller and pulls USDC via transferFrom.
contract MockCCTPV2Relayer is ICCTPV2Relayer {
    IERC20 public immutable usdc;
    uint256 public lastTransferAmount;
    uint32 public lastDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    uint256 public lastFeeAmount;
    uint256 public lastMaxFee;
    uint32 public lastMinFinality;
    bytes32 public lastDestinationCaller;
    bytes public lastHookData;
    bool public lastWasWithCaller;
    uint256 public callCount;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function requestCCTPTransfer(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        require(usdc.transferFrom(msg.sender, address(this), transferAmount + feeAmount), "transferFrom failed");
        _record(
            transferAmount,
            destinationDomain,
            mintRecipient,
            burnToken,
            feeAmount,
            maxFee,
            minFinalityThreshold,
            bytes32(0),
            hookData,
            false
        );
    }

    function requestCCTPTransferWithCaller(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external {
        require(usdc.transferFrom(msg.sender, address(this), transferAmount + feeAmount), "transferFrom failed");
        _record(
            transferAmount,
            destinationDomain,
            mintRecipient,
            burnToken,
            feeAmount,
            maxFee,
            minFinalityThreshold,
            destinationCaller,
            hookData,
            true
        );
    }

    function _record(
        uint256 transferAmount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData,
        bool withCaller
    ) internal {
        lastTransferAmount = transferAmount;
        lastDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastFeeAmount = feeAmount;
        lastMaxFee = maxFee;
        lastMinFinality = minFinalityThreshold;
        lastDestinationCaller = destinationCaller;
        lastHookData = hookData;
        lastWasWithCaller = withCaller;
        callCount++;
    }
}

/// @dev Malicious relayer that, during requestCCTPTransfer, re-enters target.requestTransfer (nonReentrant guard test).
contract ReentrantRelayer is ICCTPV2Relayer {
    IERC20 public immutable usdc;
    OutboundForwarder public target;
    uint32 internal _minFinality;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setTarget(OutboundForwarder _t, uint32 mf) external {
        target = _t;
        _minFinality = mf;
    }

    function requestCCTPTransfer(uint256, uint32, bytes32, address, uint256, uint256, uint32, bytes calldata) external {
        // Re-entry attempt → OutboundForwarder.nonReentrant reverts with Reentrancy (bubbles up).
        target.requestTransfer(1e6, 1e6, 1, _minFinality, hex"");
    }

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
    ) external {}
}

/// @dev V2 used for the OutboundForwarder logic-upgrade test (same storage layout + version()). Same immutables re-injected.
contract OutboundForwarderV2 is OutboundForwarder {
    constructor(address u, address p, address o) OutboundForwarder(u, p, o) {}

    function version() external pure override returns (uint256) {
        return 2;
    }
}

/// @dev V2 used for the factory UUPS-upgrade test.
contract OutboundForwarderFactoryV2 is OutboundForwarderFactory {
    function factoryVersion() external pure returns (uint256) {
        return 2;
    }
}

contract OutboundForwarderFactoryTest is Test {
    OutboundForwarderFactory internal factory;
    OutboundForwarderFactory internal impl;
    OutboundForwarder internal forwarderImpl;

    ERC20Mock internal usdc;
    MockCCTPV2Relayer internal relayer;

    // sender = route identifier and fund owner / recovery authority (merged recover role).
    address internal sender = address(0xABCD);
    uint32 internal destDomain = 5;
    bytes32 internal mintRecipient = bytes32(uint256(uint160(address(0xBEEF))));
    address internal operator = address(0x09E2);

    // v2 per-call params (operator-supplied)
    uint32 internal minFinality = 1000;
    bytes32 internal destCaller = bytes32(uint256(uint160(address(0xCA11))));

    function setUp() public {
        usdc = new ERC20Mock();
        relayer = new MockCCTPV2Relayer(IERC20(address(usdc)));
        forwarderImpl = new OutboundForwarder(address(usdc), address(relayer), operator);
        impl = new OutboundForwarderFactory();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(OutboundForwarderFactory.initialize, (address(forwarderImpl))));
        factory = OutboundForwarderFactory(address(proxy));
    }

    // ─────────────────────────── identity / address (3-tuple) ───────────────────────────

    // TC-01: predicted == actual
    function test_TC01_PredictEqualsDeploy() public {
        address predicted = factory.getForwarderAddress(sender, destDomain, mintRecipient);
        address deployed = factory.createForwarder(sender, destDomain, mintRecipient);
        assertEq(deployed, predicted, "predicted must equal deployed");
        assertTrue(deployed.code.length > 0, "forwarder must have code");
    }

    // TC-01b: predicted address matches an independent recomputation of the shared base formula.
    // Guards against any drift in ForwarderFactoryBase._predict / beaconInitCodeHash introduced by the
    // factory-abstraction refactor (the funds-critical predicted-address invariant, FR-3/FR-4).
    function test_TC01b_PredictMatchesIndependentFormula() public {
        bytes32 salt = keccak256(abi.encode(sender, destDomain, mintRecipient));
        address independent = Create2.computeAddress(salt, factory.beaconInitCodeHash(), address(factory));
        assertEq(
            factory.getForwarderAddress(sender, destDomain, mintRecipient),
            independent,
            "predict must match the canonical CREATE2 formula"
        );
    }

    // TC-01c GOLDEN VECTOR (funds-critical): freezes the salt PREIMAGE (the abi.encode arg order/types) against an
    // externally-computed literal. TC01b proves _predict matches the CREATE2 formula but does NOT pin the preimage, so
    // a reorder/retype of (sender, destinationDomain, mintRecipient) could silently move every predicted address —
    // orphaning the funds of already-deployed forwarders — yet still pass if TC01b were edited in lockstep. The literal
    // below was computed independently of this source:
    //   cast keccak $(cast abi-encode "f(address,uint32,bytes32)" 0xA1 7 0xBEEF)
    function test_TC01c_GoldenVector_SaltPreimageFrozen() public {
        bytes32 frozenSalt = 0x6c260661d37d1b43f2ee3565330bc025deeef9a73dc07e302d2dcee0c9f32507;
        address fromFrozenSalt = Create2.computeAddress(frozenSalt, factory.beaconInitCodeHash(), address(factory));
        assertEq(
            factory.getForwarderAddress(address(0xA1), uint32(7), bytes32(uint256(0xBEEF))),
            fromFrozenSalt,
            "salt preimage drifted from frozen golden vector"
        );
    }

    // TC-02: idempotent
    function test_TC02_PredictIdempotent() public {
        assertEq(
            factory.getForwarderAddress(sender, destDomain, mintRecipient),
            factory.getForwarderAddress(sender, destDomain, mintRecipient)
        );
    }

    // TC-03: changing any of the 3 inputs changes the address
    function test_TC03_InputSensitivity() public {
        address base = factory.getForwarderAddress(sender, destDomain, mintRecipient);
        assertTrue(base != factory.getForwarderAddress(address(0x1234), destDomain, mintRecipient), "sender");
        assertTrue(base != factory.getForwarderAddress(sender, destDomain + 1, mintRecipient), "domain");
        assertTrue(base != factory.getForwarderAddress(sender, destDomain, bytes32(uint256(1))), "recipient");
    }

    // TC-04: duplicate deploy reverts
    function test_TC04_DuplicateDeployReverts() public {
        address deployed = factory.createForwarder(sender, destDomain, mintRecipient);
        vm.expectRevert(abi.encodeWithSelector(IOutboundForwarderFactory.ForwarderAlreadyDeployed.selector, deployed));
        factory.createForwarder(sender, destDomain, mintRecipient);
    }

    // TC-05: input validation
    function test_TC05_ZeroSenderReverts() public {
        vm.expectRevert(IOutboundForwarderFactory.ZeroAddress.selector);
        factory.createForwarder(address(0), destDomain, mintRecipient);
    }

    function test_TC05_EmptyMintRecipientReverts() public {
        vm.expectRevert(IOutboundForwarderFactory.EmptyMintRecipient.selector);
        factory.createForwarder(sender, destDomain, bytes32(0));
    }

    // TC-06: event
    function test_TC06_EmitsOutboundForwarderDeployed() public {
        address predicted = factory.getForwarderAddress(sender, destDomain, mintRecipient);
        vm.expectEmit(true, true, false, true);
        emit IOutboundForwarderFactory.OutboundForwarderDeployed(predicted, sender, destDomain, mintRecipient);
        factory.createForwarder(sender, destDomain, mintRecipient);
    }

    // TC-07: child state
    function test_TC07_ChildStateInitialized() public {
        OutboundForwarder f = OutboundForwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
        assertEq(f.sender(), sender);
        assertEq(f.destinationDomain(), destDomain);
        assertEq(f.mintRecipient(), mintRecipient);
    }

    // TC-08: factory UUPS onlyOwner
    function test_TC08_FactoryUpgradeOnlyOwner() public {
        OutboundForwarderFactoryV2 newImpl = new OutboundForwarderFactoryV2();
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        factory.upgradeToAndCall(address(newImpl), "");
        factory.upgradeToAndCall(address(newImpl), "");
        assertEq(OutboundForwarderFactoryV2(address(factory)).factoryVersion(), 2);
    }

    // TC-09: deployer = proxy
    function test_TC09_DeployerIsProxy() public {
        address viaProxy = factory.getForwarderAddress(sender, destDomain, mintRecipient);
        address viaImpl = impl.getForwarderAddress(sender, destDomain, mintRecipient);
        assertTrue(viaProxy != viaImpl, "proxy and impl predictions differ");
        assertEq(factory.createForwarder(sender, destDomain, mintRecipient), viaProxy);
    }

    // TC-10: different senders each predict == deploy
    function test_TC10_MultipleSenders() public {
        address s1 = address(0x1111);
        address s2 = address(0x2222);
        assertEq(
            factory.createForwarder(s1, destDomain, mintRecipient),
            factory.getForwarderAddress(s1, destDomain, mintRecipient)
        );
        assertEq(
            factory.createForwarder(s2, destDomain, mintRecipient),
            factory.getForwarderAddress(s2, destDomain, mintRecipient)
        );
    }

    // TC-11: initialization protection
    function test_TC11_CannotInitializeOutboundForwarderImpl() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        forwarderImpl.initialize(sender, destDomain, mintRecipient);
    }

    function test_TC11_CannotReinitializeDeployedOutboundForwarder() public {
        OutboundForwarder f = OutboundForwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        f.initialize(sender, destDomain, mintRecipient);
    }

    function test_TC11_CannotReinitializeFactoryProxy() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(address(forwarderImpl));
    }

    function test_TC11_CannotInitializeFactoryImpl() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(forwarderImpl));
    }

    // TC-12: getter stability
    function test_TC12_GetterStablePrePostDeploy() public {
        address pre = factory.getForwarderAddress(sender, destDomain, mintRecipient);
        factory.createForwarder(sender, destDomain, mintRecipient);
        assertEq(pre, factory.getForwarderAddress(sender, destDomain, mintRecipient));
    }

    function test_TC12_GetterDoesNotRevertOnBadInput() public view {
        factory.getForwarderAddress(address(0), destDomain, mintRecipient);
        factory.getForwarderAddress(sender, destDomain, bytes32(0));
    }

    // TC-13: address unchanged after beacon upgrade
    function test_TC13_AddressUnchangedAfterBeaconUpgrade() public {
        address before = factory.getForwarderAddress(sender, destDomain, mintRecipient);
        assertEq(factory.createForwarder(sender, destDomain, mintRecipient), before);

        OutboundForwarderV2 v2 = new OutboundForwarderV2(address(usdc), address(relayer), operator);
        factory.upgradeForwarderImplementation(address(v2));

        assertEq(factory.getForwarderAddress(sender, destDomain, mintRecipient), before, "addr stable");
        // New inputs also predict == deploy
        assertEq(
            factory.createForwarder(address(0x9999), destDomain, mintRecipient),
            factory.getForwarderAddress(address(0x9999), destDomain, mintRecipient)
        );
    }

    // TC-14: beacon upgrade onlyOwner
    function test_TC14_UpgradeOutboundForwarderImplOnlyOwner() public {
        OutboundForwarderV2 v2 = new OutboundForwarderV2(address(usdc), address(relayer), operator);
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        factory.upgradeForwarderImplementation(address(v2));
        factory.upgradeForwarderImplementation(address(v2));
    }

    // TC-15: existing instance uses V2 logic after upgrade + state preserved
    function test_TC15_DeployedOutboundForwarderUsesNewLogicAfterUpgrade() public {
        address addr = factory.createForwarder(sender, destDomain, mintRecipient);
        OutboundForwarderV2 v2 = new OutboundForwarderV2(address(usdc), address(relayer), operator);
        factory.upgradeForwarderImplementation(address(v2));
        assertEq(OutboundForwarderV2(payable(addr)).version(), 2, "uses upgraded logic");
        assertEq(OutboundForwarderV2(payable(addr)).sender(), sender, "state persists");
    }

    // ─────────────────────────── fund logic (CCTP v2) ───────────────────────────

    function _deployFunded(uint256 amount) internal returns (OutboundForwarder f) {
        f = OutboundForwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
        usdc.mint(address(f), amount);
    }

    // TC-16: requestTransfer calls requestCCTPTransfer (8-arg) correctly + moves USDC + forwards v2 params
    function test_TC16_RequestTransferDelegates() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        f.requestTransfer(900e6, 10e6, 5e6, minFinality, hex"");

        assertEq(relayer.callCount(), 1);
        assertFalse(relayer.lastWasWithCaller(), "base variant");
        assertEq(relayer.lastTransferAmount(), 900e6);
        assertEq(relayer.lastFeeAmount(), 10e6);
        assertEq(relayer.lastMaxFee(), 5e6);
        assertEq(uint256(relayer.lastMinFinality()), uint256(minFinality));
        assertEq(relayer.lastDestinationCaller(), bytes32(0), "any caller");
        assertEq(relayer.lastHookData().length, 0);
        assertEq(uint256(relayer.lastDomain()), uint256(destDomain));
        assertEq(relayer.lastMintRecipient(), mintRecipient);
        assertEq(relayer.lastBurnToken(), address(usdc));
        assertEq(usdc.balanceOf(address(relayer)), 910e6, "usdc moved to relayer");
        assertEq(usdc.balanceOf(address(f)), 90e6, "remainder stays");
    }

    // TC-16b: requestTransferWithCaller calls requestCCTPTransferWithCaller (9-arg) correctly
    function test_TC16b_RequestTransferWithCallerDelegates() public {
        OutboundForwarder f = _deployFunded(1000e6);
        bytes memory hook = hex"1234";
        vm.prank(operator);
        f.requestTransferWithCaller(800e6, 20e6, 7e6, 2000, destCaller, hook);

        assertEq(relayer.callCount(), 1);
        assertTrue(relayer.lastWasWithCaller(), "withCaller variant");
        assertEq(relayer.lastTransferAmount(), 800e6);
        assertEq(relayer.lastFeeAmount(), 20e6);
        assertEq(relayer.lastMaxFee(), 7e6);
        assertEq(uint256(relayer.lastMinFinality()), 2000);
        assertEq(relayer.lastDestinationCaller(), destCaller, "destinationCaller passed");
        assertEq(relayer.lastHookData(), hook, "hookData passed");
        assertEq(uint256(relayer.lastDomain()), uint256(destDomain));
        assertEq(relayer.lastMintRecipient(), mintRecipient);
        assertEq(usdc.balanceOf(address(relayer)), 820e6, "usdc moved to relayer");
    }

    // TC-16c: maxFee == 0 standard transfer succeeds (maxFee = 0 is legal in v2)
    function test_TC16c_MaxFeeZeroStandardTransfer() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        f.requestTransfer(900e6, 10e6, 0, 2000, hex"");
        assertEq(relayer.callCount(), 1);
        assertEq(relayer.lastMaxFee(), 0, "maxFee 0 allowed");
        assertEq(uint256(relayer.lastMinFinality()), 2000, "standard finality");
    }

    // TC-16d: maxFee boundary — transferAmount-1 succeeds, transferAmount reverts (>= boundary)
    function test_TC16d_MaxFeeBoundary() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        f.requestTransfer(900e6, 10e6, 900e6 - 1, minFinality, hex"");
        assertEq(relayer.lastMaxFee(), 900e6 - 1, "maxFee == amount-1 ok");

        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.InvalidMaxFee.selector);
        f.requestTransfer(900e6, 10e6, 900e6, minFinality, hex"");
    }

    // TC-17: both functions are operator-only (non-operator / sender revert)
    function test_TC17_RequestTransferOnlyOperator() public {
        OutboundForwarder f = _deployFunded(1000e6);
        address[2] memory bad = [address(0xDEAD), sender];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(OutboundForwarder.NotOperator.selector);
            f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");

            vm.prank(bad[i]);
            vm.expectRevert(OutboundForwarder.NotOperator.selector);
            f.requestTransferWithCaller(100e6, 1e6, 1e6, minFinality, destCaller, hex"");
        }
        vm.prank(operator);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");
        assertEq(relayer.callCount(), 1);
    }

    // TC-18: transferAmount == 0 → ZeroAmount (both functions)
    function test_TC18_RequestTransferZeroAmount() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.ZeroAmount.selector);
        f.requestTransfer(0, 1e6, 0, minFinality, hex"");

        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.ZeroAmount.selector);
        f.requestTransferWithCaller(0, 1e6, 0, minFinality, destCaller, hex"");
    }

    // TC-18b: feeAmount == 0 → ZeroFee (both functions, v2 constraint)
    function test_TC18b_RequestTransferZeroFee() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.ZeroFee.selector);
        f.requestTransfer(100e6, 0, 1e6, minFinality, hex"");

        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.ZeroFee.selector);
        f.requestTransferWithCaller(100e6, 0, 1e6, minFinality, destCaller, hex"");
    }

    // TC-18c: maxFee >= transferAmount → InvalidMaxFee (both functions, v2 constraint)
    function test_TC18c_RequestTransferInvalidMaxFee() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.InvalidMaxFee.selector);
        f.requestTransfer(100e6, 1e6, 100e6, minFinality, hex"");

        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.InvalidMaxFee.selector);
        f.requestTransferWithCaller(100e6, 1e6, 100e6, minFinality, destCaller, hex"");
    }

    // TC-18d: minFinalityThreshold other than 1000/2000 → InvalidFinalityThreshold (both functions)
    function test_TC18d_RequestTransferInvalidFinality() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.InvalidFinalityThreshold.selector);
        f.requestTransfer(100e6, 1e6, 1e6, 1500, hex"");

        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.InvalidFinalityThreshold.selector);
        f.requestTransferWithCaller(100e6, 1e6, 1e6, 999, destCaller, hex"");
    }

    // TC-19: fixed route (operator cannot change it — no route in the args), both functions
    function test_TC19_FixedRoute() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        f.requestTransfer(500e6, 5e6, 1e6, minFinality, hex"");
        assertEq(uint256(relayer.lastDomain()), uint256(destDomain), "domain fixed");
        assertEq(relayer.lastMintRecipient(), mintRecipient, "recipient fixed");

        vm.prank(operator);
        f.requestTransferWithCaller(100e6, 1e6, 1e6, minFinality, destCaller, hex"");
        assertEq(uint256(relayer.lastDomain()), uint256(destDomain), "domain fixed (withCaller)");
        assertEq(relayer.lastMintRecipient(), mintRecipient, "recipient fixed (withCaller)");
    }

    // TC-19b: hookData passthrough (empty + non-empty)
    function test_TC19b_HookDataPassthrough() public {
        OutboundForwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");
        assertEq(relayer.lastHookData().length, 0, "empty hookData");

        bytes memory hook = hex"deadbeefcafe";
        vm.prank(operator);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hook);
        assertEq(relayer.lastHookData(), hook, "nonempty hookData passthrough");
    }

    // TC-19c: long hookData (160B, varied) passthrough
    function test_TC19c_LongHookDataPassthrough() public {
        OutboundForwarder f = _deployFunded(1000e6);
        bytes memory hook =
            abi.encode(keccak256("hook-a"), keccak256("hook-b"), uint256(123456), address(this), destCaller);
        vm.prank(operator);
        f.requestTransferWithCaller(100e6, 1e6, 1e6, minFinality, destCaller, hook);
        assertEq(relayer.lastHookData(), hook, "long hookData passthrough");
        assertEq(relayer.lastHookData().length, 160, "160 bytes");
    }

    // TC-20: recoverERC20 (operator-only)
    function test_TC20_RecoverERC20() public {
        OutboundForwarder f = _deployFunded(777e6);
        vm.prank(address(0xDEAD));
        vm.expectRevert(OutboundForwarder.NotOperator.selector);
        f.recoverERC20(address(usdc));

        vm.prank(operator);
        f.recoverERC20(address(usdc));
        assertEq(usdc.balanceOf(sender), 777e6);
        assertEq(usdc.balanceOf(address(f)), 0);
    }

    // TC-21: direct native transfers are rejected
    function test_TC21_ReceiveRejectsNativeTransfer() public {
        OutboundForwarder f = OutboundForwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
        address payer = address(0xE7A);
        vm.deal(payer, 1 ether);

        vm.prank(payer);
        (bool ok, bytes memory data) = address(f).call{value: 1 wei}("");

        assertFalse(ok, "native transfer must revert");
        assertEq(bytes4(data), OutboundForwarder.NativeNotAccepted.selector);
        assertEq(address(f).balance, 0);
    }

    // TC-22: operator rotation (beacon upgrade) → applied to all instances in bulk
    function test_TC22_OperatorRotation() public {
        OutboundForwarder f = _deployFunded(1000e6);
        address operator2 = address(0x0EE2);

        OutboundForwarderV2 v2 = new OutboundForwarderV2(address(usdc), address(relayer), operator2);
        factory.upgradeForwarderImplementation(address(v2));

        // The old operator is no longer allowed
        vm.prank(operator);
        vm.expectRevert(OutboundForwarder.NotOperator.selector);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");

        // The new operator succeeds
        vm.prank(operator2);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");
        assertEq(relayer.callCount(), 1);
    }

    // TC-23: OutboundForwarder constructor zero-address validation
    function test_TC23_ConstructorZeroReverts() public {
        vm.expectRevert(OutboundForwarder.ZeroAddress.selector);
        new OutboundForwarder(address(0), address(relayer), operator);
        vm.expectRevert(OutboundForwarder.ZeroAddress.selector);
        new OutboundForwarder(address(usdc), address(0), operator);
        vm.expectRevert(OutboundForwarder.ZeroAddress.selector);
        new OutboundForwarder(address(usdc), address(relayer), address(0));
    }

    // TC-23b: USDC equality guard — constructor reverts when paymentContract.usdc() != usdc
    function test_TC23b_ConstructorUsdcMismatch() public {
        ERC20Mock usdc2 = new ERC20Mock();
        // relayer.usdc() == usdc (original) != usdc2 → UsdcMismatch
        vm.expectRevert(OutboundForwarder.UsdcMismatch.selector);
        new OutboundForwarder(address(usdc2), address(relayer), operator);
    }

    // TC-24: nonReentrant guard — relayer re-entering requestTransfer reverts with Reentrancy
    function test_TC24_ReentrancyGuard() public {
        ReentrantRelayer rr = new ReentrantRelayer(IERC20(address(usdc)));
        // operator = relayer so the re-entry passes onlyOperator and reaches the nonReentrant guard
        OutboundForwarder rImpl = new OutboundForwarder(address(usdc), address(rr), address(rr));
        OutboundForwarderFactory rFactImpl = new OutboundForwarderFactory();
        ERC1967Proxy rProxy =
            new ERC1967Proxy(address(rFactImpl), abi.encodeCall(OutboundForwarderFactory.initialize, (address(rImpl))));
        OutboundForwarderFactory rFactory = OutboundForwarderFactory(address(rProxy));

        OutboundForwarder f = OutboundForwarder(payable(rFactory.createForwarder(sender, destDomain, mintRecipient)));
        usdc.mint(address(f), 1000e6);
        rr.setTarget(f, minFinality);

        vm.prank(address(rr));
        vm.expectRevert(OutboundForwarder.Reentrancy.selector);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");
    }

    // ─────────────────────────── isForwarderDeployed ───────────────────────────

    // TC-25: false before deploy, true after; predicted address matches getForwarderAddress
    function test_TC25_IsForwarderDeployed_FalseThenTrue() public {
        assertFalse(factory.isForwarderDeployed(sender, destDomain, mintRecipient), "false pre-deploy");
        address deployed = factory.createForwarder(sender, destDomain, mintRecipient);
        assertEq(deployed, factory.getForwarderAddress(sender, destDomain, mintRecipient), "predicted == deployed");
        assertTrue(factory.isForwarderDeployed(sender, destDomain, mintRecipient), "true post-deploy");
    }

    // TC-26: route-sensitive — deploying one route does not report another as deployed
    function test_TC26_IsForwarderDeployed_RouteSensitive() public {
        factory.createForwarder(sender, destDomain, mintRecipient);
        assertFalse(factory.isForwarderDeployed(address(0x1234), destDomain, mintRecipient), "other sender");
        assertFalse(factory.isForwarderDeployed(sender, destDomain + 1, mintRecipient), "other domain");
        assertFalse(factory.isForwarderDeployed(sender, destDomain, bytes32(uint256(1))), "other recipient");
    }

    // TC-27: front-run is harmless — a third party calling createForwarder deploys the canonical forwarder
    // bound to the route key (sender/domain/recipient), so isForwarderDeployed stays an authoritative proof.
    function test_TC27_FrontRunDeploysCanonicalForwarder() public {
        vm.prank(address(0xDEAD));
        OutboundForwarder f = OutboundForwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
        assertTrue(factory.isForwarderDeployed(sender, destDomain, mintRecipient), "deployed");
        assertEq(f.sender(), sender, "sender bound to route key");
        assertEq(f.destinationDomain(), destDomain, "domain bound to route key");
        assertEq(f.mintRecipient(), mintRecipient, "recipient bound to route key");
    }
}
