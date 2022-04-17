// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Voter.sol";
import "./VwaveRewarder.sol";

// Factory is owned by deployer acc
// MiniChef is owned by Factory
// VoterToken is owned by Factory
// Voter is owned by Factory
// TODO harvestAll()
contract VwaveFactory is Ownable, ReentrancyGuard {
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    event LogNewVoter(
        address indexed caller,
        address indexed voter,
        address indexed rewardPool
    );

    uint8 constant DEFAULT_ALLOC_POINT = 1;
    uint256 public constant VWAVE_PER_SECOND = 10000000000000000;
    mapping(address => bool) private _isVoter;
    Voter[] private _voters;

    MiniChefV2 public immutable miniChef;
    IERC20 public immutable govToken;
    uint256 public immutable chefPoolId;
    ERC20PresetMinterPauser private immutable _voteToken;
    VwaveRewarder public immutable _vwaveRewarder;

    constructor(IERC20 govToken_, IBoringERC20 vwave_) public {
        MiniChefV2 aMiniChef = new MiniChefV2(vwave_);
        aMiniChef.setVwavePerSecond(VWAVE_PER_SECOND);
        miniChef = aMiniChef;

        govToken = govToken_;

        ERC20PresetMinterPauser voteToken = new ERC20PresetMinterPauser(
            "Voter",
            "VTR"
        );
        _voteToken = voteToken;

        VwaveRewarder rewarder = new VwaveRewarder();
        // Rewarder notifies RewardPool
        _vwaveRewarder = rewarder;

        chefPoolId = aMiniChef.add(
            DEFAULT_ALLOC_POINT,
            IBoringERC20(address(voteToken)),
            IRewarder(rewarder)
        );
    }

    function getChef() external view returns (MiniChefV2) {
        return miniChef;
    }

    function getVwaveRewarder() external view returns (VwaveRewarder) {
        return _vwaveRewarder;
    }

    function isVoter(address b) external view returns (bool) {
        return _isVoter[b];
    }

    function newVoter(address rewardPool_) external onlyOwner returns (Voter) {
        Voter voter = new Voter(
            miniChef,
            chefPoolId,
            govToken,
            rewardPool_,
            _voteToken
        );
        voter.grantRole(voter.ROLE_CAN_PAUSE(), this.owner());
        _voteToken.grantRole(MINTER_ROLE, address(voter));
        _isVoter[address(voter)] = true;
        _voters.push(voter);
        emit LogNewVoter(msg.sender, address(voter), address(rewardPool_));
        return voter;
    }

    function getVoterCount() external view returns (uint256) {
        return _voters.length;
    }

    function getVoter(uint256 index) external view returns (address) {
        return address(_voters[index]);
    }

    function retire(address voter) external onlyOwner returns (bool) {
        require(_isVoter[voter], "Unknown voter");
        Voter(voter).retire();
        uint256 voterCount = _voters.length;
        _isVoter[voter] = false;
        for (uint256 i = 0; i < voterCount; i++) {
            if (address(_voters[i]) == voter) {
                if (_voters.length > 1) {
                    _voters[i] = _voters[voterCount - 1];
                }
                _voters.pop();
                return true;
            }
        }
        return false;
    }

    function harvestAll() external nonReentrant {
        uint256 voterCount = _voters.length;
        for (uint256 i = 0; i < voterCount; i++) {
            _voters[i].harvest();
        }
    }
}
