// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "../interfaces/IRewarder.sol";
import "../boringcrypto/libraries/BoringMath.sol";


contract RewarderMock is IRewarder {
    using BoringMath for uint256;
    using LibBoringERC20 for IBoringERC20;
    uint256 private immutable rewardMultiplier;
    IBoringERC20 private immutable rewardToken;
    uint256 private constant REWARD_TOKEN_DIVISOR = 1e18;
    address private immutable MASTERCHEF_V2;

    constructor (uint256 _rewardMultiplier, IBoringERC20 _rewardToken, address _MASTERCHEF_V2) public {
        rewardMultiplier = _rewardMultiplier;
        rewardToken = _rewardToken;
        MASTERCHEF_V2 = _MASTERCHEF_V2;
    }

    function onVwaveReward (uint256, address user, address to, uint256 vwaveAmount, uint256) onlyMCV2 override external {
        uint256 pendingReward = vwaveAmount.mul(rewardMultiplier) / REWARD_TOKEN_DIVISOR;
        uint256 rewardBal = rewardToken.balanceOf(address(this));
        if (pendingReward > rewardBal) {
            rewardToken.safeTransfer(to, rewardBal);
        } else {
            rewardToken.safeTransfer(to, pendingReward);
        }
    }
    
//    function pendingTokens(uint256 pid, address user, uint256 vwaveAmount) override external view returns (IBoringERC20[] memory rewardTokens, uint256[] memory rewardAmounts) {
//        IBoringERC20[] memory _rewardTokens = new IBoringERC20[](1);
//        _rewardTokens[0] = (rewardToken);
//        uint256[] memory _rewardAmounts = new uint256[](1);
//        _rewardAmounts[0] = vwaveAmount.mul(rewardMultiplier) / REWARD_TOKEN_DIVISOR;
//        return (_rewardTokens, _rewardAmounts);
//    }

    modifier onlyMCV2 {
        require(
            msg.sender == MASTERCHEF_V2,
            "Only MCV2 can call this function."
        );
        _;
    }
  
}
