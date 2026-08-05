// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import "../script/BaseScript.sol";

/// @dev Exposes BaseScript's internal target guard.
contract Harness is BaseScript {
    address private _target;
    bool private _targetSet;
    bool private _allowMismatch;

    /// @dev Inject the target without touching the shared process environment.
    function setTarget(address t) external {
        _target = t;
        _targetSet = true;
    }

    function setAllowMismatch(bool v) external {
        _allowMismatch = v;
    }

    function _relayerProxyTarget() internal view override returns (address) {
        return _targetSet ? _target : super._relayerProxyTarget();
    }

    function _configMismatchAllowed() internal view override returns (bool) {
        return _allowMismatch || super._configMismatchAllowed();
    }

    function requireProxy() external view returns (address) {
        return _requireRelayerProxy();
    }
}

/// @dev Stands in for a deployed relayer: only the wiring the guard inspects.
contract RelayerStub {
    address public usdc;
    address public messenger;
    address public transmitter;

    constructor(address usdc_, address messenger_, address transmitter_) {
        usdc = usdc_;
        messenger = messenger_;
        transmitter = transmitter_;
    }
}

/**
 * @notice Regression tests for relayer script target resolution.
 * @dev The relayer ships to every CCTP chain, so the target is taken from the environment rather than a per-chain
 *      constant. What must hold is that the address really is THIS chain's relayer — the previous script hardcoded
 *      a v1 CCTPRelayer proxy on Polygon, which is exactly the failure these tests pin down.
 */
contract ScriptGuardsTest is Test {
    function _harness(uint256 chainId) internal returns (Harness) {
        vm.chainId(chainId);
        return new Harness();
    }

    function _stubFor(Harness h) internal returns (address) {
        return address(new RelayerStub(h.usdc(), h.messenger(), h.transmitter()));
    }

    // ── the guard accepts a correctly wired relayer on any supported chain ──
    function test_acceptsMatchingRelayerOnMainnet() public {
        Harness h = _harness(CHAIN_MAINNET);
        address stub = _stubFor(h);
        h.setTarget(stub);
        assertEq(h.requireProxy(), stub);
    }

    function test_acceptsMatchingRelayerOnBase() public {
        Harness h = _harness(CHAIN_BASE);
        address stub = _stubFor(h);
        h.setTarget(stub);
        assertEq(h.requireProxy(), stub);
    }

    function test_acceptsMatchingRelayerOnInjectiveTestnet() public {
        Harness h = _harness(CHAIN_INJECTIVE_TESTNET);
        address stub = _stubFor(h);
        h.setTarget(stub);
        assertEq(h.requireProxy(), stub);
    }

    // ── a relayer wired for ANOTHER chain is rejected (the wrong-chain / hardcoded-address failure) ──
    function test_rejectsRelayerFromAnotherChain() public {
        Harness polygon = _harness(CHAIN_POLYGON);
        address polygonRelayer = _stubFor(polygon);

        // Same address, but now we are running against Base.
        Harness base = _harness(CHAIN_BASE);
        base.setTarget(polygonRelayer);
        vm.expectRevert(bytes("RELAYER_PROXY.usdc() != Config usdc for this chain"));
        base.requireProxy();
    }

    // ── an address with no code (typo, or right address on the wrong network) ──
    function test_rejectsCodelessAddress() public {
        Harness h = _harness(CHAIN_INJECTIVE_TESTNET);
        h.setTarget(address(0xDEAD));
        vm.expectRevert(bytes("no code at RELAYER_PROXY"));
        h.requireProxy();
    }

    function test_rejectsZeroAddress() public {
        Harness h = _harness(CHAIN_INJECTIVE_TESTNET);
        h.setTarget(address(0));
        vm.expectRevert(bytes("RELAYER_PROXY is zero"));
        h.requireProxy();
    }

    // ── mismatching messenger / transmitter are caught too ──
    function test_rejectsWrongMessenger() public {
        Harness h = _harness(CHAIN_INJECTIVE_TESTNET);
        address stub = address(new RelayerStub(h.usdc(), address(0xBAD1), h.transmitter()));
        h.setTarget(stub);
        vm.expectRevert(bytes("RELAYER_PROXY.messenger() != Config messenger for this chain"));
        h.requireProxy();
    }

    function test_rejectsWrongTransmitter() public {
        Harness h = _harness(CHAIN_INJECTIVE_TESTNET);
        address stub = address(new RelayerStub(h.usdc(), h.messenger(), address(0xBAD2)));
        h.setTarget(stub);
        vm.expectRevert(bytes("RELAYER_PROXY.transmitter() != Config transmitter for this chain"));
        h.requireProxy();
    }

    // ── the escape hatch, for a relayer knowingly wired to something Config no longer matches ──
    function test_configMismatchCanBeOverridden() public {
        Harness h = _harness(CHAIN_INJECTIVE_TESTNET);
        address stub = address(new RelayerStub(address(0xF00D), h.messenger(), h.transmitter()));
        h.setTarget(stub);
        h.setAllowMismatch(true);
        assertEq(h.requireProxy(), stub);
    }

    // ── chain guard is unchanged: every CCTP chain is supported, unknown ones are not ──
    function test_supportsAllConfiguredChains() public {
        uint256[14] memory chains = [
            CHAIN_MAINNET,
            CHAIN_AVALANCHE,
            CHAIN_OP,
            CHAIN_ARBITRUM,
            CHAIN_BASE,
            CHAIN_POLYGON,
            CHAIN_INJECTIVE,
            CHAIN_SEPOLIA,
            CHAIN_AVALANCHE_FUJI,
            CHAIN_OP_SEPOLIA,
            CHAIN_ARBITRUM_SEPOLIA,
            CHAIN_BASE_SEPOLIA,
            CHAIN_POLYGON_AMOY,
            CHAIN_INJECTIVE_TESTNET
        ];
        for (uint256 i = 0; i < chains.length; ++i) {
            Harness h = _harness(chains[i]);
            assertTrue(h.usdc() != address(0), "usdc resolved");
            assertTrue(h.messenger() != address(0), "messenger resolved");
            assertTrue(h.transmitter() != address(0), "transmitter resolved");
        }
    }

    function test_unsupportedChainReverts() public {
        vm.chainId(999999);
        vm.expectRevert("Chain not supported.");
        new Harness();
    }
}
