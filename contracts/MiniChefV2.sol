// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./boringcrypto/libraries/BoringMath.sol";
import "./boringcrypto/BoringBatchable.sol";
import "./boringcrypto/BoringOwnable.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/IRewarder.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IRewardDistributionRecipient.sol";
import "hardhat/console.sol";


/// @notice The (older) MasterChef contract gives out a constant number of VWAVE tokens per block.
/// It is the only address with minting rights for VWAVE.
/// The idea for this MasterChef V2 (MCV2) contract is therefore to be the owner of a dummy token
/// that is deposited into the MasterChef V1 (MCV1) contract.
/// The allocation point for this pool on MCV1 is the total allocation point for all pools that receive double incentives.
contract MiniChefV2 is BoringOwnable {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using LibBoringERC20 for IBoringERC20;
    using SignedSafeMath for int256;

    /// @notice Info of each MCV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of VWAVE entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each MCV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of VWAVE to distribute per block.
    struct PoolInfo {
        uint128 accVwavePerShare;
        uint64 lastRewardTime;
        uint64 allocPoint;
    }

    /// @notice Address of VWAVE contract.
    IBoringERC20 public immutable VWAVE;

    /// @notice Info of each MCV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each MCV2 pool.
    IBoringERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    /// @dev Tokens added
    mapping(address => bool) public addedTokens;

    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 public vwavePerSecond;
    uint256 private constant ACC_VWAVE_PRECISION = 1e18;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IBoringERC20 indexed lpToken, IRewarder indexed rewarder);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarder indexed rewarder, bool overwrite);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardTime, uint256 lpSupply, uint256 accVwavePerShare);
    event LogVwavePerSecond(uint256 vwavePerSecond);

    /// @param _vwave The VWAVE token contract address.
    constructor(IBoringERC20 _vwave) public {
        VWAVE = _vwave;
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    function add(uint256 allocPoint, IBoringERC20 _lpToken, IRewarder _rewarder) public onlyOwner returns (uint256 pid){
        require(poolLength() <= 1, "Only one pool can be added");
        require(addedTokens[address(_lpToken)] == false, "Token already added");
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(PoolInfo({
        allocPoint : allocPoint.to64(),
        lastRewardTime : block.timestamp.to64(),
        accVwavePerShare : 0
        }));
        addedTokens[address(_lpToken)] = true;
        pid = lpToken.length.sub(1);
        emit LogPoolAddition(pid, allocPoint, _lpToken, _rewarder);
    }

    /// @notice Update the given pool's VWAVE allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    // function set(uint256 _pid, uint256 _allocPoint, IRewarder _rewarder, bool overwrite) public onlyOwner {
    //     totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
    //     poolInfo[_pid].allocPoint = _allocPoint.to64();
    //     if (overwrite) {rewarder[_pid] = _rewarder;}
    //     emit LogSetPool(_pid, _allocPoint, overwrite ? _rewarder : rewarder[_pid], overwrite);
    // }

    /// @notice Sets the vwave per second to be distributed. Can only be called by the owner.
    /// @param _vwavePerSecond The amount of Vwave to be distributed per second.
    function setVwavePerSecond(uint256 _vwavePerSecond) public onlyOwner {
        vwavePerSecond = _vwavePerSecond;
        emit LogVwavePerSecond(_vwavePerSecond);
    }


    /// @notice View function to see pending VWAVE on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending VWAVE reward for a given user.
    function pendingVwave(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accVwavePerShare = pool.accVwavePerShare;
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 time = block.timestamp.sub(pool.lastRewardTime);
            uint256 vwaveReward = time.mul(vwavePerSecond).mul(pool.allocPoint) / totalAllocPoint;
            accVwavePerShare = accVwavePerShare.add(vwaveReward.mul(ACC_VWAVE_PRECISION) / lpSupply);
        }
        pending = int256(user.amount.mul(accVwavePerShare) / ACC_VWAVE_PRECISION).sub(user.rewardDebt).toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.timestamp > pool.lastRewardTime) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 time = block.timestamp.sub(pool.lastRewardTime);
                uint256 vwaveReward = time.mul(vwavePerSecond).mul(pool.allocPoint) / totalAllocPoint;
                pool.accVwavePerShare = pool.accVwavePerShare.add((vwaveReward.mul(ACC_VWAVE_PRECISION) / lpSupply).to128());
            }
            pool.lastRewardTime = block.timestamp.to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardTime, lpSupply, pool.accVwavePerShare);
        }
    }

    /// @notice Deposit LP tokens to MCV2 for VWAVE allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    function deposit(uint256 pid, uint256 amount) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(int256(amount.mul(pool.accVwavePerShare) / ACC_VWAVE_PRECISION));
        
        // Interactions
        // IRewarder _rewarder = rewarder[pid];
        // if (address(_rewarder) != address(0)) {
        //     _rewarder.onVwaveReward(pid, to, to, 0, user.amount);
        // }

        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount, msg.sender);
    }

    /// @notice Withdraw LP tokens from MCV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    function withdraw(uint256 pid, uint256 amount) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(int256(amount.mul(pool.accVwavePerShare) / ACC_VWAVE_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        // IRewarder _rewarder = rewarder[pid];
        // if (address(_rewarder) != address(0)) {
        //     _rewarder.onVwaveReward(pid, msg.sender, to, 0, user.amount);
        // }

        lpToken[pid].safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, pid, amount, msg.sender);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of VWAVE rewards.
    function harvest(uint256 pid, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedVwave = int256(user.amount.mul(pool.accVwavePerShare) / ACC_VWAVE_PRECISION);
        uint256 _pendingVwave = accumulatedVwave.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedVwave;

        // Interactions
        if (_pendingVwave != 0) {
            VWAVE.safeTransfer(to, _pendingVwave);
        }

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onVwaveReward(pid, msg.sender, to, _pendingVwave, user.amount);
        }

        emit Harvest(msg.sender, pid, _pendingVwave);
    }

    /// @notice Withdraw LP tokens from MCV2 and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and VWAVE rewards.
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedVwave = int256(user.amount.mul(pool.accVwavePerShare) / ACC_VWAVE_PRECISION);
        uint256 _pendingVwave = accumulatedVwave.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedVwave.sub(int256(amount.mul(pool.accVwavePerShare) / ACC_VWAVE_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        VWAVE.safeTransfer(to, _pendingVwave);

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onVwaveReward(pid, msg.sender, to, _pendingVwave, user.amount);
        }

        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
        emit Harvest(msg.sender, pid, _pendingVwave);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    function emergencyWithdraw(uint256 pid) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        // IRewarder _rewarder = rewarder[pid];
        // if (address(_rewarder) != address(0)) {
        //     _rewarder.onVwaveReward(pid, msg.sender, to, 0, 0);
        // }

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pid].safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, msg.sender);
    }
}
