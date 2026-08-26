// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITransitForwarder} from "../interfaces/ITransitForwarder.sol";

/**
 * @title TransitBurnParams
 * @notice The amount-independent burn parameter, checked identically by TransitExecutor and TransitForwarder.
 *
 * @dev Both contracts check these, on purpose: the executor checks first so an obviously bad call does not burn the
 *      signature-verification gas, and the forwarder checks again because it does not trust an upgradeable executor.
 *      That needs two CALL SITES, not two definitions — a second copy of the CCTP v2 finality tiers is a drift
 *      source that nothing cross-checks, and drift makes one contract silently stricter than the other.
 *
 *      Note this describes the OUTBOUND (CCTP v2) burn, not the v1 message being received.
 *
 *      ⚠️ `feeAmount` was checked here until v2 and is now gone entirely — the route takes no relayer fee. The
 *      remaining check is amount-INDEPENDENT, which is what lets both contracts run it before knowing `minted`.
 *      `maxFee` is deliberately NOT checked here: it is bounded against the amount (maxFee < minted), so it belongs
 *      where the amount is known, in the forwarder.
 */
library TransitBurnParams {
    /// @dev The only finality thresholds CCTP v2's depositForBurn accepts.
    uint32 internal constant FINALITY_FAST = 1000;
    uint32 internal constant FINALITY_STANDARD = 2000;

    /// @dev Errors are ITransitForwarder's so the revert an operator sees is identical whichever layer refused —
    ///      the two contracts are one gate as far as tooling is concerned.
    function check(uint32 minFinalityThreshold) internal pure {
        if (minFinalityThreshold != FINALITY_FAST && minFinalityThreshold != FINALITY_STANDARD) {
            revert ITransitForwarder.InvalidFinalityThreshold();
        }
    }
}
