# PaperRoute test coverage

Run from the repository root with the assignment's reproducible seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe230f1045fe7efc3bad9274c033f2b5f8666b45973104f501c1c10a5a64cc123 forge test
```

The fork suite reads `MAINNET_RPC_URL` with `vm.envOr` and passes it directly to
`vm.createSelectFork` at **Ethereum block 26,406,531**. It accepts either a URL or
socket path and skips only when that variable is empty. No endpoint is stored in
the tests. To run only the fork suite, use `forge test --match-contract PaperRouteForkTest -vv`.
To check the offline behavior, run `env -u MAINNET_RPC_URL forge test`.

The older repository README's `PAPER_ROUTE_FORK_URL` and block number do not apply
to this assignment's fork suite.

### RPC capability-probe compatibility

An RPC checker can report `eth_getAccountInfo` as unavailable even when all fork
tests pass. Foundry automatically probes that optional method when loading an
uncached account. If it fails, Foundry falls back to `eth_getBalance`,
`eth_getTransactionCount` and `eth_getCode`. This behavior is implemented in
[Foundry's fork backend](https://github.com/foundry-rs/foundry-core/blob/1534b92a9acaf436d5874e1808f9faeb7641718f/crates/fork-db/src/backend.rs#L418).
The tests do not issue the capability probe themselves. An unsupported-method
response alone does not establish that the provider lacks historical state.

To reproduce independently, run
`forge test --match-contract PaperRouteForkTest --no-storage-caching -vv`
with `MAINNET_RPC_URL` supplied by the runner. The supplied seed passed the full
suite: 97 reported tests, including all 17 fork tests, with no failures or skips;
all four invariants passed over 256 sequences and 16,384 handler calls.
`forge build` also succeeded. Foundry groups the four invariants into one reported
test in this run.

If an external checker rejects the optional probe despite successful fallback,
the relay/checker needs to distinguish that response from a failed state read,
or support the method using the same pinned-block account data. This cannot be
repaired in these Solidity tests. The suite retains the required fork, real
dependency code, pinned block and missing-variable-only skip condition; no RPC
errors are caught or converted into skipped tests.

| Requirement | Coverage |
| --- | --- |
| 5 IMD funds 40 editions; exact 0.1/0.025 payments | Baseline unit tests, full 40-day lifecycle in `PaperRouteAdversarial.t.sol`, lifecycle fuzzing, fork payment/refund test |
| Positive purchases, top-ups, zero, excess credit, insufficient funds/approval | Unit and fuzz tests, including maximum uint128 credit, arithmetic overflow, one-wei shortfalls, and failed-top-up rollback |
| One copy per issue; no older issue after a newer one | Duplicate/random-order batches, stale batches from competing couriers, actual earlier-issue delivery, and fork duplicate tests |
| 20-hour limit, including re-subscription | Just before/exactly at the boundary, cancellation and exhaustion followed by top-ups, timestamp fuzzing, and actual fork mints across two issues |
| Reverting and gas-burning receivers cannot charge credit or block a healthy reader | Offline and live mixed batches, all-failing batches, wrong selectors, large revert data, recovery/retry, and a healthy reader after 24 gas burners |
| Reentrancy through the receiver | All three mutating functions; both bubbling errors and swallowed errors. The recorder requires the guard's exact error and has funds/approval for the nested subscribe. Repeated in the fork suite |
| Contract and EIP-7702 subscribers receive at their own address | Accepting contract receivers, an accepting delegated test account, and an existing rejecting delegation on the pinned fork |
| Cancellation after partial use, even if the paper stops | Exact refunds, failed-refund rollback, receiver recovery, missing/reverting collection, closed paper, and real-token fork refunds |
| Closed and unknown issues | Unit/fuzz/fork rejection, zero and extreme IDs, publication/closing boundaries, and empty due pages |
| Mint gas must be fully forwarded; safe partial batches | Minimum forwarded gas expectation, no-call expectation below the gas floor, bounded-gas fuzzing, retry of a truncated batch, 25-reader batches using a 16,000,000 gas call budget |
| Donation isolation and value conservation | Donation fuzzing, live donation/refund test, and the independent stateful model |
| Subscriber enumeration and due pages | Swap-and-pop removal/readdition, source-page filtering, zero/overflow-sized pagination, invariant membership and uniqueness checks |
| Events | Baseline subscription, cancellation, delivery and all five skip reasons; explicit gas/callback failure events in added tests |

`PaperRouteFuzz.t.sol` sets 1,000 runs per property in source. The stateful suite
sets 256 sequences of 64 actions. Its handler randomly subscribes, cancels,
donates, publishes issues, advances time, delivers, changes receiver acceptance,
and attempts invalid purchases. Actors include EOAs, an accepting contract,
reverting/gas-burning contracts, a reentrancy probe, and a recoverable receiver.

The model predicts delivery recipients **before** calling PaperRoute. Credits,
purchases, refunds, copies, delivery history and courier payments are tracked
independently of the implementation's return values. The invariants check:

- holdings equal outstanding credit at 0.125 IMD plus donations;
- each actor's purchases equal remaining credit plus delivered copies plus refunds;
- actual vault and courier balances equal the copy prices and tips owed;
- active membership is complete and unique, with preserved delivery history;
- no collection allowance remains between calls.

At the end of each sequence every remaining subscriber cancels, leaving exactly
the donations in the contract. Setup includes successful subscriptions and a
delivery so these checks cannot pass merely because no value moved.

Offline integration uses the already-vendored IMDDaily source and token/receiver
mocks. Fault-injection tokens test rollback when token operations return false,
return nothing, or deliver an inexact amount. They do not imply that the real IMD
token has these behaviors.

Fork tests keep the real IMD, IMDDaily and vault code. `deal` supplies test-reader
token balances. Mint scenarios locally warp into the latest issue's window;
another test uses the original block timestamp. The 20-hour scenario impersonates
the publisher to create a subsequent issue **only in the local fork**, through the
real collection code. EIP-7702 acceptance tests install a designation only on a
synthetic reader. None of these changes broadcast or alter the source chain, and
the fork block never changes.
