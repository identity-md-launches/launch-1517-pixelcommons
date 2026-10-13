// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PixelCommons} from "../src/PixelCommons.sol";

/// @dev Two such wallets let us distinguish msg.sender from a shared transaction origin.
contract PaintingWallet {
    function paint(PixelCommons canvas, uint256 x, uint256 y, uint256 color) external {
        canvas.paint(x, y, color);
    }
}

/// @dev Rehearses a zero-value factory deployment with no constructor arguments.
contract CanvasFactory {
    function deploy(bytes32 salt) external returns (PixelCommons) {
        return new PixelCommons{salt: salt}();
    }
}

contract PixelCommonsTest is Test {
    PixelCommons private canvas;
    address private alice;
    address private bob;

    event Painted(address indexed painter, uint256 indexed x, uint256 indexed y, uint256 color);

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        canvas = new PixelCommons();
    }

    function test_InitialCanvasIsExactly4096WhitePixels() public view {
        assertEq(canvas.getCanvas(), new bytes(4096));
        assertEq(canvas.WIDTH(), 64);
        assertEq(canvas.HEIGHT(), 64);
        assertEq(canvas.PIXEL_COUNT(), 4096);
        assertEq(canvas.COLOR_COUNT(), 16);
        assertEq(canvas.COOLDOWN(), 30);
        assertEq(canvas.nextPaintAt(alice), 0);
        assertEq(address(canvas).balance, 0);
    }

    function test_FirstPaintWorksAtTimestampZeroAndCannotRepeat() public {
        vm.warp(0);
        vm.prank(alice);
        canvas.paint(0, 0, 15);
        assertEq(uint8(canvas.getCanvas()[0]), 15);
        assertEq(canvas.nextPaintAt(alice), 30);

        vm.expectRevert(abi.encodeWithSelector(PixelCommons.CooldownActive.selector, 30));
        vm.prank(alice);
        canvas.paint(0, 0, 1);
    }

    function test_PaintStoresColorAndEmitsExactlyOneEvent() public {
        vm.warp(1000);
        vm.recordLogs();
        vm.prank(alice);
        canvas.paint(7, 13, 9);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(canvas));
        assertEq(logs[0].topics.length, 4);
        assertEq(logs[0].topics[0], keccak256("Painted(address,uint256,uint256,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[0].topics[2], bytes32(uint256(7)));
        assertEq(logs[0].topics[3], bytes32(uint256(13)));
        assertEq(logs[0].data, abi.encode(uint256(9)));
        assertEq(canvas.nextPaintAt(alice), 1030);

        bytes memory expected = new bytes(4096);
        expected[13 * 64 + 7] = bytes1(uint8(9));
        assertEq(canvas.getCanvas(), expected);
    }

    function test_CooldownRejectsAt29SecondsAndAllowsAt30Seconds() public {
        vm.warp(1000);
        vm.prank(alice);
        canvas.paint(0, 0, 1);
        bytes memory beforePaint = canvas.getCanvas();

        vm.warp(1029);
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(PixelCommons.CooldownActive.selector, 1030));
        vm.prank(alice);
        canvas.paint(1, 0, 2);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(canvas.getCanvas(), beforePaint);
        assertEq(canvas.nextPaintAt(alice), 1030);

        vm.warp(1030);
        vm.prank(alice);
        canvas.paint(1, 0, 2);
        assertEq(uint8(canvas.getCanvas()[1]), 2);
        assertEq(canvas.nextPaintAt(alice), 1060);
    }

    function test_CooldownIsPerWalletAndAnyoneCanOverwrite() public {
        vm.warp(1000);
        vm.prank(alice);
        canvas.paint(63, 63, 15);
        vm.prank(bob);
        canvas.paint(63, 63, 4);
        assertEq(uint8(canvas.getCanvas()[4095]), 4);
        assertEq(canvas.nextPaintAt(alice), 1030);
        assertEq(canvas.nextPaintAt(bob), 1030);

        vm.expectRevert(abi.encodeWithSelector(PixelCommons.CooldownActive.selector, 1030));
        vm.prank(alice);
        canvas.paint(0, 0, 3);
        assertEq(uint8(canvas.getCanvas()[0]), 0);
    }

    function test_SmartWalletsUseTheirOwnCooldownNotTransactionOrigin() public {
        PaintingWallet first = new PaintingWallet();
        PaintingWallet second = new PaintingWallet();
        vm.warp(1000);

        vm.expectEmit(true, true, true, true, address(canvas));
        emit Painted(address(first), 0, 0, 1);
        first.paint(canvas, 0, 0, 1);
        second.paint(canvas, 1, 0, 2);
        assertEq(canvas.nextPaintAt(address(first)), 1030);
        assertEq(canvas.nextPaintAt(address(second)), 1030);
        assertEq(canvas.nextPaintAt(address(this)), 0);

        vm.expectRevert(abi.encodeWithSelector(PixelCommons.CooldownActive.selector, 1030));
        first.paint(canvas, 2, 0, 3);
    }

    function test_PaintingSameColorStillEmitsAndConsumesCooldown() public {
        vm.warp(1000);
        vm.expectEmit(true, true, true, true, address(canvas));
        emit Painted(alice, 0, 0, 0);
        vm.prank(alice);
        canvas.paint(0, 0, 0);
        assertEq(canvas.getCanvas(), new bytes(4096));
        assertEq(canvas.nextPaintAt(alice), 1030);

        vm.expectRevert(abi.encodeWithSelector(PixelCommons.CooldownActive.selector, 1030));
        vm.prank(alice);
        canvas.paint(0, 1, 0);
    }

    function test_WhiteCanReplaceAnExistingColor() public {
        vm.prank(alice);
        canvas.paint(12, 34, 15);
        vm.prank(bob);
        canvas.paint(12, 34, 0);
        assertEq(canvas.getCanvas(), new bytes(4096));
    }

    function test_AllPixelsAndColorsRoundTripWithoutRowOrStorageWordBleed() public {
        bytes memory expected = new bytes(4096);
        for (uint256 y; y < 64; ++y) {
            for (uint256 x; x < 64; ++x) {
                // Unequal x/y weights distinguish transposition; exercise every palette index.
                uint256 color = (x + 3 * y) % 16;
                vm.warp(1000 + (y * 64 + x) * 30);
                vm.prank(alice);
                canvas.paint(x, y, color);
                expected[y * 64 + x] = bytes1(uint8(color));
            }
        }
        assertEq(canvas.getCanvas(), expected);

        // Check the neighboring bytes on both sides of a packed storage-word boundary.
        vm.prank(bob);
        canvas.paint(31, 0, 0);
        expected[31] = 0;
        assertEq(canvas.getCanvas(), expected);
    }

    function test_InvalidBoundaryAndMaximumInputs() public {
        _assertRejectedInput(64, 0, 0, abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, 64, 0));
        _assertRejectedInput(0, 64, 0, abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, 0, 64));
        _assertRejectedInput(0, 0, 16, abi.encodeWithSelector(PixelCommons.InvalidColor.selector, 16));
        _assertRejectedInput(
            type(uint256).max,
            0,
            0,
            abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, type(uint256).max, 0)
        );
        _assertRejectedInput(
            0,
            type(uint256).max,
            0,
            abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, 0, type(uint256).max)
        );
        _assertRejectedInput(
            0, 0, type(uint256).max, abi.encodeWithSelector(PixelCommons.InvalidColor.selector, type(uint256).max)
        );

        // Invalid attempts have not consumed this wallet's first paint.
        vm.prank(alice);
        canvas.paint(63, 63, 15);
        assertEq(uint8(canvas.getCanvas()[4095]), 15);
    }

    function test_RejectedInputDoesNotExtendExistingCooldown() public {
        vm.warp(1000);
        vm.prank(alice);
        canvas.paint(1, 1, 1);
        vm.warp(1030);
        bytes memory beforePaint = canvas.getCanvas();
        vm.expectRevert(abi.encodeWithSelector(PixelCommons.InvalidColor.selector, 16));
        vm.prank(alice);
        canvas.paint(1, 1, 16);
        assertEq(canvas.getCanvas(), beforePaint);
        assertEq(canvas.nextPaintAt(alice), 1030);

        vm.prank(alice);
        canvas.paint(1, 1, 2);
        assertEq(canvas.nextPaintAt(alice), 1060);
    }

    function test_RejectsETHAndUnknownCallsWithoutChangingState() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool plainTransfer,) = address(canvas).call{value: 1 wei}("");
        assertFalse(plainTransfer);
        vm.prank(alice);
        (bool paidPaint,) = address(canvas).call{value: 1 wei}(abi.encodeCall(PixelCommons.paint, (0, 0, 1)));
        assertFalse(paidPaint);
        vm.prank(alice);
        (bool unknownCall,) = address(canvas).call(hex"deadbeef");
        assertFalse(unknownCall);
        assertEq(address(canvas).balance, 0);
        assertEq(alice.balance, 1 ether);
        assertEq(canvas.nextPaintAt(alice), 0);
        assertEq(canvas.getCanvas(), new bytes(4096));
    }

    function test_FactoryDeploymentNeedsNoOwnerOrExternalDependency() public {
        vm.chainId(11155111);
        CanvasFactory factory = new CanvasFactory();
        PixelCommons deployed = factory.deploy(keccak256("PixelCommons deployment rehearsal"));
        assertEq(deployed.getCanvas(), new bytes(4096));
        assertEq(address(deployed).balance, 0);
        vm.prank(alice);
        deployed.paint(0, 0, 1);
        assertEq(uint8(deployed.getCanvas()[0]), 1);
    }

    function test_RuntimeSizeAndForbiddenOpcodes() public view {
        bytes memory code = address(canvas).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_PaintChangesOnlyTheSelectedPixel(uint256 x, uint256 y, uint256 color) public {
        x = bound(x, 0, 63);
        y = bound(y, 0, 63);
        color = bound(color, 0, 15);
        vm.prank(alice);
        canvas.paint(x, y, color);
        bytes memory expected = new bytes(4096);
        expected[y * 64 + x] = bytes1(uint8(color));
        assertEq(canvas.getCanvas(), expected);
    }

    function testFuzz_InvalidCoordinatesAreRejected(uint256 x, uint256 y, bool invalidX) public {
        x = invalidX ? bound(x, 64, type(uint256).max) : bound(x, 0, 63);
        y = invalidX ? bound(y, 0, 63) : bound(y, 64, type(uint256).max);
        _assertRejectedInput(x, y, 1, abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, x, y));
    }

    function testFuzz_InvalidColorIsRejected(uint256 color) public {
        color = bound(color, 16, type(uint256).max);
        _assertRejectedInput(0, 0, color, abi.encodeWithSelector(PixelCommons.InvalidColor.selector, color));
    }

    function testFuzz_CooldownUsesTimeSinceLastSuccessfulPaint(uint64 startTime, uint64 elapsed) public {
        vm.warp(startTime);
        vm.prank(alice);
        canvas.paint(0, 0, 1);
        uint256 secondTime = uint256(startTime) + uint256(elapsed);
        vm.warp(secondTime);
        if (elapsed < 30) {
            vm.expectRevert(abi.encodeWithSelector(PixelCommons.CooldownActive.selector, uint256(startTime) + 30));
            vm.prank(alice);
            canvas.paint(0, 0, 2);
            assertEq(canvas.nextPaintAt(alice), uint256(startTime) + 30);
            assertEq(uint8(canvas.getCanvas()[0]), 1);
        } else {
            vm.prank(alice);
            canvas.paint(0, 0, 2);
            assertEq(canvas.nextPaintAt(alice), secondTime + 30);
            assertEq(uint8(canvas.getCanvas()[0]), 2);
        }
    }

    function _assertRejectedInput(uint256 x, uint256 y, uint256 color, bytes memory expectedError) private {
        vm.recordLogs();
        vm.expectRevert(expectedError);
        vm.prank(alice);
        canvas.paint(x, y, color);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(canvas.nextPaintAt(alice), 0);
        assertEq(canvas.getCanvas(), new bytes(4096));
    }
}
