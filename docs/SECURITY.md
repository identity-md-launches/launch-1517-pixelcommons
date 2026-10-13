# Implementation review notes

These notes are the implementer's review, not an independent audit. The contract-stage handoff still requires an independent contributor to review the accepted source and the separate launch manifest. No deployment, publication, source attestation, or signed artifact is claimed by this repository.

## Scope and design checks

`src/PixelCommons.sol` is the only application contract. It has no imports, linked libraries, privileges, external calls, ETH/token transfers, signatures, oracle, pool, or proxy. No reentrancy path is exposed because painting and reading cannot call any external contract, including the caller. Test-only wallet/factory/handler contracts are not launch applications.

Input validation precedes arithmetic and storage writes. Bounds ensure `y * 64 + x` is within 0–4095 and the conversion to a color byte is lossless. Solidity checked arithmetic applies; Unix timestamps plus 30 fit comfortably within `uint256` for the target chain. The fixed-length private byte array has no resizing entry point. Packed storage writes update only the selected byte; exhaustive and fuzz snapshot comparisons cover neighboring pixels.

The cooldown belongs to `msg.sender`. Storing the next deadline permits the first paint even at timestamp zero, avoids a sentinel collision with the first successful timestamp, and enforces equality at the 30-second boundary. Failed calls revert all effects and emit no successful-paint event. Contract-wallet tests verify that a shared transaction origin does not couple otherwise independent callers.

The constructor has no parameters, external calls, code-size assumptions, dynamic ABI fields, created contracts, or caller-derived authorities. Its only effect is creating the initial zero-filled canvas. A local CREATE2 factory rehearsal on chain ID 11155111 checks deployment and immediate public use. A runtime scan mirrors the supplied deployment floor by checking the EIP-170 size limit and rejecting `DELEGATECALL`, `CALLCODE`, and `SELFDESTRUCT` outside PUSH data.

The no-custody requirement is implemented as no asset entry points or transfer logic. Forced ETH and unsolicited token credits remain possible at the EVM/token level and have no recovery path, as documented in the README. No owner was introduced to recover assets because the approved behavior explicitly excludes administrators.

## Verification

The delivered suite includes deterministic success/failure tests, input/time fuzzing, and a stateful reference model. The model records each caller's last successful timestamp and compares its independently computed eligibility with the contract's response, then checks the entire canvas and every modeled caller's deadline after each attempt. Handler reverts fail the invariant run.

Required validation is `forge build`, `forge test`, and `forge fmt --check` with the pinned Solidity 0.8.26 configuration. The test dependency is vendored with licenses. Tests neither consume nor modify environment variables and need no RPC, secrets, filesystem permission, or network.

Slither and Mythril were not run. The scope contains no financial primitives to which the supplied oracle, approval, vault, or token-decimal guidance would apply. There is no additional external dependency address to verify. Reviewers should focus on the public permission model, exact cooldown and boundary behavior, snapshot ordering, ABI compatibility, bytecode/deployment constraints, and the absence of unintended privileges in the eventual manifest.
