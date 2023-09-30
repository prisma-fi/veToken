// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IIncentiveVoting {
    struct Vote {
        uint256 id;
        uint256 points;
    }
    struct LockData {
        uint256 amount;
        uint256 epochsToUnlock;
    }

    event AccountWeightRegistered(
        address indexed account,
        uint256 indexed epoch,
        uint256 frozenBalance,
        LockData[] registeredLockData
    );
    event ClearedVotes(address indexed account, uint256 indexed epoch);
    event NewVotes(address indexed account, uint256 indexed epoch, Vote[] newVotes, uint256 totalPointsUsed);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function clearRegisteredWeight(address account) external returns (bool);

    function clearVote(address account) external;

    function getReceiverVotePct(uint256 id, uint256 epoch) external returns (uint256);

    function getReceiverWeightWrite(uint256 idx) external returns (uint256);

    function getTotalWeightWrite() external returns (uint256);

    function registerAccountWeight(address account, uint256 minEpochs) external;

    function registerAccountWeightAndVote(address account, uint256 minEpochs, Vote[] calldata votes) external;

    function registerNewReceiver() external returns (uint256);

    function renounceOwnership() external;

    function setDelegateApproval(address _delegate, bool _isApproved) external;

    function transferOwnership(address newOwner) external;

    function unfreeze(address account, bool keepVote) external returns (bool);

    function vote(address account, Vote[] calldata votes, bool clearPrevious) external;

    function EPOCH_LENGTH() external view returns (uint256);

    function MAX_LOCK_EPOCHS() external view returns (uint256);

    function MAX_PCT() external view returns (uint256);

    function START_TIME() external view returns (uint256);

    function getAccountCurrentVotes(address account) external view returns (Vote[] memory votes);

    function getAccountRegisteredLocks(
        address account
    ) external view returns (uint256 frozenWeight, LockData[] memory lockData);

    function getEpoch() external view returns (uint256 epoch);

    function getReceiverWeight(uint256 idx) external view returns (uint256);

    function getReceiverWeightAt(uint256 idx, uint256 epoch) external view returns (uint256);

    function getTotalWeight() external view returns (uint256);

    function getTotalWeightAt(uint256 epoch) external view returns (uint256);

    function isApprovedDelegate(address owner, address caller) external view returns (bool isApproved);

    function owner() external view returns (address);

    function receiverCount() external view returns (uint256);

    function receiverDecayRate(uint256) external view returns (uint32);

    function receiverEpochUnlocks(uint256, uint256) external view returns (uint32);

    function receiverUpdatedEpoch(uint256) external view returns (uint16);

    function tokenLocker() external view returns (address);

    function totalDecayRate() external view returns (uint32);

    function totalEpochUnlocks(uint256) external view returns (uint32);

    function totalUpdatedEpoch() external view returns (uint16);
}
