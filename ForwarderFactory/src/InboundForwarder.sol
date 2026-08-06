// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

import {IReceiver} from "./interfaces/IReceiver.sol";
import {IInboundForwarder} from "./interfaces/IInboundForwarder.sol";
import {CCTPV2Message} from "./libraries/CCTPV2Message.sol";

/**
 * @title InboundForwarder
 * @notice Per-route inbound conduit (logic impl behind a BeaconProxy), bound to the *final intent*
 *         (sender, destinationChainId, destinationReceiver). Receives a CCTP v2 message (minting USDC to this
 *         address), then emits IBCTransferRequested so the *synchronous* Injective event-hook performs the IBC
 *         MsgTransfer in the same transaction.
 *
 *         Routing model v2 (dynamic-route): the per-transfer IBC route (channelId, receiver, memo) is not proxy
 *         storage — it rides in the attestation-backed CCTP hookData and is decoded on-chain here (D-2/D-3). The
 *         address commits only to the stable final intent; the volatile channel and next-hop receiver (an
 *         intermediate under multi-hop/PFM, generally != destinationReceiver) travel in hookData. Destination
 *         integrity is therefore pure-trust on the source burner (D-1): destinationChainId/destinationReceiver do
 *         not appear in the CCTP message and cannot be cross-checked on-chain — the address commits to them, and the
 *         attestation prevents operator/third-party redirection of hookData.
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

    /// @dev The bank denom string, rendered once in the constructor and held as two immutable words. It is exactly
    ///      48 bytes ("erc20:" 6 + "0x" 2 + 40 hex chars), so it packs into bytes32 + bytes16 with no slack.
    ///      Solidity has no immutable string, but immutables live in the impl's bytecode, which delegatecall executes
    ///      — unlike storage, they are readable through the beacon proxy (`usdc` above relies on the same property).
    bytes32 private immutable _denomHi;
    bytes16 private immutable _denomLo;

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

        // Render the denom once here rather than on every mintAndRoute, then split it across the two immutable
        // words. The 48-byte length is load-bearing — it is what makes bytes32 ++ bytes16 hold the string exactly —
        // so assert it rather than trust it: a longer rendering would be silently truncated, and the resulting
        // denom would name a bank asset that does not exist on Injective. Constructor-only, so a wrong prefix or a
        // changed upstream hex format costs a failed deployment instead of stranded funds.
        bytes memory d = bytes(_erc20Denom(usdc_));
        if (d.length != 48) revert DenomLengthUnexpected();
        // Assembled byte by byte instead of with two mload's: this runs once at deploy time, so the bounds-checked
        // form costs nothing and keeps the contract free of any memory-safety argument.
        uint256 hi;
        uint256 lo;
        for (uint256 i = 0; i < 32; ++i) {
            hi |= uint256(uint8(d[i])) << (248 - i * 8);
        }
        for (uint256 i = 0; i < 16; ++i) {
            lo |= uint256(uint8(d[32 + i])) << (248 - i * 8);
        }
        _denomHi = bytes32(hi);
        _denomLo = bytes16(bytes32(lo)); // keeps the top 16 bytes, where the loop above placed them

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

    /// @notice Mint via CCTP then signal an IBC transfer. The synchronous event-hook consumes the emitted event
    ///         in the same tx; if the hook reverts, the whole tx reverts (mint rolls back, CCTP nonce unspent).
    function mintAndRoute(bytes calldata message, bytes calldata attestation) external onlyOperator nonReentrant {
        uint256 minted = _receiveAndValidate(message, attestation);

        // Per-transfer IBC route comes from the attestation-backed hookData (D-2), not proxy storage.
        (string memory channelId, string memory receiver, bytes memory memo) = _decodeHook(message._getHookData());
        // IBC timeout_timestamp is unix nanoseconds (uint64), computed on-chain rather than read from the hook.
        // block.timestamp * 1e9 ≈ 1.78e18 today, well under uint64 max (~1.84e19) until ~year 2554.
        uint64 timeout = uint64((block.timestamp + 1 days) * 1e9);

        // Field order/types MUST match IBCTransferRequested's listener ABI. sender = address(this): this forwarder is
        // the bank holder / MsgTransfer.sender, and the hook maps that address to the Injective bank account.
        emit IBCTransferRequested(
            PORT, channelId, DENOM(), minted, address(this), receiver, _bytesToHexString(memo), timeout
        );
        // Held USDC is left in place — the synchronous hook consumes it as the IBC MsgTransfer in this same tx.
    }

    /// @notice Mint then immediately refund to refundRecipient in the same tx. No event → the hook never fires,
    ///         so no IBC transfer occurs and there is nothing to revert.
    function mintAndRefund(bytes calldata message, bytes calldata attestation) external onlyOperator nonReentrant {
        uint256 minted = _receiveAndValidate(message, attestation);
        address to = refundRecipient;
        usdc.safeTransfer(to, minted);
        emit Refunded(message._getNonce(), to, minted, RefundKind.MintTime);
    }

    /// @notice Recover funds that returned here after a downstream IBC failure (timeout/error-ack). The IBC refund
    ///         arrives as a bank coin that is ERC20-paired on Injective, so it is recoverable as USDC (design G5).
    ///         Unrelated to any CCTP message, hence sourceNonce is 0. Reverts ZeroAmount on an empty balance, staying
    ///         consistent with refund(0).
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

    /// @dev G4 binding: the attestation-verified message must mint USDC to THIS forwarder, on the Injective domain,
    ///      from the committed source depositor. mintRecipient == address(this), itself CREATE2(salt(sender,
    ///      destinationChainId, destinationReceiver)), is what commits the final intent. The per-transfer IBC route is
    ///      deliberately not bound here — it rides in hookData (D-1). sourceDomain is excluded from the key (D-19).
    ///
    ///      ⚠️ Do NOT add a `burnToken == usdc` check: the burn body's `burnToken` is a SOURCE-domain address
    ///      (Ethereum/Base/Arbitrum USDC all differ), so comparing it against this chain's `usdc` would reject every
    ///      legitimate message. Token identity is enforced downstream and more strongly — `_receiveAndValidate`
    ///      reverts NothingMinted unless THIS chain's `usdc` balance actually grew.
    function _validateBinding(bytes calldata message) internal view {
        message.validateLength();
        if (message._getDestinationDomain() != INJECTIVE_DOMAIN) revert WrongDestination();
        if (message._getMintRecipient() != _toBytes32(address(this))) revert WrongRecipient();
        if (message._getMessageSender() != _toBytes32(sender)) revert WrongSender();
    }

    /// @dev Decode the attestation-backed hookData into the per-transfer IBC route (D-2/D-3). Schema is an envelope
    ///      abi.encode(address relayer, bytes inner), inner = abi.encode(string channelId, string receiver,
    ///      bytes memo): channelId = source IBC channel for the onward MsgTransfer, receiver = next-hop recipient
    ///      (an intermediate under multi-hop/PFM — generally NOT destinationReceiver), memo = forward/PFM payload.
    ///
    ///      `relayer` is a discovery tag for the off-chain transfer monitor, which filters CCTP burns by that address
    ///      because destinationCaller is the per-transfer forwarder, not the relayer EOA. On-chain it is read and
    ///      intentionally dropped — never used, validated, or stored.
    ///
    ///      A non-decodable envelope or inner tail reverts inside abi.decode, which reverts the whole tx and rolls the
    ///      mint back. Being attestation-backed, none of this is forgeable by the operator (D-22 ③).
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

    /// @dev Lowercase, 0x-prefixed hex of `data` (matches the IRIS hookData representation). Empty → "0x".
    ///      Deliberately separate from _erc20Denom's rendering: this is plain lowercase for memo passthrough, whereas
    ///      _erc20Denom applies the EIP-55 checksum that case-sensitive Injective denoms require.
    function _bytesToHexString(bytes memory data) private pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        uint256 n = data.length;
        bytes memory out = new bytes(2 + n * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < n; ++i) {
            uint8 b = uint8(data[i]);
            out[2 + i * 2] = hexSymbols[b >> 4];
            out[3 + i * 2] = hexSymbols[b & 0x0f];
        }
        return string(out);
    }

    function _toBytes32(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @notice Injective bank denom of the minted USDC: `erc20:<EIP-55 checksummed usdc address>`.
    /// @dev Derived from the immutable `usdc` rather than stored, so it is provably the token whose balance delta
    ///      `_receiveAndValidate` measured as `minted` — never the burn body's source-domain `burnToken`. The
    ///      rendering happens once in the constructor; this only reassembles the two immutable words.
    function DENOM() public view returns (string memory) {
        return string(abi.encodePacked(_denomHi, _denomLo));
    }

    /// @dev Renders `erc20:0x<addr>` with the EIP-55 mixed-case checksum. Injective derives this denom Go-side as
    ///      "erc20:" + common.Address.Hex(), which is EIP-55, and the bank module compares denoms byte-for-byte —
    ///      a lowercase rendering would name a denom that does not exist. `toChecksumHexString` arrived in
    ///      openzeppelin-contracts v5.1; before that bump this was hand-rolled here.
    ///      Constructor-only: the result is cached in `_denomHi`/`_denomLo`, so this never runs on a routing path.
    function _erc20Denom(address token) private pure returns (string memory) {
        return string.concat("erc20:", Strings.toChecksumHexString(token));
    }

    /// @notice Reject direct native transfers; this forwarder only handles ERC20/bank USDC.
    receive() external payable {
        revert NativeNotAccepted();
    }

    fallback() external payable {
        revert NativeNotAccepted();
    }
}
