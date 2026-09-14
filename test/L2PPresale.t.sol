// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import { L2PPresale } from "../contracts/L2PPresale.sol";

contract L2PPresaleTest is Test {
    address internal constant PRESALE_ADDR = 0x0000000000000000000000000000000000003000;
    address internal owner = address(0x1B272dC2635CFBE67116434CdBfD7525f8F5196F);
    address internal alice = address(0xA11CE);

    uint256 internal constant ONE_YEAR_OF_BLOCKS = 365 days * 1000 / 1500;

    L2PPresale internal presale;

    event PresaleStarted(uint256 startBlock, uint256 endBlock);

    // Places the runtime bytecode and the owner slot the way genesis.json does: no constructor
    // runs, the owner is storage slot 0.
    function setUp() public {
        vm.etch(PRESALE_ADDR, vm.getDeployedCode("L2PPresale.sol:L2PPresale"));
        vm.store(PRESALE_ADDR, bytes32(uint256(0)), bytes32(uint256(uint160(owner))));
        presale = L2PPresale(PRESALE_ADDR);
        vm.roll(1000);
    }

    function _start() internal {
        vm.prank(owner);
        presale.start();
    }

    /*----------------- schedule constants -----------------*/

    function test_OwnerComesFromGenesisStorage() public view {
        assertEq(presale.owner(), owner);
        assertEq(presale.startBlock(), 0);
    }

    function test_FiveErasCoverExactlyOneYearOfBlocks() public view {
        assertEq(presale.ERA_COUNT(), 5);
        assertEq(presale.TOTAL_BLOCKS(), ONE_YEAR_OF_BLOCKS);
        assertEq(presale.TOTAL_BLOCKS(), 21_024_000);
        assertEq(presale.ERA_BLOCKS(), 4_204_800);
        assertEq(presale.ERA_BLOCKS() * presale.ERA_COUNT(), presale.TOTAL_BLOCKS());
    }

    function test_PricesAndSupplyMatchTheSchedule() public view {
        uint256[5] memory prices = presale.eraPrices();
        assertEq(prices[0], 10_000); // $0.0001
        assertEq(prices[1], 11_000); // $0.00011
        assertEq(prices[2], 12_000); // $0.00012
        assertEq(prices[3], 13_000); // $0.00013
        assertEq(prices[4], 14_000); // $0.00014
        assertEq(presale.PRICE_DECIMALS(), 8);
        assertEq(presale.ERA_SUPPLY(), 1_500_000_000 ether);
        assertEq(presale.PRESALE_SUPPLY(), 7_500_000_000 ether);
    }

    function test_EraRaisesTheExpectedUsd() public view {
        L2PPresale.Era[5] memory eras = presale.eras();
        uint256[5] memory expectedUsd = [uint256(150_000), 165_000, 180_000, 195_000, 210_000];
        for (uint256 i; i < 5; ++i) {
            assertEq(eras[i].priceUsd * eras[i].supply / 1 ether / 1e8, expectedUsd[i]);
        }
    }

    /*----------------- before start -----------------*/

    function test_NotStartedViewsRevert() public {
        assertEq(uint256(presale.status()), uint256(L2PPresale.Status.NotStarted));
        assertEq(presale.endBlock(), 0);

        bytes memory notActive =
            abi.encodeWithSelector(L2PPresale.PresaleNotActive.selector, L2PPresale.Status.NotStarted);
        vm.expectRevert(notActive);
        presale.currentPriceUsd();
        vm.expectRevert(notActive);
        presale.currentEraIndex();
        vm.expectRevert(notActive);
        presale.currentEra();
        vm.expectRevert(notActive);
        presale.blocksUntilNextEra();

        vm.expectRevert(L2PPresale.NotStarted.selector);
        presale.eraIndexAt(block.number);
    }

    function test_ErasAreListedWithoutBlockRangeBeforeStart() public view {
        L2PPresale.Era[5] memory eras = presale.eras();
        for (uint256 i; i < 5; ++i) {
            assertEq(eras[i].startBlock, 0);
            assertEq(eras[i].endBlock, 0);
            assertEq(eras[i].priceUsd, 10_000 + i * 1_000);
            assertEq(eras[i].supply, 1_500_000_000 ether);
        }
    }

    function test_EraIndexOutOfRangeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(L2PPresale.InvalidEra.selector, 5));
        presale.era(5);
    }

    function test_OnlyOwnerCanStart() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        presale.start();
        assertEq(presale.startBlock(), 0);
    }

    function test_OwnerCannotRenounceBeforeStart() public {
        vm.prank(owner);
        vm.expectRevert(L2PPresale.NotStarted.selector);
        presale.renounceOwnership();
        assertEq(presale.owner(), owner);
    }

    /*----------------- start -----------------*/

    function test_StartSetsTheClockToTheCurrentBlock() public {
        vm.expectEmit(true, true, true, true, PRESALE_ADDR);
        emit PresaleStarted(1000, 1000 + ONE_YEAR_OF_BLOCKS - 1);
        _start();

        assertEq(presale.startBlock(), 1000);
        assertEq(presale.endBlock(), 1000 + ONE_YEAR_OF_BLOCKS - 1);
        assertEq(uint256(presale.status()), uint256(L2PPresale.Status.Active));
        assertEq(presale.currentEraIndex(), 0);
        assertEq(presale.currentPriceUsd(), 10_000);
        assertEq(presale.blocksUntilNextEra(), presale.ERA_BLOCKS());
    }

    function test_StartOnlyOnce() public {
        _start();
        vm.prank(owner);
        vm.expectRevert(L2PPresale.AlreadyStarted.selector);
        presale.start();
    }

    function test_OwnerCanRenounceAfterStart() public {
        _start();
        vm.prank(owner);
        presale.renounceOwnership();
        assertEq(presale.owner(), address(0));
        assertEq(presale.currentPriceUsd(), 10_000);
    }

    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        presale.transferOwnership(alice);
        assertEq(presale.owner(), owner);
        assertEq(presale.pendingOwner(), alice);

        vm.prank(alice);
        presale.acceptOwnership();
        assertEq(presale.owner(), alice);

        vm.prank(alice);
        presale.start();
        assertEq(presale.startBlock(), block.number);
    }

    /*----------------- era boundaries -----------------*/

    function test_ErasAreConsecutiveAndCoverTheWholePresale() public {
        _start();
        L2PPresale.Era[5] memory eras = presale.eras();
        uint256 eraBlocks = presale.ERA_BLOCKS();

        assertEq(eras[0].startBlock, presale.startBlock());
        for (uint256 i; i < 5; ++i) {
            assertEq(eras[i].endBlock - eras[i].startBlock + 1, eraBlocks);
            if (i > 0) assertEq(eras[i].startBlock, eras[i - 1].endBlock + 1);
        }
        assertEq(eras[4].endBlock, presale.endBlock());
    }

    function test_EraSwitchesExactlyAtTheBoundary() public {
        _start();
        uint256 eraBlocks = presale.ERA_BLOCKS();

        for (uint256 i; i < 5; ++i) {
            uint256 eraStart = 1000 + i * eraBlocks;

            vm.roll(eraStart);
            assertEq(presale.currentEraIndex(), i);
            assertEq(presale.currentPriceUsd(), 10_000 + i * 1_000);
            assertEq(presale.blocksUntilNextEra(), eraBlocks);

            vm.roll(eraStart + eraBlocks - 1);
            assertEq(presale.currentEraIndex(), i);
            assertEq(presale.currentPriceUsd(), 10_000 + i * 1_000);
            assertEq(presale.blocksUntilNextEra(), 1);

            L2PPresale.Era memory current = presale.currentEra();
            assertEq(current.startBlock, eraStart);
            assertEq(current.endBlock, eraStart + eraBlocks - 1);
            assertEq(current.priceUsd, 10_000 + i * 1_000);
        }
    }

    function test_BlocksUntilNextEraCountsDown() public {
        _start();
        uint256 eraBlocks = presale.ERA_BLOCKS();

        vm.roll(1000 + 12_345);
        assertEq(presale.blocksUntilNextEra(), eraBlocks - 12_345);

        vm.roll(1000 + eraBlocks + 7);
        assertEq(presale.currentEraIndex(), 1);
        assertEq(presale.blocksUntilNextEra(), eraBlocks - 7);
    }

    function test_EraIndexAtAnyBlockInThePresale() public {
        _start();
        uint256 eraBlocks = presale.ERA_BLOCKS();

        assertEq(presale.eraIndexAt(1000), 0);
        assertEq(presale.eraIndexAt(1000 + eraBlocks - 1), 0);
        assertEq(presale.eraIndexAt(1000 + eraBlocks), 1);
        assertEq(presale.eraIndexAt(1000 + 3 * eraBlocks + 100), 3);
        assertEq(presale.eraIndexAt(presale.endBlock()), 4);

        vm.expectRevert(abi.encodeWithSelector(L2PPresale.BlockOutsidePresale.selector, 999));
        presale.eraIndexAt(999);
        uint256 afterEnd = presale.endBlock() + 1;
        vm.expectRevert(abi.encodeWithSelector(L2PPresale.BlockOutsidePresale.selector, afterEnd));
        presale.eraIndexAt(afterEnd);
    }

    /*----------------- after end -----------------*/

    function test_LastBlockIsStillTheLastEra() public {
        _start();
        vm.roll(presale.endBlock());
        assertEq(uint256(presale.status()), uint256(L2PPresale.Status.Active));
        assertEq(presale.currentEraIndex(), 4);
        assertEq(presale.currentPriceUsd(), 14_000);
        assertEq(presale.blocksUntilNextEra(), 1);
    }

    function test_EndedViewsRevert() public {
        _start();
        vm.roll(presale.endBlock() + 1);
        assertEq(uint256(presale.status()), uint256(L2PPresale.Status.Ended));

        bytes memory notActive = abi.encodeWithSelector(L2PPresale.PresaleNotActive.selector, L2PPresale.Status.Ended);
        vm.expectRevert(notActive);
        presale.currentPriceUsd();
        vm.expectRevert(notActive);
        presale.currentEraIndex();
        vm.expectRevert(notActive);
        presale.blocksUntilNextEra();

        L2PPresale.Era[5] memory eras = presale.eras();
        assertEq(eras[4].endBlock, presale.endBlock());
    }

    function testFuzz_EraIndexMatchesBlockArithmetic(
        uint256 offset
    ) public {
        _start();
        offset = bound(offset, 0, presale.TOTAL_BLOCKS() - 1);
        vm.roll(1000 + offset);

        uint256 index = presale.currentEraIndex();
        assertEq(index, offset / presale.ERA_BLOCKS());
        assertEq(presale.currentPriceUsd(), presale.eraPrices()[index]);
        L2PPresale.Era memory current = presale.currentEra();
        assertGe(block.number, current.startBlock);
        assertLe(block.number, current.endBlock);
        assertEq(presale.blocksUntilNextEra(), current.endBlock + 1 - block.number);
    }
}
