// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

interface IStakeCredit {
    function initialize(address operatorAddress, string memory moniker) external payable;
    function claim(address delegator, uint256 requestNumber) external returns (uint256);
    function totalPooledL2P() external view returns (uint256);
    function getPooledL2PByShares(uint256 shares) external view returns (uint256);
    function getSharesByPooledL2P(uint256 l2pAmount) external view returns (uint256);
    function delegate(address delegator) external payable returns (uint256);
    function undelegate(address delegator, uint256 shares) external returns (uint256);
    function unbond(address delegator, uint256 shares) external returns (uint256);
    function distributeReward(uint64 commissionRate) external payable;
    function slash(uint256 slashL2pAmount) external returns (uint256);
    function balanceOf(address delegator) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getPooledL2P(address account) external view returns (uint256);
    function rewardRecord(uint256 dayIndex) external view returns (uint256);
    function totalPooledL2PRecord(uint256 dayIndex) external view returns (uint256);
}
