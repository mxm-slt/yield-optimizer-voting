// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import ".././boringcrypto/libraries/LibBoringERC20.sol";
interface IRewarder {
    using LibBoringERC20 for IBoringERC20;
    function onVwaveReward(uint256 pid, address user, address recipient, uint256 vwaveAmount, uint256 newLpAmount) external;
}
