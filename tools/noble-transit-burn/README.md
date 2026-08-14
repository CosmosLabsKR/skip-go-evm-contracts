# noble-transit-burn

Drives an end-to-end test of the transit path, in two commands:

| Command | Hop | What it does |
| --- | --- | --- |
| `burn` | Noble → Avalanche | Builds (and optionally broadcasts) the CCTP v1 `depositForBurnWithCaller` |
| `execute` | Avalanche → Injective | Fetches Circle's attestation and calls `TransitExecutor.executeTransit` |

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

## Layout

| File | Role |
| --- | --- |
| `src/index.ts` | Command dispatch (`burn` / `execute`) |
| `src/config.ts` | Env resolution and validation; holds the deployed-testnet defaults |
| `src/burn.ts` | Hop 1: assemble the Noble message, write `tx.json`, optionally sign and broadcast |
| `src/execute.ts` | Hop 2: preflight the message and call `executeTransit` / `executeRefund` |
| `src/predict.ts` | Reads the forwarder address from the live factory, cross-checks the executor's factory |
| `src/attestation.ts` | Polls Circle's Iris API for the attestation |
| `src/cctpMessage.ts` | Read-only mirror of the on-chain CCTP v1 message offsets |
| `src/proto.ts` | Hand-rolled codec for `circle.cctp.v1.MsgDepositForBurnWithCaller` (not in `cosmjs-types`) |
