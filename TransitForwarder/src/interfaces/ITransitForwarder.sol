// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the TransitForwarder: a per-route conduit that re-burns the USDC a CCTP message minted to it,
 *      in the same transaction, toward the next hop engraved in its address. The burn is delegated to the
 *      PaymentContract (CCTPV2Relayer).
 *
 *      It has NO mint capability — TransitExecutor calls receiveMessage, measures the delta and passes it in — so
 *      authority splits two ways:
 *
 *          executor → transferMinted / refundMinted   (push along the route, or hand back to `sender`)
 *          operator → recoverERC20 x2                 (sweep whatever is left to `sender`)
 *
 *      Least privilege: the executor cannot withdraw to `sender`, the operator cannot route funds anywhere, and
 *      neither can reach an arbitrary address — `sender` and `mintRecipient` are setter-less storage.
 *
 *      Error and event spellings match the sibling ForwarderFactory contracts so existing operator tooling needs no
 *      new cases. New here: SelfLoop, FeeExceedsMinted, NotExecutor, MissingBalance. ReceiveFailed and NothingMinted
 *      moved to ITransitExecutor with the mint capability.
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

    /// @notice refundMinted: minted and immediately returned to `sender`, never re-burned. Only one refund
    ///         situation exists here (mint time), so no discriminator is needed — post-transit sweeps are Recovered,
    ///         which may carry a token other than USDC.
    event Refunded(bytes32 indexed sourceNonce, address indexed to, uint256 amount);
    event Recovered(address indexed token, uint256 amount);

    // ── State-changing (executor-only) ──

    /// @notice Called by the executor after it has caused the mint. Re-burns `minted` along the engraved route.
    /// @param minted The executor's measured balance delta, bounded here by `0 < minted <= balanceOf(this)`.
    /// @param destinationCaller Restricts who may call receiveMessage on the next hop. Always set.
    /// @dev Argument order mirrors ICCTPV2Relayer: destinationCaller after minFinalityThreshold.
    function transferMinted(
        bytes calldata message,
        uint256 minted,
        uint256 feeAmount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 destinationCaller
    ) external;

    /// @notice Hand the just-minted funds back to `sender` instead of burning them onward.
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
    function version() external view returns (uint256);
}
