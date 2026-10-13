// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PixelCommons} from "src/PixelCommons.sol";

/// @dev A shared forwarding wallet and an outer transaction that can roll back a paint.
contract AdversarialPaintingWallet {
    error AbortedPaint();

    function forward(PixelCommons canvas, uint256 x, uint256 y, uint256 color) external {
        canvas.paint(x, y, color);
    }

    function paintTwice(PixelCommons canvas, uint256 x, uint256 y, uint256 color) external {
        canvas.paint(x, y, color);
        canvas.paint(x, y, color);
    }

    function paintAndAbort(PixelCommons canvas, uint256 x, uint256 y, uint256 color) external {
        canvas.paint(x, y, color);
        revert AbortedPaint();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract PixelCommonsAdversarialTest is Test {
    PixelCommons private canvas;
    AdversarialPaintingWallet private wallet;
    address private alice;
    address private bob;

    function setUp() public {
        vm.warp(1000);
        alice = makeAddr("adversarial alice");
        bob = makeAddr("adversarial bob");
        canvas = new PixelCommons();
        wallet = new AdversarialPaintingWallet();

        // A nonempty starting state makes rejected-call atomicity assertions meaningful.
        vm.prank(bob);
        canvas.paint(31, 1, 15);
    }

    function test_ChangingUsersOfOneForwarderCannotBypassItsCooldown() public {
        vm.recordLogs();
        vm.prank(alice);
        wallet.forward(canvas, 32, 1, 7);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(wallet)))));
        bytes memory beforeAttempt = canvas.getCanvas();

        vm.expectRevert(abi.encodeWithSelector(PixelCommons.CooldownActive.selector, 1030));
        vm.prank(bob);
        wallet.forward(canvas, 63, 63, 8);
        assertEq(canvas.getCanvas(), beforeAttempt);
        assertEq(canvas.nextPaintAt(address(wallet)), 1030);
        assertEq(canvas.nextPaintAt(alice), 0);
        assertEq(canvas.nextPaintAt(bob), 1030);

        // Using a forwarding wallet does not consume the user's own direct-call allowance.
        vm.prank(alice);
        canvas.paint(63, 63, 8);
        assertEq(canvas.nextPaintAt(alice), 1030);
        vm.warp(1030);
        vm.prank(bob);
        wallet.forward(canvas, 32, 1, 0);
        assertEq(canvas.nextPaintAt(address(wallet)), 1060);
        assertEq(canvas.nextPaintAt(bob), 1030);
    }

    function test_SecondPaintRevertRollsBackFirstPaintAndNewCooldown() public {
        bytes memory beforeAttempt = canvas.getCanvas();

        vm.expectRevert(abi.encodeWithSelector(PixelCommons.CooldownActive.selector, 1030));
        wallet.paintTwice(canvas, 31, 1, 0);
        assertEq(canvas.getCanvas(), beforeAttempt);
        assertEq(canvas.nextPaintAt(address(wallet)), 0);
        assertEq(canvas.nextPaintAt(bob), 1030);

        // The reverted transaction must not prevent an immediate successful retry.
        wallet.forward(canvas, 31, 1, 0);
        assertEq(canvas.getCanvas(), new bytes(4096));
        assertEq(canvas.nextPaintAt(address(wallet)), 1030);
    }

    function test_OuterRevertRestoresPixelAndExpiredCooldown() public {
        wallet.forward(canvas, 32, 1, 6);
        vm.warp(1030);
        bytes memory beforeAttempt = canvas.getCanvas();

        vm.expectRevert(AdversarialPaintingWallet.AbortedPaint.selector);
        wallet.paintAndAbort(canvas, 32, 1, 0);
        assertEq(canvas.getCanvas(), beforeAttempt);
        assertEq(canvas.nextPaintAt(address(wallet)), 1030);

        wallet.forward(canvas, 32, 1, 0);
        beforeAttempt[96] = 0;
        assertEq(canvas.getCanvas(), beforeAttempt);
        assertEq(canvas.nextPaintAt(address(wallet)), 1060);
    }

    function test_EveryTruncatedPaintCalldataLengthRevertsAtomically() public {
        bytes memory complete = abi.encodeCall(PixelCommons.paint, (63, 63, 15));
        bytes memory beforeAttempt = canvas.getCanvas();
        assertEq(complete.length, 100);
        vm.recordLogs();

        // Includes empty calldata, incomplete selectors and every partially encoded word.
        for (uint256 length; length < complete.length; ++length) {
            bytes memory truncated = new bytes(length);
            for (uint256 i; i < length; ++i) {
                truncated[i] = complete[i];
            }
            vm.prank(alice);
            (bool success,) = address(canvas).call(truncated);
            assertFalse(success, "truncated paint was accepted");
            assertEq(canvas.nextPaintAt(alice), 0);
            assertEq(canvas.nextPaintAt(bob), 1030);
            assertEq(canvas.getCanvas(), beforeAttempt);
        }
        assertEq(vm.getRecordedLogs().length, 0);

        vm.prank(alice);
        canvas.paint(63, 63, 15);
        beforeAttempt[4095] = bytes1(uint8(15));
        assertEq(canvas.getCanvas(), beforeAttempt);
    }

    function test_InvalidAttemptsThroughoutCooldownDoNotDelayRecovery() public {
        vm.prank(alice);
        canvas.paint(63, 0, 1);
        bytes memory beforeAttempt = canvas.getCanvas();
        vm.recordLogs();

        for (uint256 elapsed = 1; elapsed < 30; ++elapsed) {
            vm.warp(1000 + elapsed);
            if (elapsed % 3 == 0) {
                vm.expectRevert(abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, 64, 0));
                vm.prank(alice);
                canvas.paint(64, 0, 1);
            } else if (elapsed % 3 == 1) {
                vm.expectRevert(abi.encodeWithSelector(PixelCommons.InvalidCoordinates.selector, 0, 64));
                vm.prank(alice);
                canvas.paint(0, 64, 1);
            } else {
                vm.expectRevert(abi.encodeWithSelector(PixelCommons.InvalidColor.selector, 16));
                vm.prank(alice);
                canvas.paint(0, 0, 16);
            }
            assertEq(canvas.nextPaintAt(alice), 1030);
            assertEq(canvas.getCanvas(), beforeAttempt);
        }
        assertEq(vm.getRecordedLogs().length, 0);

        vm.warp(1030);
        vm.prank(alice);
        canvas.paint(0, 1, 2);
        beforeAttempt[64] = bytes1(uint8(2));
        assertEq(canvas.getCanvas(), beforeAttempt);
        assertEq(canvas.nextPaintAt(alice), 1060);
    }

    function testFuzz_AllEntryPointsRejectEtherAndPreserveExistingState(uint96 valueSeed) public {
        uint256 value = bound(uint256(valueSeed), 1, type(uint96).max);
        vm.deal(alice, value);
        bytes memory beforeAttempt = canvas.getCanvas();
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(PixelCommons.paint, (0, 0, 1));
        calls[1] = abi.encodeCall(PixelCommons.getCanvas, ());
        calls[2] = abi.encodeWithSignature("nextPaintAt(address)", bob);
        calls[3] = abi.encodeWithSignature("WIDTH()");
        calls[4] = abi.encodeWithSignature("HEIGHT()");
        calls[5] = abi.encodeWithSignature("COLOR_COUNT()");
        calls[6] = abi.encodeWithSignature("PIXEL_COUNT()");
        calls[7] = abi.encodeWithSignature("COOLDOWN()");
        calls[8] = bytes("");
        calls[9] = hex"ffffffff";
        vm.recordLogs();

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool success,) = address(canvas).call{value: value}(calls[i]);
            assertFalse(success, "entry point accepted ETH");
            assertEq(alice.balance, value, "rejected call retained the caller's ETH");
            assertEq(address(canvas).balance, 0);
            assertEq(canvas.getCanvas(), beforeAttempt);
            assertEq(canvas.nextPaintAt(alice), 0);
            assertEq(canvas.nextPaintAt(bob), 1030);
        }
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_GetCanvasReturnsCanonicalABIAndIndependentMemoryCopies() public {
        vm.prank(alice);
        canvas.paint(0, 1, 3);
        wallet.forward(canvas, 63, 63, 11);
        bytes memory expected = new bytes(4096);
        expected[64] = bytes1(uint8(3));
        expected[95] = bytes1(uint8(15));
        expected[4095] = bytes1(uint8(11));

        vm.recordLogs();
        (bool success, bytes memory result) = address(canvas).staticcall(abi.encodeCall(PixelCommons.getCanvas, ()));
        assertTrue(success);
        // ABI offset + byte count + exactly 4,096 pixel bytes; there is no per-pixel padding.
        assertEq(result.length, 4160);
        assertEq(result, abi.encode(expected));
        bytes memory snapshot = abi.decode(result, (bytes));
        snapshot[64] = 0;
        snapshot[4095] = 0;
        assertEq(canvas.getCanvas(), expected);

        // Reads and elapsed time do not erase pixels or move stored deadlines.
        vm.warp(2000);
        assertEq(canvas.getCanvas(), expected);
        assertEq(canvas.nextPaintAt(alice), 1030);
        assertEq(canvas.nextPaintAt(bob), 1030);
        assertEq(canvas.nextPaintAt(address(wallet)), 1030);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testFuzz_IndependentPaintsOnDistinctPixelsCommute(
        uint256 firstPixelSeed,
        uint256 distanceSeed,
        uint256 firstColorSeed,
        uint256 secondColorSeed
    ) public {
        uint256 firstPixel = bound(firstPixelSeed, 0, 4095);
        // Construct distinct pixels directly, without discarding any fuzz cases.
        uint256 secondPixel = (firstPixel + bound(distanceSeed, 1, 4095)) % 4096;
        uint256 firstColor = bound(firstColorSeed, 1, 15);
        uint256 secondColor = bound(secondColorSeed, 1, 15);
        PixelCommons other = new PixelCommons();

        // Keep both canvases' initial states equal, including Bob's existing cooldown.
        vm.prank(bob);
        other.paint(31, 1, 15);
        vm.warp(1030);
        vm.prank(alice);
        canvas.paint(firstPixel % 64, firstPixel / 64, firstColor);
        vm.prank(bob);
        canvas.paint(secondPixel % 64, secondPixel / 64, secondColor);
        vm.prank(bob);
        other.paint(secondPixel % 64, secondPixel / 64, secondColor);
        vm.prank(alice);
        other.paint(firstPixel % 64, firstPixel / 64, firstColor);

        assertEq(canvas.getCanvas(), other.getCanvas(), "independent paint order changed the final canvas");
        assertEq(canvas.nextPaintAt(alice), other.nextPaintAt(alice));
        assertEq(canvas.nextPaintAt(bob), other.nextPaintAt(bob));
        assertEq(canvas.nextPaintAt(alice), 1060);
        assertEq(canvas.nextPaintAt(bob), 1060);
    }
}
