// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {SafeERC20, IERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract Distribution is Ownable {
    using SafeERC20 for IERC20;

    uint public constant MULTIPLIER = 1e36;

    struct Pool {
        IERC20 asset;
        uint totalAmount;
        uint[] rewards;
    }
    /// @dev poolId => Pool
    mapping(uint => Pool) public pools;
    /// @dev poolId => userAddress => staked amount
    mapping(uint => mapping(address => uint)) public userBalance;

    struct RewardPool {
        uint id;
        uint weight;
        uint speed;
        uint index;
        uint updateBlock;
    }

    struct Reward {
        IERC20 asset; // reward token
        uint totalAmount;
        uint startBlock;
        uint endBlock;
        mapping(uint => RewardPool) pools;
        uint[] poolIds; // cache pool id
    }

    /// @dev rewardId => reward
    mapping(uint => Reward) public rewards;

    struct UserSnapshot {
        uint index; // user index
        uint accrued; // claimable reward
    }

    /// @dev rewardId => poolId => userAddress => UserSnapshot
    mapping(uint => mapping(uint => mapping(address => UserSnapshot))) public users;

    uint public totalPoolNum;
    uint public totalRewardNum;

    /* event */
    event NewPool(uint poolId, address asset);
    /// @notice maybe notify enough info?
    event NewReward(uint rewardId, address rewardToken, uint rewardAmount);
    event NewSpeed(uint rewardId, uint poolId, uint speed);
    event RewardUpdated(uint rewardId, int256 amountDelta, uint endBlock);
    event RewardPoolWeightUpdated(uint rewardId, uint[] weights);
    event RestartReward(uint rewardId, uint startBlock);
    event DistributeReward(uint rewardId, uint poolId, address user, uint accrued, uint rewardPoolIndex);

    constructor()Ownable(){

    }

    /// @dev open a pool to enable user stake
    function newPool(IERC20 stakingAsset) public onlyOwner {
        totalPoolNum++;
        pools[totalPoolNum].asset = stakingAsset;
        emit NewPool(totalPoolNum, address(stakingAsset));
    }

    function newReward(IERC20 rewardAsset, uint totalAmount, uint startBlock, uint endBlock, uint[] calldata poolIds,
        uint[] calldata weights) public onlyOwner {
        require(poolIds.length == weights.length, 'illegal pool & weight length');
        // transfer reward in
        rewardAsset.safeTransferFrom(_msgSender(), address(this), totalAmount);
        // save reward
        totalRewardNum++;
        rewards[totalRewardNum].asset = rewardAsset;
        rewards[totalRewardNum].totalAmount = totalAmount;
        rewards[totalRewardNum].startBlock = startBlock;
        rewards[totalRewardNum].endBlock = endBlock;

        // check pool duplicated
        uint totalWeight;
        for (uint i = 0; i < weights.length; i++) {
            require(poolIds[i] > 0 && poolIds[i] <= totalPoolNum, 'illegal poolId');
            RewardPool storage rewardPool = rewards[totalRewardNum].pools[poolIds[i]];
            require(rewardPool.index == 0, 'duplicated poolId');
            rewardPool.id = poolIds[i];
            rewardPool.index = MULTIPLIER;
            rewardPool.weight = weights[i];

            totalWeight += weights[i];
        }

        // if endBlock <= startBlock, revert here
        uint totalSpeed = totalAmount / (endBlock - startBlock);
        for (uint i = 0; i < poolIds.length; i++) {
            RewardPool storage rewardPool = rewards[totalRewardNum].pools[poolIds[i]];
            rewardPool.speed = totalSpeed * weights[i] / totalWeight;
            emit NewSpeed(totalRewardNum, poolIds[i], rewardPool.speed);
        }
        rewards[totalRewardNum].poolIds = poolIds;
        emit NewReward(totalRewardNum, address(rewardAsset), totalAmount);
    }

    /// @dev if reward not ended, we can add new pool to reward
    function addPoolToReward(uint rewardId, uint poolId, uint weight) public onlyOwner {
        require(poolId > 0 && poolId <= totalPoolNum, 'illegal poolId');
        Reward storage reward = rewards[rewardId];
        require(reward.pools[poolId].index == 0, 'duplicated poolId');
        onlyRewardNotEnded(reward);
        // settle old state
        uint totalWeights = refreshRewardPoolIndex(reward);
        RewardPool storage rewardPool = reward.pools[poolId];
        rewardPool.id = poolId;
        rewardPool.index = MULTIPLIER;
        rewardPool.weight = weight;
        reward.poolIds.push(poolId);
        totalWeights += weight;
        // calculate new speed
        refreshRewardPoolSpeed(rewardId, reward, totalWeights);
        // update pool reward mapping
        pools[poolId].rewards.push(rewardId);
    }

    /// @dev if reward not ended, we can add new pool to reward, we can adjust reward
    function updateReward(uint rewardId, int256 amountDelta, uint endBlock) public onlyOwner {
        Reward storage reward = rewards[rewardId];
        onlyRewardNotEnded(reward);
        // settle old state
        uint totalWeights = refreshRewardPoolIndex(reward);
        // update reward total amount
        if (amountDelta < 0) {
            uint amount = uint(- amountDelta);
            reward.asset.safeTransfer(_msgSender(), amount);
            reward.totalAmount -= amount;
        } else {
            uint amount = uint(- amountDelta);
            reward.asset.safeTransferFrom(_msgSender(), address(this), amount);
            reward.totalAmount += amount;
        }
        require(endBlock > block.number, 'illegal endBlock');
        reward.endBlock = endBlock;
        // calculate new speed
        refreshRewardPoolSpeed(rewardId, reward, totalWeights);
        emit RewardUpdated(rewardId, amountDelta, endBlock);
    }

    function updateRewardStartBlock(uint rewardId, uint startBlock) public onlyOwner {
        Reward storage reward = rewards[rewardId];
        require(block.number <= reward.startBlock, 'reward started');
        require(block.number < startBlock, 'illegal startBlock');
        reward.startBlock = startBlock;
        emit RestartReward(rewardId, startBlock);
    }

    function updateRewardPoolWeight(uint rewardId, uint[] calldata weights) public onlyOwner {
        Reward storage reward = rewards[rewardId];
        require(weights.length == reward.poolIds.length, 'illegal weights length');
        onlyRewardNotEnded(reward);
        // settle old state
        refreshRewardPoolIndex(reward);
        // update weight
        uint totalWeights;
        for (uint i = 0; i < reward.poolIds.length; i++) {
            reward.pools[reward.poolIds[i]].weight = weights[i];
        }
        // calculate new speed
        refreshRewardPoolSpeed(rewardId, reward, totalWeights);
        emit RewardPoolWeightUpdated(rewardId, weights);
    }

    function deposit(uint poolId, uint amount) public {
        Pool storage pool = pools[poolId];
        for (uint i = 0; i < pool.rewards.length; i++) {
            Reward storage reward = rewards[pool.rewards[i]];
            updatePoolIndex(reward.startBlock, reward.endBlock, reward.pools[poolId]);
            distributeReward(reward, pool.rewards[i], poolId, _msgSender());
        }
        // update state
        pool.totalAmount += amount;
        userBalance[poolId][_msgSender()] += amount;
        // transfer asset in
        pool.asset.safeTransferFrom(_msgSender(), address(this), amount);
    }

    function withdraw(uint poolId, uint amount) public {
        Pool storage pool = pools[poolId];
        for (uint i = 0; i < pool.rewards.length; i++) {
            Reward storage reward = rewards[pool.rewards[i]];
            updatePoolIndex(reward.startBlock, reward.endBlock, reward.pools[poolId]);
            distributeReward(reward, pool.rewards[i], poolId, _msgSender());
        }
        // update state
        pool.totalAmount -= amount;
        userBalance[poolId][_msgSender()] -= amount;
        // transfer asset out
        pool.asset.safeTransfer(_msgSender(), amount);
    }

    function claim(uint[] calldata poolIds) public {
        for (uint i = 0; i < poolIds.length; i++) {
            uint poolId = poolIds[i];
            Pool storage pool = pools[poolId];
            for (uint j = 0; j < pool.rewards.length; j++) {
                Reward storage reward = rewards[pool.rewards[j]];
                updatePoolIndex(reward.startBlock, reward.endBlock, reward.pools[poolId]);
                distributeReward(reward, pool.rewards[j], poolId, _msgSender());
            }
        }
    }

    function updatePoolIndex(uint rewardStartBlock, uint rewardEndBlock, RewardPool storage rewardPool) internal {
        if (block.number < rewardStartBlock) {
            return;
        }
        if (rewardPool.updateBlock == 0) {
            rewardPool.updateBlock = rewardStartBlock;
        }
        uint endBlock = block.number <= rewardEndBlock ? block.number : rewardEndBlock;
        uint blockDelta = endBlock - rewardPool.updateBlock;
        if (blockDelta == 0) {
            return;
        }
        uint rewardAccrued = rewardPool.speed * blockDelta;
        Pool memory pool = pools[rewardPool.id];
        uint indexDelta = rewardAccrued * MULTIPLIER / pool.totalAmount;
        rewardPool.index += indexDelta;
        rewardPool.updateBlock = block.number;
    }

    function distributeReward(Reward storage reward, uint rewardId, uint poolId, address user) internal {
        UserSnapshot storage userSnapshot = users[rewardId][poolId][user];
        if (userSnapshot.index == 0) {
            userSnapshot.index = MULTIPLIER;
        }
        uint rewardPoolIndex = reward.pools[poolId].index;
        uint indexDelta = rewardPoolIndex - userSnapshot.index;
        if (indexDelta == 0) {
            return;
        }
        userSnapshot.index = rewardPoolIndex;
        uint earned = indexDelta * userBalance[poolId][user] / MULTIPLIER;
        userSnapshot.accrued += earned;
        if (userSnapshot.accrued > 0 && reward.asset.balanceOf(address(this)) >= userSnapshot.accrued) {
            reward.asset.safeTransfer(user, userSnapshot.accrued);
            userSnapshot.accrued = 0;
        }
        emit DistributeReward(rewardId, poolId, user, earned, rewardPoolIndex);
    }

    function onlyRewardNotEnded(Reward storage reward) internal view {
        require(reward.endBlock <= block.number, 'reward ended');
    }

    /// @notice refresh reward pool index and return total weights
    function refreshRewardPoolIndex(Reward storage reward) internal returns (uint){
        uint totalWeights;
        for (uint i = 0; i < reward.poolIds.length; i++) {
            RewardPool storage rewardPool = reward.pools[reward.poolIds[i]];
            totalWeights += rewardPool.weight;
            // update existed pool index
            updatePoolIndex(reward.startBlock, reward.endBlock, rewardPool);
        }
        return totalWeights;
    }

    /// @dev refresh reward pool speed
    function refreshRewardPoolSpeed(uint rewardId, Reward storage reward, uint totalWeights) internal {
        uint totalSpeed = reward.totalAmount / (reward.endBlock - reward.startBlock);
        for (uint i = 0; i < reward.poolIds.length; i++) {
            RewardPool storage rewardPool = reward.pools[reward.poolIds[i]];
            rewardPool.speed = totalSpeed * rewardPool.weight / totalWeights;
            emit NewSpeed(rewardId, rewardPool.id, rewardPool.speed);
        }
    }

    // return rewardId[] => rewardAmount[]
    function claimable(address user, uint poolId) public view returns (uint[] memory, uint[] memory){
        Pool memory pool = pools[poolId];
        uint[] memory results = new uint[](pool.rewards.length);
        for (uint i = 0; i < pool.rewards.length; i++) {
            Reward storage reward = rewards[pool.rewards[i]];
            if (block.number < reward.startBlock) {
                continue;
            }
            RewardPool memory rewardPool = reward.pools[poolId];
            if (rewardPool.updateBlock == 0) {
                rewardPool.updateBlock = reward.startBlock;
            }
            uint endBlock = block.number <= reward.endBlock ? block.number : reward.endBlock;
            uint blockDelta = endBlock - rewardPool.updateBlock;
            if (blockDelta > 0) {
                uint rewardAccrued = rewardPool.speed * blockDelta;
                rewardPool.index += rewardAccrued * MULTIPLIER / pool.totalAmount;
            }
            UserSnapshot memory userSnapshot = users[pool.rewards[i]][poolId][user];
            if (userSnapshot.index == 0) {
                userSnapshot.index = MULTIPLIER;
            }
            results[i] = (rewardPool.index - userSnapshot.index) * userBalance[poolId][user]
            / MULTIPLIER + userSnapshot.accrued;
        }
        return (pool.rewards, results);
    }
}