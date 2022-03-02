// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./MiniChefV2.sol";
import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";

// Each voter has a corresponding ERC20 token to send to MiniChef
// Exchange rate between tokens is always 1:1, 1 GovToken == 1 VoteToken
interface IVoter {
    event Vote(address indexed user, uint256 amount);
    event Unvote(address indexed user, uint256 amount);

    function vote(uint256 govTokenAmount) external;

    function unvote(uint256 govTokenAmount) external;

    function harvest() external;

    function voteCount() external view returns (uint256);

    function pause() external;

    function unpause() external;

    function isActive() external returns (bool);
}

contract Voter is IVoter, Ownable {
    using SafeMath for uint256;

    MiniChefV2 public immutable miniChef;
    address public immutable rewardPoolAddress;
    IERC20 public immutable govToken;
    uint256 public immutable chefPoolId;

    ERC20PresetMinterPauser immutable _voteToken;
    mapping(address => uint256) private _userVotes;

    uint8 constant DEFAULT_ALLOC_POINT = 1;

    constructor(MiniChefV2 miniChef_, 
                uint256 chefPoolId_, 
                IERC20 govToken_, 
                address rewardPool_, 
                ERC20PresetMinterPauser voteToken_) public {
        govToken = govToken_;
        miniChef = miniChef_;
        _voteToken = voteToken_;
        rewardPoolAddress = rewardPool_;
        chefPoolId = chefPoolId_;
    }

    function vote(uint256 tokenAmount) external override {
        require(this.isActive(), "Voting is inactive");
        // transferring GovToken from user to this contract
        govToken.transfer(address(this), tokenAmount);
        // remember user vote count
        _userVotes[msg.sender] = _userVotes[msg.sender].add(tokenAmount);
        // mint and approve VoteToken transfer, the transfer will be done by miniChef
        _voteToken.mint(address(this), tokenAmount);
        _voteToken.approve(address(miniChef), tokenAmount);
        // deposit VoteToken to our contract
        miniChef.deposit(chefPoolId, tokenAmount, address(this));
        emit Vote(msg.sender, tokenAmount);
    }

    function unvote(uint256 tokenAmount) external override {
        // decrease user vote count
        _userVotes[msg.sender] = _userVotes[msg.sender].sub(tokenAmount, "Not enough votes");
        // withdraw VoteToken from minichef
        miniChef.withdraw(chefPoolId, tokenAmount, address(this));
        // burn withdrawn vote tokens
        _voteToken.burn(tokenAmount);
        // send user their GovToken
        govToken.transfer(msg.sender, tokenAmount);
        emit Unvote(msg.sender, tokenAmount);
    }

    function harvest() external override {
        miniChef.harvest(chefPoolId, rewardPoolAddress);
    }

    function voteCount() external override view returns (uint256) {
        return _userVotes[msg.sender];
    }

    function pause() external override onlyOwner {
        //        _voteToken.pause();
    }

    function unpause() external override onlyOwner {
        //        _voteToken.unpause();
    }

    function isActive() external override returns (bool) {
        return _voteToken.paused();
    }

}