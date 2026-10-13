// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PixelCommons} from "../src/PixelCommons.sol";

/// @dev Models success from elapsed time since the previous paint, independent of nextPaintAt.
contract PixelCommonsHandler is Test {
    PixelCommons public immutable canvas;
    address[4] public actors;
    bytes private expectedCanvas = new bytes(4096);
    mapping(address => bool) public hasPainted;
    mapping(address => uint256) public lastSuccess;
    uint256 public successfulPaints;
    uint256 public rejectedPaints;

    constructor(PixelCommons canvas_) {
        canvas = canvas_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("invariant painter ", vm.toString(i)));
        }
    }

    function attempt(uint256 actorSeed, uint256 xSeed, uint256 ySeed, uint256 colorSeed, uint256 timeSeed) public {
        address painter = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 x = bound(xSeed, 0, 70);
        uint256 y = bound(ySeed, 0, 70);
        uint256 color = bound(colorSeed, 0, 19);
        uint256 timestamp = vm.getBlockTimestamp() + bound(timeSeed, 0, 60);
        vm.warp(timestamp);

        bool expectedSuccess =
            x < 64 && y < 64 && color < 16 && (!hasPainted[painter] || timestamp - lastSuccess[painter] >= 30);
        vm.prank(painter);
        (bool success, bytes memory reason) = address(canvas).call(abi.encodeCall(PixelCommons.paint, (x, y, color)));
        assertEq(success, expectedSuccess, "paint result differs from model");

        if (expectedSuccess) {
            expectedCanvas[y * 64 + x] = bytes1(uint8(color));
            hasPainted[painter] = true;
            lastSuccess[painter] = timestamp;
            ++successfulPaints;
        } else {
            bytes memory expectedReason;
            if (x >= 64 || y >= 64) {
                expectedReason = abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, x, y);
            } else if (color >= 16) {
                expectedReason = abi.encodeWithSelector(PixelCommons.InvalidColor.selector, color);
            } else {
                expectedReason = abi.encodeWithSelector(PixelCommons.CooldownActive.selector, lastSuccess[painter] + 30);
            }
            assertEq(reason, expectedReason, "revert reason differs from model");
            ++rejectedPaints;
        }
    }

    function modelCanvas() external view returns (bytes memory) {
        return expectedCanvas;
    }
}

contract PixelCommonsInvariantTest is StdInvariant, Test {
    PixelCommons private canvas;
    PixelCommonsHandler private handler;

    function setUp() public {
        canvas = new PixelCommons();
        handler = new PixelCommonsHandler(canvas);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PixelCommonsHandler.attempt.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_CanvasAndWalletCooldownsMatchModel() public view {
        assertEq(canvas.getCanvas(), handler.modelCanvas());
        assertEq(canvas.getCanvas().length, 4096);
        for (uint256 i; i < 4; ++i) {
            address painter = handler.actors(i);
            uint256 expectedNext = handler.hasPainted(painter) ? handler.lastSuccess(painter) + 30 : 0;
            assertEq(canvas.nextPaintAt(painter), expectedNext);
        }
        assertEq(address(canvas).balance, 0);
    }
}
