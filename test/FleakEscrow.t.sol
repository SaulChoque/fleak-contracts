// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/FleakEscrow.sol";

contract FleakEscrowTest is Test {
    FleakEscrow private escrow;
    address private constant ORACLE = address(0x0A11CE);
    address private alice = address(0xA1);
    address private bob = address(0xB0B);
    address private carol = address(0xCA);

    function setUp() external {
        escrow = new FleakEscrow(ORACLE);
    }

    function testCreateFlakeStoresConfig() external {
        address[] memory expected = new address[](2);
        expected[0] = alice;
        expected[1] = bob;

        vm.prank(alice);
        escrow.createFlake(1, expected, 500, address(0), address(0));

        FleakEscrow.FlakeView memory viewData = escrow.getFlake(1);
        assertEq(viewData.creator, alice);
        assertEq(uint8(viewData.state), uint8(FleakEscrow.State.Active));
        assertEq(viewData.feeBps, 500);
        assertEq(viewData.feeRecipient, address(this));
        assertEq(viewData.currentStake, 0);

        (address[] memory participants,,) = escrow.getParticipants(1);
        assertEq(participants.length, 2);
        assertEq(participants[0], alice);
        assertEq(participants[1], bob);
    }

    function testStakeAddsFundsAndParticipant() external {
        address[] memory expected = new address[](0);
        vm.prank(alice);
        escrow.createFlake(2, expected, 0, address(0), address(0));

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        escrow.stake{value: 0.4 ether}(2, address(0));

        assertEq(escrow.stakeOf(2, bob), 0.4 ether);
        FleakEscrow.FlakeView memory viewData = escrow.getFlake(2);
        assertEq(viewData.currentStake, 0.4 ether);
        assertEq(viewData.lifetimeStake, 0.4 ether);

        (address[] memory participants,,) = escrow.getParticipants(2);
        assertEq(participants.length, 1);
        assertEq(participants[0], bob);
    }

    function testResolveFlakePaysWinnerAndFee() external {
        address[] memory expected = new address[](0);
        vm.prank(alice);
        escrow.createFlake(3, expected, 500, address(0), address(0));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.stake{value: 0.6 ether}(3, address(0));

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        escrow.stake{value: 0.4 ether}(3, address(0));

        uint256 winnerPre = carol.balance;
        uint256 ownerPre = address(this).balance;

        vm.prank(ORACLE);
        escrow.resolveFlake(3, carol);

        uint256 expectedFee = (1 ether * 500) / 10_000;
        uint256 expectedPayout = 1 ether - expectedFee;

        assertEq(carol.balance, winnerPre + expectedPayout);
        assertEq(address(this).balance, ownerPre + expectedFee);

        FleakEscrow.FlakeView memory viewData = escrow.getFlake(3);
        assertEq(uint8(viewData.state), uint8(FleakEscrow.State.Resolved));
        assertEq(viewData.distributedPayout, expectedPayout);
        assertEq(viewData.distributedFee, expectedFee);
        assertEq(viewData.currentStake, 0);
    }

    function testOnlyOracleCanResolve() external {
        address[] memory expected = new address[](0);
        vm.prank(alice);
        escrow.createFlake(4, expected, 0, address(0), address(0));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.stake{value: 0.2 ether}(4, address(0));

        vm.expectRevert("NotOracle");
        escrow.resolveFlake(4, alice);
    }

    function testRefundFlow() external {
        address[] memory expected = new address[](0);
        vm.prank(alice);
        escrow.createFlake(5, expected, 0, address(0), address(0));

        vm.deal(bob, 1 ether);
        vm.deal(alice, 1 ether);

        vm.prank(bob);
        escrow.stake{value: 0.3 ether}(5, address(0));
        vm.prank(alice);
        escrow.stake{value: 0.5 ether}(5, address(0));

        vm.prank(ORACLE);
        escrow.openRefunds(5);

        uint256 bobPre = bob.balance;
        vm.prank(bob);
        uint256 refunded = escrow.withdrawRefund(5);
        assertEq(refunded, 0.3 ether);
        assertEq(bob.balance, bobPre + 0.3 ether);

        vm.expectRevert("Refunded");
        vm.prank(bob);
        escrow.withdrawRefund(5);

        FleakEscrow.FlakeView memory viewData = escrow.getFlake(5);
        assertEq(uint8(viewData.state), uint8(FleakEscrow.State.Refunding));
        assertEq(viewData.refundedAmount, 0.3 ether);
        assertEq(viewData.currentStake, 0.5 ether);
    }

    function testUpdateFeeRecipient() external {
        address[] memory expected = new address[](0);
        vm.prank(alice);
        escrow.createFlake(6, expected, 0, address(0), address(0));

        address newRecipient = address(0x123);
        escrow.updateFlakeFeeRecipient(6, newRecipient);

        FleakEscrow.FlakeView memory viewData = escrow.getFlake(6);
        assertEq(viewData.feeRecipient, newRecipient);
    }

    receive() external payable {}
}
