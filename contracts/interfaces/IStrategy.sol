// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrategy {
    function vault() external view returns (address); // TODO none of the strategies implement this???
    function want() external view returns (IERC20);
    function beforeDeposit() external;
    function deposit() external;
    function withdraw(uint256) external;
    function balanceOf() external view returns (uint256);
    function balanceOfWant() external view returns (uint256);
    function balanceOfPool() external view returns (uint256);
    function harvest() external;
    function retireStrat() external;
    function panic() external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    function unirouter() external view returns (address);
}
