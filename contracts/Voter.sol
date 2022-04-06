// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./MiniChefV2.sol";
import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";
import "hardhat/console.sol";


// vote(amount) + lock(amount, time)
// unvote(amount) - check whether there are unlockable votes (locked but expired)
//

// 1. deposit(amount, time)
// 2. undeposit()





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
    event Lock(address indexed user, uint256 amount, uint256 duration);
    event Paused();
    event Unpaused();

    // deposit tokens without time lock
    function vote(uint256 govTokenAmount) external;

    // lock previously deposited tokens, only one time locked deposit per user is allowed
    function lock(uint256 govTokenAmount, uint256 durationSeconds) external;

    // deposit tokens with time lock, only one time locked deposit per user is allowed
    // vote(amount, duration) is the same as vote(amount) and lock(amount, duration)
    function voteWithLock(uint256 govTokenAmount, uint256 durationSeconds) external;

    // withdraw non locked tokens
    function unvote(uint256 govTokenAmount) external;

    // @return unlocked GovToken balance
    function unlockedBalance() external view returns (uint256);
    // @return locked GovToken balance
    function lockedBalance() external view returns (uint256);
    // @return total GovToken balance
    function totalBalance() external view returns (uint256);
    // @return the number of votes for caller, time-locked multipliers are taken into account
    function voteCount() external view returns (uint256);

    function totalVoteCount() external view returns (uint256);

    function harvest() external;

    function pause() external;

    function unpause() external;

    function isActive() external returns (bool);
}

contract Voter is IVoter, Ownable {
    using SafeMath for uint256;

    struct UserInfo {
        uint256 unlockedAmount;
        uint256 lockedAmount;
        // unix time in seconds
        uint256 lockExpiration;
        // if lockedAmount = 100 and return coeff = 1.2 then lockBonus = 20 (lockedAmount * (multiplicator - 1))
        uint256 lockBonus;
    }

    uint8 constant DEFAULT_ALLOC_POINT = 1;
    uint32 public constant MIN_TIME_LOCK = 60 * 60 * 24 * 7; // one week
    uint32 public constant MAX_TIME_LOCK = 60 * 60 * 24 * 365 * 4; // 4 years
    uint32 public constant MAX_TIME_LOCK_MULTIPLIER_PCNT = 40;

    MiniChefV2 public immutable miniChef;
    address public immutable rewardPoolAddress;
    IERC20 public immutable govToken;
    uint256 public immutable chefPoolId;

    ERC20PresetMinterPauser immutable _voteToken;
    uint private _totalVoteTokenAmount;
    mapping(address => UserInfo) private _userVotes;

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

    function doVote(uint256 tokenAmount) private {
        require(this.isActive(), "Voting is paused");
        // transferring GovToken from user to this contract
        govToken.transferFrom(msg.sender, address(this), tokenAmount);
        // remember user vote count
        UserInfo storage userInfo = _userVotes[msg.sender];
        userInfo.unlockedAmount = userInfo.unlockedAmount.add(tokenAmount);
        // deposit vote tokens to miniChef
        depositVotesToMinichef(tokenAmount);
        emit Vote(msg.sender, tokenAmount);
    }

    function vote(uint256 tokenAmount) external override {
        doVote(tokenAmount);
    }

    function doLock(uint256 govTokenAmount, uint256 durationSeconds) private {
        require(this.isActive(), "Voting is paused");
        require(durationSeconds >= MIN_TIME_LOCK && durationSeconds <= MAX_TIME_LOCK, "Invalid duration");
        UserInfo storage userInfo = _userVotes[msg.sender];
        // make sure we have no active time locked deposit
        require(userInfo.lockExpiration < block.timestamp, "Time lock already present");
        unlockExpired(userInfo);

        // create new lock
        userInfo.unlockedAmount = userInfo.unlockedAmount.sub(govTokenAmount, "Not enough tokens");
        userInfo.lockedAmount = govTokenAmount;
        userInfo.lockExpiration = block.timestamp + durationSeconds;
        // TODO calculate coeff
        userInfo.lockBonus = govTokenAmount.mul(durationSeconds).div(MAX_TIME_LOCK).mul(MAX_TIME_LOCK_MULTIPLIER_PCNT).div(100);
        // deposit bonus amount to miniChef
        depositVotesToMinichef(userInfo.lockBonus);
    }

    function lock(uint256 govTokenAmount, uint256 durationSeconds) external override {
        doLock(govTokenAmount, durationSeconds);
    }

    function voteWithLock(uint256 govTokenAmount, uint256 durationSeconds) external override {
        doVote(govTokenAmount);
        doLock(govTokenAmount, durationSeconds);
    }

    function unvote(uint256 tokenAmount) external override {
        // decrease user vote count
        UserInfo storage userInfo = _userVotes[msg.sender];
        unlockExpired(userInfo);
        userInfo.unlockedAmount = userInfo.unlockedAmount.sub(tokenAmount, "Not enough non-locked votes");
        _totalVoteTokenAmount = _totalVoteTokenAmount.sub(tokenAmount);

        if (active) {
            withdrawVotesFromMinichef(tokenAmount);
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

    function unlockedBalance() external override view returns (uint256) {
        return _userVotes[msg.sender].unlockedAmount;
    }

    function lockedBalance() external override view returns (uint256) {
        return _userVotes[msg.sender].lockedAmount;
    }

    function totalBalance() external override view returns (uint256) {
        UserInfo storage userInfo = _userVotes[msg.sender];
        return userInfo.unlockedAmount.add(userInfo.lockedAmount);
    }

    function voteCount() external override view returns (uint256) {
        UserInfo storage userInfo = _userVotes[msg.sender];
        return userInfo.lockedAmount.add(userInfo.unlockedAmount).add(userInfo.lockBonus);
    }

    function totalVoteCount() external override view returns (uint256) {
        return _totalVoteTokenAmount;
    }

    function pause() external override onlyOwner {
        require(this.isActive(), "Voting is already paused");
        active = false;
        if (_totalVoteTokenAmount > 0) {
            miniChef.withdrawAndHarvest(chefPoolId, _totalVoteTokenAmount, rewardPoolAddress);
            _voteToken.burn(_totalVoteTokenAmount);
        }
        emit Paused();
    }

    function unpause() external override onlyOwner {
        require(!this.isActive(), "Voting is active");
        active = true;
        if (_totalVoteTokenAmount > 0) {
            depositVotesToMinichef(_totalVoteTokenAmount);
        }
        emit Unpaused();
    }

    function isActive() external override returns (bool) {
        return active;
    }

    function withdrawVotesFromMinichef(uint256 tokenAmount) private {
        // withdraw VoteToken from minichef
        miniChef.withdraw(chefPoolId, tokenAmount);
        // burn withdrawn vote tokens
        _voteToken.burn(tokenAmount);
    }

    function depositVotesToMinichef(uint256 tokenAmount) private {
        _totalVoteTokenAmount = _totalVoteTokenAmount.add(tokenAmount);
        // mint and approve VoteToken transfer, the transfer will be done by miniChef
        _voteToken.mint(address(this), tokenAmount);
        _voteToken.approve(address(miniChef), tokenAmount);
        // deposit VoteToken to our contract address
        miniChef.deposit(chefPoolId, tokenAmount);
    }

    function unlockExpired(UserInfo storage userInfo) private {
        if (userInfo.lockExpiration < block.timestamp && userInfo.lockedAmount > 0) {
            userInfo.unlockedAmount = userInfo.unlockedAmount.add(userInfo.lockedAmount);
            if (userInfo.lockBonus > 0) {
                withdrawVotesFromMinichef(userInfo.lockBonus);
                _totalVoteTokenAmount -= userInfo.lockBonus;
                userInfo.lockBonus = 0;
            }
            userInfo.lockedAmount = 0;
            userInfo.lockExpiration = 0;
        }
    }

}