pragma solidity ^0.8.10;

import "./utils/Deployer.sol";

contract ValidatorSetTest is Deployer {
    using RLPEncode for *;

    event validatorSetUpdated();
    event systemTransfer(uint256 amount);
    event RewardDistributed(address indexed operatorAddress, uint256 reward);
    event deprecatedDeposit(address indexed validator, uint256 amount);
    event validatorDeposit(address indexed validator, uint256 amount);
    event finalityRewardDeposit(address indexed validator, uint256 amount);
    event deprecatedFinalityRewardDeposit(address indexed validator, uint256 amount);
    event unsupportedPackage(uint64 indexed packageSequence, uint8 indexed channelId, bytes payload);

    uint256 public totalInComing;
    uint256 public burnRatio;
    uint256 public burnRatioScale;
    uint256 public maxNumOfWorkingCandidates;
    uint256 public numOfCabinets;
    uint256 public systemRewardBaseRatio;
    uint256 public systemRewardRatioScale;

    address public coinbase;
    address public validator0;
    mapping(address => bool) public cabinets;

    function setUp() public {
        // add operator
        bytes memory key = "addOperator";
        bytes memory valueBytes = abi.encodePacked(address(l2pValidatorSet));
        vm.expectEmit(false, false, false, true, address(systemReward));
        emit paramChange(string(key), valueBytes);
        _updateParamByGovHub(key, valueBytes, address(systemReward));
        assertTrue(systemReward.isOperator(address(l2pValidatorSet)));

        burnRatio =
            l2pValidatorSet.isSystemRewardIncluded() ? l2pValidatorSet.burnRatio() : l2pValidatorSet.INIT_BURN_RATIO();
        burnRatioScale = l2pValidatorSet.BLOCK_FEES_RATIO_SCALE();
        systemRewardBaseRatio = l2pValidatorSet.isSystemRewardIncluded()
            ? l2pValidatorSet.systemRewardBaseRatio()
            : l2pValidatorSet.INIT_SYSTEM_REWARD_RATIO();
        systemRewardRatioScale = l2pValidatorSet.BLOCK_FEES_RATIO_SCALE();
        totalInComing = l2pValidatorSet.totalInComing();
        maxNumOfWorkingCandidates = l2pValidatorSet.maxNumOfWorkingCandidates();
        numOfCabinets = l2pValidatorSet.numOfCabinets();

        address[] memory validators = l2pValidatorSet.getValidators();
        validator0 = validators[0];

        coinbase = block.coinbase;
        vm.deal(coinbase, 100 ether);

        // set gas price to zero to send system slash tx
        vm.txGasPrice(0);
        vm.mockCall(address(0x66), bytes(""), hex"01");
    }

    function testDeposit(uint256 amount) public {
        vm.assume(amount >= 1e16);
        vm.assume(amount <= 1e19);

        vm.expectRevert("the message sender must be the block producer");
        l2pValidatorSet.deposit{ value: amount }(validator0);

        vm.startPrank(coinbase);
        vm.expectRevert("deposit value is zero");
        l2pValidatorSet.deposit(validator0);

        uint256 realAmount0 = _calcIncoming(amount);
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit validatorDeposit(validator0, realAmount0);
        l2pValidatorSet.deposit{ value: amount }(validator0);

        vm.stopPrank();
        assertEq(l2pValidatorSet.getTurnLength(), 16);
        bytes memory key = "turnLength";
        bytes memory value = bytes(hex"0000000000000000000000000000000000000000000000000000000000000005"); // 5
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.getTurnLength(), 5);

        key = "systemRewardAntiMEVRatio";
        value = bytes(hex"0000000000000000000000000000000000000000000000000000000000000200"); // 512
        _updateParamByGovHub(key, value, address(l2pValidatorSet));
        assertEq(l2pValidatorSet.systemRewardAntiMEVRatio(), 512);
        vm.startPrank(coinbase);

        uint256 realAmount1 = _calcIncoming(amount);
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit validatorDeposit(validator0, realAmount1);
        l2pValidatorSet.deposit{ value: amount }(validator0);

        address newAccount = _getNextUserAddress();
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit deprecatedDeposit(newAccount, realAmount1);
        l2pValidatorSet.deposit{ value: amount }(newAccount);

        assertEq(l2pValidatorSet.totalInComing(), totalInComing + realAmount0 + realAmount1);
        vm.stopPrank();
    }

	function testGov() public {
		bytes memory key = "maxNumOfWorkingCandidates";
		bytes memory value = bytes(
			hex"0000000000000000000000000000000000000000000000000000000000000015"
		); // 21

		// Invalid: maxNumOfWorkingCandidates > maxNumOfCandidates
		vm.expectRevert(
			"the maxNumOfWorkingCandidates must be not greater than maxNumOfCandidates"
		);
		_updateParamByGovHub(key, value, address(l2pValidatorSet));
		// Value must remain unchanged after the failed update
		assertEq(
			l2pValidatorSet.maxNumOfWorkingCandidates(),
			maxNumOfWorkingCandidates
		);

		// Valid: set maxNumOfWorkingCandidates = 10
		value = bytes(
			hex"000000000000000000000000000000000000000000000000000000000000000a"
		); // 10
		_updateParamByGovHub(key, value, address(l2pValidatorSet));
		assertEq(l2pValidatorSet.maxNumOfWorkingCandidates(), 10);

		// Change maxNumOfCandidates = 5, and ensure maxNumOfWorkingCandidates is synced to 5
		key = "maxNumOfCandidates";
		value = bytes(
			hex"0000000000000000000000000000000000000000000000000000000000000005"
		); // 5
		_updateParamByGovHub(key, value, address(l2pValidatorSet));
		assertEq(l2pValidatorSet.maxNumOfCandidates(), 5);
		assertEq(l2pValidatorSet.maxNumOfWorkingCandidates(), 5);

		// Also test a normal param update still works
		key = "systemRewardBaseRatio";
		value = bytes(
			hex"0000000000000000000000000000000000000000000000000000000000000400"
		); // 1024
		_updateParamByGovHub(key, value, address(l2pValidatorSet));
		assertEq(l2pValidatorSet.systemRewardBaseRatio(), 1024);
	}


    function testValidateSetChange() public {
        for (uint256 i; i < 5; ++i) {
            (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
                _batchCreateValidators(5);
            vm.prank(coinbase);
            l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

            address[] memory valSet = l2pValidatorSet.getValidators();
            for (uint256 j; j < 5; ++j) {
                assertEq(valSet[j], consensusAddrs[j], "consensus address not equal");
                assertTrue(l2pValidatorSet.isCurrentValidator(consensusAddrs[j]), "the address should be a validator");
            }
        }
    }

    function testGetMiningValidatorsWith41Vals() public {
        (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
            _batchCreateValidators(41);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        address[] memory vals = l2pValidatorSet.getValidators();
        (address[] memory miningVals,) = l2pValidatorSet.getMiningValidators();

        uint256 count;
        uint256 _numOfCabinets;
        uint256 _maxNumOfWorkingCandidates = maxNumOfWorkingCandidates;
        if (numOfCabinets == 0) {
            _numOfCabinets = l2pValidatorSet.INIT_NUM_OF_CABINETS();
        } else {
            _numOfCabinets = numOfCabinets;
        }
        if ((vals.length - _numOfCabinets) < _maxNumOfWorkingCandidates) {
            _maxNumOfWorkingCandidates = vals.length - _numOfCabinets;
        }

        for (uint256 i; i < _numOfCabinets; ++i) {
            cabinets[vals[i]] = true;
        }
        for (uint256 i; i < _numOfCabinets; ++i) {
            if (!cabinets[miningVals[i]]) {
                ++count;
            }
        }
        assertGe(_maxNumOfWorkingCandidates, count);
        assertGe(count, 0);
    }

    function testDistributeAlgorithm() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _batchCreateValidators(1);

        vm.startPrank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        address val = consensusAddrs[0];
        address deprecated = _getNextUserAddress();
        vm.deal(address(l2pValidatorSet), 0);

        for (uint256 i; i < 5; ++i) {
            l2pValidatorSet.deposit{ value: 1 ether }(val);
            l2pValidatorSet.deposit{ value: 1 ether }(deprecated);
            l2pValidatorSet.deposit{ value: 0.1 ether }(val);
            l2pValidatorSet.deposit{ value: 0.1 ether }(deprecated);
        }

        uint256 expectedBalance = _calcIncoming(11 ether);
        uint256 expectedIncoming = _calcIncoming(5.5 ether);
        uint256 balance = address(l2pValidatorSet).balance;
        uint256 incoming = l2pValidatorSet.totalInComing();
        assertEq(balance, expectedBalance);
        assertEq(incoming, expectedIncoming);

        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], expectedIncoming);
        vm.expectEmit(false, false, false, true, address(l2pValidatorSet));
        emit systemTransfer(expectedBalance - expectedIncoming);
        vm.expectEmit(false, false, false, false, address(l2pValidatorSet));
        emit validatorSetUpdated();
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        vm.stopPrank();
    }

    function testMassiveDistribute() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _batchCreateValidators(41);

        vm.startPrank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        for (uint256 i; i < 41; ++i) {
            l2pValidatorSet.deposit{ value: 1 ether }(consensusAddrs[i]);
        }
        vm.stopPrank();

        (operatorAddrs, consensusAddrs, votingPowers, voteAddrs) = _batchCreateValidators(41);
        vm.prank(coinbase);
        l2pValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
    }

    function testDistributeFinalityReward() public {
        address[] memory addrs = new address[](20);
        uint256[] memory weights = new uint256[](20);
        address[] memory vals = l2pValidatorSet.getValidators();
        for (uint256 i; i < 10; ++i) {
            addrs[i] = vals[i];
            weights[i] = 1;
        }

        for (uint256 i = 10; i < 20; ++i) {
            vals[i] = _getNextUserAddress();
            weights[i] = 1;
        }

        // failed case
        uint256 ceil = l2pValidatorSet.MAX_SYSTEM_REWARD_BALANCE();
        vm.deal(address(systemReward), ceil - 1);
        vm.expectRevert(bytes("the message sender must be the block producer"));
        l2pValidatorSet.distributeFinalityReward(addrs, weights);

        vm.startPrank(coinbase);
        l2pValidatorSet.distributeFinalityReward(addrs, weights);
        vm.expectRevert(bytes("can not do this twice in one block"));
        l2pValidatorSet.distributeFinalityReward(addrs, weights);

        // success case
        // balanceOfSystemReward > MAX_SYSTEM_REWARD_BALANCE
        uint256 reward = 1 ether;
        vm.deal(address(systemReward), ceil + reward);
        vm.roll(block.number + 1);

        uint256 expectReward = reward / 20;
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit finalityRewardDeposit(addrs[0], expectReward);
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit finalityRewardDeposit(addrs[9], expectReward);
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit deprecatedFinalityRewardDeposit(addrs[10], expectReward);
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit deprecatedFinalityRewardDeposit(addrs[19], expectReward);
        l2pValidatorSet.distributeFinalityReward(addrs, weights);
        assertEq(address(systemReward).balance, ceil);

        // cannot exceed MAX_REWARDS
        uint256 cap = systemReward.MAX_REWARDS();
        vm.deal(address(systemReward), ceil + cap * 2);
        vm.roll(block.number + 1);

        expectReward = cap / 20;
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit finalityRewardDeposit(addrs[0], expectReward);
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit finalityRewardDeposit(addrs[9], expectReward);
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit deprecatedFinalityRewardDeposit(addrs[10], expectReward);
        vm.expectEmit(true, false, false, true, address(l2pValidatorSet));
        emit deprecatedFinalityRewardDeposit(addrs[19], expectReward);
        l2pValidatorSet.distributeFinalityReward(addrs, weights);
        assertEq(address(systemReward).balance, ceil + cap);

        vm.stopPrank();
    }

    function _calcIncoming(uint256 value) internal view returns (uint256 incoming) {
        uint256 turnLength = l2pValidatorSet.getTurnLength();
        uint256 systemRewardAntiMEVRatio = l2pValidatorSet.systemRewardAntiMEVRatio();
        uint256 systemRewardRatio = systemRewardBaseRatio;
        if (turnLength > 1 && systemRewardAntiMEVRatio > 0) {
            systemRewardRatio += systemRewardAntiMEVRatio * (block.number % turnLength) / (turnLength - 1);
        }
        uint256 toSystemReward = (value * systemRewardRatio) / systemRewardRatioScale;
        uint256 toBurn = (value * burnRatio) / burnRatioScale;
        incoming = value - toSystemReward - toBurn;
    }
}
