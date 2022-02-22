pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MiniChefV2.sol";

// Each voter has a corresponding ERC20 token to send to MiniChef
interface IVoter {
    function deposit(uint256 govTokenAmount);
}

contract Voter is IVoter, Ownable {

    MiniChefV2 public immutable miniChef;
    address public immutable rewardPool;
    IERC20 public immutable govToken;
    IERC20 public immutable voteToken;

    constructor(MiniChefV2 miniChef_, IERC20 govToken_, address rewardPool_) {
        govToken = govToken_;
        miniChef = miniChef_;
        voteToken = new ERC20();
        miniChef.add(?1?, voteToken, null);
    }

    function deposit(uint256 govTokenAmount) {
        miniChef.deposit(pid, govTokenAmount, rewardPool);
    }

}
