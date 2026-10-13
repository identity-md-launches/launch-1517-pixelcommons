# PixelCommons

A permissionless 64 × 64 pixel canvas for Sepolia (chain ID **11155111**). This repository delivers the contract, offline-buildable Foundry tests, and its ABI for the contract implementation stage.

## Behavior

- Each pixel stores a palette index from 0 to 15. All 4,096 pixels start at 0 (white).
- Anyone, including a smart contract wallet, can call `paint(x, y, color)` with coordinates from 0 to 63 and a color from 0 to 15.
- A caller's first paint is immediately available. Each successful paint sets a 30-second cooldown for that `msg.sender`, across the entire canvas. The next paint is allowed exactly at the deadline.
- A paint may overwrite another caller's pixel. Transaction execution order determines the final color. Painting the existing color, including white, still emits an event and consumes the cooldown.
- Invalid or premature paints revert without modifying pixels or cooldowns and without emitting a `Painted` event.
- `getCanvas()` returns exactly 4,096 color bytes, ordered left to right and top to bottom. The offset of `(x, y)` is `y * 64 + x`.

There is no owner, administrator, fee, pause, upgrade, external call, dependency contract, token, or pool. Users pay ordinary network gas. There are no payable methods, receive/fallback handlers, deposits, withdrawals, approvals, or asset transfers.

## Build and test

Use Foundry with Solidity **0.8.26** installed in its compiler cache:

```sh
forge build
forge test
forge fmt --check
```

The root `foundry.toml` pins the compiler, Cancun EVM, optimizer settings, and `bytecode_hash = "none"`. The complete test dependency is vendored under `lib/forge-std/` as ordinary source files, with its revision and licenses. There are no runtime dependencies, submodules, package downloads, FFI, filesystem permissions, or test environment variables. No secrets or RPC connection are needed for local verification.

Tests cover initial state, every coordinate and palette index, complete snapshot ordering, packed storage boundaries, overwriting and repainting white, emitted events, invalid inputs up to `uint256.max`, cooldown boundaries, failed-call atomicity, independent wallets, contract wallets, ETH rejection, factory deployment, runtime size and forbidden opcodes. Fuzz tests vary inputs and time; a stateful invariant test compares arbitrary successful and rejected paint sequences against a separate model of the canvas and each wallet's last successful paint.

## Deployment parameters and handoff

| Parameter | Value |
| --- | --- |
| Application | `PixelCommons` |
| Source | `src/PixelCommons.sol` |
| Chain | Sepolia, `11155111` |
| Constructor arguments | None (`[]`) |
| Constructor value | `0` wei; constructor is nonpayable |
| Owner/admin arguments | None; the application has no privileged role |
| External dependencies | None |
| Initialization/funding | None |
| ABI | `docs/abi/PixelCommons.json` |

The nonpayable constructor allocates a white canvas. It makes no external calls, creates no other contracts, and does not inspect or grant privileges to its caller. Factory deployment therefore requires no preexisting contracts or post-deployment initialization. Each deployment is an independent canvas.

The separate manifest assignment supplies `launch.json` and its independent review. Publication, source attestation, admission, factory deployment, explorer verification, confirmed addresses, and the website/IPFS release belong to subsequent services. This implementation does not contain a manifest, broadcasting script, or invented deployment address. The deployment handoff must give the frontend the confirmed chain ID, `PixelCommons` address, deployment block, and this ABI.

## After launch

No owner settings, external service configuration, funding, keeper, or maintenance transaction is required. Nobody can pause, reset, or upgrade the canvas. The deployment service should verify the source and record the confirmed address and deployment block. A separate contributor must complete the independent review before release; local tests and the implementation review notes are not that review.

Frontend operators should:

- Use a Sepolia read RPC for wallet-free viewing and decode `getCanvas()` as bytes, without treating its hex text as individual pixels. Scale pixels with nearest-neighbor rendering and refresh every few seconds.
- Use a stable 16-color display palette with index 0 white. RGB values for indices 1–15 are a frontend presentation choice; the contract stores indices only.
- Submit zero-value `paint` calls from the connected wallet. Read `nextPaintAt(wallet)` and the latest chain timestamp for the countdown; use `max(0, nextPaintAt - timestamp)`. A local countdown is advisory; the mined block timestamp determines eligibility.
- Query `Painted` logs from the confirmed deployment block, sort by block/transaction/log order, and show the latest 20. Poll incrementally, de-duplicate logs, and reconcile chain reorganizations and pending/failed transactions. Use the snapshot as the current canvas; no on-chain history array is required.

## Assumptions and limitations

The cooldown is per calling address, not per human. Multiple addresses can paint independently; a forwarding contract shares its own cooldown among its users. There is no `tx.origin` restriction, signature relayer, identity check, censorship control, or Sybil resistance. The shared canvas is intentionally open to overwrites and transaction ordering effects. Block timestamps provide the requested approximate wall-clock interval; they are not a randomness source.

Normal ETH transfers and value-bearing function calls revert. Ethereum can still force ETH into any address, and arbitrary token contracts can credit unsolicited balances without consulting the recipient. PixelCommons never uses these assets and has no recovery authority, so forced ETH or accidentally sent tokens cannot be recovered. It cannot enforce an absolute zero balance against those mechanisms. Do not send it funds.

See [the ABI documentation](docs/ABI.md) for integration details and [implementation review notes](docs/SECURITY.md) for the security reasoning and review boundary.
