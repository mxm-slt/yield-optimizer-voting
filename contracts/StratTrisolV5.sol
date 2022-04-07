// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/IMiniChefV2.sol";
import "./interfaces/IUniswapRouterETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IRewarder.sol";
import "./libraries/StratTrisolV5FeeManager.sol";
import "./libraries/StratTrisolV5StratsManager.sol";

contract StratTrisolV5 is StratTrisolV5StratsManager, StratTrisolV5FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address constant public wrapped = address(0xC9BdeEd33CD01541e1eeD10f90519d2C06Fe3feB);  //  wrapped ETH. 
    address constant public output = address(0xFa94348467f64D5A457F75F8bc40495D33c65aBB);   //  TRI the farm reward token
    address public dualReward;
    address public want;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address constant public masterchef = address(0x1f1Ed214bef5E83D8f5d0eB5D7011EB965D0D79B);   //  trisol masterchef 
    uint256 public poolId;

    uint256 public lastHarvest;
    uint256 public liquidityBal;
    // Routes
    address[] public outputToWrappedRoute;
    address[] public outputToLp0Route;
    address[] public outputToLp1Route;
    address[] public dualRewardToOutputRoute;
    address[] public lp0ToOutputRoute;
    address[] public lp1ToOutputRoute;

    //  boolean checks
    bool public charged = false;
    bool public swapped = false;
    bool public harvested = false;
    bool public isRetired = false;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event lpSwapped();
    event addedLiquidity();
    event panicking();
    event dualRewardChanged();
    event manualRebalanced();

    constructor(
        address _want,
        //uint256 _poolId,
        address _unirouter,
        address _harvester,
        address[] memory _outputToWrappedRoute,
        address[] memory _outputToLp0Route,
        address[] memory _outputToLp1Route,
        address[] memory _dualRewardToOutputRoute,
        address[] memory _lp0ToOutputRoute,
        address[] memory _lp1ToOutputRoute
    ) StratTrisolV5StratsManager(_harvester, _unirouter) public {
        want = _want;
        poolId = 0;
        
        outputToWrappedRoute = _outputToWrappedRoute;
        dualReward = _dualRewardToOutputRoute[0];
        dualRewardToOutputRoute = _dualRewardToOutputRoute;
        lp0ToOutputRoute = _lp0ToOutputRoute;
        lp1ToOutputRoute = _lp1ToOutputRoute;

        // setup lp routing
        lpToken0 = IUniswapV2Pair(want).token0();
        require(_outputToLp0Route[0] == output, "outputToLp0Route[0] != output");
        require(_outputToLp0Route[_outputToLp0Route.length - 1] == lpToken0, "outputToLp0Route[last] != lpToken0");
        outputToLp0Route = _outputToLp0Route;


        lpToken1 = IUniswapV2Pair(want).token1();
        require(_outputToLp1Route[0] == output, "outputToLp1Route[0] != output");
        require(_outputToLp1Route[_outputToLp1Route.length - 1] == lpToken1, "outputToLp1Route[last] != lpToken1");
        outputToLp1Route = _outputToLp1Route;

        _giveAllowances();
    }

    function setDualReward(address[] memory _dualRewardToOutputRoute) external onlyManager {
        dualReward = _dualRewardToOutputRoute[0];
        dualRewardToOutputRoute = _dualRewardToOutputRoute;
        IERC20(dualReward).safeApprove(unirouter, 0);
        IERC20(dualReward).safeApprove(unirouter, uint256(-1));
        emit dualRewardChanged();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            //IMiniChefV2(masterchef).deposit(poolId, wantBal);
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            //IMiniChefV2(masterchef).withdraw(poolId, _amount.sub(wantBal));  
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFeeAmount));
        }
        emit Withdraw(balanceOf());
    }

    // compounds earnings and charges performance fee
    function harvest() external whenNotPaused {
            if (charged) { 
                if (swapped){   
                    addLiquidity(); 
                    uint256 wantHarvested = balanceOfWant();
                    //IMiniChefV2(masterchef).deposit(poolId, wantHarvested);   
                    toggleHarvest();
                    lastHarvest = block.timestamp;
                    emit StratHarvest(msg.sender, wantHarvested, balanceOf());  
                } else {
                    swap(); 
                }
            } else { 
                if (harvested) {
                    uint256 outputBal = IERC20(output).balanceOf(address(this));
                    if (outputBal > 0) {
                        chargeFees();
                }
            }   else {
                harvestAndSwap();
            }
        }
    }

    //  harvest and swap reward token
    function harvestAndSwap() internal {
        //IMiniChefV2(masterchef).deposit(poolId, 0);  
        harvested = true;
        uint256 toOutput = IERC20(dualReward).balanceOf(address(this));
        if (toOutput > 0) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(toOutput, 0, dualRewardToOutputRoute, address(this), now.add(600));
        }
    }

     // performance fees
    function chargeFees() internal {

        uint256 toWrapped = IERC20(output).balanceOf(address(this)).mul(42).div(1000);  //  4.2%
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toWrapped, 0, outputToWrappedRoute, address(this), now.add(600));

        uint256 wrappedBal = IERC20(wrapped).balanceOf(address(this));  

        uint256 callFeeAmount = wrappedBal.mul(callFee).div(MAX_FEE);
        uint256 treasuryFee = wrappedBal.mul(TREASURY_FEE).div(MAX_FEE);
        uint256 platformFee = callFeeAmount.add(treasuryFee);
        IERC20(wrapped).safeTransfer(treasury, platformFee);

        uint256 vaporwaveFeeAmount = wrappedBal.mul(vaporwaveFee).div(MAX_FEE);
        IERC20(wrapped).safeTransfer(vaporwaveFeeRecipient, vaporwaveFeeAmount);

        charged = true;
        liquidityBal = IERC20(output).balanceOf(address(this));
        bool tradeLP0 = lpToken0 != output ? canTrade(liquidityBal.div(2), outputToLp0Route): true;
        bool tradeLP1 = lpToken1 != output ? canTrade(liquidityBal.div(2), outputToLp1Route): true;
        require(tradeLP0 == true && tradeLP1 == true, "Not enough output");
    }


    function swap() internal  {
        uint256 outputHalf = liquidityBal.div(2);

        if (lpToken0 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp0Route, address(this), now);
        }

        if (lpToken1 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp1Route, address(this), now);
        }
        swapped = true;
        emit lpSwapped();
    }


    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 lpBal0 = IERC20(lpToken0).balanceOf(address(this));
        uint256 lpBal1 = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(lpToken0, lpToken1, lpBal0, lpBal1, 1, 1, address(this), now);
        liquidityBal = 0;
        emit addedLiquidity();
    }

    // Toggle harvest cycle to false to start again 
    function toggleHarvest() internal {
        charged = false;
        swapped = false;
        harvested = false;
    }

    // it calculates how much 'rewardToken' the strategy is earning.
    function pendingRewards() external view returns (uint256) {
        uint256 _amount = 0; // = IMiniChefV2(masterchef).pendingTri(poolId, address(this));
        return _amount;
    }

    function dualRewardBal() external view returns (uint256) {
        uint256 _dualRewardBal = IERC20(dualReward).balanceOf(address(this));
        return _dualRewardBal;
    }

    function outputBal() external view returns (uint256) {
        uint256 _outputBal = IERC20(output).balanceOf(address(this));
        return _outputBal;
    }
    
    function lp0Bal() external view returns (uint256) {
        uint256 _lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        return _lp0Bal;
    }

    function lp1Bal() external view returns (uint256) {
        uint256 _lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        return _lp1Bal;
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMiniChefV2(masterchef).userInfo(poolId, address(this));
        return _amount;
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        uint256 first = 0; // IMiniChefV2(masterchef).pendingTri(poolId, address(this));
        return first;
    }

    // Validates if we can trade because of decimals
    function canTrade(uint256 tradeableOutput, address[] memory route) internal view returns (bool tradeable) {
        try IUniswapRouterETH(unirouter).getAmountsOut(tradeableOutput, route)
            returns (uint256[] memory amountOut) 
            {
                uint256 amount = amountOut[amountOut.length -1];
                if (amount > 0) {
                    tradeable = true;
                }
            }
            catch { 
                tradeable = false; 
            }
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        //IMiniChefV2(masterchef).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).safeTransfer(vault, wantBal);
        isRetired = true;
    }

    function removeDust() external onlyManager {
        require(isRetired, "nope");
        uint256 _lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 _lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        uint256 outputDust = IERC20(output).balanceOf(address(this));

        if (_lp0Bal != 0) {
            IERC20(lpToken0).safeTransfer(treasury, _lp0Bal);
        }
        if (_lp1Bal != 0) {
            IERC20(lpToken1).safeTransfer(treasury, _lp1Bal);
        }
        if (lpToken0 != output && lpToken1 != output && outputDust != 0) {
            IERC20(output).safeTransfer(treasury, outputDust);
        }
    }

    //  if there is an abudnance of unbalanced lpToken0/1 dust,
    //  this sells both back to OUTPUT 
    //  and the autocomp loop will return the OUTPUT to lpTokens to create more WANT
    function manualRebalance() external onlyManager {
        toggleHarvest();
        uint256 lpToken0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lpToken1Bal = IERC20(lpToken1).balanceOf(address(this));

        if (lpToken0Bal != 0 && lpToken0 != output) { 
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(lpToken0Bal, 0, lp0ToOutputRoute, address(this), now.add(600));
        }
        if (lpToken1Bal != 0 && lpToken1 != output) { 
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(lpToken1Bal, 0, lp1ToOutputRoute, address(this), now.add(600));
        }
        
        emit manualRebalanced();
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() external onlyManager {
        pause();
        //IMiniChefV2(masterchef).emergencyWithdraw(poolId);
        emit panicking();
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(masterchef, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));

        IERC20(dualReward).safeApprove(unirouter, 0);
        IERC20(dualReward).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(masterchef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(dualReward).safeApprove(unirouter, 0);
    }

    function outputToWrapped() external view returns (address[] memory) {
        return outputToWrappedRoute;
    }

    function outputToLp0() external view returns (address[] memory) {
        return outputToLp0Route;
    }

    function outputToLp1() external view returns (address[] memory) {
        return outputToLp1Route;
    }

    function dualRewardToOutput() external view returns (address[] memory) {
        return dualRewardToOutputRoute;
    }
}