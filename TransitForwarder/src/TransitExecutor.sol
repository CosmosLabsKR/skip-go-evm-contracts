// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {IReceiver} from "./interfaces/IReceiver.sol";
import {ITransitExecutor} from "./interfaces/ITransitExecutor.sol";
import {ITransitForwarder} from "./interfaces/ITransitForwarder.sol";
import {ITransitForwarderFactory} from "./interfaces/ITransitForwarderFactory.sol";
import {CCTPV2Message} from "./libraries/CCTPV2Message.sol";

/**
 * @title TransitExecutor
 * @notice The single fixed address that source-chain burners commit as `destinationCaller`. It performs the mint
 *         (transmitter.receiveMessage) and, in the same transaction, instructs the forwarder named by the message's
 *         mintRecipient to re-burn toward that forwarder's engraved next hop.
 *
 *         Why a single contract instead of pinning destinationCaller to each route's forwarder: both close the
 *         griefing path, but per-route values must be computed and injected by the source side for every route, and
 *         getting one wrong is UNRECOVERABLE — only the address named in destinationCaller may ever receive that
 *         message, and CCTP messages do not expire. One constant, injected once, removes that failure mode.
 *
 * @dev ⚠️ THIS ADDRESS CAN NEVER CHANGE. It is baked into (a) every forwarder's `executor` immutable and (b) the
 *      `destinationCaller` of messages ALREADY BURNED on other chains. In-flight funds can only be received by this
 *      exact address, so replacing it would strand them permanently. Hence UUPS: fix behaviour, keep the address.
 *      Deployment scripts must reference the PROXY, never the implementation — see _assertIsProxy in BaseScript.
 *
 *      ⚠️ SHORT-LIVED BY DESIGN, like the rest of this subproject. See TransitForwarder's note and the design
 *      document's §10 sunset procedure.
 *
 *      This contract holds no funds: USDC is minted directly to the forwarder and burned from there within the same
 *      transaction. recoverERC20 exists only for third-party mis-sends.
 */
contract TransitExecutor is ITransitExecutor, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;
    using CCTPV2Message for bytes;

    // ── config (impl immutable; rotated by a UUPS upgrade, which preserves this address) ──
    /// @notice Used ONLY to measure the forwarder's balance delta. This contract never moves USDC on the transit path.
    IERC20 public immutable usdc;
    /// @notice CCTP v2 MessageTransmitter. Also the discriminator that tells a TransitExecutor impl apart from a
    ///         TransitForwarder impl in the deploy scripts — the forwarder deliberately no longer exposes it.
    IReceiver public immutable transmitter;
    /// @notice The only address allowed to call the transit entry points. To rotate, upgrade the implementation.
    /// @dev An immutable rather than a storage variable with a setter: a setter would let the owner move the executor
    ///      authority arbitrarily, blurring the operator/owner trust boundary this design keeps sharp.
    address public immutable operator;

    // ── storage (proxy) ──
    // Slot 0, packed: factory (20 bytes) + _reentrant (1 byte). The OZ parents above all use ERC-7201 namespaced
    // storage, so they occupy NO sequential slots and these land at slot 0.

    /// @notice Factory used to create a forwarder that does not exist yet. Storage, not immutable — see setFactory.
    address public factory;
    bool private _reentrant;

    // append-only: add new state variables before __gap and shrink __gap (never prepend). 1 slot used above.
    uint256[50] private __gap;

    modifier nonReentrant() {
        if (_reentrant) revert Reentrancy();
        _reentrant = true;
        _;
        _reentrant = false;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address usdc_, address transmitter_, address operator_) {
        if (usdc_ == address(0) || transmitter_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        transmitter = IReceiver(transmitter_);
        operator = operator_;
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        // Do NOT replace with a bare __Ownable2Step_init() — that is a no-op and would leave this contract ownerless
        // (owner == address(0)), permanently bricking every onlyOwner upgrade. Ownable2Step adds no init state.
        // Same trap the factory's initialize documents.
        __Ownable_init(owner_);
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    /// @notice Point the executor at the factory it creates missing forwarders with.
    /// @dev ⚠️ Storage rather than an immutable is FORCED by the deployment order: the factory needs a forwarder
    ///      implementation, and that implementation needs this contract's address. Something has to be injected
    ///      after the fact, and this is it. Deployment order: executor proxy → forwarder impl → factory → setFactory.
    ///
    ///      Re-settable on purpose (a factory redeployment is a real scenario — see
    ///      _assertFactoryUpgradeKeepsAddressSpace). A hostile factory cannot hijack anything: a CREATE2 address
    ///      commits to the factory that produced it, so a different factory predicts different addresses and the
    ///      RouteMismatch check refuses them.
    function setFactory(address factory_) external onlyOwner {
        emit FactorySet(factory, factory_);
        factory = factory_;
    }

    /// @notice Mint via CCTP and re-burn through the message's forwarder, atomically. Next hop caller = any.
    function executeTransit(
        bytes calldata message,
        bytes calldata attestation,
        Route calldata route,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external onlyOperator nonReentrant {
        _checkStaticParams(feeAmount, minFinalityThreshold);
        address forwarder = _ensureForwarder(message, route);
        uint256 minted = _receiveAndMeasure(message, attestation, forwarder);

        ITransitForwarder(forwarder).transferMinted(
            message, minted, feeAmount, maxFee, minFinalityThreshold, hookData
        );
    }

    /// @notice Same, but restricts who may call receiveMessage on the next hop.
    function executeTransitWithCaller(
        bytes calldata message,
        bytes calldata attestation,
        Route calldata route,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external onlyOperator nonReentrant {
        _checkStaticParams(feeAmount, minFinalityThreshold);
        address forwarder = _ensureForwarder(message, route);
        uint256 minted = _receiveAndMeasure(message, attestation, forwarder);

        ITransitForwarder(forwarder).transferMintedWithCaller(
            message, minted, feeAmount, maxFee, minFinalityThreshold, destinationCaller, hookData
        );
    }

    /// @notice Mint and have the forwarder return everything to its `sender`. The exit when the operator knows at
    ///         mint time that the transit cannot proceed (e.g. the amount cannot cover a fee).
    /// @dev No _checkStaticParams: this path spends no fee and sets no finality.
    function executeRefund(bytes calldata message, bytes calldata attestation, Route calldata route)
        external
        onlyOperator
        nonReentrant
    {
        address forwarder = _ensureForwarder(message, route);
        uint256 minted = _receiveAndMeasure(message, attestation, forwarder);

        ITransitForwarder(forwarder).refundMinted(message, minted);
    }

    /// @notice Escape hatch for third-party mis-sends. This contract is not a fund custodian.
    function recoverERC20(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Recovered(token, to, amount);
    }

    // ── internal ──

    /// @dev Checked BEFORE receiveMessage so an obviously bad call does not burn the signature-verification gas.
    ///      The forwarder re-checks these as self-defence; the rollback outcome is identical either way (the whole
    ///      transaction reverts and the CCTP nonce stays unspent), so this is purely a failure-cost optimisation.
    function _checkStaticParams(uint256 feeAmount, uint32 minFinalityThreshold) internal pure {
        if (feeAmount == 0) revert ITransitForwarder.ZeroFee();
        // CCTP v2 accepts only 1000 (fast/soft) or 2000 (standard/hard).
        if (minFinalityThreshold != 1000 && minFinalityThreshold != 2000) {
            revert ITransitForwarder.InvalidFinalityThreshold();
        }
    }

    /// @dev Derive the destination forwarder from the message itself. No factory or forwarder address is needed to
    ///      get this far, which is what lets an executor with no factory keep serving already-deployed routes.
    ///
    ///      validateLength must run first: _getMintRecipient slices message[184:216], and slicing past the end
    ///      panics (0x32) instead of producing the MalformedMessage the off-chain decoder expects.
    function _forwarderOf(bytes calldata message) internal pure returns (address forwarder) {
        message.validateLength();
        bytes32 raw = message._getMintRecipient();
        if (uint256(raw) >> 160 != 0) revert NotEvmRecipient();
        forwarder = address(uint160(uint256(raw)));
    }

    /// @dev Resolve the forwarder the message names, creating it on first use.
    ///
    ///      ⚠️ `route` comes from the operator and is NOT trusted. The equality below is what makes accepting it
    ///      safe: a forwarder's address commits to (factory, salt(route), initCodeHash), so if the factory predicts
    ///      THIS address from the supplied route, the route is necessarily the one the source-chain burner
    ///      committed funds to. Without the check, the operator could deploy a forwarder for a route of its own
    ///      choosing and have the mint land there.
    ///
    ///      Consulted only when the forwarder does not exist yet. Once it does, the forwarder's own WrongRecipient
    ///      check already proves the message belongs to it, so the route arguments are redundant and the factory
    ///      round-trip is skipped.
    function _ensureForwarder(bytes calldata message, Route calldata route) internal returns (address forwarder) {
        forwarder = _forwarderOf(message);

        if (forwarder.code.length == 0) {
            address f = factory;
            if (f == address(0)) revert FactoryNotSet();
            if (
                ITransitForwarderFactory(f).getForwarderAddress(
                    route.sender, route.destinationDomain, route.mintRecipient
                ) != forwarder
            ) revert RouteMismatch();
            ITransitForwarderFactory(f).createForwarder(route.sender, route.destinationDomain, route.mintRecipient);
        }

        // Post-condition, not a redundant check: see ITransitExecutor.NotContract. A void external call skips the
        // extcodesize check, so if creation ever failed to produce code the next call would "succeed" silently and
        // the minted funds would sit at an address nobody controls.
        if (forwarder.code.length == 0) revert NotContract();
    }

    /// @dev Snapshot the FORWARDER's balance (the mint goes straight there, never through this contract), receive,
    ///      and return the delta.
    ///
    ///      The delta — never the burn body's `amount`. A CCTP v2 fast transfer deducts feeExecuted on the
    ///      destination, so the body's amount exceeds what actually arrived. It also excludes any dust already
    ///      sitting on the forwarder, keeping per-message figures exact for off-chain reconciliation; dust leaves
    ///      separately via the forwarder's recoverERC20.
    function _receiveAndMeasure(bytes calldata message, bytes calldata attestation, address forwarder)
        internal
        returns (uint256 minted)
    {
        uint256 balBefore = usdc.balanceOf(forwarder);
        if (!transmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
        minted = usdc.balanceOf(forwarder) - balBefore;
        if (minted == 0) revert NothingMinted();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
