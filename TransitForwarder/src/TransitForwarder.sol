// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {ICCTPV2Relayer} from "./interfaces/ICCTPV2Relayer.sol";
import {ITransitForwarder} from "./interfaces/ITransitForwarder.sol";
import {CCTPV2Message} from "./libraries/CCTPV2Message.sol";

/**
 * @title TransitForwarder
 * @notice Per-route transit conduit (logic impl behind a BeaconProxy): a CCTP v2 message mints USDC to this address,
 *         and this contract re-burns that amount toward a fixed next hop **in the same transaction**, so nothing is
 *         left parked on this chain.
 *
 *         This contract does NOT mint. The TransitExecutor calls Circle's MessageTransmitter (which is what causes
 *         the mint to land here), measures the balance delta, and passes it in. The burn leg is delegated to the
 *         PaymentContract (CCTPV2Relayer) exactly as OutboundForwarder does, because the relayer already owns fee
 *         collection and depositForBurn parameter normalisation.
 *
 *         Why the mint moved out: pinning the source-chain `destinationCaller` to one fixed address closes a
 *         griefing path where a third party receives the message first, spending the CCTP nonce without triggering
 *         the burn and stranding the funds here. A per-route pin would work too, but one wrong value is
 *         unrecoverable, so the pin is a single executor address instead.
 *
 *         The next hop (destinationDomain, mintRecipient) is part of the CREATE2 salt, so it is engraved in this
 *         contract's address. The source-chain burner committing mintRecipient = this address is what fixes the
 *         onward destination — neither the operator nor the executor can redirect it.
 *
 * @dev ⚠️ SHORT-LIVED BY DESIGN. This subproject is not a permanent member of the codebase; it lives beside
 *      ForwarderFactory rather than inside it precisely so that retiring it is a directory deletion. Do not grow
 *      dependencies from the permanent contracts into this one. Sunset procedure: see the design document's §10.
 *
 *      config (usdc/paymentContract/operator/executor/LOCAL_DOMAIN) is impl immutable and shared by all instances
 *      (rotated in bulk via a beacon upgrade). Per-route values live in proxy storage. Every entry point is
 *      non-reentrant and gated: transit entry points to the executor, recovery entry points to the operator.
 */
contract TransitForwarder is ITransitForwarder, Initializable {
    using SafeERC20 for IERC20;
    using CCTPV2Message for bytes;

    // ── config (impl immutable, shared by all instances; injected by Deployment) ──
    IERC20 public immutable usdc;
    ICCTPV2Relayer public immutable paymentContract; // PaymentContract (burn, delegated)
    /// @notice Authorized caller for RECOVERY only. To rotate, deploy a new impl and apply it via beacon.upgradeTo.
    address public immutable operator;
    /// @notice Authorized caller for TRANSIT only — the TransitExecutor PROXY address.
    /// @dev ⚠️ Must be the proxy, never an implementation. The executor's address is also baked into the
    ///      `destinationCaller` of messages already burned on other chains, so it can never be replaced; pointing
    ///      this at an implementation would orphan every forwarder the moment that impl is upgraded away.
    ///      The deploy script enforces this with _assertIsProxy.
    address public immutable executor;
    /// @notice This chain's CCTP domain (Avalanche). Drives the inbound binding check.
    /// @dev Named LOCAL_DOMAIN rather than the inbound forwarder's INJECTIVE_DOMAIN purely for readability — here it
    ///      sits next to `destinationDomain`, and the here/there contrast is load-bearing when reading the code.
    uint32 public immutable LOCAL_DOMAIN;
    /// @notice The only destination `initialize` will accept (Injective). A CREATION-TIME CONSTRAINT, not the value
    ///         used when transferring — see the warning below.
    /// @dev ⚠️ Read this before "simplifying" the destination into this immutable and dropping the storage slot.
    ///
    ///      `mintAndTransfer` deliberately reads the per-route STORAGE `destinationDomain`, never this immutable, and
    ///      `destinationDomain` stays in the CREATE2 salt. That is what keeps each forwarder's address a commitment
    ///      to its destination — the property the whole design rests on (a source-chain burner sets mintRecipient to
    ///      this address, and that act fixes where the funds go).
    ///
    ///      If the transfer read this immutable instead, a single beacon upgrade would silently redirect EVERY
    ///      deployed forwarder, including funds already committed to those addresses by burners on other chains.
    ///      Destination integrity would degrade from "engraved in the address" to "trust the beacon owner".
    ///
    ///      So this value only narrows which routes can be CREATED. Changing it via a beacon upgrade widens or moves
    ///      the allowed set for FUTURE routes and leaves every existing forwarder untouched.
    uint32 public immutable ALLOWED_DESTINATION_DOMAIN;

    // ── per-route (proxy storage) ──
    /// @notice Route identifier, fund owner, and the sole refund/recovery recipient. No setter exists.
    address public sender;
    uint32 public destinationDomain;
    // Packs into slot 0 with sender + destinationDomain. Keep this width: a wider type takes its own slot and shifts
    // everything after it, which the beacon upgrade model forbids once proxies hold the layout. Layout constraint
    // only — measured, packed `bool` / own-slot `uint256` 0/1 / OZ's 1/2 all land within ~20 gas of each other.
    bool private _reentrant;
    bytes32 public mintRecipient;

    // append-only: add new state variables before __gap and shrink __gap (never prepend). 2 slots used above.
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

    /// @dev ⚠️ The parameter list deliberately does NOT keep `executor_` in the slot `transmitter_` used to occupy.
    ///      Both are addresses, so a same-arity swap would let an un-updated caller compile and deploy an impl bound
    ///      to the wrong contract, silently. Moving it after `operator_` makes such a call fail to compile.
    constructor(
        address usdc_,
        address paymentContract_,
        address operator_,
        address executor_,
        uint32 localDomain_,
        uint32 allowedDestinationDomain_
    ) {
        if (
            usdc_ == address(0) || paymentContract_ == address(0) || operator_ == address(0)
                || executor_ == address(0)
        ) {
            revert ZeroAddress();
        }
        // Enforce usdc == paymentContract.usdc == burnToken at deploy time (blocks an immutable+beacon mismatch).
        if (address(ICCTPV2Relayer(paymentContract_).usdc()) != usdc_) revert UsdcMismatch();
        // Config sanity, checked once here rather than on every route: a deployment whose only allowed destination is
        // its own chain could never produce a usable route, and CCTP would reject the burn anyway.
        if (allowedDestinationDomain_ == localDomain_) revert SelfLoop();
        usdc = IERC20(usdc_);
        paymentContract = ICCTPV2Relayer(paymentContract_);
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
        // would still look perfectly valid. The factory cannot perform this check (ALLOWED_DESTINATION_DOMAIN is an
        // impl immutable), so it lands here and createForwarder bubbles the revert.
        //
        // Note this constrains CREATION only; the stored value below is what transfers use. See the immutable's docs.
        if (_destinationDomain != ALLOWED_DESTINATION_DOMAIN) revert UnsupportedDestination();
        sender = _sender;
        destinationDomain = _destinationDomain;
        mintRecipient = _mintRecipient;
    }

    /// @dev 2, not 1: the executor migration replaced three entry points, so this marks an ABI generation. It is the
    ///      only on-chain way for off-chain tooling to tell which surface a beacon-upgraded proxy presents.
    function version() external pure virtual returns (uint256) {
        return 2;
    }

    /// @notice Re-burn the amount the executor just caused to be minted here, toward the fixed next hop.
    ///         destinationCaller on the next hop = any.
    function transferMinted(
        bytes calldata message,
        uint256 minted,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external onlyExecutor nonReentrant {
        _checkStaticParams(feeAmount, minFinalityThreshold);
        _validateBinding(message, minted);
        uint256 transferAmount = _split(minted, feeAmount, maxFee);

        paymentContract.requestCCTPTransfer(
            transferAmount,
            destinationDomain,
            mintRecipient,
            address(usdc),
            feeAmount,
            maxFee,
            minFinalityThreshold,
            hookData
        );

        emit TransitCompleted(
            message._getNonce(), minted, transferAmount, feeAmount, maxFee, minFinalityThreshold, bytes32(0)
        );
    }

    /// @notice Same as above but restricts who may call receiveMessage on the destination (destinationCaller).
    function transferMintedWithCaller(
        bytes calldata message,
        uint256 minted,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external onlyExecutor nonReentrant {
        _checkStaticParams(feeAmount, minFinalityThreshold);
        _validateBinding(message, minted);
        uint256 transferAmount = _split(minted, feeAmount, maxFee);

        paymentContract.requestCCTPTransferWithCaller(
            transferAmount,
            destinationDomain,
            mintRecipient,
            address(usdc),
            feeAmount,
            maxFee,
            minFinalityThreshold,
            destinationCaller,
            hookData
        );

        emit TransitCompleted(
            message._getNonce(), minted, transferAmount, feeAmount, maxFee, minFinalityThreshold, destinationCaller
        );
    }

    /// @notice Return the just-minted funds to `sender`, skipping the onward burn entirely. The exit when the
    ///         operator knows at mint time that the transit cannot proceed (e.g. the amount cannot cover a fee).
    function refundMinted(bytes calldata message, uint256 minted) external onlyExecutor nonReentrant {
        _validateBinding(message, minted);
        address to = sender;
        usdc.safeTransfer(to, minted);
        emit Refunded(message._getNonce(), to, minted);
    }

    /// @notice Escape hatch — recover the entire `token` balance to `sender`. Accepts any token because this address
    ///         is CREATE2-predictable, so a third party can send anything here and it would otherwise be stuck.
    ///         Also the only way to sweep the dust a partially failed transit can leave behind.
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

    /// @dev Parameters that do NOT depend on the minted amount, checked BEFORE receiveMessage so a bad call does not
    ///      burn the signature-verification gas. Purely a failure-cost optimisation: the rollback outcome is the same
    ///      either way (whole tx reverts, CCTP nonce unspent).
    function _checkStaticParams(uint256 feeAmount, uint32 minFinalityThreshold) internal pure {
        if (feeAmount == 0) revert ZeroFee();
        // CCTP v2 accepts only 1000 (fast/soft) or 2000 (standard/hard).
        if (minFinalityThreshold != 1000 && minFinalityThreshold != 2000) revert InvalidFinalityThreshold();
    }

    /// @dev Validate the route binding and the amount the executor reported.
    ///
    ///      Self-defence, not ceremony. The executor derives this address FROM mintRecipient, so on the honest path
    ///      the recipient check below is always true — but the executor is upgradeable behind a proxy, and an
    ///      upgrade could change that derivation without touching this contract. These checks are what keep a
    ///      forwarder on its own route regardless of what the executor becomes.
    ///
    ///      The binding: the message must mint to THIS forwarder, on this chain's domain. mintRecipient ==
    ///      address(this) — itself CREATE2(salt(sender, destinationDomain, mintRecipient)) — is what commits the
    ///      onward destination and keeps a message on its route.
    ///
    ///      ⚠️ Do NOT compare burn.messageSender against `sender`. It is bytes32, and non-EVM source domains
    ///      (Solana, Sui, Aptos) use all 32 bytes, so matching it against a 20-byte address would reject every
    ///      message from them. Consequently `sender` is a route key, not an enforced claim: anyone can burn to this
    ///      forwarder, and those funds follow the route's committed destination. Nothing the route owner holds is at
    ///      risk — the destination is fixed by the address — but provenance is not proven on-chain.
    ///
    ///      ⚠️ Do NOT add a `burnToken == usdc` check. `burnToken` is a SOURCE-domain address, so it can never equal
    ///      this chain's `usdc` and the check would reject every legitimate message. Token identity is enforced more
    ///      strongly by the balance bound below: this chain's USDC must actually be here.
    ///
    ///      The `minted` bound is the whole of what this contract does about trusting the executor's measurement.
    ///      Over-reporting cannot move more than this address holds; under-reporting just leaves dust behind, which
    ///      recoverERC20 sweeps. That asymmetry is why an upper bound suffices and no lower bound is possible.
    function _validateBinding(bytes calldata message, uint256 minted) internal view {
        message.validateLength();
        if (message._getDestinationDomain() != LOCAL_DOMAIN) revert WrongDestination();
        if (message._getMintRecipient() != _toBytes32(address(this))) revert WrongRecipient();

        if (minted == 0) revert ZeroAmount();
        if (minted > usdc.balanceOf(address(this))) revert MissingBalance();
    }

    /// @dev Split the minted amount into the onward transfer and the relayer fee, then approve the PaymentContract.
    ///
    ///      Self-funded by necessity: unlike OutboundForwarder, this contract holds nothing before the mint, so the
    ///      fee cannot be pre-deposited — it comes out of `minted`.
    ///
    ///      `minted` is the BALANCE DELTA, never the burn body's `amount`. A CCTP v2 fast transfer deducts
    ///      feeExecuted on the destination, so the body's amount exceeds what actually arrived; splitting that
    ///      larger number would make the relayer's transferFrom revert for insufficient balance.
    ///
    ///      The delta also excludes any pre-existing balance, so dust from an earlier failure never rides along in
    ///      this message's accounting. That is intentional — per-message figures have to be exact for off-chain
    ///      reconciliation; dust leaves via recoverERC20.
    function _split(uint256 minted, uint256 feeAmount, uint256 maxFee) internal returns (uint256 transferAmount) {
        // feeAmount == minted would leave transferAmount == 0, which the relayer rejects with PaymentCannotBeZero;
        // catching it here also makes the subtraction below underflow-free.
        if (feeAmount >= minted) revert FeeExceedsMinted();
        unchecked {
            transferAmount = minted - feeAmount;
        }
        // CCTP v2 requires maxFee < amount (strict); it is deducted from the minted amount on the destination.
        if (maxFee >= transferAmount) revert InvalidMaxFee();

        // Exactly transferAmount + feeAmount == minted, which the relayer pulls in full → no residual allowance.
        // Cannot overflow: the sum reconstructs `minted`.
        usdc.forceApprove(address(paymentContract), minted);
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
