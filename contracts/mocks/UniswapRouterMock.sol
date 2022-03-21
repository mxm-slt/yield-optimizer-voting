// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../interfaces/IUniswapRouterETH.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniswapRouterMock is IUniswapRouterETH {

    IERC20 private inToken;
    IERC20 private outToken;

    constructor (address _inToken, address _outToken) public {
        inToken = IERC20(_inToken);
        outToken = IERC20(_outToken);
    }


    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external override returns (uint amountA, uint amountB, uint liquidity) {
        return (0, 0, 0);
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external override payable returns (uint amountToken, uint amountETH, uint liquidity) {
        return (0, 0, 0);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external override returns (uint amountA, uint amountB) {
        return (0, 0);
    }

    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external override returns (uint amountToken, uint amountETH) {
        return (0, 0);
    }

    function swapExactTokensForTokens(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external override returns (uint[] memory amounts) {
        // 1:1 swap
        inToken.transferFrom(msg.sender, address(this), amountIn);
        outToken.transfer(to, amountIn);

        uint[] memory value = new uint[](0);
        return value;
    }

    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        override
        returns (uint[] memory amounts) {
            uint[] memory value = new uint[](0);
            return value;
        }
    
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        override
        returns (uint[] memory amounts) {
            uint[] memory value = new uint[](0);
            return value;

        }

    function getAmountsOut(uint amountIn, address[] calldata path) 
        external 
        view 
        override 
        returns (uint[] memory amounts) {
            uint[] memory value = new uint[](0);
            return value;
        }


}