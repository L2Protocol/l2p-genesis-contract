pragma solidity ^0.8.10;

import "./utils/Deployer.sol";

contract EmissionScheduleTest is Deployer {
    using stdStorage for StdStorage;

    event validatorSetUpdated();
    event systemTransfer(uint256 amount);
    event RewardDistributed(address indexed operatorAddress, uint256 reward);
    event emissionDistributed(uint256 epochEmission, uint256 poolRemaining);
    event failReasonWithStr(string message);

    address public coinbase;

    function setUp() public {
        coinbase = block.coinbase;
        vm.deal(coinbase, 100 ether);

        // set gas price to zero to send system slash tx
        vm.txGasPrice(0);
        vm.mockCall(address(0x66), bytes(""), hex"01");
    }

    /*----------------- helpers -----------------*/

    // forces the emission-schedule storage of the live singleton into a known state, since the
    // contract under test here is loaded from a mainnet fork where these fields are unset.
    function _setEmissionState(
        uint256 rate,
        uint256 halvingPeriod,
        uint256 maxHalvings,
        uint256 poolRemaining,
        uint256 startBlock,
        uint256 lastBlock
    ) internal {
        stdstore.target(address(l2pValidatorSet)).sig("emissionRatePerBlock()").checked_write(rate);
        stdstore.target(address(l2pValidatorSet)).sig("emissionHalvingPeriod()").checked_write(halvingPeriod);
        stdstore.target(address(l2pValidatorSet)).sig("emissionMaxHalvings()").checked_write(maxHalvings);
        stdstore.target(address(l2pValidatorSet)).sig("emissionPoolRemaining()").checked_write(poolRemaining);
        stdstore.target(address(l2pValidatorSet)).sig("emissionStartBlock()").checked_write(startBlock);
        stdstore.target(address(l2pValidatorSet)).sig("emissionLastBlock()").checked_write(lastBlock);
        vm.deal(address(l2pValidatorSet), poolRemaining);
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

    /*----------------- init -----------------*/

    function testInitRequiresExactEmissionPoolGenesisBalance() public {
        address freshAddr = address(0xEA51F00D);
        bytes memory code = vm.getDeployedCode("L2PValidatorSet.sol:L2PValidatorSet");
        vm.etch(freshAddr, code);
        L2PValidatorSet fresh = L2PValidatorSet(payable(freshAddr));

        assertFalse(fresh.alreadyInit());

        vm.expectRevert(bytes("emission pool genesis balance mismatch"));
        fresh.init();

        vm.deal(freshAddr, fresh.EMISSION_POOL_TOTAL() - 1);
        vm.expectRevert(bytes("emission pool genesis balance mismatch"));
        fresh.init();

        vm.deal(freshAddr, fresh.EMISSION_POOL_TOTAL());
        fresh.init();

        assertTrue(fresh.alreadyInit());
        assertEq(fresh.emissionPoolRemaining(), fresh.EMISSION_POOL_TOTAL());
        assertEq(fresh.emissionRatePerBlock(), fresh.EMISSION_RATE_PER_BLOCK_INIT());
        assertEq(fresh.emissionHalvingPeriod(), fresh.EMISSION_HALVING_PERIOD_INIT());
        assertEq(fresh.emissionMaxHalvings(), fresh.EMISSION_MAX_HALVINGS_INIT());
        assertEq(fresh.emissionStartBlock(), fresh.EMISSION_START_BLOCK_INIT());
        assertEq(fresh.emissionLastBlock(), fresh.EMISSION_START_BLOCK_INIT());
        assertEq(fresh.totalEmitted(), 0);

        vm.expectRevert(bytes("the contract already init"));
        fresh.init();
    }

    /*----------------- accrual -----------------*/

    function testEmissionNotAccruedBeforeStartBlock() public {
        (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
            _registerValidators(1);

        uint256 startBlock = block.number + 50;
        _setEmissionState({
            rate: 100 ether,
            halvingPeriod: 1_000_000,
            maxHalvings: 5,
            poolRemaining: 1_000_000 ether,
            startBlock: startBlock,
            lastBlock: startBlock
        });

        // rolling to exactly startBlock must still not accrue (strictly-after check)
        vm.roll(startBlock);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        assertEq(l2pValidatorSet.emissionPoolRemaining(), 1_000_000 ether);
        assertEq(l2pValidatorSet.totalEmitted(), 0);
    }

    function testEmissionAccrualBasic() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);

        uint256 startBlock = block.number;
        _setEmissionState({
            rate: 100 ether,
            halvingPeriod: 1_000_000,
            maxHalvings: 5,
            poolRemaining: 1_000_000 ether,
            startBlock: startBlock,
            lastBlock: startBlock
        });

        vm.roll(startBlock + 10);

        uint256 expectedEmission = 100 ether * 10;
        uint256 pooledBefore = _pooled(operatorAddrs[0]);

        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(expectedEmission, 1_000_000 ether - expectedEmission);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], expectedEmission);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        assertEq(l2pValidatorSet.emissionPoolRemaining(), 1_000_000 ether - expectedEmission);
        assertEq(l2pValidatorSet.totalEmitted(), expectedEmission);
        assertEq(_pooled(operatorAddrs[0]), pooledBefore + expectedEmission);
    }

    function testEmissionProportionalSplitWithRoundingRemainder() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(3);

        uint256 startBlock = block.number;
        _setEmissionState({
            rate: 100 ether,
            halvingPeriod: 1_000_000,
            maxHalvings: 5,
            poolRemaining: 1_000_000 ether,
            startBlock: startBlock,
            lastBlock: startBlock
        });

        vm.roll(startBlock + 7);

        uint256 epochEmission = 100 ether * 7;
        uint256 totalVotingPower = uint256(votingPowers[0]) + uint256(votingPowers[1]) + uint256(votingPowers[2]);
        uint256 share0 = (epochEmission * votingPowers[0]) / totalVotingPower;
        uint256 share1 = (epochEmission * votingPowers[1]) / totalVotingPower;
        uint256 share2 = epochEmission - share0 - share1; // last validator absorbs rounding dust

        uint256[] memory pooledBefore = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            pooledBefore[i] = _pooled(operatorAddrs[i]);
        }

        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(epochEmission, 1_000_000 ether - epochEmission);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], share0);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[1], share1);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[2], share2);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        // no dust is ever lost: the three shares add back up to exactly the epoch emission
        assertEq(share0 + share1 + share2, epochEmission);
        assertEq(_pooled(operatorAddrs[0]), pooledBefore[0] + share0);
        assertEq(_pooled(operatorAddrs[1]), pooledBefore[1] + share1);
        assertEq(_pooled(operatorAddrs[2]), pooledBefore[2] + share2);
        assertEq(l2pValidatorSet.totalEmitted(), epochEmission);
    }

    function testEmissionHalvingAcrossWindowsAndStopsAtMax() public {
        (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
            _registerValidators(1);

        uint256 startBlock = block.number;
        _setEmissionState({
            rate: 800 ether,
            halvingPeriod: 100,
            maxHalvings: 2,
            poolRemaining: 100_000 ether,
            startBlock: startBlock,
            lastBlock: startBlock
        });

        // window 0: full rate
        vm.roll(startBlock + 50);
        uint256 epoch0 = 800 ether * 50;
        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(epoch0, 100_000 ether - epoch0);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
        assertEq(l2pValidatorSet.totalEmitted(), epoch0);

        // window 1: rate halved
        vm.roll(startBlock + 150);
        uint256 epoch1 = 400 ether * 100;
        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(epoch1, 100_000 ether - epoch0 - epoch1);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
        assertEq(l2pValidatorSet.totalEmitted(), epoch0 + epoch1);

        // window 2 == maxHalvings: emission permanently stops
        uint256 poolBeforeCutoff = l2pValidatorSet.emissionPoolRemaining();
        uint256 emittedBeforeCutoff = l2pValidatorSet.totalEmitted();
        vm.roll(startBlock + 250);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
        assertEq(l2pValidatorSet.emissionPoolRemaining(), poolBeforeCutoff);
        assertEq(l2pValidatorSet.totalEmitted(), emittedBeforeCutoff);

        // and it stays stopped even further out
        vm.roll(startBlock + 10_000);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
        assertEq(l2pValidatorSet.emissionPoolRemaining(), poolBeforeCutoff);
        assertEq(l2pValidatorSet.totalEmitted(), emittedBeforeCutoff);
    }

    function testEmissionPoolExhaustionCapsEpochAndThenStops() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _registerValidators(1);

        uint256 startBlock = block.number;
        _setEmissionState({
            rate: 1000 ether,
            halvingPeriod: 1_000_000,
            maxHalvings: 5,
            poolRemaining: 1500 ether,
            startBlock: startBlock,
            lastBlock: startBlock
        });

        // nominal emission (1000 ether * 10 = 10000 ether) far exceeds the 1500 ether left in the pool
        vm.roll(startBlock + 10);
        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(1500 ether, 0);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], 1500 ether);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        assertEq(l2pValidatorSet.emissionPoolRemaining(), 0);
        assertEq(l2pValidatorSet.totalEmitted(), 1500 ether);

        // once the pool is drained, further calls are permanently a no-op
        vm.roll(startBlock + 20);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
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

        uint256 startBlock = block.number;
        _setEmissionState({
            rate: 1000 ether,
            halvingPeriod: 1_000_000,
            maxHalvings: 5,
            poolRemaining: 1_000_000 ether,
            startBlock: startBlock,
            lastBlock: startBlock
        });
        // the accounting pool tracks far more than the contract actually holds
        vm.deal(address(l2pValidatorSet), 300 ether);

        vm.roll(startBlock + 10); // nominal epoch emission would be 10,000 ether
        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit emissionDistributed(300 ether, 1_000_000 ether - 300 ether);
        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], 300 ether);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

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

        uint256 startBlock = block.number;
        _setEmissionState({
            rate: 100 ether,
            halvingPeriod: 1_000_000,
            maxHalvings: 5,
            poolRemaining: 1_000_000 ether,
            startBlock: startBlock,
            lastBlock: startBlock
        });

        vm.roll(startBlock + 10);
        uint256 expectedEmission = 100 ether * 10;
        uint256 pooled0Before = _pooled(operatorAddrs[0]);
        uint256 pooled1Before = _pooled(operatorAddrs[1]);

        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[1], expectedEmission);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        // the jailed validator receives nothing; the sole active validator gets the full epoch
        assertEq(_pooled(operatorAddrs[0]), pooled0Before);
        assertEq(_pooled(operatorAddrs[1]), pooled1Before + expectedEmission);
        assertEq(l2pValidatorSet.totalEmitted(), expectedEmission);
    }

    function testEmissionDustSweepNeverTouchesThePool() public {
        (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
            _registerValidators(1);

        // start the emission schedule far in the future so this call does not accrue anything
        uint256 startBlock = block.number + 1_000_000;
        _setEmissionState({
            rate: 100 ether,
            halvingPeriod: 1_000_000,
            maxHalvings: 5,
            poolRemaining: 500 ether,
            startBlock: startBlock,
            lastBlock: startBlock
        });

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
    function testEmissionParamGovernanceBounds() public {
        bytes memory key = "emissionRatePerBlock";
        bytes memory value = abi.encode(uint256(500 ether));
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionRatePerBlock(), 500 ether);

        value = abi.encode(uint256(10_001 ether));
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("emissionRatePerBlock too high");
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionRatePerBlock(), 500 ether);

        key = "emissionHalvingPeriod";
        value = abi.encode(uint256(2_000_000));
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionHalvingPeriod(), 2_000_000);

        value = abi.encode(uint256(999_999));
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("emissionHalvingPeriod too short");
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionHalvingPeriod(), 2_000_000);

        key = "emissionMaxHalvings";
        value = abi.encode(uint256(10));
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionMaxHalvings(), 10);

        value = abi.encode(uint256(0));
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("emissionMaxHalvings out of range");
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionMaxHalvings(), 10);

        value = abi.encode(uint256(21));
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("emissionMaxHalvings out of range");
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.emissionMaxHalvings(), 10);
    }
}
