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
 *         (sender, destinationChainId, destinationReceiver). Receives a CCTP v2 message (mints USDC to this
 *         address via the MessageTransmitter), then emits IBCTransferRequested so the *synchronous* Injective
 *         event-hook performs the IBC MsgTransfer in the same transaction.
 *
 *         Routing model v2 (dynamic-route): the per-transfer IBC route (channelId, receiver, memo) is NOT proxy
 *         storage — it is carried in the attestation-backed CCTP hookData and decoded on-chain here (D-2/D-3).
 *         The forwarder address commits only to the stable final intent; the volatile IBC channel and the
 *         next-hop receiver (an intermediate in multi-hop/PFM, generally != destinationReceiver) ride in
 *         hookData. Destination integrity is therefore pure-trust on the source burner (D-1): destinationChainId/
 *         destinationReceiver are not present in the CCTP message and cannot be cross-checked on-chain; the
 *         address commits to them, and the attestation prevents operator/third-party redirection of hookData.
 * @dev config (usdc/transmitter/operator/INJECTIVE_DOMAIN) is impl immutable and shared by all instances
 *      (rotated in bulk via a beacon upgrade). Per-route values live in proxy storage. All entry points are
 *      operator-only and non-reentrant.
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
    address public refundRecipient; // refund sink (default = sender, D-20)

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
        refundRecipient = _sender; // default = sender (D-20) — refund reaches the source burn depositor
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    /// @notice Mint via CCTP then signal an IBC transfer. The synchronous event-hook consumes the emitted event
    ///         in the same tx; if the hook reverts, the whole tx reverts (mint rolls back, CCTP nonce unspent).
    function mintAndRoute(bytes calldata message, bytes calldata attestation) external onlyOperator nonReentrant {
        uint256 minted = _receiveAndValidate(message, attestation);

        // The per-transfer IBC route is decoded from the attestation-backed hookData (D-2 on-chain parse), not from
        // proxy storage. channelId/receiver are the next-hop IBC values; memo is the (PFM/forward) payload.
        (string memory channelId, string memory receiver, bytes memory memo) = _decodeHook(message._getHookData());
        // IBC timeout_timestamp is unix nanoseconds (uint64). Computed on-chain as now + 1 day, not taken from the
        // hook. block.timestamp(sec) * 1e9 ≈ 1.78e18 today, well under uint64 max (~1.84e19) until ~year 2554.
        uint64 timeout = uint64((block.timestamp + 1 days) * 1e9);

        // Field order/types MUST match IBCTransferRequested's listener ABI. sender = address(this) (this forwarder
        // is the bank holder / MsgTransfer.sender); the hook maps the address to the Injective bank account.
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

    /// @notice Recover funds that returned to this forwarder after a downstream IBC failure (timeout/error-ack).
    ///         The IBC refund arrives as a bank coin that is ERC20-paired on Injective, so it is recoverable here
    ///         as USDC (see design G5). Unrelated to any CCTP message, so sourceNonce is unknown (0).
    function refund(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (usdc.balanceOf(address(this)) < amount) revert MissingBalance();
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
    ///      from the committed source depositor. mintRecipient == address(this) + CREATE2(salt(sender,
    ///      destinationChainId, destinationReceiver)) is what commits the final intent. The per-transfer IBC route
    ///      (channelId/receiver) is NOT bound here — it rides in hookData (D-1 pure-trust). sourceDomain is excluded
    ///      from the key (D-19).
    function _validateBinding(bytes calldata message) internal view {
        message.validateLength();
        if (message._getDestinationDomain() != INJECTIVE_DOMAIN) revert WrongDestination();
        if (message._getMintRecipient() != _toBytes32(address(this))) revert WrongRecipient();
        if (message._getBurnToken() != _toBytes32(address(usdc))) revert WrongBurnToken();
        // Burn-body messageSender = source depositor (per-route identity), compared against the bound sender.
        if (message._getMessageSender() != _toBytes32(sender)) revert WrongSender();
    }

    /// @dev Decode the attestation-backed hookData into the per-transfer IBC route (D-2/D-3). Schema is
    ///      abi.encode(string channelId, string receiver, bytes memo): channelId = source IBC channel for the onward
    ///      MsgTransfer, receiver = next-hop recipient (an intermediate in multi-hop/PFM — generally NOT
    ///      destinationReceiver), memo = forward/PFM payload. Reverts EmptyHookRoute if channel or receiver is empty;
    ///      a non-decodable tail reverts inside abi.decode (whole tx reverts → mint rolls back). hookData is
    ///      attestation-backed, so the operator cannot forge these (D-22 ③); timeout is computed on-chain, not read here.
    function _decodeHook(bytes calldata hookData)
        internal
        pure
        returns (string memory channelId, string memory receiver, bytes memory memo)
    {
        (channelId, receiver, memo) = abi.decode(hookData, (string, string, bytes));
        if (bytes(channelId).length == 0 || bytes(receiver).length == 0) revert EmptyHookRoute();
    }

    /// @dev Lowercase, 0x-prefixed hex of `data` (matches the IRIS hookData hex representation). Empty → "0x".
    function _bytesToHexString(bytes memory data) private pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        uint256 n = data.length;
        bytes memory out = new bytes(2 + n * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < n; i++) {
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
    /// @dev Derived from the immutable `usdc` (readable through the BeaconProxy delegatecall) rather than stored,
    ///      so it is provably the same token validated in _validateBinding (burnToken == usdc) and cannot be
    ///      misconfigured. A view (not immutable) because Solidity has no immutable strings and a constructor-set
    ///      storage string would live in the impl, invisible through the proxy.
    function DENOM() public view returns (string memory) {
        return _erc20Denom(address(usdc));
    }

    /// @dev Renders `erc20:0x<addr>` with the EIP-55 mixed-case checksum (Injective bank denoms are case-sensitive).
    function _erc20Denom(address token) private pure returns (string memory) {
        bytes memory hexStr = bytes(Strings.toHexString(token)); // "0x" + 40 lowercase hex chars
        // EIP-55 hashes the 40 lowercase hex chars (without the "0x"). Copy them out to hash, then fix case in place.
        bytes memory lower40 = new bytes(40);
        for (uint256 i = 0; i < 40; i++) {
            lower40[i] = hexStr[2 + i];
        }
        bytes32 hash = keccak256(lower40);
        for (uint256 i = 0; i < 40; i++) {
            uint8 c = uint8(lower40[i]);
            if (c >= 0x61 && c <= 0x66) {
                // 'a'..'f': uppercase when the matching hash nibble >= 8 (EIP-55)
                uint8 hashByte = uint8(hash[i / 2]);
                uint8 nibble = (i % 2 == 0) ? (hashByte >> 4) : (hashByte & 0x0f);
                if (nibble >= 8) hexStr[2 + i] = bytes1(c - 0x20);
            }
        }
        return string.concat("erc20:", string(hexStr));
    }

    /// @notice Reject direct native transfers; this forwarder only handles ERC20/bank USDC.
    receive() external payable {
        revert NativeNotAccepted();
    }

    fallback() external payable {
        revert NativeNotAccepted();
    }
}
