# Paper Route

A prepaid subscription to The IMD Daily on Ethereum mainnet. A reader pays 0.125 IMD an edition
(5 IMD for 40) and anyone may then deliver each day's issue: one copy is minted from The IMD Daily to
the subscriber for 0.1 IMD out of their credit, and the deliverer earns the remaining 0.025 IMD.

Paper Route is unofficial and is not run by The IMD Daily's publisher. It launches no token, no NFT
collection, no pool and no liquidity. The contract has no owner, no admin, no fee to its maker, no
pause and no upgrade, and needs no call after deployment.

- Contract: `src/PaperRoute.sol`, Solidity 0.8.26, non-upgradeable, nonpayable, no constructor arguments.
- ABI: `docs/abi/PaperRoute.json`.
- Tests: `test/` (local, with the real IMDDaily source as the stand-in) and `test/fork/` (Ethereum mainnet fork).

## Existing contracts it calls (constants, never changed)

| Name | Address | Role |
| --- | --- | --- |
| IMD (ERC-20, 18 decimals) | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | payment token |
| The IMD Daily (ERC-1155) | `0xB8FD2b7fb37cbf03A26B4c4688eD5ccE86C0a9c5` | the paper; `mint`, `isAvailable` |

Both are compile-time constants, so the constructor makes no external call and deploys on an empty
chain. The IMD Daily's vault (`0x3343692C3667852a1D4A7D8052c24862e6c523C0`) receives the 0.1 IMD a
copy through The IMD Daily's own `mint`; Paper Route never addresses it directly.

## Fixed numbers

| Constant | Value | Why |
| --- | --- | --- |
| `COPY_PRICE` | 0.1 IMD | The IMD Daily's `PRICE`, checked on the fork |
| `TIP` | 0.025 IMD | paid to whoever delivers a copy |
| `EDITION_PRICE` | 0.125 IMD | `COPY_PRICE + TIP`, what a subscriber pays per edition |
| `DELIVERY_INTERVAL` | 20 hours | one delivery per subscriber per 20 hours |
| `MINT_GAS` | 400,000 | gas forwarded to each `mint` attempt (chosen; see Gas) |

## Behaviour

### subscribe(uint256 editions)

Pulls `editions * 0.125 IMD` from the caller (who must have approved Paper Route for at least that
amount) and adds the editions to the caller's credit. Any positive number; calling again adds more.
The transfer is checked to the wei: a token that delivered less would revert. Emits `Subscribed`.

### cancel()

Refunds every unused edition at 0.125 IMD to the caller and ends the subscription. It touches only
the IMD token, never The IMD Daily, so it works whatever state the paper is in (reverting, stopped,
or without code). Reverts with `NoSubscription` when there is nothing to refund. The subscriber's
delivery history (last issue, last delivery time) is kept, so a later subscription still gets one copy
an issue. Emits `Cancelled`.

### deliver(uint256 issueId, address[] readers) returns (address[] delivered)

Anyone may call it. The issue must be open for minting (`isAvailable` on The IMD Daily), else it
reverts with `IssueNotOpen`; an unknown issue is not open. For each listed address, in order:

1. Not due? Skipped with a `Skipped` event: `NoCredit`, `AlreadyDelivered` (already had this issue or a
   later one from Paper Route; a duplicate in the list lands here), or `TooSoon` (last delivery less
   than 20 hours ago).
2. Less than `MINT_GAS` plus a margin left? `Skipped(GasAllowance)` for this address and the rest of
   the list is left for another call. The call does not revert.
3. Otherwise Paper Route approves The IMD Daily for exactly 0.1 IMD and calls
   `mint(issueId, 1, subscriber, block.timestamp)` with exactly `MINT_GAS`. On success one edition of
   credit is taken, the subscriber's last issue and last delivery time are set, and `Delivered` is
   emitted. If the mint reverts for any reason (a receiver that reverts, a receiver that needs more
   than the allowance, a 7702 account whose delegate rejects ERC-1155 copies, the paper refusing),
   The IMD Daily's own revert rolls back its payment and the copy: `Skipped(MintFailed)`, nothing
   charged, and the list goes on.

At the end the caller is paid `0.025 IMD * delivered.length` and any unused 0.1 IMD approval is reset
to zero. Returns the delivered subscribers in list order.

The 20-hour rule caps what a subscriber is charged if several issues are published in one day: one
copy per 20 hours, and never an issue older than the last one delivered.

### Views

| View | Returns |
| --- | --- |
| `editionsLeft(a)`, `lastIssue(a)`, `lastDeliveredAt(a)`, `subscriptionOf(a)` | a subscriber's record |
| `subscriberCount()`, `subscribers(offset, limit)` | the addresses with credit, paged |
| `due(issueId, offset, limit)` | those among that page a `deliver` call would serve now; empty if the issue is not open |
| `dueStatus(a, issueId)` | whether `a` is due and otherwise the `SkipReason`, without consulting the paper |
| `reservedEditions()`, `reservedBalance()` | all unused editions and their IMD value |
| `surplus()` | IMD held beyond what subscribers are owed |

`due` cannot know whether a contract receiver will accept the copy: simulate `deliver` before sending.

## Custody rule

A subscriber's IMD leaves the contract only three ways: 0.1 IMD to The IMD Daily for a copy minted to
that subscriber, 0.025 IMD to whoever delivered that copy, or a refund to that subscriber. Nobody
else can move it. Consequently `IMD.balanceOf(PaperRoute) >= reservedEditions * 0.125 IMD` always,
with equality when nothing was sent in outside `subscribe`. IMD sent in any other way is not counted,
is not refundable, and simply stays there (`surplus()` reports it). This is tested as an invariant
(`test/PaperRouteInvariant.t.sol`) with EOA, accepting, reverting and gas-burning subscribers,
donations, several issues over time, duplicates in lists and cancellations.

Reentrancy: all three entry points share one reentrancy guard. The ERC-1155 receiver hook runs
inside `mint`; a receiver that re-enters `subscribe`, `cancel` or `deliver` makes its own mint revert
and is skipped unchanged. A receiver that swallows the failed re-entry and accepts the copy is charged
exactly once (both tested).

## Gas

Measured with the real IMDDaily source: the first mint in a transaction costs about 145,000 gas and
each later one about 47,000 when the recipient is a plain wallet, plus whatever the recipient's
receiver hook uses. `MINT_GAS = 400,000` therefore leaves more than 250,000 gas for a contract or
7702 receiver's hook. A mint is attempted only when `MINT_GAS + MINT_GAS/63 + 150,001` gas remains,
so EIP-150 forwards the whole allowance and the tip payment and return still fit after a receiver
that burns everything.

How many subscribers fit one `deliver` under Ethereum's 16,777,216 gas limit:

| Case | Gas per listed address | Fit in one transaction |
| --- | --- | --- |
| worst case, every receiver burns its whole allowance | about 430,000 | 38 |
| ordinary wallets, all delivered | about 75,000 (first about 175,000) | about 200 |
| the website's batch of 25, even if all burn gas | under 11,000,000 total | always |

Set the transaction's gas limit from the simulation; `deliver` never reverts for lack of gas once past
its fixed overhead, it only cuts the list short.

## Running a delivery bot

1. Read `issueCount()` on The IMD Daily; the open issue, if any, is the latest id (each issue is open
   for 24 hours from publication; check `isAvailable(id)`).
2. Read `subscriberCount()` and page `due(id, offset, limit)` on Paper Route.
3. Simulate `deliver(id, list)` with `eth_call` from your address; the return value is who will be
   delivered and `Skipped` events say who will not. Drop addresses that come back `MintFailed` to
   save gas.
4. Send `deliver` with at most 25 addresses (the website's batch) or up to 38 if you accept the worst
   case above; you receive 0.025 IMD per delivered copy in the same transaction.

Nobody is obliged to deliver: subscribers with nobody delivering keep their credit and can cancel.

## Deployment parameters

- Launch kind: `evm_contracts`, one contract, Solidity name `PaperRoute`, `constructorArgs: []`.
- No owner or admin argument exists; `$owner` is not used anywhere. Nothing is callable by any
  privileged address, and the contract has no `receive` or `fallback`.
- `foundry.toml`: `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on with 200 runs,
  `bytecode_hash = "none"`. Runtime is about 5.8 KB, well under EIP-170.
- After launch: nothing to set and nothing to call. The contract is complete at deployment.

## Assumptions and operational responsibilities

- The IMD Daily's `mint` keeps pulling exactly `quantity * 0.1 IMD` from `msg.sender` and safe-minting
  to `recipient`, and `isAvailable(id)` keeps meaning "open for minting". Both are constants of a
  non-upgradeable contract and are verified on the fork. If the paper ever stops, deliveries stop and
  every subscriber can still `cancel()` in full.
- IMD is a plain ERC-20 without transfer fees or hooks (checked to the wei on every `subscribe`). If
  the token itself were paused, both `subscribe` and `cancel` would revert until it resumes; nothing
  in Paper Route can work around its own payment token.
- A subscriber that is a contract or a 7702 account must accept ERC-1155 copies
  (`onERC1155Received`), else every delivery to it is skipped and its credit stays refundable.
  Copies go to the subscriber's own address only; there is no "deliver to" option.
- Delivery depends on someone calling `deliver`. The tip is the only incentive; nobody runs a bot
  for the requester.
- IMD sent directly to the contract is lost to its sender by design (the brief: not counted, stays there).
- Timestamps: the 20-hour rule and the paper's 24-hour window use `block.timestamp`, which a builder
  can nudge by seconds, not hours.
- Tests passing are not a security audit. An independent adversarial review is a separate step of
  this workflow before deployment.

## Tests

```
forge build
forge test
forge fmt --check
```

Local tests (`test/PaperRoute.t.sol`, `test/PaperRouteInvariant.t.sol`) etch the vendored real
IMDDaily source at its mainnet address and a plain ERC-20 at IMD's, so they run offline. They cover
payments to the wei, one copy an issue, the 20-hour boundary, reverting and gas-burning receivers
inside a batch, re-entrancy from the receiver, refund after partial use, closed and unknown issues,
a gas-starved call, the stopped paper, and the holdings invariant.

Fork tests (`test/fork/PaperRouteFork.t.sol`) run against the real IMD and The IMD Daily at block
26,406,400, warped into issue 23's mint window. They are skipped unless an archive RPC for Ethereum
mainnet is given:

```
PAPER_ROUTE_FORK_URL=https://<your mainnet archive rpc> forge test --match-path 'test/fork/*'
```

They include a live EIP-7702 account whose delegate rejects ERC-1155 copies (the forge default
"alice" address, delegated on mainnet), which is skipped unchanged exactly as the rules require.

Dependencies are vendored as ordinary files: OpenZeppelin Contracts v5.4.0 (`lib/openzeppelin-contracts`)
and forge-std v1.11.0 (`lib/forge-std`). No submodules.
