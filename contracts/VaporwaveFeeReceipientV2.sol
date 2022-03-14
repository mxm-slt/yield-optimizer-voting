// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IUniswapRouterETH.sol";
import "./interfaces/IVaporRewardPool.sol";

contract VaporwaveFeeRecipientV2 is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address public wNative ;
    address public VWAVE;

    address public rewardPool;
    address public unirouter;
    address public vaultChef;

    // Fee constants
    uint public BUYBACK_FEE = 250;
    uint public REWARD_POOL_FEE = 750;
    uint constant public MAX_FEE = 1000;

    address[] public wNativeToVWAVERoute;

    constructor(
        address _rewardPool,
        address _unirouter,
        address _VWAVE,
        address _wNative,
        address _vaultChef

    ) public {
        rewardPool = _rewardPool;
        unirouter = _unirouter;
        VWAVE = _VWAVE;
        wNative  = _wNative ;
        vaultChef = _vaultChef;

        wNativeToVWAVERoute = [wNative, VWAVE];

        IERC20(wNative).safeApprove(unirouter, uint256(-1));
    }

    event NewRewardPool(address oldRewardPool, address newRewardPool);
    event NewTreasury(address oldTreasury, address newTreasury);
    event NewUnirouter(address oldUnirouter, address newUnirouter);
    event NewVaultChef(address oldVaultChef, address newVaultChef);
    event NewFees(uint newBuybackFee, uint newRewardFee);

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "!EOA");
        _;
    }

    // Main function. Divides Vaporwave's profits.
    function harvest() public onlyEOA {
        uint256 wNativeBal = IERC20(wNative).balanceOf(address(this));

        uint256 buyBackFee = wNativeBal.mul(BUYBACK_FEE).div(MAX_FEE);
        if (buyBackFee != 0) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(buyBackFee, 0, wNativeToVWAVERoute, vaultChef, now);  //  send purchased Vaporwave tokens to VaporwaveChef for reward distribution
        }

        uint256 rewardsFeeAmount = wNativeBal.mul(REWARD_POOL_FEE).div(MAX_FEE);
        IERC20(wNative).safeTransfer(rewardPool, rewardsFeeAmount);         //  send rewards
        IVaporRewardPool(rewardPool).notifyRewardAmount(rewardsFeeAmount);  //  notify rewards
    }

    // Manage the contract
    function setFees(uint _BUYBACK_FEE, uint _REWARD_POOL_FEE) external onlyOwner {
        require(_BUYBACK_FEE.add(_REWARD_POOL_FEE) <= MAX_FEE, "Fee Too High.");
        BUYBACK_FEE = _BUYBACK_FEE;
        REWARD_POOL_FEE = _REWARD_POOL_FEE;
        emit NewFees(BUYBACK_FEE, REWARD_POOL_FEE);
    }

    function setRewardPool(address _rewardPool) external onlyOwner {
        emit NewRewardPool(rewardPool, _rewardPool);
        rewardPool = _rewardPool;
    }

    function setVaultChef(address _vaultChef) external onlyOwner {
        emit NewVaultChef(vaultChef, _vaultChef);
        vaultChef = _vaultChef;
    }

    function setUnirouter(address _unirouter) external onlyOwner {

        IERC20(wNative).safeApprove(_unirouter, uint256(-1));
        IERC20(wNative).safeApprove(unirouter, 0);

        unirouter = _unirouter;
        emit NewUnirouter(unirouter, _unirouter);
    }

    // Rescue locked funds sent by mistake
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        require(_token != wNative, "!safe");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }

}