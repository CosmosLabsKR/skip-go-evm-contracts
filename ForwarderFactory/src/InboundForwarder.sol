// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

import {IReceiver} from "./interfaces/IReceiver.sol";
import {IInboundForwarder} from "./interfaces/IInboundForwarder.sol";
import {CCTPV2Message} from "./libraries/CCTPV2Message.sol";

/**
 * @title InboundForwarder
 * @notice Per-route inbound conduit (logic impl behind a BeaconProxy), bound to the *final intent*
 *         (sender, destinationChainId, destinationReceiver). Receives a CCTP v2 message, which mints USDC to this
 *         address.
 *
 *         ⚠️ INTERIM: the onward IBC leg is not implemented yet. mintAndRoute mints and then only EMITS the
 *         intended transfer — nothing moves the funds, so they stay on this forwarder until refund() sweeps them.
 *         The event exists so the team can observe routing end-to-end while Injective core finishes the ICS20
 *         precompile; once that ships, mintAndRoute calls it and performs the transfer for real. The earlier
 *         off-chain event-hook design is abandoned — nothing consumes this event on-chain.
 *
 *         Routing model v2: the address commits to the stable final intent; the volatile per-transfer route
 *         (channelId, receiver, memo) rides in attestation-backed hookData and is decoded here (D-2/D-3).
 *         destinationChainId/destinationReceiver never appear in the CCTP message, so destination integrity is
 *         pure-trust on the source burner (D-1) — the attestation only prevents hookData redirection.
 * @dev config (usdc/transmitter/operator/INJECTIVE_DOMAIN) is impl immutable and shared by all instances (rotated in
 *      bulk via a beacon upgrade). Per-route values live in proxy storage. All entry points are operator-only and
 *      non-reentrant.
 */
contract InboundForwarder is IInboundForwarder, Initializable {
    using SafeERC20 for IERC20;
    using CCTPV2Message for bytes;

    // ── deploy-fixed constants (build-time) ──
    /// @notice IBC port for the MsgTransfer. Standard ICS-20 port.
    string public constant PORT = "transfer";

    // ── config (impl immutable, shared by all instances; injected by Deployment) ──
    IERC20 public immutable usdc;
    IReceiver public immutable transmitter; // CCTP v2 MessageTransmitter
    address public immutable operator; // single trusted entity
    uint32 public immutable INJECTIVE_DOMAIN; // CCTP destination domain (binding check)

    // ── per-route (proxy storage; salt inputs = the stable final intent) ──
    address public sender; // source-EVM burn depositor (0x)        (route key #1)
    string public destinationChainId; // final destination chain id (route key #2 · address-engraved)
    string public destinationReceiver; // final-hop recipient        (route key #3 · address-engraved)
    /// @notice Refund sink for both mintAndRefund and refund(). Fixed to `sender` at initialize and never writable
    ///         afterwards (D-20), so refunds can only ever reach the source burn depositor.
    address public refundRecipient;

    uint256 private _reentrant;
    // append-only: add new state variables before __gap and shrink __gap (never prepend).
    uint256[48] private __gap;

    modifier nonReentrant() {
        if (_reentrant == 1) revert Reentrancy();
        _reentrant = 1;
        _;
        _reentrant = 0;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address usdc_, address transmitter_, address operator_, uint32 injectiveDomain_) {
        if (usdc_ == address(0) || transmitter_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        transmitter = IReceiver(transmitter_);
        operator = operator_;
        INJECTIVE_DOMAIN = injectiveDomain_;
        _disableInitializers();
    }

    /// @notice Called once by the factory right after deployment to inject the route identity values.
    function initialize(address _sender, string calldata _destinationChainId, string calldata _destinationReceiver)
        external
        initializer
    {
        if (_sender == address(0)) revert ZeroAddress();
        if (bytes(_destinationChainId).length == 0 || bytes(_destinationReceiver).length == 0) revert EmptyRoute();
        sender = _sender;
        destinationChainId = _destinationChainId;
        destinationReceiver = _destinationReceiver;
        refundRecipient = _sender; // fixed to sender (D-20); no setter exists
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    /// @notice Mint via CCTP and record the intended IBC transfer.
    /// @dev ⚠️ INTERIM — this does NOT transfer. The minted USDC stays on this forwarder and the CCTP nonce is spent
    ///      either way, so a route that is wrong (or a precompile that is still missing) leaves funds parked here
    ///      rather than reverting; refund() is the only exit until the ICS20 call lands. Emitting is deliberately
    ///      the last step so the future precompile call slots in ahead of it without reordering anything.
    function mintAndRoute(bytes calldata message, bytes calldata attestation) external onlyOperator nonReentrant {
        uint256 minted = _receiveAndValidate(message, attestation);

        // Per-transfer IBC route comes from the attestation-backed hookData (D-2), not proxy storage.
        (string memory channelId, string memory receiver, bytes memory memo) = _decodeHook(message._getHookData());
        // IBC timeout_timestamp is unix nanoseconds (uint64), computed on-chain rather than taken from hookData.
        // block.timestamp * 1e9 ≈ 1.78e18 today, well under uint64 max (~1.84e19) until ~year 2554.
        uint64 timeout = uint64((block.timestamp + 1 days) * 1e9);

        // Carries the values the ICS20 precompile call will use, though not its exact argument list:
        //   ICS20.transfer(sourcePort, sourceChannel, denom, amount, receiver, Height, timeoutTimestamp, memo)
        // differs in order from index 4 on, drops `sender` (the precompile derives it from the caller — which is
        // why address(this) is emitted here), and adds `Height timeoutHeight`, for which this timestamp-based
        // timeout means Height(0, 0). memo is lowercase 0x hex (the IRIS representation, "0x" when empty) — plain
        // hex, unlike DENOM()'s EIP-55 casing.
        emit IBCTransferRequested(
            PORT, channelId, DENOM(), minted, address(this), receiver, Strings.toHexString(memo), timeout
        );
    }

    /// @notice Mint and immediately return the funds to refundRecipient, skipping the route entirely.
    function mintAndRefund(bytes calldata message, bytes calldata attestation) external onlyOperator nonReentrant {
        uint256 minted = _receiveAndValidate(message, attestation);
        address to = refundRecipient;
        usdc.safeTransfer(to, minted);
        emit Refunded(message._getNonce(), to, minted, RefundKind.MintTime);
    }

    /// @notice Sweep the forwarder's whole USDC balance to refundRecipient. Today that is every mintAndRoute that
    ///         ever ran, since none of them move funds; once the ICS20 call lands it is instead the recovery path for
    ///         a downstream IBC failure, whose refund arrives as an ERC20-paired bank coin (G5). Not tied to a CCTP
    ///         message, hence sourceNonce 0.
    function refund() external onlyOperator nonReentrant {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal == 0) revert ZeroAmount();
        _refund(bal);
    }

    /// @notice Refund a specific amount.
    function refund(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (usdc.balanceOf(address(this)) < amount) revert MissingBalance();
        _refund(amount);
    }

    /// @dev Shared refund core — prevents drift between the two entry points.
    function _refund(uint256 amount) private {
        address to = refundRecipient;
        usdc.safeTransfer(to, amount);
        emit Refunded(bytes32(0), to, amount, RefundKind.PostRoute);
    }

    function getRoute() external view returns (address, string memory, string memory, address) {
        return (sender, destinationChainId, destinationReceiver, refundRecipient);
    }

    // ── internal (CCTP v2 message handling) ──

    /// @dev Validate the route binding, run receiveMessage, and return the minted balance delta.
    function _receiveAndValidate(bytes calldata message, bytes calldata attestation) internal returns (uint256 minted) {
        _validateBinding(message);
        uint256 balBefore = usdc.balanceOf(address(this));
        if (!transmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
        minted = usdc.balanceOf(address(this)) - balBefore;
        if (minted == 0) revert NothingMinted();
    }

    /// @dev G4 binding: the message must mint to THIS forwarder, on the Injective domain, from the committed source
    ///      depositor. mintRecipient == address(this) — itself CREATE2(salt(sender, destinationChainId,
    ///      destinationReceiver)) — is what commits the final intent. sourceDomain is excluded from the key (D-19).
    ///
    ///      ⚠️ Do NOT add a `burnToken == usdc` check. `burnToken` is a SOURCE-domain address, so it can never equal
    ///      this chain's `usdc` and the check would reject every legitimate message. Token identity is already
    ///      enforced more strongly downstream: `_receiveAndValidate` reverts unless THIS chain's balance grew.
    function _validateBinding(bytes calldata message) internal view {
        message.validateLength();
        if (message._getDestinationDomain() != INJECTIVE_DOMAIN) revert WrongDestination();
        if (message._getMintRecipient() != _toBytes32(address(this))) revert WrongRecipient();
        if (message._getMessageSender() != _toBytes32(sender)) revert WrongSender();
    }

    /// @dev Decode the attestation-backed hookData into the per-transfer IBC route (D-2/D-3):
    ///        abi.encode(address relayer, bytes inner), inner = abi.encode(string channelId, string receiver, bytes memo)
    ///      receiver is the NEXT hop (a PFM intermediate under multi-hop), generally not destinationReceiver.
    ///
    ///      `relayer` is a discovery tag the off-chain monitor filters burns by — read and dropped, never validated
    ///      or stored. Malformed input reverts inside abi.decode, rolling the mint back. Attestation-backed, so none
    ///      of it is forgeable by the operator (D-22 ③).
    function _decodeHook(bytes calldata hookData)
        internal
        pure
        returns (string memory channelId, string memory receiver, bytes memory memo)
    {
        // Strip the discovery envelope; `relayer` is monitor-only and deliberately dropped.
        (, bytes memory inner) = abi.decode(hookData, (address, bytes));
        (channelId, receiver, memo) = abi.decode(inner, (string, string, bytes));
        if (bytes(channelId).length == 0 || bytes(receiver).length == 0) revert EmptyHookRoute();
    }

    function _toBytes32(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @notice Injective bank denom of the minted USDC: `erc20:<EIP-55 checksummed usdc address>`.
    /// @dev Derived from the immutable `usdc`, so it is provably the token whose balance delta became `minted` —
    ///      never the burn body's source-domain `burnToken`.
    ///
    ///      EIP-55 casing is load-bearing: Injective builds this denom as "erc20:" + common.Address.Hex() and the
    ///      bank module compares byte-for-byte, so a lowercase rendering names an asset that does not exist.
    ///
    ///      Rendered per call, not cached in immutables — caching would save ~20k gas but mintAndRoute spends far
    ///      more hex-encoding the memo, and a fixed-width cache adds an invariant to funds-critical state.
    function DENOM() public view returns (string memory) {
        return string.concat("erc20:", Strings.toChecksumHexString(address(usdc)));
    }

    /// @notice Reject direct native transfers; this forwarder only handles ERC20/bank USDC.
    receive() external payable {
        revert NativeNotAccepted();
    }

    fallback() external payable {
        revert NativeNotAccepted();
    }
}
