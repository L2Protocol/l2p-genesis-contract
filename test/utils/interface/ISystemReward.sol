// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface SystemReward {
    event addOperator(address indexed operator);
    event deleteOperator(address indexed operator);
    event paramChange(string key, bytes value);
    event receiveDeposit(address indexed from, uint256 amount);
    event rewardEmpty();
    event rewardTo(address indexed to, uint256 amount);

    receive() external payable;

    function CODE_OK() external view returns (uint32);
    function GOVERNOR_ADDR() external view returns (address);
    function GOV_HUB_ADDR() external view returns (address);
    function GOV_TOKEN_ADDR() external view returns (address);
    function MAX_REWARDS() external view returns (uint256);
    function SLASH_CONTRACT_ADDR() external view returns (address);
    function STAKE_CREDIT_ADDR() external view returns (address);
    function STAKE_HUB_ADDR() external view returns (address);
    function STAKING_CONTRACT_ADDR() external view returns (address);
    function SYSTEM_REWARD_ADDR() external view returns (address);
    function TIMELOCK_ADDR() external view returns (address);
    function VALIDATOR_CONTRACT_ADDR() external view returns (address);
    function alreadyInit() external view returns (bool);
    function l2pChainID() external view returns (uint16);
    function claimRewards(address payable to, uint256 amount) external returns (uint256);
    function isOperator(address addr) external view returns (bool);
    function numOperator() external view returns (uint256);
    function updateParam(string memory key, bytes memory value) external;
}
