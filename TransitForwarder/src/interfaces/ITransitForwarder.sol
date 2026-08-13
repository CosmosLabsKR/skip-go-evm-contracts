// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the TransitForwarder: a per-route conduit whose engraved next hop receives the USDC that a
 *      CCTP v2 message minted to it, re-burned **in the same transaction** and delegated to the PaymentContract
 *      (CCTPV2Relayer).
 *
 *      This contract has NO mint capability. The TransitExecutor calls receiveMessage (which mints here), measures
 *      the delta, and then calls transferMinted/refundMinted. Authority is split accordingly:
 *
 *          executor → transferMinted / transferMintedWithCaller / refundMinted   (push along the engraved route)
 *          operator → recoverERC20 ×2                                            (pull back to `sender`)
 *
 *      Least privilege: the executor can only push funds where the address already commits them and cannot withdraw
 *      to `sender`; the operator can only withdraw to `sender` and cannot route funds anywhere. Neither key, if
 *      leaked, can send funds to an arbitrary address — `sender` and `mintRecipient` are both setter-less storage.
 *
 *      Error and event spellings are deliberately kept identical to the sibling ForwarderFactory contracts
 *      (Inbound/Outbound) so the off-chain operator tooling that already decodes those reverts needs no new cases.
 *      Only SelfLoop, FeeExceedsMinted, NotExecutor and MissingBalance are new to this contract. ReceiveFailed and
 *      NothingMinted MOVED to ITransitExecutor along with the mint capability — same spelling, new emitter.
 */
interface ITransitForwarder {
    // ── Errors ──
    error ZeroAddress();
    error UsdcMismatch(); // paymentContract.usdc() != usdc (blocks deploying a mismatched impl)
    error EmptyMintRecipient(); // initialize: mintRecipient == bytes32(0)
    error SelfLoop(); // constructor: ALLOWED_DESTINATION_DOMAIN == LOCAL_DOMAIN — a config that routes to itself
    error UnsupportedDestination(); // initialize: destinationDomain != ALLOWED_DESTINATION_DOMAIN
    error NotOperator(); // recovery entry points
    error NotExecutor(); // transit entry points — see the split described above
    error Reentrancy();
    error NativeNotAccepted();
    error MissingBalance(); // executor reported a `minted` larger than this contract's USDC balance
    error WrongDestination(); // message.destinationDomain != LOCAL_DOMAIN
    error WrongRecipient(); // burn.mintRecipient != address(this)
    error ZeroFee(); // CCTP v2 disallows feeAmount == 0
    error InvalidFinalityThreshold(); // must be 1000 (fast) or 2000 (standard)
    error FeeExceedsMinted(); // feeAmount >= minted — nothing would be left to transfer
    error InvalidMaxFee(); // CCTP v2 requires maxFee < transferAmount
    error ZeroAmount(); // recoverERC20(token, 0)

    // ── Events ──
    /// @notice One completed transit: mint (sourceNonce) → re-burn (transferAmount).
    /// @dev `minted` and `transferAmount` are BOTH carried on purpose — their difference is the relayer fee, and
    ///      leaving the off-chain side to reconstruct it by subtraction would make a single event unverifiable.
    ///      destinationDomain / mintRecipient are deliberately absent: they are engraved in this contract's CREATE2
    ///      address, reported by TransitForwarderDeployed, and readable via getRoute().
    event TransitCompleted(
        bytes32 indexed sourceNonce,
        uint256 minted,
        uint256 transferAmount,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    );

    /// @notice refundMinted: minted and immediately returned to `sender`, never re-burned. There is only one refund
    ///         situation here (mint time), so unlike the inbound forwarder no RefundKind discriminator is needed —
    ///         post-transit sweeps are Recovered, which may carry a token other than USDC.
    event Refunded(bytes32 indexed sourceNonce, address indexed to, uint256 amount);
    event Recovered(address indexed token, uint256 amount);

    // ── State-changing (executor-only) ──

    /// @notice Called by the executor after it has caused the mint. Re-burns `minted` along the engraved route.
    /// @param minted Amount the executor measured as this contract's balance delta. Bounded here by
    ///        `0 < minted <= usdc.balanceOf(this)` — over-reporting cannot move more than this contract holds, and
    ///        under-reporting merely leaves dust for recoverERC20.
    function transferMinted(
        bytes calldata message,
        uint256 minted,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    /// @dev Argument order mirrors ICCTPV2Relayer: destinationCaller after minFinalityThreshold, before hookData.
    function transferMintedWithCaller(
        bytes calldata message,
        uint256 minted,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller,
        bytes calldata hookData
    ) external;

    function refundMinted(bytes calldata message, uint256 minted) external;

    // ── State-changing (operator-only) ──
    function recoverERC20(address token) external;
    function recoverERC20(address token, uint256 amount) external;

    // ── Views ──
    function sender() external view returns (address);
    function destinationDomain() external view returns (uint32);
    function mintRecipient() external view returns (bytes32);
    function executor() external view returns (address);
    function getRoute() external view returns (address, uint32, bytes32);
    /// @dev Bumped to 2 by the executor migration: three entry points were replaced, so this is an ABI generation
    ///      marker, not a cosmetic counter. The implementation is `pure`; `view` here is the compatible declaration.
    function version() external view returns (uint256);
}
