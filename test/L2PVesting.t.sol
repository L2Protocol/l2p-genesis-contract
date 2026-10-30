// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import { L2PVesting } from "../contracts/L2PVesting.sol";

contract RejectingBeneficiary {
    receive() external payable {
        revert("no");
    }
}

contract L2PVestingTest is Test {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant TOTAL = 15_000_000_000 ether;

    event Released(address indexed beneficiary, uint256 amount);

    address internal beneficiary = address(0xBE11E);
    uint256 internal start;
    L2PVesting internal vesting;

    function setUp() public {
        vm.warp(1_800_000_000);
        start = block.timestamp;
        vesting = new L2PVesting(beneficiary, start, YEAR, 4 * YEAR);
        vm.deal(address(vesting), TOTAL);
    }

    function test_RejectsAZeroBeneficiary() public {
        vm.expectRevert(L2PVesting.InvalidBeneficiary.selector);
        new L2PVesting(address(0), start, YEAR, 4 * YEAR);
    }

    function test_RejectsAScheduleWithoutDurationOrWithTheCliffPastTheEnd() public {
        vm.expectRevert(L2PVesting.InvalidSchedule.selector);
        new L2PVesting(beneficiary, start, 0, 0);

        vm.expectRevert(L2PVesting.InvalidSchedule.selector);
        new L2PVesting(beneficiary, start, 4 * YEAR + 1, 4 * YEAR);
    }

    function test_NothingBeforeTheCliff() public {
        vm.warp(start + YEAR - 1);
        assertEq(vesting.releasable(), 0);

        vm.recordLogs();
        vesting.release();
        assertEq(vm.getRecordedLogs().length, 0, "a release of nothing should not log");
        assertEq(vesting.released(), 0);
        assertEq(beneficiary.balance, 0);
        assertEq(address(vesting).balance, TOTAL);
    }

    function test_AQuarterAtTheCliff() public {
        vm.warp(start + YEAR);
        assertEq(vesting.releasable(), TOTAL / 4);
    }

    function test_LinearAfterTheCliff() public {
        vm.warp(start + 2 * YEAR);
        assertEq(vesting.releasable(), TOTAL / 2);

        vm.warp(start + 3 * YEAR);
        assertEq(vesting.releasable(), TOTAL * 3 / 4);

        vm.warp(start + 2 * YEAR + 1 days);
        assertEq(vesting.vestedAmount(block.timestamp), TOTAL * (2 * YEAR + 1 days) / (4 * YEAR));
    }

    function test_EverythingAtTheEnd() public {
        vm.warp(start + 4 * YEAR);
        assertEq(vesting.releasable(), TOTAL);

        vm.warp(start + 10 * YEAR);
        assertEq(vesting.releasable(), TOTAL);
    }

    function test_AnyoneCanReleaseButOnlyTheBeneficiaryIsPaid() public {
        vm.warp(start + 2 * YEAR);

        vm.expectEmit(true, false, false, true, address(vesting));
        emit Released(beneficiary, TOTAL / 2);
        vm.prank(address(0xCAFE));
        vesting.release();

        assertEq(beneficiary.balance, TOTAL / 2);
        assertEq(address(0xCAFE).balance, 0);
        assertEq(vesting.released(), TOTAL / 2);
        assertEq(vesting.releasable(), 0);
    }

    function test_ASecondReleasePaysOnlyWhatVestedSince() public {
        vm.warp(start + 2 * YEAR);
        vesting.release();

        vm.warp(start + 3 * YEAR);
        assertEq(vesting.releasable(), TOTAL / 4);
        vesting.release();
        assertEq(beneficiary.balance, TOTAL * 3 / 4);

        vm.warp(start + 4 * YEAR);
        vesting.release();
        assertEq(beneficiary.balance, TOTAL);
        assertEq(address(vesting).balance, 0);
    }

    function test_FundsAddedLaterFollowTheSameSchedule() public {
        L2PVesting advisor = new L2PVesting(beneficiary, start, YEAR, 4 * YEAR);
        vm.deal(address(this), 1_000 ether);
        (bool ok,) = address(advisor).call{ value: 1_000 ether }("");
        assertTrue(ok);

        vm.warp(start + 2 * YEAR);
        advisor.release();
        assertEq(beneficiary.balance, 500 ether);

        // a top-up halfway is vested as if it had been there from the start
        vm.deal(address(this), 1_000 ether);
        (ok,) = address(advisor).call{ value: 1_000 ether }("");
        assertTrue(ok);
        assertEq(advisor.releasable(), 500 ether);
    }

    function test_ScheduleCannotBeChanged() public view {
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.start(), start);
        assertEq(vesting.cliffDuration(), YEAR);
        assertEq(vesting.duration(), 4 * YEAR);
    }

    function test_AFailedPaymentRevertsAndKeepsTheBooksStraight() public {
        RejectingBeneficiary rejecting = new RejectingBeneficiary();
        L2PVesting stuck = new L2PVesting(address(rejecting), start, YEAR, 4 * YEAR);
        vm.deal(address(stuck), 100 ether);

        vm.warp(start + 4 * YEAR);
        vm.expectRevert(L2PVesting.TransferFailed.selector);
        stuck.release();
        assertEq(stuck.released(), 0);
        assertEq(address(stuck).balance, 100 ether);
    }
}
