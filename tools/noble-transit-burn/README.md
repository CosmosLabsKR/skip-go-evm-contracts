# noble-transit-burn

Drives an end-to-end test of the transit path, in three commands:

| Command | Hop | What it does |
| --- | --- | --- |
| `burn` | Noble → Avalanche | Builds (and optionally broadcasts) the CCTP v1 `depositForBurnWithCaller` |
| `execute` | Avalanche → Injective | Fetches Circle's attestation and calls `TransitExecutor.executeTransit` |
| `mint` | on Injective | Fetches the onward attestation and calls `MessageTransmitterV2.receiveMessage` |

## What the transaction has to say

The transit is two CCTP hops:

```
Noble (domain 4)                Avalanche Fuji (domain 1)              Injective (domain 29)
  depositForBurnWithCaller  ──►  TransitExecutor.executeTransit   ──►   final recipient
    mintRecipient     = predicted TransitForwarder                       (ROUTE_MINT_RECIPIENT)
    destinationCaller = TransitExecutor
```

Two fields carry the whole design:

- **`destinationCaller` = TransitExecutor** (`0x015218cFdce7E8285DfFB16c457054EE2a441025`). Only that address may
  call `receiveMessage` for this message, so the mint and the onward re-burn can only happen in one transaction.
- **`mintRecipient` = the predicted TransitForwarder**, which does not exist yet. Its address is
  `CREATE2(factory, keccak256(abi.encode(sender, destinationDomain, mintRecipient)), beaconInitCodeHash)` — the route
  is engraved in the address, so committing to it here is what fixes the funds' final destination. The executor
  creates the forwarder on first use.

The prediction is read from the **live factory** (`getForwarderAddress`), never recomputed locally: the factory's
`beaconInitCodeHash` is frozen in its storage at initialize, and a local re-derivation from compiled bytecode can
drift from it. The tool also checks that `TransitExecutor.factory()` is the factory it predicted against — otherwise
the executor would reject the message with `RouteMismatch` after the funds are already burned.

## Setup

```bash
npm install
cp .env.example .env      # fill in ROUTE_MINT_RECIPIENT (required) and, to broadcast, NOBLE_PK
```

Defaults target **Fuji + Noble grand-1** with the currently deployed executor/factory. For mainnet, override
`NOBLE_RPC`, `NOBLE_CHAIN_ID`, `EVM_RPC` and the two contract addresses.

## Use

Both commands **simulate by default** and do nothing until you add the send flag.

```bash
# hop 1 — build only: prints the resolved route, predicted forwarder, writes an unsigned tx.json
npm run burn -- --usdc 1.5
npm run burn -- --usdc 1.5 --from noble1...    # when no key is configured
npm run burn -- --usdc 1.5 --broadcast         # sign with NOBLE_PK and send

# hop 2 — takes the Noble txhash printed by the burn
npm run execute -- --tx <nobleTxHash>                  # fetch attestation, simulate, do not send
npm run execute -- --tx <nobleTxHash> --wait 900 --send
npm run execute -- --tx <nobleTxHash> --refund --send  # mint and return to ROUTE_SENDER instead

# hop 3 — takes the Avalanche txhash printed by execute
npm run mint -- --tx <avalancheTxHash>                 # fetch attestation, simulate, do not send
npm run mint -- --tx <avalancheTxHash> --wait 900 --send
```

`--amount` takes uusdc (6 decimals) instead of whole USDC. `tx.json` is written in the shape `nobled tx sign` /
`nobled tx broadcast` accept, so the burn can be signed by a key this tool never sees. Run either command with
`--help` for its full option list.

### What `execute` checks before spending gas

Circle only attests a burn once it has finalised, so `--wait <seconds>` polls until the attestation appears; without
it a single attempt is made. The burn is never lost by waiting — re-run `execute --tx <hash>` whenever.

Before building the call, the message is parsed (`src/cctpMessage.ts`, a mirror of the on-chain `CCTPV1Message`
library) and checked against the configuration: version, source and destination domain, that it mints to the
predicted forwarder, that it pins the executor as `destinationCaller`, and that the fee fits inside the minted
amount. Every one of these is enforced on-chain too — this only turns an opaque revert that has already cost gas
into a readable error. The executor's `operator()` is read and compared against `EVM_PK` for the same reason:
`NotOperator` is the most common failure and the cheapest to catch.

If the amount cannot cover the onward fee, `--refund` calls `executeRefund` instead: it mints and returns everything
to `ROUTE_SENDER` with no second hop, and needs none of the fee parameters.

## Hop 3: the mint on Injective

Injective's EVM runs Circle's stock CCTP v2 contracts — `MessageTransmitterV2` at its usual cross-chain address,
reporting `localDomain() == 29` — so the last leg involves no contract of ours. `mint` fetches the attestation for
the message the forwarder emitted and calls `receiveMessage`; the USDC mints to the `mintRecipient` the forwarder
already committed to.

**The attestation comes from a different API than hops 1–2.** The mint leg is CCTP v1, so `burn`/`execute` read
`GET /v1/messages/4/{txHash}`. The onward leg is CCTP v2, which lives in a separate index:
`GET /v2/messages/1?transactionHash={txHash}`. The two do not overlap and both answer 404 for anything they do not
hold, so a v1 lookup of an Avalanche hash reports "Transaction hash not found" — not "pending". `mint` picks the v2
endpoint itself and, on a miss, says which coordinates have to line up rather than polling in silence.

Nothing about this hop is a choice. `mintRecipient`, `amount` and `destinationCaller` were burned into the message
on Avalanche and cannot be redirected afterwards, so every check `mint` runs is a comparison against what the
message already says:

- `destinationCaller` decides whether the command can act at all. It has to be an account you hold a key to **on
  Injective**. Naming an Avalanche contract (the forwarder, the executor) produces a message nobody can ever
  submit — the funds are burned on Avalanche and un-mintable on Injective, with no recovery path.
- `mintRecipient` is compared against `ROUTE_MINT_RECIPIENT` and a mismatch is fatal. The transmitter itself does
  not care who the recipient is: a drifted value would mint successfully, to someone else, permanently.
- `usedNonces` is read first, so a second run reports "already minted" instead of reverting after gas.

The signing key is `INJECTIVE_PK`, falling back to `EVM_PK` — on a single-operator deployment the operator is
usually also the pinned caller, and duplicating the key into two variables buys nothing.

## Layout

| File | Role |
| --- | --- |
| `src/index.ts` | Command dispatch (`burn` / `execute` / `mint`) |
| `src/config.ts` | Env resolution and validation; holds the deployed-testnet defaults |
| `src/burn.ts` | Hop 1: assemble the Noble message, write `tx.json`, optionally sign and broadcast |
| `src/execute.ts` | Hop 2: preflight the message and call `executeTransit` / `executeRefund` |
| `src/mint.ts` | Hop 3: preflight the onward message and call `receiveMessage` on Injective |
| `src/predict.ts` | Reads the forwarder address from the live factory, cross-checks the executor's factory |
| `src/attestation.ts` | Polls Circle's Iris API — v1 for the mint leg, v2 for the onward leg |
| `src/cctpMessage.ts` | Read-only mirror of the on-chain CCTP v1 message offsets |
| `src/cctpV2Message.ts` | The same for CCTP v2 — a different layout, not an extension of v1 |
| `src/proto.ts` | Hand-rolled codec for `circle.cctp.v1.MsgDepositForBurnWithCaller` (not in `cosmjs-types`) |
