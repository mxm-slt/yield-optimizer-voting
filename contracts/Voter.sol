// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
//// Conflict: IERC20 from OpenZepplilin with IERC20 from Boring (MiniChef import)
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
//import "@boringcrypto/boring-solidity/contracts/ERC20.sol";

import "./MiniChefV2.sol";
import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";

// Each voter has a corresponding ERC20 token to send to MiniChef
interface IVoter {
    function vote(uint256 govTokenAmount) external;

    function unvote(uint256 govTokenAmount) external;

    function voteCount() external returns (uint256);

    function totalVoteCount() external returns (uint256);

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

    mapping (address => uint256) private _userVotes;

    uint8 constant DEFAULT_ALLOC_POINT = 1;

    constructor(MiniChefV2 miniChef_, IERC20 govToken_, address rewardPool_) public {
        govToken = govToken_;
        miniChef = miniChef_;
        _voteToken = new ERC20PresetMinterPauser("VaporVoter", "VVT");
        chefPoolId = miniChef.add(DEFAULT_ALLOC_POINT, _voteToken, null);
    }

    function vote(uint256 govTokenAmount) external override {
        require(this.isActive(), "Voting for this voter is paused");
        // transferring GovToken from user to this contract
        govToken.transfer(address(this), govTokenAmount);
        // remember user vote count
        _userVotes[msg.sender] = _userVotes[msg.sender].add(govTokenAmount);
        // mint and approve VoteToken transfer, the transfer will be done by miniChef
        _voteToken.mint(address(this), govTokenAmount);
        voteToken.approve(address(miniChef), govTokenAmount);
        miniChef.deposit(chefPoolId, govTokenAmount, rewardPoolAddress);
    }

    function unvote(uint256 govTokenAmount) external override {
        // decrease user vote count
        _userVotes[msg.sender] = _userVotes[msg.sender].sub(govTokenAmount, "Not enough votes");
        // withdraw VoteToken from minichef
        miniChef.withdraw(chefPoolId, govTokenAmount, address(this));
        // send user their GovToken
        govToken.transfer(msg.sender, govTokenAmount);
    }

    function voteCount() external override returns (uint256) {
        return _userVotes[msg.sender];
    }

    function pause() external override onlyOwner {
        _voteToken.pause();
    }

    function unpause() external override onlyOwner {
        _voteToken.unpause();
    }

    function isActive() external override returns (bool) {
        return _voteToken.paused();
    }

}
