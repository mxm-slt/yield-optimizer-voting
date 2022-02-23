// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import ".././boringcrypto/libraries/LibBoringERC20.sol";
interface IRewarder {
    using LibBoringERC20 for IBoringERC20;
    function onSushiReward(uint256 pid, address user, address recipient, uint256 sushiAmount, uint256 newLpAmount) external;
    function pendingTokens(uint256 pid, address user, uint256 sushiAmount) external view returns (IBoringERC20[] memory, uint256[] memory);
}
