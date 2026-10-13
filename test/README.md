# PixelCommons test contribution

The original unit, fuzz and state-model tests remain intact. This contribution adds two independent suites against `src/PixelCommons.sol`.

| Suite | Additional guarantees checked |
| --- | --- |
| `PixelCommonsAdversarial.t.sol` | A shared forwarding wallet has one cooldown across its users; nested transaction failures roll back pixel writes and deadlines; all 100 truncated paint calldata lengths are rejected; invalid attempts during cooldown do not postpone eligibility; every entry point rejects ETH without changing existing state; the complete canvas has canonical dynamic-bytes ABI encoding; distinct-pixel paints by independent callers commute. |
| `PixelCommonsEventsInvariant.t.sol` | Random sequences across three EOAs and two deployed wallets preserve agreement between the entire canvas, its event history and every caller's deadline. Successful same-color paints still emit an event and consume cooldown. Invalid full-width inputs, immediate second paints and value-bearing calls revert with no committed changes. |

The event oracle reconstructs pixels from `Painted` topics and data. It predicts eligibility from elapsed time since each caller's last accepted event, without reading the application's cooldown to decide whether a call should succeed. Each successful call must emit exactly one correctly encoded event; rejected calls must emit none. A deterministic handler test exercises every action and both contract wallets, so handler assertions are also checked outside random selection.

Inline configuration sets the new fuzz tests to 1,000 runs and the event invariant to 256 runs of depth 96, with handler reverts treated as failures. Inputs use bounded generation without discarded assumptions. The existing suite additionally exercises every pixel, all palette indices, first paints at timestamp zero, maximum invalid values, the 29/30-second boundary, factory deployment and the protected runtime restrictions.

PixelCommons has no asset accounting or custody operations. The ETH invariant covers attempts through its public interface, where rejected transfers must preserve caller balances. It does not claim that EVM-forced ETH or unsolicited token balances can be prevented.

Validation requires only the project's existing vendored forge-std and cached Solidity 0.8.26 compiler:

```sh
forge build --offline
forge test --offline
```

No fork, network access, FFI, environment mutation or external service is needed. Tests advance simulated chain time with `vm.warp`; they never wait for real time.
