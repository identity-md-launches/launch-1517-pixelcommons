// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PixelCommons} from "src/PixelCommons.sol";

contract EventPaintingWallet {
    function forward(PixelCommons canvas, uint256 x, uint256 y, uint256 color) external {
        canvas.paint(x, y, color);
    }
}

/// @dev The oracle replays emitted events, rather than copying private canvas storage.
/// Eligibility is determined from elapsed time since a caller's last accepted event.
contract PixelCommonsEventsHandler is Test {
    PixelCommons public immutable canvas;
    address[5] public actors;
    mapping(address => bool) public seenPainter;
    mapping(address => uint256) public lastEventAt;
    uint256 public successfulPaints;
    uint256 public rejectedCalls;
    bytes private replayedCanvas = new bytes(4096);

    constructor(PixelCommons canvas_) {
        canvas = canvas_;
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string.concat("event oracle painter ", vm.toString(i)));
            vm.deal(actors[i], 1 ether);
        }
        actors[3] = address(new EventPaintingWallet());
        actors[4] = address(new EventPaintingWallet());
    }

    /// @dev Guarantees a reachable successful paint, including at the exact deadline.
    function paintAfterWait(uint256 actorSeed, uint256 pixelSeed, uint256 colorSeed, uint256 timeSeed) public {
        uint256 actorIndex = bound(actorSeed, 0, 4);
        _waitUntilReady(actorIndex, bound(timeSeed, 0, 60));
        assertTrue(_paint(actorIndex, bound(pixelSeed, 0, 4095), bound(colorSeed, 0, 15)));
    }

    /// @dev A valid paint followed by another valid-input paint in the same block.
    function burst(uint256 actorSeed, uint256 pixelSeed, uint256 colorSeed) public {
        uint256 actorIndex = bound(actorSeed, 0, 4);
        uint256 pixel = bound(pixelSeed, 0, 4095);
        uint256 color = bound(colorSeed, 0, 15);
        _waitUntilReady(actorIndex, 0);
        assertTrue(_paint(actorIndex, pixel, color));
        assertFalse(_paint(actorIndex, (pixel + 1) % 4096, (color + 1) % 16));
    }

    /// @dev Repainting an existing color must still produce an event and a new cooldown.
    function repaint(uint256 actorSeed, uint256 pixelSeed, uint256 timeSeed) public {
        uint256 actorIndex = bound(actorSeed, 0, 4);
        uint256 pixel = bound(pixelSeed, 0, 4095);
        uint256 color = uint8(replayedCanvas[pixel]);
        _waitUntilReady(actorIndex, bound(timeSeed, 0, 60));
        assertTrue(_paint(actorIndex, pixel, color));
    }

    /// @dev Exercise the whole invalid uint256 domain, rather than only small overshoots.
    function invalidInput(uint256 actorSeed, uint256 xSeed, uint256 ySeed, uint256 colorSeed, uint256 kindSeed) public {
        uint256 actorIndex = bound(actorSeed, 0, 4);
        uint256 kind = bound(kindSeed, 0, 2);
        uint256 x = kind == 0 ? bound(xSeed, 64, type(uint256).max) : bound(xSeed, 0, 63);
        uint256 y = kind == 1 ? bound(ySeed, 64, type(uint256).max) : bound(ySeed, 0, 63);
        uint256 color = kind == 2 ? bound(colorSeed, 16, type(uint256).max) : bound(colorSeed, 0, 15);
        bytes memory expectedReason = kind < 2
            ? abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, x, y)
            : abi.encodeWithSelector(PixelCommons.InvalidColor.selector, color);

        vm.recordLogs();
        (bool success, bytes memory reason) = _invoke(actorIndex, x, y, color);
        assertFalse(success, "invalid input was accepted");
        assertEq(reason, expectedReason);
        assertEq(vm.getRecordedLogs().length, 0, "rejected paint emitted a log");
        ++rejectedCalls;
    }

    /// @dev Send value to the application itself, never to a wallet's nonpayable wrapper.
    function paidCall(uint256 actorSeed, uint256 valueSeed, uint256 kindSeed) public {
        address painter = actors[bound(actorSeed, 0, 2)];
        uint256 value = bound(valueSeed, 1, 1 ether);
        uint256 kind = bound(kindSeed, 0, 4);
        bytes memory data;
        if (kind == 0) data = abi.encodeCall(PixelCommons.paint, (0, 0, 1));
        else if (kind == 1) data = abi.encodeCall(PixelCommons.getCanvas, ());
        else if (kind == 2) data = abi.encodeWithSignature("nextPaintAt(address)", painter);
        else if (kind == 3) data = bytes("");
        else data = hex"ffffffff";

        uint256 balanceBefore = painter.balance;
        vm.recordLogs();
        vm.prank(painter);
        (bool success,) = address(canvas).call{value: value}(data);
        assertFalse(success, "application accepted ETH");
        assertEq(painter.balance, balanceBefore, "rejected call retained ETH");
        assertEq(vm.getRecordedLogs().length, 0);
        ++rejectedCalls;
    }

    function eventCanvas() external view returns (bytes memory) {
        return replayedCanvas;
    }

    function _waitUntilReady(uint256 actorIndex, uint256 extraTime) private {
        address painter = actors[actorIndex];
        uint256 timestamp = vm.getBlockTimestamp();
        // Do not read nextPaintAt to decide when a successful call should be possible.
        if (seenPainter[painter] && timestamp < lastEventAt[painter] + 30) {
            timestamp = lastEventAt[painter] + 30;
        }
        vm.warp(timestamp + extraTime);
    }

    function _invoke(uint256 actorIndex, uint256 x, uint256 y, uint256 color)
        private
        returns (bool success, bytes memory result)
    {
        if (actorIndex < 3) {
            vm.prank(actors[actorIndex]);
            return address(canvas).call(abi.encodeCall(PixelCommons.paint, (x, y, color)));
        }
        return actors[actorIndex].call(abi.encodeCall(EventPaintingWallet.forward, (canvas, x, y, color)));
    }

    function _paint(uint256 actorIndex, uint256 pixel, uint256 color) private returns (bool success) {
        address painter = actors[actorIndex];
        uint256 timestamp = vm.getBlockTimestamp();
        bool eligible = !seenPainter[painter] || timestamp - lastEventAt[painter] >= 30;
        vm.recordLogs();
        bytes memory result;
        (success, result) = _invoke(actorIndex, pixel % 64, pixel / 64, color);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(success, eligible, "paint eligibility differs from elapsed time since its last event");

        if (!success) {
            assertEq(result, abi.encodeWithSelector(PixelCommons.CooldownActive.selector, lastEventAt[painter] + 30));
            assertEq(logs.length, 0, "cooldown rejection emitted a log");
            ++rejectedCalls;
            return false;
        }

        assertEq(result.length, 0);
        assertEq(logs.length, 1, "a successful paint must emit exactly one event");
        Vm.Log memory painted = logs[0];
        assertEq(painted.emitter, address(canvas));
        assertEq(painted.topics.length, 4);
        assertEq(painted.topics[0], keccak256("Painted(address,uint256,uint256,uint256)"));
        assertEq(painted.topics[1], bytes32(uint256(uint160(painter))));
        assertEq(uint256(painted.topics[2]), pixel % 64);
        assertEq(uint256(painted.topics[3]), pixel / 64);
        assertEq(painted.data, abi.encode(color));

        // Reconstruct the frontend's state from the event, not from the call arguments.
        uint256 eventPixel = uint256(painted.topics[3]) * 64 + uint256(painted.topics[2]);
        replayedCanvas[eventPixel] = bytes1(uint8(abi.decode(painted.data, (uint256))));
        seenPainter[painter] = true;
        lastEventAt[painter] = timestamp;
        ++successfulPaints;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PixelCommonsEventsInvariantTest is StdInvariant, Test {
    PixelCommons private canvas;
    PixelCommonsEventsHandler private handler;

    function setUp() public {
        vm.warp(0);
        canvas = new PixelCommons();
        handler = new PixelCommonsEventsHandler(canvas);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PixelCommonsEventsHandler.paintAfterWait.selector;
        selectors[1] = PixelCommonsEventsHandler.burst.selector;
        selectors[2] = PixelCommonsEventsHandler.repaint.selector;
        selectors[3] = PixelCommonsEventsHandler.invalidInput.selector;
        selectors[4] = PixelCommonsEventsHandler.paidCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Every accepted paint must be recoverable from the feed after any call sequence.
    function invariant_EventsReproduceTheWholeCanvasAndEveryCallerDeadline() public view {
        assertEq(canvas.getCanvas(), handler.eventCanvas(), "event history disagrees with canvas storage");
        assertEq(canvas.getCanvas().length, 4096);
        for (uint256 i; i < 5; ++i) {
            address painter = handler.actors(i);
            uint256 expectedDeadline = handler.seenPainter(painter) ? handler.lastEventAt(painter) + 30 : 0;
            assertEq(canvas.nextPaintAt(painter), expectedDeadline, "deadline disagrees with paint history");
            if (i < 3) assertEq(painter.balance, 1 ether, "paint attempts consumed value");
        }
        assertEq(address(canvas).balance, 0, "application retained value from its interface");
    }

    /// @dev Pins every handler path, including both real contract wallets, outside random selection.
    function test_HandlerExercisesEveryActionForEOAAndContractCallers() public {
        for (uint256 i; i < 5; ++i) {
            handler.paintAfterWait(i, 31 + i * 32, 15, 0);
            handler.burst(i, 63 + i * 64, 7);
            handler.invalidInput(i, type(uint256).max, type(uint256).max, type(uint256).max, i % 3);
            handler.repaint(i, 63 + i * 64, 0);
            handler.paidCall(i % 3, 1 wei, i);
            invariant_EventsReproduceTheWholeCanvasAndEveryCallerDeadline();
        }
        assertEq(handler.successfulPaints(), 15);
        assertEq(handler.rejectedCalls(), 15);
    }
}
