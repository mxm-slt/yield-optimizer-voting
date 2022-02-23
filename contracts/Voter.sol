// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
//// Conflict: IERC20 from OpenZepplilin with IERC20 from Boring (MiniChef import)
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 
import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; 
//import "@boringcrypto/boring-solidity/contracts/ERC20.sol";

import "./MiniChefV2.sol";

// Each voter has a corresponding ERC20 token to send to MiniChef
interface IVoter {
    function deposit(uint256 govTokenAmount) external;
}

contract Voter is IVoter, Ownable {

    MiniChefV2 public immutable miniChef;
    address public immutable rewardPool;
    IERC20 public immutable govToken;
    IERC20 public immutable voteToken;

    constructor(MiniChefV2 miniChef_, IERC20 govToken_, address rewardPool_) public {
        govToken = govToken_;
        miniChef = miniChef_;
        voteToken = new ERC20();
        //miniChef.add(1, voteToken, null);
    }

    function deposit(uint256 govTokenAmount) external override {
        miniChef.deposit(1, govTokenAmount, rewardPool);
    }

}
