// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Voter.sol";

contract VwaveFactory is Ownable {
    event LOG_NEW_VOTER(
        address indexed caller,
        address indexed voter
    );
    uint8 constant DEFAULT_ALLOC_POINT = 1;

    mapping(address=>bool) private _isVoter;

    MiniChefV2 public /*immutable*/ miniChef;
    IERC20 public immutable govToken;


    constructor(IBoringERC20 vwave_, IERC20 govToken_) public {
        miniChef = new MiniChefV2(vwave_);
        miniChef.setVwavePerSecond(10000000000000000);
        govToken = govToken_;
    }

    function getChef() external view returns (MiniChefV2) {
        return miniChef;
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
        ERC20PresetMinterPauser voteToken = new ERC20PresetMinterPauser("Voter", "VTR");
        uint256 chefPoolId = miniChef.add(DEFAULT_ALLOC_POINT, IBoringERC20(address(voteToken)), IRewarder(0));

        Voter voter = new Voter(miniChef, chefPoolId, govToken, rewardPool_, voteToken);
        _isVoter[address(voter)] = true;
        emit LOG_NEW_VOTER(msg.sender, address(voter));
        return voter;
    }


}
