// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ITokenLocker {
    struct LockData {
        uint256 amount;
        uint256 epochsToUnlock;
    }
    struct ExtendLockData {
        uint256 amount;
        uint256 currentEpochs;
        uint256 newEpochs;
    }

    event LockCreated(address indexed account, uint256 amount, uint256 _epochs);
    event LockExtended(address indexed account, uint256 amount, uint256 _epochs, uint256 newEpochs);
    event LocksCreated(address indexed account, LockData[] newLocks);
    event LocksExtended(address indexed account, ExtendLockData[] locks);
    event LocksFrozen(address indexed account, uint256 amount);
    event LocksUnfrozen(address indexed account, uint256 amount);
    event LocksWithdrawn(address indexed account, uint256 withdrawn, uint256 penalty);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function extendLock(uint256 _amount, uint256 _epochs, uint256 _newEpochs) external returns (bool);

    function extendMany(ExtendLockData[] calldata newExtendLocks) external returns (bool);

    function freeze() external;

    function getAccountWeightWrite(address account) external returns (uint256);

    function getTotalWeightWrite() external returns (uint256);

    function lock(address _account, uint256 _amount, uint256 _epochs) external returns (bool);

    function lockMany(address _account, LockData[] calldata newLocks) external returns (bool);

    function renounceOwnership() external;

    function setFeeReceiver(address _receiver) external returns (bool);

    function setPenaltyWithdrawalsEnabled(bool _enabled) external returns (bool);

    function transferOwnership(address newOwner) external;

    function unfreeze(bool keepIncentivesVote) external;

    function withdrawExpiredLocks(uint256 _epochs) external returns (bool);

    function withdrawWithPenalty(uint256 amountToWithdraw) external returns (uint256);

    function EPOCH_LENGTH() external view returns (uint256);

    function LOCK_TO_TOKEN_RATIO() external view returns (uint256);

    function MAX_LOCK_EPOCHS() external view returns (uint256);

    function MAX_PCT() external view returns (uint256);

    function START_TIME() external view returns (uint256);

    function feeReceiver() external view returns (address);

    function getAccountActiveLocks(
        address account,
        uint256 minEpochs
    ) external view returns (LockData[] memory lockData, uint256 frozenAmount);

    function getAccountBalances(address account) external view returns (uint256 locked, uint256 unlocked);

    function getAccountIsFrozen(address account) external view returns (bool isFrozen);

    function getAccountWeight(address account) external view returns (uint256);

    function getAccountWeightAt(address account, uint256 epoch) external view returns (uint256);

    function getEpoch() external view returns (uint256 epoch);

    function getTotalWeight() external view returns (uint256);

    function getTotalWeightAt(uint256 epoch) external view returns (uint256);

    function getWithdrawWithPenaltyAmounts(
        address account,
        uint256 amountToWithdraw
    ) external view returns (uint256 amountWithdrawn, uint256 penaltyAmountPaid);

    function incentiveVoter() external view returns (address);

    function lockToken() external view returns (address);

    function owner() external view returns (address);

    function penaltyWithdrawalsEnabled() external view returns (bool);

    function totalDecayRate() external view returns (uint32);

    function totalUpdatedEpoch() external view returns (uint16);
}
