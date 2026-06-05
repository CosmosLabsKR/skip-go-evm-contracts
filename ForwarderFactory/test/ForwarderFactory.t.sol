// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "openzeppelin-contracts/mocks/token/ERC20Mock.sol";

import {ForwarderFactory} from "../src/ForwarderFactory.sol";
import {IForwarderFactory} from "../src/interfaces/IForwarderFactory.sol";
import {Forwarder} from "../src/Forwarder.sol";
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
    Forwarder public target;
    uint32 internal _minFinality;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setTarget(Forwarder _t, uint32 mf) external {
        target = _t;
        _minFinality = mf;
    }

    function requestCCTPTransfer(uint256, uint32, bytes32, address, uint256, uint256, uint32, bytes calldata) external {
        // Re-entry attempt → Forwarder.nonReentrant reverts with Reentrancy (bubbles up).
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

/// @dev V2 used for the Forwarder logic-upgrade test (same storage layout + version()). Same immutables re-injected.
contract ForwarderV2 is Forwarder {
    constructor(address u, address p, address o) Forwarder(u, p, o) {}

    function version() external pure override returns (uint256) {
        return 2;
    }
}

/// @dev V2 used for the factory UUPS-upgrade test.
contract ForwarderFactoryV2 is ForwarderFactory {
    function factoryVersion() external pure returns (uint256) {
        return 2;
    }
}

contract ForwarderFactoryTest is Test {
    ForwarderFactory internal factory;
    ForwarderFactory internal impl;
    Forwarder internal forwarderImpl;

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
        forwarderImpl = new Forwarder(address(usdc), address(relayer), operator);
        impl = new ForwarderFactory();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(ForwarderFactory.initialize, (address(forwarderImpl))));
        factory = ForwarderFactory(address(proxy));
    }

    // ─────────────────────────── identity / address (3-tuple) ───────────────────────────

    // TC-01: predicted == actual
    function test_TC01_PredictEqualsDeploy() public {
        address predicted = factory.getForwarderAddress(sender, destDomain, mintRecipient);
        address deployed = factory.createForwarder(sender, destDomain, mintRecipient);
        assertEq(deployed, predicted, "predicted must equal deployed");
        assertTrue(deployed.code.length > 0, "forwarder must have code");
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
        vm.expectRevert(abi.encodeWithSelector(IForwarderFactory.ForwarderAlreadyDeployed.selector, deployed));
        factory.createForwarder(sender, destDomain, mintRecipient);
    }

    // TC-05: input validation
    function test_TC05_ZeroSenderReverts() public {
        vm.expectRevert(IForwarderFactory.ZeroAddress.selector);
        factory.createForwarder(address(0), destDomain, mintRecipient);
    }

    function test_TC05_EmptyMintRecipientReverts() public {
        vm.expectRevert(IForwarderFactory.EmptyMintRecipient.selector);
        factory.createForwarder(sender, destDomain, bytes32(0));
    }

    // TC-06: event
    function test_TC06_EmitsForwarderDeployed() public {
        address predicted = factory.getForwarderAddress(sender, destDomain, mintRecipient);
        vm.expectEmit(true, true, false, true);
        emit IForwarderFactory.ForwarderDeployed(predicted, sender, destDomain, mintRecipient);
        factory.createForwarder(sender, destDomain, mintRecipient);
    }

    // TC-07: child state
    function test_TC07_ChildStateInitialized() public {
        Forwarder f = Forwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
        assertEq(f.sender(), sender);
        assertEq(f.destinationDomain(), destDomain);
        assertEq(f.mintRecipient(), mintRecipient);
    }

    // TC-08: factory UUPS onlyOwner
    function test_TC08_FactoryUpgradeOnlyOwner() public {
        ForwarderFactoryV2 newImpl = new ForwarderFactoryV2();
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        factory.upgradeToAndCall(address(newImpl), "");
        factory.upgradeToAndCall(address(newImpl), "");
        assertEq(ForwarderFactoryV2(address(factory)).factoryVersion(), 2);
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
    function test_TC11_CannotInitializeForwarderImpl() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        forwarderImpl.initialize(sender, destDomain, mintRecipient);
    }

    function test_TC11_CannotReinitializeDeployedForwarder() public {
        Forwarder f = Forwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
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

        ForwarderV2 v2 = new ForwarderV2(address(usdc), address(relayer), operator);
        factory.upgradeForwarderImplementation(address(v2));

        assertEq(factory.getForwarderAddress(sender, destDomain, mintRecipient), before, "addr stable");
        // New inputs also predict == deploy
        assertEq(
            factory.createForwarder(address(0x9999), destDomain, mintRecipient),
            factory.getForwarderAddress(address(0x9999), destDomain, mintRecipient)
        );
    }

    // TC-14: beacon upgrade onlyOwner
    function test_TC14_UpgradeForwarderImplOnlyOwner() public {
        ForwarderV2 v2 = new ForwarderV2(address(usdc), address(relayer), operator);
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        factory.upgradeForwarderImplementation(address(v2));
        factory.upgradeForwarderImplementation(address(v2));
    }

    // TC-15: existing instance uses V2 logic after upgrade + state preserved
    function test_TC15_DeployedForwarderUsesNewLogicAfterUpgrade() public {
        address addr = factory.createForwarder(sender, destDomain, mintRecipient);
        ForwarderV2 v2 = new ForwarderV2(address(usdc), address(relayer), operator);
        factory.upgradeForwarderImplementation(address(v2));
        assertEq(ForwarderV2(payable(addr)).version(), 2, "uses upgraded logic");
        assertEq(ForwarderV2(payable(addr)).sender(), sender, "state persists");
    }

    // ─────────────────────────── fund logic (CCTP v2) ───────────────────────────

    function _deployFunded(uint256 amount) internal returns (Forwarder f) {
        f = Forwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
        usdc.mint(address(f), amount);
    }

    // TC-16: requestTransfer calls requestCCTPTransfer (8-arg) correctly + moves USDC + forwards v2 params
    function test_TC16_RequestTransferDelegates() public {
        Forwarder f = _deployFunded(1000e6);
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
        Forwarder f = _deployFunded(1000e6);
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
        Forwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        f.requestTransfer(900e6, 10e6, 0, 2000, hex"");
        assertEq(relayer.callCount(), 1);
        assertEq(relayer.lastMaxFee(), 0, "maxFee 0 allowed");
        assertEq(uint256(relayer.lastMinFinality()), 2000, "standard finality");
    }

    // TC-16d: maxFee boundary — transferAmount-1 succeeds, transferAmount reverts (>= boundary)
    function test_TC16d_MaxFeeBoundary() public {
        Forwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        f.requestTransfer(900e6, 10e6, 900e6 - 1, minFinality, hex"");
        assertEq(relayer.lastMaxFee(), 900e6 - 1, "maxFee == amount-1 ok");

        vm.prank(operator);
        vm.expectRevert(Forwarder.InvalidMaxFee.selector);
        f.requestTransfer(900e6, 10e6, 900e6, minFinality, hex"");
    }

    // TC-17: both functions are operator-only (non-operator / sender revert)
    function test_TC17_RequestTransferOnlyOperator() public {
        Forwarder f = _deployFunded(1000e6);
        address[2] memory bad = [address(0xDEAD), sender];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(Forwarder.NotOperator.selector);
            f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");

            vm.prank(bad[i]);
            vm.expectRevert(Forwarder.NotOperator.selector);
            f.requestTransferWithCaller(100e6, 1e6, 1e6, minFinality, destCaller, hex"");
        }
        vm.prank(operator);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");
        assertEq(relayer.callCount(), 1);
    }

    // TC-18: transferAmount == 0 → ZeroAmount (both functions)
    function test_TC18_RequestTransferZeroAmount() public {
        Forwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        vm.expectRevert(Forwarder.ZeroAmount.selector);
        f.requestTransfer(0, 1e6, 0, minFinality, hex"");

        vm.prank(operator);
        vm.expectRevert(Forwarder.ZeroAmount.selector);
        f.requestTransferWithCaller(0, 1e6, 0, minFinality, destCaller, hex"");
    }

    // TC-18b: feeAmount == 0 → ZeroFee (both functions, v2 constraint)
    function test_TC18b_RequestTransferZeroFee() public {
        Forwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        vm.expectRevert(Forwarder.ZeroFee.selector);
        f.requestTransfer(100e6, 0, 1e6, minFinality, hex"");

        vm.prank(operator);
        vm.expectRevert(Forwarder.ZeroFee.selector);
        f.requestTransferWithCaller(100e6, 0, 1e6, minFinality, destCaller, hex"");
    }

    // TC-18c: maxFee >= transferAmount → InvalidMaxFee (both functions, v2 constraint)
    function test_TC18c_RequestTransferInvalidMaxFee() public {
        Forwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        vm.expectRevert(Forwarder.InvalidMaxFee.selector);
        f.requestTransfer(100e6, 1e6, 100e6, minFinality, hex"");

        vm.prank(operator);
        vm.expectRevert(Forwarder.InvalidMaxFee.selector);
        f.requestTransferWithCaller(100e6, 1e6, 100e6, minFinality, destCaller, hex"");
    }

    // TC-18d: minFinalityThreshold other than 1000/2000 → InvalidFinalityThreshold (both functions)
    function test_TC18d_RequestTransferInvalidFinality() public {
        Forwarder f = _deployFunded(1000e6);
        vm.prank(operator);
        vm.expectRevert(Forwarder.InvalidFinalityThreshold.selector);
        f.requestTransfer(100e6, 1e6, 1e6, 1500, hex"");

        vm.prank(operator);
        vm.expectRevert(Forwarder.InvalidFinalityThreshold.selector);
        f.requestTransferWithCaller(100e6, 1e6, 1e6, 999, destCaller, hex"");
    }

    // TC-19: fixed route (operator cannot change it — no route in the args), both functions
    function test_TC19_FixedRoute() public {
        Forwarder f = _deployFunded(1000e6);
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
        Forwarder f = _deployFunded(1000e6);
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
        Forwarder f = _deployFunded(1000e6);
        bytes memory hook =
            abi.encode(keccak256("hook-a"), keccak256("hook-b"), uint256(123456), address(this), destCaller);
        vm.prank(operator);
        f.requestTransferWithCaller(100e6, 1e6, 1e6, minFinality, destCaller, hook);
        assertEq(relayer.lastHookData(), hook, "long hookData passthrough");
        assertEq(relayer.lastHookData().length, 160, "160 bytes");
    }

    // TC-20: recoverERC20 (operator-only)
    function test_TC20_RecoverERC20() public {
        Forwarder f = _deployFunded(777e6);
        vm.prank(address(0xDEAD));
        vm.expectRevert(Forwarder.NotOperator.selector);
        f.recoverERC20(address(usdc));

        vm.prank(operator);
        f.recoverERC20(address(usdc));
        assertEq(usdc.balanceOf(sender), 777e6);
        assertEq(usdc.balanceOf(address(f)), 0);
    }

    // TC-21: direct native transfers are rejected
    function test_TC21_ReceiveRejectsNativeTransfer() public {
        Forwarder f = Forwarder(payable(factory.createForwarder(sender, destDomain, mintRecipient)));
        address payer = address(0xE7A);
        vm.deal(payer, 1 ether);

        vm.prank(payer);
        (bool ok, bytes memory data) = address(f).call{value: 1 wei}("");

        assertFalse(ok, "native transfer must revert");
        assertEq(bytes4(data), Forwarder.NativeNotAccepted.selector);
        assertEq(address(f).balance, 0);
    }

    // TC-22: operator rotation (beacon upgrade) → applied to all instances in bulk
    function test_TC22_OperatorRotation() public {
        Forwarder f = _deployFunded(1000e6);
        address operator2 = address(0x0EE2);

        ForwarderV2 v2 = new ForwarderV2(address(usdc), address(relayer), operator2);
        factory.upgradeForwarderImplementation(address(v2));

        // The old operator is no longer allowed
        vm.prank(operator);
        vm.expectRevert(Forwarder.NotOperator.selector);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");

        // The new operator succeeds
        vm.prank(operator2);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");
        assertEq(relayer.callCount(), 1);
    }

    // TC-23: Forwarder constructor zero-address validation
    function test_TC23_ConstructorZeroReverts() public {
        vm.expectRevert(Forwarder.ZeroAddress.selector);
        new Forwarder(address(0), address(relayer), operator);
        vm.expectRevert(Forwarder.ZeroAddress.selector);
        new Forwarder(address(usdc), address(0), operator);
        vm.expectRevert(Forwarder.ZeroAddress.selector);
        new Forwarder(address(usdc), address(relayer), address(0));
    }

    // TC-23b: USDC equality guard — constructor reverts when paymentContract.usdc() != usdc
    function test_TC23b_ConstructorUsdcMismatch() public {
        ERC20Mock usdc2 = new ERC20Mock();
        // relayer.usdc() == usdc (original) != usdc2 → UsdcMismatch
        vm.expectRevert(Forwarder.UsdcMismatch.selector);
        new Forwarder(address(usdc2), address(relayer), operator);
    }

    // TC-24: nonReentrant guard — relayer re-entering requestTransfer reverts with Reentrancy
    function test_TC24_ReentrancyGuard() public {
        ReentrantRelayer rr = new ReentrantRelayer(IERC20(address(usdc)));
        // operator = relayer so the re-entry passes onlyOperator and reaches the nonReentrant guard
        Forwarder rImpl = new Forwarder(address(usdc), address(rr), address(rr));
        ForwarderFactory rFactImpl = new ForwarderFactory();
        ERC1967Proxy rProxy =
            new ERC1967Proxy(address(rFactImpl), abi.encodeCall(ForwarderFactory.initialize, (address(rImpl))));
        ForwarderFactory rFactory = ForwarderFactory(address(rProxy));

        Forwarder f = Forwarder(payable(rFactory.createForwarder(sender, destDomain, mintRecipient)));
        usdc.mint(address(f), 1000e6);
        rr.setTarget(f, minFinality);

        vm.prank(address(rr));
        vm.expectRevert(Forwarder.Reentrancy.selector);
        f.requestTransfer(100e6, 1e6, 1e6, minFinality, hex"");
    }
}
