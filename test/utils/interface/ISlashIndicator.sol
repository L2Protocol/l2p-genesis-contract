// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface SlashIndicator {
    struct FinalityEvidence {
        VoteData voteA;
        VoteData voteB;
        bytes voteAddr;
    }

    struct VoteData {
        uint256 srcNum;
        bytes32 srcHash;
        uint256 tarNum;
        bytes32 tarHash;
        bytes sig;
    }

    event failedFelony(address indexed validator, uint256 slashCount, bytes failReason);
    event indicatorCleaned();
    event paramChange(string key, bytes value);
    event validatorSlashed(address indexed validator);

    function CODE_OK() external view returns (uint32);
    function DECREASE_RATE() external view returns (uint256);
    function FELONY_THRESHOLD() external view returns (uint256);
    function GOVERNOR_ADDR() external view returns (address);
    function GOV_HUB_ADDR() external view returns (address);
    function GOV_TOKEN_ADDR() external view returns (address);
    function INIT_FELONY_SLASH_REWARD_RATIO() external view returns (uint256);
    function INIT_FELONY_SLASH_SCOPE() external view returns (uint256);
    function MISDEMEANOR_THRESHOLD() external view returns (uint256);
    function SLASH_CONTRACT_ADDR() external view returns (address);
    function STAKE_CREDIT_ADDR() external view returns (address);
    function STAKE_HUB_ADDR() external view returns (address);
    function STAKING_CONTRACT_ADDR() external view returns (address);
    function SYSTEM_REWARD_ADDR() external view returns (address);
    function TIMELOCK_ADDR() external view returns (address);
    function VALIDATOR_CONTRACT_ADDR() external view returns (address);
    function alreadyInit() external view returns (bool);
    function l2pChainID() external view returns (uint16);
    function clean() external;
    function downtimeSlash(address validator, uint256 count, bool shouldRevert) external;
    function enableMaliciousVoteSlash() external view returns (bool);
    function felonySlashRewardRatio() external view returns (uint256);
    function felonySlashScope() external view returns (uint256);
    function felonyThreshold() external view returns (uint256);
    function getSlashIndicator(address validator) external view returns (uint256, uint256);
    function getSlashThresholds() external view returns (uint256, uint256);
    function indicators(address) external view returns (uint256 height, uint256 count, bool exist);
    function init() external;
    function misdemeanorThreshold() external view returns (uint256);
    function previousHeight() external view returns (uint256);
    function sendFelonyPackage(address validator) external;
    function slash(address validator) external;
    function submitDoubleSignEvidence(bytes memory header1, bytes memory header2) external;
    function submitFinalityViolationEvidence(FinalityEvidence memory _evidence) external;
    function updateParam(string memory key, bytes memory value) external;
    function validators(uint256) external view returns (address);
}
