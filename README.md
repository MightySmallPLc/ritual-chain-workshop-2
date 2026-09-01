# PredictMarket

An autonomous, self-resolving binary prediction market on [Ritual Chain](https://docs.ritualfoundation.org). (PLC version)

Create a market like _"Will ETH/USD be above $4,000 when this market resolves?"_, stake native
RITUAL on YES or NO, and watch it settle on its own. When the betting window closes, **no button
press and no backend cron** is needed. The Ritual Scheduler wakes the contract at a pre-determined
block; the contract calls the HTTP precompile to fetch the oracle URL, extracts one number with
the jq precompile, compares it to the target, and settles. Winners pull their proportional share.

---

## Architecture

```
                createMarket()                     ????????????????????????????
  user  ???????????????????????????????????????????  PredictMarket.sol        ?
  user  ???????????? bet(id, YES|NO) ??????????????                           ?
                                                  ?  markets, stakes, claims  ?
                                    schedule() ????                           ?
                                                  ????????????????????????????
   ???????????????????????????????                      ?             ?
   ? Scheduler  0x56e7?D58B      ?  onScheduledResolve  ?             ? deposit()
   ? system contract             ????????????????????????             ?
   ? fires at resolveBlock,      ?                        ??????????????????????????
   ? 3 attempts, 200 blocks apart?                        ? RitualWallet 0x532F?   ?
   ???????????????????????????????                        ? prepaid execution fees ?
                                                          ??????????????????????????
                       inside that one scheduled transaction:

  TEEServiceRegistry 0x9644?  ??pickServiceByCapability(HTTP_CALL)???  executor address
  HTTP precompile    0x0801   ??GET oracleUrl (in a TEE)?????????????  oracle endpoint
  jq  precompile     0x0803   ??jsonPath, outputType=uint256??????????  observed value
                                         ?
                                         ?
                       observed ? target  ?  Settled(YES|NO)
                       failed 3?          ?  Refunded (everyone reclaims stake)
```

---

## Design highlights

**Block-number deadlines only.** Human durations (in seconds) are converted to blocks at
deployment using the measured `blockTimeMs`. Nothing reads `block.timestamp`.

**Typed failure codes.** Every resolution attempt records an `AttemptCode` enum value
(`NoExecutor`, `HttpFailure`, `BadStatus`, `OracleError`, `BadValue`) alongside a string detail,
making failures indexable and auditable without parsing free-form strings.

**Separate claim paths.** Winners call `claimWinnings`; losers from failed markets call
`claimRefund`. The `cancelled` or `refunded` status covers both exhausted-retries and
creator-initiated cancellation.

**Paginated market reads.** `getMarkets(offset, limit)` returns a bounded page, suitable for
frontends and scripts that need discovery without an unpaginated full scan.

**A failed oracle read is never a NO.** HTTP errors, non-2xx responses, malformed envelopes,
executor error messages, and unparseable jq output are all recorded as failures, not outcomes.

---

## Prerequisites

- Node.js 20+ and `pnpm`
- A wallet with testnet RITUAL from <https://faucet.ritualfoundation.org>

## Setup

```bash
cd hardhat
pnpm install
cp .env.example .env
```

---

## Commands

```bash
npx hardhat test                                # local safety checks (no chain needed)
npx hardhat build                               # compile

npx hardhat run scripts/block-time.ts           # measure live block time
npx hardhat run scripts/deploy.ts               # deploy to Ritual Chain
PREDICT_ADDRESS=0x... npx hardhat run scripts/status.ts
PREDICT_ADDRESS=0x... npx hardhat run scripts/fund.ts
```

---

## Error Encountered and Solution

During initial development, the `_pickExecutor` function caused a Solidity compile error:

```text
DeclarationError: Variable already declared.
```

The issue was declaring `bool found` inline inside a tuple assignment when the variable was
already part of the tuple. Fixed by declaring `bool found;` on a separate line before the
tuple assignment `(executor, found) = ...`.

After the fix, the contract compiled cleanly and all four local tests pass.

---

## Reference

- Ritual Chain docs ? <https://docs.ritualfoundation.org>
- dApp skills ? <https://github.com/ritual-foundation/ritual-dapp-skills>
- Explorer ? <https://explorer.ritualfoundation.org> ? Faucet ? <https://faucet.ritualfoundation.org>
