// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {ITokenMessenger} from "./interfaces/ITokenMessenger.sol";
import {ITransitForwarder} from "./interfaces/ITransitForwarder.sol";
import {CCTPV1Message} from "./libraries/CCTPV1Message.sol";
import {TransitBurnParams} from "./libraries/TransitBurnParams.sol";

/**
 * @title TransitForwarder
 * @notice Per-route transit conduit (logic impl behind a BeaconProxy). A CCTP v1 message mints USDC here; this
 *         contract re-burns it as a CCTP v2 transfer toward a fixed next hop in the SAME transaction, so nothing is
 *         left parked on this chain.
 *
 *         It does NOT mint. TransitExecutor calls the transmitter (which is what lands the mint here), measures the
 *         balance delta and passes it in. The burn goes straight to Circle's TokenMessenger.
 *
 *         ⚠️ NO FEE IS TAKEN. The whole minted amount is burned onward. Until v2 the burn was delegated to the
 *         PaymentContract (CCTPV2Relayer), whose only contribution on this path was fee collection — and it REJECTS
 *         a zero fee (PaymentCannotBeZero), which forced this route to pay a meaningless 1-unit dust fee on every
 *         transit. Calling the messenger directly removes the dust, the delegation, and ~34% of the gas.
 *         `maxFee` is a different thing entirely and is untouched — see the note on transferMinted.
 *
 *         The next hop (destinationDomain, mintRecipient) is part of the CREATE2 salt and so is engraved in this
 *         address. A burner committing mintRecipient = this address is what fixes the destination — neither the
 *         operator nor the executor can redirect it.
 *
 * @dev Config (usdc/messenger/operator/executor/LOCAL_DOMAIN) is impl immutable, shared by all instances and
 *      rotated in bulk via a beacon upgrade. Per-route values live in proxy storage. Every entry point is
 *      non-reentrant and gated: transit to the executor, recovery to the operator.
 *
 *      ⚠️ SHORT-LIVED BY DESIGN. It sits beside ForwarderFactory rather than inside it so retiring it is a
 *      directory deletion. Do not grow dependencies from the permanent contracts into this one. See §10 sunset.
 */
contract TransitForwarder is ITransitForwarder, Initializable {
    using SafeERC20 for IERC20;
    using CCTPV1Message for bytes;

    // ── config (impl immutable, shared by all instances; injected by Deployment) ──
    IERC20 public immutable usdc;
    /// @notice Circle's CCTP v2 TokenMessenger — the burn leg, called directly (no relayer in between).
    /// @dev ⚠️ Must be the v2 messenger, never the v1 one and never a MessageTransmitter. Nothing infers the
    ///      version at runtime; binding the right address is what makes this leg v2. The mint leg is v1 and lives
    ///      on TransitExecutor, so the two Circle addresses this system depends on sit in different contracts.
    ITokenMessenger public immutable messenger;
    /// @notice Authorized caller for RECOVERY only. To rotate, deploy a new impl and apply it via beacon.upgradeTo.
    address public immutable operator;
    /// @notice Authorized caller for TRANSIT only — the TransitExecutor PROXY address.
    /// @dev ⚠️ Must be the proxy, never an implementation: an impl is discarded on upgrade, and that would orphan
    ///      every forwarder at once. Enforced at deploy time by _assertIsProxy.
    address public immutable executor;
    /// @notice The domain of the chain this impl is deployed on (Avalanche 1, Polygon 7). Drives the inbound
    ///         binding check. Injected per chain by BaseScript — the contract itself is chain-agnostic.
    /// @dev Named for the here/there contrast with `destinationDomain` right below it.
    uint32 public immutable LOCAL_DOMAIN;
    /// @notice The only destination `initialize` accepts (Injective). A CREATION-TIME constraint only.
    /// @dev ⚠️ Read this before "simplifying" the destination into this immutable and dropping the storage slot.
    ///      Transfers read the per-route STORAGE `destinationDomain`, which also stays in the CREATE2 salt — that is
    ///      what makes each address a commitment to its destination. Reading this immutable instead would let one
    ///      beacon upgrade silently redirect EVERY deployed forwarder, degrading destination integrity from
    ///      "engraved in the address" to "trust the beacon owner". Changing it only moves the allowed set for
    ///      FUTURE routes.
    uint32 public immutable ALLOWED_DESTINATION_DOMAIN;

    // ── per-route (proxy storage) ──
    /// @notice Route identifier, fund owner, and the sole refund/recovery recipient. No setter exists.
    address public sender;
    uint32 public destinationDomain;
    // Packs into slot 0 with sender + destinationDomain. Keep this width: a wider type takes its own slot and
    // shifts everything after it, which the beacon model forbids once proxies hold the layout. Layout constraint
    // only — measured, the packing alternatives land within ~20 gas of each other.
    bool private _reentrant;
    bytes32 public mintRecipient;

    // append-only: new variables go before __gap and shrink it (never prepend). 2 slots used above.
    uint256[48] private __gap;

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

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    /// @dev ⚠️ `executor_` deliberately does NOT sit where `transmitter_` used to. Both are addresses, so a
    ///      same-position swap would let an un-updated caller compile and bind the wrong contract silently.
    constructor(
        address usdc_,
        address messenger_,
        address operator_,
        address executor_,
        uint32 localDomain_,
        uint32 allowedDestinationDomain_
    ) {
        if (usdc_ == address(0) || messenger_ == address(0) || operator_ == address(0) || executor_ == address(0)) {
            revert ZeroAddress();
        }
        // ⚠️ NO usdc/burnToken cross-check here any more. Until v2 the constructor asserted
        // `paymentContract.usdc() == usdc_` (UsdcMismatch), which caught a mismatched impl at deploy time.
        // ITokenMessenger exposes no equivalent getter — it takes burnToken per call — so that guard has no
        // replacement on-chain. What stands in for it: `usdc` is the ONLY value ever passed as burnToken (see
        // transferMinted), the deploy scripts compare every immutable against Config
        // (BaseScript._assertTransitImmutablesMatch), and inspect.sh grades a live impl the same way.
        // Config sanity, checked once here rather than on every route: a deployment whose only allowed destination is
        // its own chain could never produce a usable route, and CCTP would reject the burn anyway.
        if (allowedDestinationDomain_ == localDomain_) revert SelfLoop();
        usdc = IERC20(usdc_);
        messenger = ITokenMessenger(messenger_);
        operator = operator_;
        executor = executor_;
        // No zero-check on either domain: 0 (Ethereum) is a legitimate CCTP domain, so there is no sentinel to
        // reject. The deploy script's _assertTransitImmutablesMatch compares both against Config instead.
        LOCAL_DOMAIN = localDomain_;
        ALLOWED_DESTINATION_DOMAIN = allowedDestinationDomain_;
        _disableInitializers();
    }

    /// @notice Called once by the factory right after deployment to inject the route identity values.
    function initialize(address _sender, uint32 _destinationDomain, bytes32 _mintRecipient) external initializer {
        if (_sender == address(0)) revert ZeroAddress();
        if (_mintRecipient == bytes32(0)) revert EmptyMintRecipient();
        // This deployment routes to exactly one destination (Injective). Anything else is a typo or a
        // misunderstanding, and getting it wrong sends funds to the wrong chain irrecoverably — the CREATE2 address
        // would still look perfectly valid.
        //
        // The factory refuses such a route earlier, in _guardRoute, so no honest caller is ever handed the address.
        // ⚠️ That is a guard on the factory's own views, NOT a barrier: the salt preimage and both CREATE2 inputs
        // (beacon(), beaconInitCodeHash()) are public, so anyone determined can still derive the address off-chain
        // and burn to it. This check STAYS: it is self-defence that assumes no particular factory.
        //
        // Note this constrains CREATION only; the stored value below is what transfers use. See the immutable's docs.
        if (_destinationDomain != ALLOWED_DESTINATION_DOMAIN) revert UnsupportedDestination();
        sender = _sender;
        destinationDomain = _destinationDomain;
        mintRecipient = _mintRecipient;
    }

    /// @dev The only on-chain way for off-chain tooling to tell which surface a beacon-upgraded proxy presents.
    ///      Bump it on every impl that changes the ABI or behaviour.
    /// @dev v2: the relayer fee was removed. `feeAmount` is gone from transferMinted and TransitCompleted, the
    ///      burn is dispatched to Circle's messenger directly, and the `paymentContract` immutable became
    ///      `messenger`. Any tooling that reads version() to pick a call shape must branch on this.
    function version() external pure virtual returns (uint256) {
        return 2;
    }

    /// @notice Re-burn the amount the executor just caused to be minted here, toward the fixed next hop.
    /// @dev ⚠️ `maxFee` is NOT a fee this contract takes — nothing is taken here, the full `minted` is burned. It is
    ///      Circle's cap on the DESTINATION-side fee, deducted from what the next hop receives, and CCTP v2 requires
    ///      it to be strictly less than the burned amount. Setting it to 0 is accepted on-chain but a fast transfer
    ///      (finality 1000) below Circle's quoted fee will not be attested as fast; that is an off-chain property no
    ///      guard here can see.
    function transferMinted(
        bytes calldata message,
        uint256 minted,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    ) external onlyExecutor nonReentrant {
        // Every other transit invariant is re-checked here because the executor is upgradeable; this one is the
        // reason the executor exists at all, so it gets the same treatment rather than being trusted upstream.
        if (destinationCaller == bytes32(0)) revert EmptyDestinationCaller();
        TransitBurnParams.check(minFinalityThreshold);
        _validateBinding(message, minted);
        // CCTP v2 requires maxFee < amount (strict); it is deducted from the minted amount on the destination.
        if (maxFee >= minted) revert InvalidMaxFee();

        // Exactly `minted` is approved and exactly `minted` is pulled → no residual allowance.
        usdc.forceApprove(address(messenger), minted);
        messenger.depositForBurn(
            minted,
            destinationDomain,
            mintRecipient,
            address(usdc), // the only value ever passed as burnToken — see the constructor note
            destinationCaller,
            maxFee,
            minFinalityThreshold
        );

        emit TransitCompleted(message._getNonce(), minted, maxFee, minFinalityThreshold, destinationCaller);
    }

    /// @notice Return the just-minted funds to `sender`, skipping the onward burn entirely. The exit when the
    ///         operator knows at mint time that the transit cannot proceed (e.g. the amount cannot cover a fee).
    function refundMinted(bytes calldata message, uint256 minted) external onlyExecutor nonReentrant {
        _validateBinding(message, minted);
        address to = sender;
        usdc.safeTransfer(to, minted);
        emit Refunded(message._getNonce(), to, minted);
    }

    /// @notice Escape hatch — recover the entire `token` balance to `sender`. Any token: this address is
    ///         CREATE2-predictable, so anything sent here would otherwise be stuck. Also sweeps transit dust.
    function recoverERC20(address token) external onlyOperator nonReentrant {
        _recover(token, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Partial recovery to `sender`. An amount exceeding the balance reverts inside safeTransfer.
    function recoverERC20(address token, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _recover(token, amount);
    }

    /// @dev Shared recovery core — prevents drift between the two entry points.
    function _recover(address token, uint256 amount) private {
        IERC20(token).safeTransfer(sender, amount);
        emit Recovered(token, amount);
    }

    function getRoute() external view returns (address, uint32, bytes32) {
        return (sender, destinationDomain, mintRecipient);
    }

    // ── internal ──

    /// @dev The message must mint to THIS forwarder, on this chain's domain — that binding is what keeps a message
    ///      on its route. Self-defence, not ceremony: the executor derives this address from mintRecipient so the
    ///      recipient check is always true on the honest path, but the executor is upgradeable and this is what
    ///      keeps the forwarder on its route regardless of what it becomes.
    ///
    ///      `minted` is bounded twice: it must not exceed what this contract holds, and it must equal what the
    ///      attested message says was burned. CCTP v1 deducts no destination-side fee, so that equality is exact —
    ///      which makes this check independent of the executor's measurement rather than a restatement of it.
    ///
    ///      ⚠️ Do NOT compare burn.messageSender against `sender`. It is bytes32 and non-EVM source domains use all
    ///      32 bytes, so the check would reject every message from them. `sender` is therefore a route key, not an
    ///      enforced claim — anyone can burn to this forwarder, and those funds follow its committed destination.
    ///
    ///      ⚠️ Do NOT add a `burnToken == usdc` check. `burnToken` is a SOURCE-domain address and can never equal
    ///      this chain's `usdc`. Token identity is enforced more strongly by the balance bound below.
    function _validateBinding(bytes calldata message, uint256 minted) internal view {
        if (message._getDestinationDomain() != LOCAL_DOMAIN) revert WrongDestination();
        if (message._getMintRecipient() != _toBytes32(address(this))) revert WrongRecipient();

        if (minted == 0) revert ZeroAmount();
        if (minted > usdc.balanceOf(address(this))) revert MissingBalance();
        if (minted != message._getAmount()) revert AmountMismatch();
    }

    function _toBytes32(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @notice Reject direct native transfers; this forwarder only handles ERC20 USDC.
    receive() external payable {
        revert NativeNotAccepted();
    }

    fallback() external payable {
        revert NativeNotAccepted();
    }
}
