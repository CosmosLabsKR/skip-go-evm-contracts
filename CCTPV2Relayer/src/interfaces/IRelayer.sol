// SPDX-License-Identifier: Apache-2.0
/*
 * Copyright (c) 2022, Circle Internet Financial Limited.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
pragma solidity ^0.8.20;

/**
 * @title IRelayer
 * @notice Sends messages from source domain to destination domain (CCTP v2).
 * @dev v2 differs from v1: `sendMessage` takes `destinationCaller` and `minFinalityThreshold`
 * as standard parameters, returns nothing (no synchronous nonce), and `sendMessageWithCaller` /
 * `replaceMessage` are removed. The full message bytes are surfaced only via `MessageSent`.
 */
interface IRelayer {
    /**
     * @notice Emitted when a new message is dispatched.
     * @param message Raw bytes of the message (the nonce field is empty at send time and is
     * assigned by the off-chain attestation service).
     */
    event MessageSent(bytes message);

    /**
     * @notice Sends an outgoing message from the source domain.
     * @param destinationDomain Domain of destination chain
     * @param recipient Address of message recipient on destination domain as bytes32
     * @param destinationCaller caller on the destination domain, as bytes32 (bytes32(0) = any caller)
     * @param minFinalityThreshold the minimum finality at which the message should be attested to
     * @param messageBody Raw bytes content of message
     */
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes calldata messageBody
    ) external;
}
