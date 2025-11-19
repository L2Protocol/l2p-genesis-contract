// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface GovHub {
    event failReasonWithBytes(bytes message);
    event failReasonWithStr(string message);

    function CODE_OK() external view returns (uint32);
    function ERROR_TARGET_CONTRACT_FAIL() external view returns (uint32);
    function ERROR_TARGET_NOT_CONTRACT() external view returns (uint32);
    function GOVERNOR_ADDR() external view returns (address);
    function GOV_HUB_ADDR() external view returns (address);
    function GOV_TOKEN_ADDR() external view returns (address);
    function SLASH_CONTRACT_ADDR() external view returns (address);
    function STAKE_CREDIT_ADDR() external view returns (address);
    function STAKE_HUB_ADDR() external view returns (address);
    function SYSTEM_REWARD_ADDR() external view returns (address);
    function TIMELOCK_ADDR() external view returns (address);
    function VALIDATOR_CONTRACT_ADDR() external view returns (address);
    function alreadyInit() external view returns (bool);
    function l2pChainID() external view returns (uint16);
    function updateParam(string memory key, bytes memory value, address target) external;
}
