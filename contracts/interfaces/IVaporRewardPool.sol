// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IVaporRewardPool {
    function exit() external;
    function stake(uint256 amount) external ;
    function withdraw(uint256 amount) external;
    function getReward() external ;
    function balanceOf(address account) external view returns (uint256);
    function notifyRewardAmount(uint256 reward) external;
}
