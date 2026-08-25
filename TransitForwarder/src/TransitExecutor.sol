// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {IReceiver} from "./interfaces/IReceiver.sol";
import {ITransitExecutor} from "./interfaces/ITransitExecutor.sol";
import {ITransitForwarder} from "./interfaces/ITransitForwarder.sol";
import {ITransitForwarderFactory} from "./interfaces/ITransitForwarderFactory.sol";
import {CCTPV1Message} from "./libraries/CCTPV1Message.sol";
import {TransitBurnParams} from "./libraries/TransitBurnParams.sol";

/**
 * @title TransitExecutor
 * @notice The single fixed address source-chain burners commit as `destinationCaller`. Creates the forwarder if this
 *         is its first use, mints (transmitter.receiveMessage), and has that forwarder re-burn — one transaction.
 *         Holds no funds: USDC is minted straight to the forwarder.
 *
 *         Pinning destinationCaller per route would also close the griefing path, but one wrong value is
 *         unrecoverable — only the named address may ever receive that message, and CCTP messages do not expire.
 *
 * @dev ⚠️ THIS ADDRESS CAN NEVER CHANGE. It is baked into every forwarder's `executor` immutable and into the
 *      `destinationCaller` of messages already burned elsewhere. Hence UUPS: fix behaviour, keep the address.
 *      Scripts must reference the PROXY, never the implementation (BaseScript._assertIsProxy).
 *
 *      ⚠️ Version mix, fixed by construction: mint = CCTP v1 (`transmitter` below, parsed by CCTPV1Message),
 *      burn = CCTP v2 (the forwarder calls Circle's TokenMessenger directly). Nothing sniffs the version at runtime.
 *
 *      ⚠️ SHORT-LIVED BY DESIGN — see the design document's §10 sunset procedure.
 */
contract TransitExecutor is ITransitExecutor, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using CCTPV1Message for bytes;

    // ── config (impl immutable; rotated by a UUPS upgrade, which preserves this address) ──
    /// @notice Used ONLY to measure the forwarder's balance delta. This contract never moves USDC on the transit path.
    IERC20 public immutable usdc;
    /// @notice CCTP **v1** MessageTransmitter — NOT the v2 one. Also the scripts' discriminator for an executor
    ///         impl, since the forwarder does not expose it.
    IReceiver public immutable transmitter;
    /// @notice The only caller of the transit entry points. To rotate, upgrade the implementation.
    /// @dev Immutable rather than a setter: a setter would let the owner move executor authority at will, blurring
    ///      the operator/owner boundary.
    address public immutable operator;

    // ── storage (proxy) ──
    // Slot 0, packed: factory + _reentrant. The OZ parents use ERC-7201 namespaced storage and claim no slot here.

    /// @notice Factory used to create a forwarder that does not exist yet. Storage, not immutable — see setFactory.
    address public factory;
    bool private _reentrant;

    // append-only: new variables go before __gap and shrink it (never prepend). 1 slot used above.
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

    /// @param factory_ The TransitForwarderFactory, or address(0) to wire it later with setFactory.
    /// @dev ⚠️ In the canonical deployment order this MUST be address(0): the factory needs a forwarder
    ///      implementation, that implementation needs this contract's address, and this contract must therefore
    ///      exist first. The parameter is here for the orders where the factory IS already known — a redeployment,
    ///      or a flow that pre-computes this proxy's address — so those do not need a second transaction.
    ///      Not a constructor immutable for the same reason, plus the factory must stay replaceable.
    function initialize(address owner_, address factory_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        // Do NOT swap for a bare __Ownable2Step_init() — it is a no-op and would leave this ownerless, permanently
        // bricking every onlyOwner upgrade.
        __Ownable_init(owner_);
        if (factory_ != address(0)) {
            factory = factory_;
            emit FactorySet(address(0), factory_);
        }
    }

    /// @dev v2: `feeAmount` was removed from executeTransit — this route takes no relayer fee. Must be upgraded
    ///      together with the forwarder beacon: the two share TransitBurnParams and the transferMinted ABI, so a
    ///      v1 executor cannot drive a v2 forwarder or vice versa.
    function version() external pure virtual returns (uint256) {
        return 2;
    }

    /// @notice Point the executor at the factory it creates missing forwarders with.
    /// @dev Storage, not an immutable: the factory needs a forwarder impl, which needs this contract's address, so
    ///      it cannot exist yet at construction. Order is executor proxy → forwarder impl → factory → setFactory.
    ///      Re-settable because a factory redeployment is a real scenario. A hostile factory cannot hijack anything —
    ///      a CREATE2 address commits to its factory, so RouteMismatch refuses addresses another factory predicts.
    function setFactory(address factory_) external onlyOwner {
        emit FactorySet(factory, factory_);
        factory = factory_;
    }

    /// @notice Create the forwarder if absent, mint, and re-burn through it — atomically.
    function executeTransit(
        bytes calldata message,
        bytes calldata attestation,
        address routeSender,
        uint32 routeDestinationDomain,
        bytes32 routeMintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    ) external onlyOperator nonReentrant {
        if (destinationCaller == bytes32(0)) revert EmptyDestinationCaller();
        TransitBurnParams.check(minFinalityThreshold);
        address forwarder = _ensureForwarder(message, routeSender, routeDestinationDomain, routeMintRecipient);
        uint256 minted = _receiveAndMeasure(message, attestation, forwarder);

        // maxFee is bounded against `minted` by the forwarder, which is the first place the amount is known.
        ITransitForwarder(forwarder).transferMinted(message, minted, maxFee, minFinalityThreshold, destinationCaller);
    }

    /// @notice Mint and have the forwarder return everything to its `sender`, skipping the onward burn.
    /// @dev The exit when a message can be minted but not transited (e.g. maxFee is not below the amount). Without
    ///      it such a message is unresolvable: the source chain has already burned and only a receiveMessage here
    ///      can redeem it. No _checkStaticParams and no destinationCaller — nothing is burned onward.
    function executeRefund(
        bytes calldata message,
        bytes calldata attestation,
        address routeSender,
        uint32 routeDestinationDomain,
        bytes32 routeMintRecipient
    ) external onlyOperator nonReentrant {
        address forwarder = _ensureForwarder(message, routeSender, routeDestinationDomain, routeMintRecipient);
        uint256 minted = _receiveAndMeasure(message, attestation, forwarder);

        ITransitForwarder(forwarder).refundMinted(message, minted);
    }

    // ── internal ──

    /// @dev Derived from the message alone, so an executor with no factory still serves already-deployed routes.
    ///      No length pre-check: an out-of-range slice reverts by itself.
    function _forwarderOf(bytes calldata message) internal pure returns (address forwarder) {
        bytes32 raw = message._getMintRecipient();
        if (uint256(raw) >> 160 != 0) revert NotEvmRecipient();
        forwarder = address(uint160(uint256(raw)));
    }

    /// @dev Resolve the forwarder the message names, creating it on first use.
    ///
    ///      ⚠️ The route arguments are operator-supplied and NOT trusted. The equality below is what makes accepting
    ///      them safe: a forwarder's address commits to (factory, salt(route), initCodeHash), so a factory
    ///      predicting THIS address proves the route is the one the burner committed to. Without it the operator
    ///      could have a forwarder of its own choosing created and the mint land there.
    ///
    ///      Only consulted when the forwarder is absent; once it exists its own WrongRecipient check covers this.
    function _ensureForwarder(bytes calldata message, address routeSender, uint32 routeDomain, bytes32 routeRecipient)
        internal
        returns (address forwarder)
    {
        forwarder = _forwarderOf(message);

        if (forwarder.code.length == 0) {
            address f = factory;
            if (f == address(0)) revert FactoryNotSet();
            if (ITransitForwarderFactory(f).getForwarderAddress(routeSender, routeDomain, routeRecipient) != forwarder)
            {
                revert RouteMismatch();
            }
            ITransitForwarderFactory(f).createForwarder(routeSender, routeDomain, routeRecipient);

            // Post-condition of CREATION, not redundant: a void external call skips the extcodesize check, so
            // code-less here would let the next call "succeed" while the mint sits at an address nobody controls.
            if (forwarder.code.length == 0) revert NotContract();
        }
    }

    /// @dev Snapshots the FORWARDER's balance — the mint goes straight there, never through this contract.
    ///
    ///      The reported figure is the measured delta, not the body's `amount`, so dust already sitting on the
    ///      forwarder never rides along in this message's accounting. The two are then cross-checked: CCTP v1 mints
    ///      `amount` exactly, so the observed movement and the attested message must agree. Measuring gives the
    ///      dust exclusion; comparing gives the assurance that what moved is what this message authorised.
    function _receiveAndMeasure(bytes calldata message, bytes calldata attestation, address forwarder)
        internal
        returns (uint256 minted)
    {
        uint256 balBefore = usdc.balanceOf(forwarder);
        if (!transmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
        minted = usdc.balanceOf(forwarder) - balBefore;
        if (minted == 0) revert NothingMinted();
        if (minted != message._getAmount()) revert AmountMismatch();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
