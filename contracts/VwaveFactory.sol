// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Voter.sol";

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

    mapping(address=>bool) private _isVoter;

    MiniChefV2 public /*immutable*/ miniChef;
    IERC20 public immutable govToken;
    uint256 public immutable chefPoolId;
    ERC20PresetMinterPauser private immutable _voteToken;

    constructor(IERC20 govToken_, IBoringERC20 vwave_) public {
        miniChef = new MiniChefV2(vwave_);
        miniChef.setVwavePerSecond(10000000000000000);
        govToken = govToken_;
        ERC20PresetMinterPauser voteToken = new ERC20PresetMinterPauser("Voter", "VTR");
        _voteToken = voteToken;
        chefPoolId = miniChef.add(DEFAULT_ALLOC_POINT, IBoringERC20(address(voteToken)), IRewarder(0));
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
        Voter voter = new Voter(miniChef, chefPoolId, govToken, rewardPool_, _voteToken);
        _voteToken.grantRole(MINTER_ROLE, address(voter));
        _isVoter[address(voter)] = true;
        emit LOG_NEW_VOTER(msg.sender, address(voter));
        return voter;
    }


}
