// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./MiniChefV2.sol";
import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";
import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Each voter has a corresponding ERC20 token to send to MiniChef
// Exchange rate between tokens is always 1:1, 1 GovToken == 1 VoteToken
interface IVoter {
    event Vote(address indexed user, uint256 amount);
    event Unvote(address indexed user, uint256 amount);
    event Lock(address indexed user, uint256 amount, uint256 duration);
    event Paused();
    event Unpaused();
    event Retired();

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
    function lockExpiration() external view returns (uint256);

    // @return the number of votes for caller, time-locked multipliers are taken into account
    function voteCount() external view returns (uint256);

    function totalVoteCount() external view returns (uint256);

    function harvest() external;

    function pause() external;

    function unpause() external;

    function retire() external;

    function isActive() external view returns (bool);

    function isRetired() external view returns (bool);
}

contract Voter is IVoter, AccessControl, ReentrancyGuard {
    using SafeMath for uint256;

    struct UserInfo {
        uint256 unlockedAmount;
        uint256 lockedAmount;
        // unix time in seconds
        uint256 lockExpiration;
        // if lockedAmount = 100 and return coeff = 1.2 then lockBonus = 20 (lockedAmount * (multiplicator - 1))
        uint256 lockBonus;
    }

    bytes32 public constant ROLE_CAN_RETIRE = keccak256("CAN_RETIRE");
    bytes32 public constant ROLE_CAN_PAUSE = keccak256("CAN_PAUSE");

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

    enum State{ACTIVE, PAUSED, RETIRED}

    State public state = State.ACTIVE;

    constructor(MiniChefV2 miniChef_,
        uint256 chefPoolId_,
        IERC20 govToken_,
        address rewardPool_,
        ERC20PresetMinterPauser voteToken_) public {

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setRoleAdmin(ROLE_CAN_PAUSE, DEFAULT_ADMIN_ROLE);
        _setupRole(ROLE_CAN_PAUSE, _msgSender());
        _setupRole(ROLE_CAN_RETIRE, _msgSender());

        govToken = govToken_;
        miniChef = miniChef_;
        _voteToken = voteToken_;
        rewardPoolAddress = rewardPool_;
        chefPoolId = chefPoolId_;
    }

    function vote(uint256 tokenAmount) external override nonReentrant {
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

    function lock(uint256 govTokenAmount, uint256 durationSeconds) external override nonReentrant {
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

    function voteWithLock(uint256 govTokenAmount, uint256 durationSeconds) external override nonReentrant {
        require(this.isActive(), "Voting is paused");
        require(durationSeconds >= MIN_TIME_LOCK && durationSeconds <= MAX_TIME_LOCK, "Invalid duration");
        UserInfo storage userInfo = _userVotes[msg.sender];
        // make sure we have no active time locked deposit
        require(userInfo.lockExpiration < block.timestamp, "Time lock already present");
        unlockExpired(userInfo);
        // transferring GovToken from user to this contract
        govToken.transferFrom(msg.sender, address(this), govTokenAmount);

        // create new lock
        userInfo.lockedAmount = govTokenAmount;
        userInfo.lockExpiration = block.timestamp + durationSeconds;
        userInfo.lockBonus = govTokenAmount.mul(durationSeconds).div(MAX_TIME_LOCK).mul(MAX_TIME_LOCK_MULTIPLIER_PCNT).div(100);
        // deposit main and bonus amount to miniChef
        depositVotesToMinichef(userInfo.lockedAmount.add(userInfo.lockBonus));

        emit Vote(msg.sender, govTokenAmount);
    }

    function unvote(uint256 tokenAmount) external override nonReentrant {
        // decrease user vote count
        UserInfo storage userInfo = _userVotes[msg.sender];
        if (state == State.RETIRED) {
            // make sure unlockExpired() will unlock
            userInfo.lockExpiration = 0;
        }
        unlockExpired(userInfo);

        userInfo.unlockedAmount = userInfo.unlockedAmount.sub(tokenAmount, "Not enough non-locked votes");
        _totalVoteTokenAmount = _totalVoteTokenAmount.sub(tokenAmount);
        if (state == State.ACTIVE) {
            withdrawVotesFromMinichef(tokenAmount);
        } else {
            // withdrawal and burning already done when pausing or retiring
        }

        // send user their GovToken
        govToken.transfer(msg.sender, tokenAmount);
        emit Unvote(msg.sender, tokenAmount);
    }

    function harvest() external override nonReentrant {
        miniChef.harvest(chefPoolId, rewardPoolAddress);
    }

    function unlockedBalance() external override view returns (uint256) {
        UserInfo storage userInfo = _userVotes[msg.sender];
        return userInfo.unlockedAmount;
    }

    function lockedBalance() external override view returns (uint256) {
        UserInfo storage userInfo = _userVotes[msg.sender];
        return userInfo.lockedAmount;
    }

    function totalBalance() external override view returns (uint256) {
        UserInfo storage userInfo = _userVotes[msg.sender];
        return userInfo.unlockedAmount.add(userInfo.lockedAmount);
    }

    function lockExpiration() external override view returns (uint256) {
        UserInfo storage userInfo = _userVotes[msg.sender];
        return userInfo.lockExpiration;
    }

    function voteCount() external override view returns (uint256) {
        UserInfo storage userInfo = _userVotes[msg.sender];
        return userInfo.lockedAmount.add(userInfo.unlockedAmount).add(userInfo.lockBonus);
    }

    function totalVoteCount() external override view returns (uint256) {
        return _totalVoteTokenAmount;
    }

    function pause() external override {
        require(hasRole(ROLE_CAN_PAUSE, msg.sender), "Caller cannot pause/unpause");
        require(state == State.ACTIVE, "Voting is not active");
        state = State.PAUSED;
        withdrawAndHarvestAll();
        emit Paused();
    }

    function unpause() external override {
        require(hasRole(ROLE_CAN_PAUSE, msg.sender), "Caller cannot pause/unpause");
        require(state == State.PAUSED, "Voting is not paused");
        state = State.ACTIVE;
        if (_totalVoteTokenAmount > 0) {
            depositVotesToMinichef(_totalVoteTokenAmount);
        }
        emit Unpaused();
    }

    function retire() external override {
        require(hasRole(ROLE_CAN_RETIRE, msg.sender), "Caller cannot retire");
        require(state != State.RETIRED, "Already retired");
        if (state == State.ACTIVE) {
            withdrawAndHarvestAll();
        }
        state = State.RETIRED;
        emit Retired();
    }

    function isActive() external view override returns (bool) {
        return state == State.ACTIVE;
    }

    function isRetired() external view override returns (bool) {
        return state == State.RETIRED;
    }

    function withdrawAndHarvestAll() private {
        miniChef.harvest(chefPoolId, rewardPoolAddress);
        if (_totalVoteTokenAmount > 0) {
            withdrawVotesFromMinichef(_totalVoteTokenAmount);
        }
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
                if (state == State.ACTIVE) {
                    withdrawVotesFromMinichef(userInfo.lockBonus);
                } else {
                    // otherwise withdrawal already happened when retiring / pausing
                }
                _totalVoteTokenAmount = _totalVoteTokenAmount.sub(userInfo.lockBonus);
                userInfo.lockBonus = 0;
            }
            userInfo.lockedAmount = 0;
            userInfo.lockExpiration = 0;
        }
    }

}