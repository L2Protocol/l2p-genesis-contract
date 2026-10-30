pragma solidity ^0.8.10;

import "./utils/Deployer.sol";

contract EmissionScheduleTest is Deployer {
    using stdStorage for StdStorage;

    event validatorSetUpdated();
    event systemTransfer(uint256 amount);
    event RewardDistributed(address indexed operatorAddress, uint256 reward);
    event emissionDistributed(uint256 epochEmission, uint256 poolRemaining);
    event emissionStartScheduled(uint256 startTime);
    event emissionStarted(uint256 startBlock);
    event failReasonWithStr(string message);

    uint256 internal constant YEAR = 365 days;
    uint256 internal constant APR_SCALE = 10000;

    address public coinbase;

    function setUp() public {
        coinbase = block.coinbase;
        vm.deal(coinbase, 100 ether);

        // set gas price to zero to send system slash tx
        vm.txGasPrice(0);
        vm.mockCall(address(0x66), bytes(""), hex"01");
    }

    /*----------------- helpers -----------------*/

    // forces the emission storage of the live singleton into a known state, since the contract under
    // test here is loaded from a fork whose storage was written by an older build. The yields and the
    // target stake go back to their genesis values unless a test overrides them afterwards.
    function _setEmissionState(
        uint256 poolRemaining,
        uint256 startTime,
        uint256 startBlock,
        uint256 lastTime
    ) internal {
        _setEmissionParams(
            l2pValidatorSet.EMISSION_APR_PHASE_ONE_INIT(),
            l2pValidatorSet.EMISSION_APR_PHASE_TWO_INIT(),
            l2pValidatorSet.EMISSION_TARGET_STAKE_INIT()
        );
        stdstore.target(address(l2pValidatorSet)).sig("emissionPoolRemaining()").checked_write(poolRemaining);
        stdstore.target(address(l2pValidatorSet)).sig("emissionStartTime()").checked_write(startTime);
        stdstore.target(address(l2pValidatorSet)).sig("emissionStartBlock()").checked_write(startBlock);
        stdstore.target(address(l2pValidatorSet)).sig("emissionLastTime()").checked_write(lastTime);
        stdstore.target(address(l2pValidatorSet)).sig("totalEmitted()").checked_write(uint256(0));
        vm.deal(address(l2pValidatorSet), poolRemaining);
    }

    function _setEmissionParams(
        uint256 aprPhaseOne,
        uint256 aprPhaseTwo,
        uint256 targetStake
    ) internal {
        stdstore.target(address(l2pValidatorSet)).sig("emissionAprPhaseOne()").checked_write(aprPhaseOne);
        stdstore.target(address(l2pValidatorSet)).sig("emissionAprPhaseTwo()").checked_write(aprPhaseTwo);
        stdstore.target(address(l2pValidatorSet)).sig("emissionTargetStake()").checked_write(targetStake);
    }

    // a schedule that started `elapsed` seconds ago. One breathe block, a second from now, takes the stake
    // snapshots and pays nothing, because the previous payout is put at a moment no snapshot was taken at;
    // from then on the next breathe block pays as if the schedule had been running all along.
    function _setEmissionRunning(
        uint256 poolRemaining,
        uint256 elapsed,
        address[] memory consensusAddrs,
        uint64[] memory votingPowers,
        bytes[] memory voteAddrs
    ) internal {
        _setEmissionState({
            poolRemaining: poolRemaining,
            startTime: block.timestamp + 1 - elapsed,
            startBlock: block.number,
            lastTime: block.timestamp - 1
        });
        _breathe(consensusAddrs, votingPowers, voteAddrs, 1);
        assertEq(l2pValidatorSet.totalEmitted(), 0, "the snapshot breathe block paid out");
    }

    // puts the schedule back into its not-started genesis state
    function _setEmissionNotStarted(
        address starter
    ) internal {
        stdstore.target(address(l2pValidatorSet)).sig("emissionStarter()").checked_write(starter);
        stdstore.target(address(l2pValidatorSet)).sig("emissionStartTime()").checked_write(uint256(0));
        stdstore.target(address(l2pValidatorSet)).sig("emissionStartBlock()").checked_write(uint256(0));
        stdstore.target(address(l2pValidatorSet)).sig("emissionLastTime()").checked_write(uint256(0));
    }

    function _registerValidators(
        uint256 number
    )
        internal
        returns (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        )
    {
        (operatorAddrs, consensusAddrs, votingPowers, voteAddrs) = _batchCreateValidators(number);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
    }

    function _pooled(
        address operatorAddr
    ) internal view returns (uint256) {
        return StakeCredit(payable(stakeHub.getValidatorCreditContract(operatorAddr))).totalPooledL2P();
    }

    function _totalPooled(
        address[] memory operatorAddrs
    ) internal view returns (uint256 total) {
        for (uint256 i; i < operatorAddrs.length; ++i) {
            total += _pooled(operatorAddrs[i]);
        }
    }

    function _breathe(
        address[] memory consensusAddrs,
        uint64[] memory votingPowers,
        bytes[] memory voteAddrs,
        uint256 elapsed
    ) internal {
        vm.roll(block.number + elapsed / 3 + 1);
        vm.warp(block.timestamp + elapsed);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
    }

    /*----------------- init -----------------*/

    function testInitRequiresAtLeastEmissionPoolGenesisBalance() public {
        address freshAddr = address(0xEA51F00D);
        bytes memory code = vm.getDeployedCode("L2PValidatorSet.sol:L2PValidatorSet");
        vm.etch(freshAddr, code);
        L2PValidatorSet fresh = L2PValidatorSet(payable(freshAddr));

        assertFalse(fresh.alreadyInit());

        vm.expectRevert(bytes("emission pool genesis balance too low"));
        fresh.init();

        vm.deal(freshAddr, fresh.EMISSION_POOL_TOTAL() - 1);
        vm.expectRevert(bytes("emission pool genesis balance too low"));
        fresh.init();

        vm.deal(freshAddr, fresh.EMISSION_POOL_TOTAL() + 1 ether);
        fresh.init();

        assertTrue(fresh.alreadyInit());
        assertEq(fresh.EMISSION_POOL_TOTAL(), 20_000_000_000 ether);
        assertEq(fresh.emissionPoolRemaining(), fresh.EMISSION_POOL_TOTAL());
        assertEq(fresh.emissionAprPhaseOne(), 750);
        assertEq(fresh.emissionAprPhaseTwo(), 400);
        assertEq(fresh.emissionTargetStake(), 30_000_000_000 ether);
        assertEq(fresh.EMISSION_PHASE_ONE_DURATION(), 5 * 365 days);
        assertEq(fresh.emissionStartBlock(), 0);
        assertEq(fresh.emissionLastTime(), 0);
        assertEq(fresh.emissionStartTime(), 0);
        assertEq(fresh.emissionStarter(), fresh.EMISSION_STARTER_INIT());
        assertEq(fresh.totalEmitted(), 0);
        assertEq(fresh.numOfCabinets(), fresh.INIT_NUM_OF_CABINETS());
        assertEq(fresh.maxNumOfMaintaining(), fresh.INIT_MAX_NUM_OF_MAINTAINING());
        assertEq(fresh.maintainSlashScale(), fresh.INIT_MAINTAIN_SLASH_SCALE());

        vm.expectRevert(bytes("the contract already init"));
        fresh.init();
    }

    function testUpdateValidatorSetBeforeInitCannotDrainThePool() public {
        address freshAddr = address(0xEA51F00E);
        vm.etch(freshAddr, vm.getDeployedCode("L2PValidatorSet.sol:L2PValidatorSet"));
        L2PValidatorSet fresh = L2PValidatorSet(payable(freshAddr));
        vm.deal(freshAddr, fresh.EMISSION_POOL_TOTAL());

        assertFalse(fresh.alreadyInit());

        address[] memory consensusAddrs = new address[](0);
        uint64[] memory votingPowers = new uint64[](0);
        bytes[] memory voteAddrs = new bytes[](0);

        // before init emissionPoolRemaining is still zero, so an unguarded dust sweep would
        // hand the entire emission pool to SystemReward
        vm.prank(coinbase);
        vm.expectRevert(bytes("the contract not init yet"));
        fresh.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        assertEq(freshAddr.balance, fresh.EMISSION_POOL_TOTAL());
    }

    function testEmissionAccountingStaysBalancedAcrossEpochs() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(3);

        uint256 pool = 1_000_000 ether;
        _setEmissionRunning(pool, 5 * YEAR - 3 days, consensusAddrs, votingPowers, voteAddrs);

        uint256 paidToValidators;
        for (uint256 i = 1; i <= 6; ++i) {
            uint256 before = _totalPooled(operatorAddrs);
            _breathe(consensusAddrs, votingPowers, voteAddrs, 1 days);
            paidToValidators += _totalPooled(operatorAddrs) - before;

            // nothing is created or lost: what left the pool is exactly what was booked as emitted
            assertEq(
                l2pValidatorSet.emissionPoolRemaining() + l2pValidatorSet.totalEmitted(),
                pool,
                "pool and totalEmitted no longer sum to the starting pool"
            );
        }

        // every emitted L2P reached a validator's credit contract
        assertEq(paidToValidators, l2pValidatorSet.totalEmitted(), "emitted amount did not reach validators");
        assertGt(l2pValidatorSet.totalEmitted(), 0);
    }

    /*----------------- start -----------------*/

    function testStartEmissionOnlyByStarterAndOnlyOnce() public {
        address starter = _getNextUserAddress();
        _setEmissionNotStarted(starter);
        uint256 interval = stakeHub.BREATHE_BLOCK_INTERVAL();

        // somewhere in the middle of an epoch
        vm.warp((block.timestamp / interval) * interval + interval / 2);
        uint256 expectedStart = (block.timestamp / interval + 1) * interval;

        vm.prank(_getNextUserAddress());
        vm.expectRevert(bytes("the message sender must be the emission starter"));
        l2pValidatorSet.startEmission();
        assertEq(l2pValidatorSet.emissionStartTime(), 0);

        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionStartScheduled(expectedStart);
        vm.prank(starter);
        l2pValidatorSet.startEmission();
        assertEq(l2pValidatorSet.emissionStartTime(), expectedStart);
        // the schedule itself only starts at the breathe block of the next epoch
        assertEq(l2pValidatorSet.emissionStartBlock(), 0);

        vm.prank(starter);
        vm.expectRevert(bytes("emission already started"));
        l2pValidatorSet.startEmission();
        assertEq(l2pValidatorSet.emissionStartTime(), expectedStart);
    }

    function testStartEmissionJustBeforeEpochBoundarySchedulesTheNextOne() public {
        address starter = _getNextUserAddress();
        _setEmissionNotStarted(starter);
        uint256 interval = stakeHub.BREATHE_BLOCK_INTERVAL();

        uint256 boundary = (block.timestamp / interval + 1) * interval;
        vm.warp(boundary - 1);
        vm.prank(starter);
        l2pValidatorSet.startEmission();
        assertEq(l2pValidatorSet.emissionStartTime(), boundary);
    }

    function testStartEmissionExactlyOnEpochBoundarySchedulesTheOneAfter() public {
        address starter = _getNextUserAddress();
        _setEmissionNotStarted(starter);
        uint256 interval = stakeHub.BREATHE_BLOCK_INTERVAL();

        uint256 boundary = (block.timestamp / interval + 1) * interval;
        vm.warp(boundary);
        vm.prank(starter);
        l2pValidatorSet.startEmission();
        assertEq(l2pValidatorSet.emissionStartTime(), boundary + interval);
    }

    function testEmissionDoesNothingUntilStarted() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        _setEmissionState({ poolRemaining: 1_000_000 ether, startTime: 0, startBlock: 0, lastTime: 0 });
        _setEmissionNotStarted(_getNextUserAddress());

        uint256 pooledBefore = _pooled(operatorAddrs[0]);

        // epochs without a start call must leave the pool untouched
        for (uint256 i = 1; i <= 3; ++i) {
            _breathe(consensusAddrs, votingPowers, voteAddrs, 1 days);
        }

        assertEq(l2pValidatorSet.emissionStartBlock(), 0);
        assertEq(l2pValidatorSet.emissionLastTime(), 0);
        assertEq(l2pValidatorSet.emissionPoolRemaining(), 1_000_000 ether);
        assertEq(l2pValidatorSet.totalEmitted(), 0);
        assertEq(_pooled(operatorAddrs[0]), pooledBefore);
    }

    function testEmissionStartsAtFirstBreatheBlockOfNextEpoch() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        address starter = _getNextUserAddress();
        _setEmissionState({ poolRemaining: 1_000_000 ether, startTime: 0, startBlock: 0, lastTime: 0 });
        _setEmissionNotStarted(starter);
        uint256 interval = stakeHub.BREATHE_BLOCK_INTERVAL();

        vm.warp((block.timestamp / interval) * interval + interval / 2);
        vm.prank(starter);
        l2pValidatorSet.startEmission();
        uint256 startTime = l2pValidatorSet.emissionStartTime();

        // the last block of the current epoch: still nothing
        vm.roll(block.number + 100);
        vm.warp(startTime - 1);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
        assertEq(l2pValidatorSet.emissionStartBlock(), 0);
        assertEq(l2pValidatorSet.totalEmitted(), 0);

        // the breathe block of the next epoch starts the schedule; it pays nothing itself
        vm.roll(block.number + 1);
        vm.warp(startTime);
        uint256 breatheBlock = block.number;
        uint256 pooledBefore = _pooled(operatorAddrs[0]);

        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionStarted(breatheBlock);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        assertEq(l2pValidatorSet.emissionStartBlock(), breatheBlock);
        assertEq(l2pValidatorSet.emissionLastTime(), startTime);
        assertEq(l2pValidatorSet.totalEmitted(), 0);
        assertEq(_pooled(operatorAddrs[0]), pooledBefore);

        // the epoch after that is the first one paid out: 7.5% a year on the stake, for one epoch
        vm.roll(breatheBlock + 10);
        vm.warp(startTime + interval);
        uint256 expectedEmission = pooledBefore * 750 * interval / (APR_SCALE * YEAR);

        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(expectedEmission, 1_000_000 ether - expectedEmission);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], expectedEmission);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        assertEq(l2pValidatorSet.emissionLastTime(), startTime + interval);
        assertEq(l2pValidatorSet.totalEmitted(), expectedEmission);
        assertEq(_pooled(operatorAddrs[0]), pooledBefore + expectedEmission);
    }

    /*----------------- yield -----------------*/

    function testEmissionPaysSevenAndAHalfPercentAYearInPhaseOne() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        uint256 stake = _pooled(operatorAddrs[0]);
        _breathe(consensusAddrs, votingPowers, voteAddrs, YEAR);

        assertEq(l2pValidatorSet.totalEmitted(), stake * 750 / APR_SCALE);
        assertEq(_pooled(operatorAddrs[0]), stake + stake * 750 / APR_SCALE);
    }

    function testEmissionPaysFourPercentAYearInPhaseTwo() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        _setEmissionRunning(1_000_000 ether, 6 * YEAR, consensusAddrs, votingPowers, voteAddrs);

        uint256 stake = _pooled(operatorAddrs[0]);
        _breathe(consensusAddrs, votingPowers, voteAddrs, YEAR);

        assertEq(l2pValidatorSet.totalEmitted(), stake * 400 / APR_SCALE);
    }

    function testEmissionPhasesCountFromTheScheduledStartTime() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        // phase one ends 10 days into the coming 30
        _setEmissionRunning(1_000_000 ether, 5 * YEAR - 10 days, consensusAddrs, votingPowers, voteAddrs);

        uint256 stake = _pooled(operatorAddrs[0]);
        _breathe(consensusAddrs, votingPowers, voteAddrs, 30 days);

        uint256 expected = stake * (750 * 10 days + 400 * 20 days) / (APR_SCALE * YEAR);
        assertEq(l2pValidatorSet.totalEmitted(), expected);
    }

    function testEmissionKeepsPayingPhaseTwoAfterTenYears() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        _setEmissionRunning(1_000_000 ether, 12 * YEAR, consensusAddrs, votingPowers, voteAddrs);

        uint256 stake = _pooled(operatorAddrs[0]);
        _breathe(consensusAddrs, votingPowers, voteAddrs, 1 days);

        assertEq(l2pValidatorSet.totalEmitted(), stake * 400 * 1 days / (APR_SCALE * YEAR));
        assertGt(l2pValidatorSet.totalEmitted(), 0);
    }

    function testEmissionIsPaidOnAtMostTheTargetStake() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(2);
        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        uint256 totalStake = _totalPooled(operatorAddrs);
        uint256 target = totalStake / 4;
        _setEmissionParams(750, 400, target);

        uint256 stake0 = _pooled(operatorAddrs[0]);
        _breathe(consensusAddrs, votingPowers, voteAddrs, YEAR);

        // the yield is paid on the target, and shared over all of the stake
        uint256 expected = target * 750 / APR_SCALE;
        assertEq(l2pValidatorSet.totalEmitted(), expected);
        assertEq(_pooled(operatorAddrs[0]), stake0 + expected * stake0 / totalStake);
    }

    function testEmissionWithoutStakeIsNotCarriedOver() public {
        // validators the stake hub does not know, like the ones in genesis before anyone has staked
        address[] memory consensusAddrs = new address[](2);
        uint64[] memory votingPowers = new uint64[](2);
        bytes[] memory voteAddrs = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            consensusAddrs[i] = address(uint160(0xC0FFEE00 + i));
            votingPowers[i] = 1;
            voteAddrs[i] = abi.encodePacked(bytes32(uint256(i + 1)), bytes16(0));
        }
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        _breathe(consensusAddrs, votingPowers, voteAddrs, 30 days);

        assertEq(l2pValidatorSet.totalEmitted(), 0);
        assertEq(l2pValidatorSet.emissionLastTime(), block.timestamp);
        assertEq(l2pValidatorSet.emissionPoolRemaining(), 1_000_000 ether);
    }

    function testEmissionNotAccruedWithinTheSameSecond() public {
        (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
            _registerValidators(1);
        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        vm.roll(block.number + 1);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        assertEq(l2pValidatorSet.emissionPoolRemaining(), 1_000_000 ether);
        assertEq(l2pValidatorSet.totalEmitted(), 0);
    }

    /*----------------- stake snapshots -----------------*/

    function testStakeAddedJustBeforePayoutWaitsAFullPeriod() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        _setEmissionRunning(1_000_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);
        uint256 stakeBefore = _pooled(operatorAddrs[0]);

        // a billion arrives two seconds before the payout
        vm.warp(block.timestamp + 1 days - 2);
        address delegator = _getNextUserAddress();
        vm.deal(delegator, 1_000_000_000 ether);
        vm.prank(delegator);
        stakeHub.delegate{ value: 1_000_000_000 ether }(operatorAddrs[0], false);

        _breathe(consensusAddrs, votingPowers, voteAddrs, 2);
        uint256 firstDay = stakeBefore * 750 * 1 days / (APR_SCALE * YEAR);
        assertEq(l2pValidatorSet.totalEmitted(), firstDay, "late stake was paid for a day it was not there");

        // the day after, it was there all day and earns like the rest
        uint256 stakeNow = _pooled(operatorAddrs[0]);
        _breathe(consensusAddrs, votingPowers, voteAddrs, 1 days);
        assertEq(l2pValidatorSet.totalEmitted(), firstDay + stakeNow * 750 * 1 days / (APR_SCALE * YEAR));
    }

    function testStakeWithdrawnDuringThePeriodIsNotPaid() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);

        address delegator = _getNextUserAddress();
        vm.deal(delegator, 1_000_000_000 ether);
        vm.prank(delegator);
        stakeHub.delegate{ value: 1_000_000_000 ether }(operatorAddrs[0], false);
        _setEmissionRunning(1_000_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        // the billion leaves halfway through the day
        vm.warp(block.timestamp + 12 hours);
        StakeCredit credit = StakeCredit(payable(stakeHub.getValidatorCreditContract(operatorAddrs[0])));
        uint256 shares = credit.balanceOf(delegator);
        vm.prank(delegator);
        stakeHub.undelegate(operatorAddrs[0], shares);
        uint256 stakeAfter = _pooled(operatorAddrs[0]);

        _breathe(consensusAddrs, votingPowers, voteAddrs, 12 hours);
        assertEq(l2pValidatorSet.totalEmitted(), stakeAfter * 750 * 1 days / (APR_SCALE * YEAR));
    }

    function testNewlyElectedValidatorEarnsFromItsFirstFullPeriod() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _batchCreateValidators(2);

        // only the first one is in the set when the schedule is running
        address[] memory firstConsensus = new address[](1);
        uint64[] memory firstPowers = new uint64[](1);
        bytes[] memory firstVotes = new bytes[](1);
        firstConsensus[0] = consensusAddrs[0];
        firstPowers[0] = votingPowers[0];
        firstVotes[0] = voteAddrs[0];
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(firstConsensus, firstPowers, firstVotes);
        _setEmissionRunning(1_000_000_000 ether, 0, firstConsensus, firstPowers, firstVotes);

        // the second one is elected at this breathe block: the day before is paid to the first one alone
        uint256 stake1 = _pooled(operatorAddrs[1]);
        _breathe(consensusAddrs, votingPowers, voteAddrs, 1 days);
        assertEq(_pooled(operatorAddrs[1]), stake1, "paid for a day before it was elected");

        // and the day after, it was in the set all day; as the last one paid it also takes the rounding dust
        uint256 stake0 = _pooled(operatorAddrs[0]);
        uint256 total = (stake0 + stake1) * 750 * 1 days / (APR_SCALE * YEAR);
        _breathe(consensusAddrs, votingPowers, voteAddrs, 1 days);
        assertEq(_pooled(operatorAddrs[1]), stake1 + total - total * stake0 / (stake0 + stake1));
        assertEq(_pooled(operatorAddrs[0]), stake0 + total * stake0 / (stake0 + stake1));
    }

    function testStakeJailedInStakeHubEarnsNothing() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(2);
        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        // StakeHub has jailed validator 0, while the validator set still lists it as working
        address credit0 = stakeHub.getValidatorCreditContract(operatorAddrs[0]);
        vm.mockCall(
            address(stakeHub),
            abi.encodeWithSignature("getValidatorEmissionInfo(address)", consensusAddrs[0]),
            abi.encode(credit0, true)
        );

        uint256 pooled0Before = _pooled(operatorAddrs[0]);
        uint256 pooled1Before = _pooled(operatorAddrs[1]);
        uint256 systemRewardBefore = address(systemReward).balance;
        uint256 expectedEmission = pooled1Before * 750 * 1 days / (APR_SCALE * YEAR);

        _breathe(consensusAddrs, votingPowers, voteAddrs, 1 days);

        // the jailed stake neither raises the emission nor has a share of it sent to SystemReward
        assertEq(l2pValidatorSet.totalEmitted(), expectedEmission);
        assertEq(_pooled(operatorAddrs[0]), pooled0Before);
        assertEq(_pooled(operatorAddrs[1]), pooled1Before + expectedEmission);
        assertEq(address(systemReward).balance, systemRewardBefore);
    }

    /*----------------- distribution -----------------*/

    function testEmissionSplitByStakeWithRoundingRemainder() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(3);

        // give the validators different stakes, so the split is not even
        address delegator = _getNextUserAddress();
        vm.deal(delegator, 10_000_000 ether);
        vm.startPrank(delegator);
        stakeHub.delegate{ value: 1_234_567 ether }(operatorAddrs[1], false);
        stakeHub.delegate{ value: 3_000_001 ether }(operatorAddrs[2], false);
        vm.stopPrank();

        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        uint256[] memory stakes = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            stakes[i] = _pooled(operatorAddrs[i]);
        }
        uint256 totalStake = stakes[0] + stakes[1] + stakes[2];
        uint256 epochEmission = totalStake * 750 * 7 days / (APR_SCALE * YEAR);
        uint256 share0 = epochEmission * stakes[0] / totalStake;
        uint256 share1 = epochEmission * stakes[1] / totalStake;
        uint256 share2 = epochEmission - share0 - share1; // last validator absorbs rounding dust

        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(epochEmission, 1_000_000 ether - epochEmission);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], share0);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[1], share1);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[2], share2);
        _breathe(consensusAddrs, votingPowers, voteAddrs, 7 days);

        // no dust is ever lost: the three shares add back up to exactly the epoch emission
        assertEq(share0 + share1 + share2, epochEmission);
        assertEq(_pooled(operatorAddrs[0]), stakes[0] + share0);
        assertEq(_pooled(operatorAddrs[1]), stakes[1] + share1);
        assertEq(_pooled(operatorAddrs[2]), stakes[2] + share2);
        assertEq(l2pValidatorSet.totalEmitted(), epochEmission);
    }

    function testEmissionPoolExhaustionCapsEpochAndThenStops() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        _setEmissionRunning(1500 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        // a year at 7.5% on seven million far exceeds the 1500 L2P left in the pool
        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(1500 ether, 0);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], 1500 ether);
        _breathe(consensusAddrs, votingPowers, voteAddrs, YEAR);

        assertEq(l2pValidatorSet.emissionPoolRemaining(), 0);
        assertEq(l2pValidatorSet.totalEmitted(), 1500 ether);

        // once the pool is drained, further calls are permanently a no-op
        _breathe(consensusAddrs, votingPowers, voteAddrs, YEAR);
        assertEq(l2pValidatorSet.emissionPoolRemaining(), 0);
        assertEq(l2pValidatorSet.totalEmitted(), 1500 ether);
    }

    function testEmissionCappedByAvailableContractBalance() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);
        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);
        // the accounting pool tracks far more than the contract actually holds
        vm.deal(address(l2pValidatorSet), 300 ether);

        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(300 ether, 1_000_000 ether - 300 ether);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], 300 ether);
        _breathe(consensusAddrs, votingPowers, voteAddrs, YEAR);

        assertEq(l2pValidatorSet.emissionPoolRemaining(), 1_000_000 ether - 300 ether);
        assertEq(l2pValidatorSet.totalEmitted(), 300 ether);
    }

    function testEmissionSkipsJailedValidators() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(2);
        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        // force currentValidatorSet[0].jailed = true directly in storage; in normal operation a
        // jailed validator is filtered out of currentValidatorSet entirely, but _accrueEmission
        // defensively re-checks the flag, which we exercise here.
        bytes32 baseSlot = keccak256(abi.encode(uint256(1)));
        bytes32 slot0 = bytes32(uint256(baseSlot) + 2); // struct 0, field slot 2 (votingPower/jailed packed)
        bytes32 word = vm.load(address(l2pValidatorSet), slot0);
        word = word | bytes32(uint256(1) << 224); // jailed bool is at byte offset 28
        vm.store(address(l2pValidatorSet), slot0, word);

        (,,,, bool jailed0,) = l2pValidatorSet.currentValidatorSet(0);
        assertTrue(jailed0);

        uint256 pooled0Before = _pooled(operatorAddrs[0]);
        uint256 pooled1Before = _pooled(operatorAddrs[1]);
        // only the working validator's stake earns
        uint256 expectedEmission = pooled1Before * 750 * 10 days / (APR_SCALE * YEAR);

        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[1], expectedEmission);
        _breathe(consensusAddrs, votingPowers, voteAddrs, 10 days);

        assertEq(_pooled(operatorAddrs[0]), pooled0Before);
        assertEq(_pooled(operatorAddrs[1]), pooled1Before + expectedEmission);
        assertEq(l2pValidatorSet.totalEmitted(), expectedEmission);
    }

    function testEmissionSkipsMaintainingValidators() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(2);
        // a breathe block ends every maintenance, so the snapshots are taken before it starts
        _setEmissionRunning(1_000_000 ether, 0, consensusAddrs, votingPowers, voteAddrs);

        uint256 idx0 = l2pValidatorSet.getCurrentValidatorIndex(consensusAddrs[0]);
        vm.prank(consensusAddrs[0]);
        l2pValidatorSet.enterMaintenance();
        assertFalse(l2pValidatorSet.isWorkingValidator(idx0), "validator 0 should be maintaining");

        uint256 pooled0Before = _pooled(operatorAddrs[0]);
        uint256 pooled1Before = _pooled(operatorAddrs[1]);
        uint256 expectedEmission = pooled1Before * 750 * 10 days / (APR_SCALE * YEAR);

        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 10 days);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        // a validator that produced nothing all epoch must not be paid for it
        assertEq(_pooled(operatorAddrs[0]), pooled0Before, "maintaining validator was paid emission");
        assertEq(_pooled(operatorAddrs[1]), pooled1Before + expectedEmission, "active validator underpaid");
        assertEq(l2pValidatorSet.totalEmitted(), expectedEmission);
    }

    function testEmissionDustSweepNeverTouchesThePool() public {
        (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
            _registerValidators(1);

        // the schedule has not started, so this call does not accrue anything
        _setEmissionState({ poolRemaining: 500 ether, startTime: 0, startBlock: 0, lastTime: 0 });
        _setEmissionNotStarted(_getNextUserAddress());

        address payer = _getNextUserAddress();
        vm.prank(payer);
        (bool ok,) = address(l2pValidatorSet).call{ value: 7 ether }("");
        assertTrue(ok);
        assertEq(address(l2pValidatorSet).balance, 507 ether);

        uint256 systemRewardBalanceBefore = address(systemReward).balance;

        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit systemTransfer(7 ether);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        assertEq(address(l2pValidatorSet).balance, 500 ether);
        assertEq(address(systemReward).balance, systemRewardBalanceBefore + 7 ether);
        assertEq(l2pValidatorSet.emissionPoolRemaining(), 500 ether);
    }

    /*----------------- governance -----------------*/

    // GovHub.updateParam calls the target through a try/catch and only emits
    // `failReasonWithStr` on failure rather than reverting, so invalid updates are
    // asserted by checking the value is left unchanged (matching GovHub's own behavior).
    function testEmissionParamsCanOnlyBeLowered() public {
        _setEmissionParams(750, 400, 30_000_000_000 ether);

        _assertLowerOnly("emissionAprPhaseOne", 750, 500, "emissionAprPhaseOne out of range");
        _assertLowerOnly("emissionAprPhaseTwo", 400, 250, "emissionAprPhaseTwo out of range");
        _assertLowerOnly(
            "emissionTargetStake", 30_000_000_000 ether, 20_000_000_000 ether, "emissionTargetStake out of range"
        );

        // zero would switch emission off through the back door; that is not what these dials are for
        bytes memory key = "emissionAprPhaseOne";
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("emissionAprPhaseOne out of range");
        _updateParamByGovHub(key, abi.encode(uint256(0)), address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionAprPhaseOne(), 500);

        key = "emissionAprPhaseTwo";
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("emissionAprPhaseTwo out of range");
        _updateParamByGovHub(key, abi.encode(uint256(0)), address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionAprPhaseTwo(), 250);

        key = "emissionTargetStake";
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("emissionTargetStake out of range");
        _updateParamByGovHub(key, abi.encode(uint256(1 ether - 1)), address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionTargetStake(), 20_000_000_000 ether);
    }

    function _assertLowerOnly(
        bytes memory key,
        uint256 ceiling,
        uint256 lower,
        string memory reason
    ) internal {
        _updateParamByGovHub(key, abi.encode(lower), address(l2pValidatorSet));
        (bool ok, bytes memory data) =
            address(l2pValidatorSet).staticcall(abi.encodeWithSignature(string.concat(string(key), "()")));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), lower);

        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr(reason);
        _updateParamByGovHub(key, abi.encode(ceiling + 1), address(l2pValidatorSet));
        (, data) = address(l2pValidatorSet).staticcall(abi.encodeWithSignature(string.concat(string(key), "()")));
        assertEq(abi.decode(data, (uint256)), lower);

        // back up to the genesis value is fine, past it is not
        _updateParamByGovHub(key, abi.encode(ceiling), address(l2pValidatorSet));
        (, data) = address(l2pValidatorSet).staticcall(abi.encodeWithSignature(string.concat(string(key), "()")));
        assertEq(abi.decode(data, (uint256)), ceiling);
        _updateParamByGovHub(key, abi.encode(lower), address(l2pValidatorSet));
    }

    function testEmissionStarterGovernance() public {
        address original = _getNextUserAddress();
        _setEmissionNotStarted(original);
        address replacement = _getNextUserAddress();

        bytes memory key = "emissionStarter";
        bytes memory value = abi.encodePacked(replacement);
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionStarter(), replacement);

        value = abi.encodePacked(address(0));
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("emissionStarter is zero address");
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionStarter(), replacement);

        value = abi.encode(replacement);
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("length of emissionStarter mismatch");
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionStarter(), replacement);

        // the old starter lost the right, the new one has it
        vm.prank(original);
        vm.expectRevert(bytes("the message sender must be the emission starter"));
        l2pValidatorSet.startEmission();

        vm.prank(replacement);
        l2pValidatorSet.startEmission();
        assertGt(l2pValidatorSet.emissionStartTime(), block.timestamp);
    }
}
