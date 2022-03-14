// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./MiniChefV2.sol";
import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";

// Time lock multiplicator ideas:
// If user stores X amount of funds for at least T days, he's given extra X*m extra VoteTokens that
// are deposited to MiniChef. Any withdrawal resets extra VoteTokens.
// Implementation questions:
// 1. Where to store this information?
//      A. Instead of storing just vote count per user inside voter we can introduce UserInfo structure
//         UserInfo(uint voteCount, uint minVoteCountPerPeriod, uint minVoteCountUpdateTime, uint extraVotes).
//         How we work with it:
//         vote(): voteCount += amount, 
//         unvote(): voteCount -= amount, minVoteCountPerPeriod = voteCount, minVoteCountTime = now(), extraVotes = 0
//         claimExtra(): if (now() -
//      B. 
//

// Each voter has a corresponding ERC20 token to send to MiniChef
// Exchange rate between tokens is always 1:1, 1 GovToken == 1 VoteToken
interface IVoter {
    event Vote(address indexed user, uint256 amount);
    event Unvote(address indexed user, uint256 amount);
    event Paused();
    event Unpaused();

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
    uint private _totalTokenAmount;
    mapping(address => uint256) private _userVotes;

    uint8 constant DEFAULT_ALLOC_POINT = 1;

    bool public active = true;

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
        require(this.isActive(), "Voting is paused");
        // transferring GovToken from user to this contract
        govToken.transferFrom(msg.sender, address(this), tokenAmount);
        // remember user vote count
        _userVotes[msg.sender] = _userVotes[msg.sender].add(tokenAmount);
        _totalTokenAmount = _totalTokenAmount.add(tokenAmount);
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
        _totalTokenAmount = _totalTokenAmount.sub(tokenAmount);

        if (active) {
            // withdraw VoteToken from minichef
            miniChef.withdraw(chefPoolId, tokenAmount, address(this));
            // burn withdrawn vote tokens
            _voteToken.burn(tokenAmount);
        } else {
            // withdrawal and burning already done when pausing
        }
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
        require(this.isActive(), "Voting is already paused");
        active = false;
        if (_totalTokenAmount > 0) {
            miniChef.withdrawAndHarvest(chefPoolId, _totalTokenAmount, rewardPoolAddress);
            _voteToken.burn(_totalTokenAmount);
        }
        emit Paused();
    }

    function unpause() external override onlyOwner {
        require(!this.isActive(), "Voting is active");
        active = true;
        if (_totalTokenAmount > 0) {
            _voteToken.mint(address(this), _totalTokenAmount);
            _voteToken.approve(address(miniChef), _totalTokenAmount);
            miniChef.deposit(chefPoolId, _totalTokenAmount, address(this));
        }
        emit Unpaused();
    }

    function isActive() external override returns (bool) {
        return active;
    }

}