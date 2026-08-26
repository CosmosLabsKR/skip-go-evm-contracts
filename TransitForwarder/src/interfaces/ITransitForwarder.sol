// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface for the TransitForwarder: a per-route conduit that re-burns the USDC a CCTP message minted to it,
<<<<<<< HEAD
 *      in the same transaction, toward the next hop engraved in its address. The burn is delegated to the
 *      PaymentContract (CCTPV2Relayer).
=======
 *      in the same transaction, toward the next hop engraved in its address. The burn goes straight to Circle's
 *      CCTP v2 TokenMessenger — this route charges no relayer fee, so there is nothing for a fee-collecting
 *      PaymentContract to do.
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
 *      new cases. New here: SelfLoop, FeeExceedsMinted, NotExecutor, MissingBalance. ReceiveFailed and NothingMinted
 *      moved to ITransitExecutor with the mint capability.
=======
 *      new cases. New here: SelfLoop, NotExecutor, MissingBalance. ReceiveFailed and NothingMinted moved to
 *      ITransitExecutor with the mint capability.
 *
 *      ⚠️ v2 REMOVED the relayer fee. `feeAmount` is gone from transferMinted and from TransitCompleted, and the
 *      ZeroFee / FeeExceedsMinted / UsdcMismatch errors with it. `maxFee` is UNAFFECTED and still required: it is
 *      Circle's DESTINATION-side fee cap, a CCTP v2 protocol parameter, not a relayer charge. Do not conflate them.
>>>>>>> sungrak/cctp-v2-contracts
 */
interface ITransitForwarder {
    // ── Errors ──
    error ZeroAddress();
<<<<<<< HEAD
    error UsdcMismatch(); // paymentContract.usdc() != usdc (blocks deploying a mismatched impl)
=======
>>>>>>> sungrak/cctp-v2-contracts
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
<<<<<<< HEAD
    error ZeroFee(); // CCTP v2 disallows feeAmount == 0
    error InvalidFinalityThreshold(); // must be 1000 (fast) or 2000 (standard)
    error FeeExceedsMinted(); // feeAmount >= minted — nothing would be left to transfer
    error InvalidMaxFee(); // CCTP v2 requires maxFee < transferAmount
    error ZeroAmount(); // recoverERC20(token, 0)

    // ── Events ──
    /// @notice One completed transit: mint (sourceNonce) → re-burn (transferAmount).
    /// @dev `minted` and `transferAmount` are BOTH carried on purpose — their difference is the relayer fee, and
    ///      leaving the off-chain side to reconstruct it by subtraction would make a single event unverifiable.
=======
    error InvalidFinalityThreshold(); // must be 1000 (fast) or 2000 (standard)
    error InvalidMaxFee(); // CCTP v2 requires maxFee < the burned amount
    error ZeroAmount(); // recoverERC20(token, 0)
    error EmptyDestinationCaller(); // an unrestricted next hop is the griefing path this design closes
    error AmountMismatch(); // `minted` != the amount the attested message says was burned

    // ── Events ──
    /// @notice One completed transit: mint (sourceNonce) → re-burn of the whole amount.
    /// @dev ⚠️ TOPIC0 CHANGED IN v2. `feeAmount` was removed, and with no fee `transferAmount` would only ever
    ///      restate `minted`, so the pair collapsed to one field. Off-chain consumers must add the new signature —
    ///      the v1 topic0 will never be emitted by a v2 impl.
    ///      `maxFee` stays: it is Circle's destination-side cap, not a fee taken here, and it is not observable
    ///      from `minted` alone.
>>>>>>> sungrak/cctp-v2-contracts
    ///      destinationDomain / mintRecipient are deliberately absent: they are engraved in this contract's CREATE2
    ///      address, reported by TransitForwarderDeployed, and readable via getRoute().
    event TransitCompleted(
        bytes32 indexed sourceNonce,
        uint256 minted,
<<<<<<< HEAD
        uint256 transferAmount,
        uint256 feeAmount,
=======
>>>>>>> sungrak/cctp-v2-contracts
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

<<<<<<< HEAD
    /// @notice Called by the executor after it has caused the mint. Re-burns `minted` along the engraved route.
    /// @param minted The executor's measured balance delta, bounded here by `0 < minted <= balanceOf(this)`.
    /// @param destinationCaller Restricts who may call receiveMessage on the next hop. Always set.
    /// @dev Argument order mirrors ICCTPV2Relayer: destinationCaller after minFinalityThreshold.
    function transferMinted(
        bytes calldata message,
        uint256 minted,
        uint256 feeAmount,
=======
    /// @notice Called by the executor after it has caused the mint. Re-burns ALL of `minted` along the engraved
    ///         route — nothing is withheld, because this route takes no fee.
    /// @param minted The executor's measured balance delta, bounded here by `0 < minted <= balanceOf(this)`.
    /// @param maxFee Circle's DESTINATION-side fee cap (CCTP v2 protocol parameter). Must be < minted.
    /// @param destinationCaller Restricts who may call receiveMessage on the next hop. Always set.
    /// @dev Argument order mirrors ITokenMessenger: destinationCaller last, after minFinalityThreshold.
    function transferMinted(
        bytes calldata message,
        uint256 minted,
>>>>>>> sungrak/cctp-v2-contracts
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
