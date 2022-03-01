// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "../interfaces/IRewarder.sol";


contract RewarderBrokenMock is IRewarder {

    function onVwaveReward (uint256, address, address, uint256, uint256) override external {
        revert();
    }

}
