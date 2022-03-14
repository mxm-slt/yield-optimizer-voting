// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IRewardDistributionRecipient {
    function notifyRewardAmount(uint256 reward) external virtual;
}
