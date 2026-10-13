# PixelCommons ABI

The canonical ABI is [`abi/PixelCommons.json`](abi/PixelCommons.json), exported from `src/PixelCommons.sol` using the pinned Foundry configuration. To regenerate after an intentional interface change:

```sh
forge inspect src/PixelCommons.sol:PixelCommons abi --json > docs/abi/PixelCommons.json
```

## Constructor and functions

`constructor()` is nonpayable and takes no arguments. It creates an all-white canvas with no owner and no dependencies.

| Signature | Mutability | Result / behavior |
| --- | --- | --- |
| `paint(uint256 x, uint256 y, uint256 color)` | nonpayable | Sets one pixel and emits `Painted`. Bounds: x/y 0–63, color 0–15. Each caller waits 30 seconds between successful paints. |
| `getCanvas()` | view | `bytes`: exactly 4,096 bytes in row-major order; `(x,y)` is byte `y * 64 + x`. |
| `nextPaintAt(address painter)` | view | `uint256`: next allowed Unix timestamp in seconds, or zero for a caller that has never painted. |
| `WIDTH()` | view | `uint256`: 64 |
| `HEIGHT()` | view | `uint256`: 64 |
| `PIXEL_COUNT()` | view | `uint256`: 4096 |
| `COLOR_COUNT()` | view | `uint256`: 16 |
| `COOLDOWN()` | view | `uint256`: 30 seconds |

For a decoded byte buffer, `buffer[0]` is `(0,0)`, `buffer[63]` is `(63,0)`, `buffer[64]` is `(0,1)`, and `buffer[4095]` is `(63,63)`. Each byte is between `0x00` and `0x0f`, inclusive. These are color indices, not ASCII digits or packed pairs of colors. A hex-string representation has 8,192 hex digits after `0x`. Raw ABI return data also includes the standard dynamic-byte offset and length; use an ABI decoder before indexing it.

## Event

```solidity
event Painted(address indexed painter, uint256 indexed x, uint256 indexed y, uint256 color);
```

The event signature is `Painted(address,uint256,uint256,uint256)`. Topic 0 is its Keccak-256 hash; topics 1–3 encode painter, x, and y. The nonindexed data encodes color as one `uint256` word. There is exactly one event per successful call, including when the color is unchanged, and none on a revert. `painter` is the direct `msg.sender`, including when that sender is a smart contract wallet. Its block's timestamp plus 30 is that paint's new deadline.

## Errors and validation order

| Error | Meaning |
| --- | --- |
| `InvalidCoordinates(uint256 x, uint256 y)` | Either coordinate is at least 64. |
| `InvalidColor(uint256 color)` | The color is at least 16. |
| `CooldownActive(uint256 nextAllowedAt)` | The block timestamp is less than this caller's deadline. |

Validation occurs in the table's order. Inputs use `uint256` so out-of-range values are checked explicitly instead of being truncated. Clients should reject negative/noninteger UI inputs before ABI encoding. A valid call at exactly `nextAllowedAt` succeeds. Reverts leave state unchanged. Nonzero ETH is rejected by the nonpayable dispatcher; unknown selectors and empty-calldata transfers also revert.

There are no other state-changing functions, initializer, owner setter, asset recovery methods, batch painting, payable entry points, or upgrade interface.
