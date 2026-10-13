// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PixelCommons
/// @notice A shared 64 by 64 canvas with one paint per caller every 30 seconds.
/// @dev No owner, fees, external calls, asset handling, or upgrade mechanism.
contract PixelCommons {
    uint256 public constant WIDTH = 64;
    uint256 public constant HEIGHT = 64;
    uint256 public constant COLOR_COUNT = 16;
    uint256 public constant PIXEL_COUNT = WIDTH * HEIGHT;
    uint256 public constant COOLDOWN = 30 seconds;

    /// @notice Coordinates must each be between 0 and 63 inclusive.
    error InvalidCoordinates(uint256 x, uint256 y);
    /// @notice Color indices must be between 0 and 15 inclusive.
    error InvalidColor(uint256 color);
    /// @notice The caller may paint again at this Unix timestamp (inclusive).
    error CooldownActive(uint256 nextAllowedAt);

    event Painted(address indexed painter, uint256 indexed x, uint256 indexed y, uint256 color);

    /// @notice Earliest Unix timestamp at which a caller can paint; zero if it has never painted.
    mapping(address painter => uint256 timestamp) public nextPaintAt;

    // Private so callers cannot resize the canvas. Each stored byte is one color index.
    bytes private _canvas;

    /// @notice Creates an all-white canvas. No configuration or funding is required.
    constructor() {
        _canvas = new bytes(PIXEL_COUNT);
    }

    /// @notice Paint a pixel. Even painting its existing color consumes the caller's cooldown.
    /// @param x Horizontal coordinate, from 0 through 63.
    /// @param y Vertical coordinate, from 0 through 63.
    /// @param color Palette index, from 0 through 15; zero is white.
    /// @dev Rate limiting uses msg.sender, including for smart contract wallets.
    function paint(uint256 x, uint256 y, uint256 color) external {
        if (x >= WIDTH || y >= HEIGHT) revert InvalidCoordinates(x, y);
        if (color >= COLOR_COUNT) revert InvalidColor(color);

        uint256 nextAllowedAt = nextPaintAt[msg.sender];
        // The cooldown deliberately follows chain time; it is not a randomness source.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < nextAllowedAt) revert CooldownActive(nextAllowedAt);

        nextPaintAt[msg.sender] = block.timestamp + COOLDOWN;
        // The bounds check above makes this conversion lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        _canvas[y * WIDTH + x] = bytes1(uint8(color));
        emit Painted(msg.sender, x, y, color);
    }

    /// @notice Returns exactly 4,096 bytes, one color index per byte, in row-major order.
    /// @dev Pixel (x, y) is at offset y * 64 + x. Row zero is the top row for display.
    function getCanvas() external view returns (bytes memory) {
        return _canvas;
    }
}
