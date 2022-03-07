// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Voter.sol";
import "./VwaveRewarder.sol";

// Factory is owned by deployer acc
// MiniChef is owned by Factory
// VoterToken is owned by Factory
// Voter is owned by Factory
// 
contract VwaveFactory is Ownable {
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    event LOG_NEW_VOTER(
        address indexed caller,
        address indexed voter
    );
    uint8 constant DEFAULT_ALLOC_POINT = 1;
    uint256 public constant VWAVE_PER_SECOND = 10000000000000000;
    mapping(address=>bool) private _isVoter;

    MiniChefV2 public immutable miniChef;
    IERC20 public immutable govToken;
    uint256 public immutable chefPoolId;
    ERC20PresetMinterPauser private immutable _voteToken;
    VwaveRewarder public immutable _vwaveRewarder;

    constructor(IERC20 govToken_, IBoringERC20 vwave_) public {
        MiniChefV2 miniChef_ = new MiniChefV2(vwave_);
        miniChef_.setVwavePerSecond(VWAVE_PER_SECOND);
        miniChef = miniChef_;
        
        govToken = govToken_;

        ERC20PresetMinterPauser voteToken = new ERC20PresetMinterPauser("Voter", "VTR");
        _voteToken = voteToken;

        VwaveRewarder rewarder = new VwaveRewarder(); // Rewarder notifies RewardPool 
        _vwaveRewarder = rewarder;

        chefPoolId = miniChef_.add(DEFAULT_ALLOC_POINT, IBoringERC20(address(voteToken)), IRewarder(rewarder));
    }

    function getChef() external view returns (MiniChefV2) {
        return miniChef;
    }

    function getVwaveRewarder() external view returns (VwaveRewarder) {
        return _vwaveRewarder;
    }

    function isVoter(address b)
        external view returns (bool)
    {
        return _isVoter[b];
    }

    function newVoter(address rewardPool_)
        external
        onlyOwner
        returns (Voter)
    {        
        // this must be exectued by the rewardPool_ owner
        //rewardPool_.setRewardDistribution(address(_vwaveRewarder)); 

        Voter voter = new Voter(miniChef, chefPoolId, govToken, rewardPool_, _voteToken);
        _voteToken.grantRole(MINTER_ROLE, address(voter));
        _isVoter[address(voter)] = true;
        emit LOG_NEW_VOTER(msg.sender, address(voter));
        return voter;
    }


}
