// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./dependencies/BaseConfig.sol";
import "./interfaces/IIncentiveVoting.sol";
import "./interfaces/IGovToken.sol";

/**
    @title Token Locker
    @author Prisma Finance
    @notice Tokens can be locked in this contract to receive "lock weight",
            which is used within `AdminVoting` and `IncentiveVoting` to vote on
            core protocol operations.
 */
contract TokenLocker is Ownable, BaseConfig {
    // Multiplier applied during token deposits and withdrawals. A balance within this
    // contract corresponds to a deposit of `balance * LOCK_TO_TOKEN_RATIO` tokens. Balances
    // in this contract are stored as `uint32`, so the invariant:
    //
    // `govToken.totalSupply() <= type(uint32).max * LOCK_TO_TOKEN_RATIO`
    //
    // cannot be violated or the system could break due to overflow.
    uint256 public immutable LOCK_TO_TOKEN_RATIO;

    IGovToken public immutable govToken;
    IIncentiveVoting public immutable incentiveVoter;

    bool public penaltyWithdrawalsEnabled;
    address public feeReceiver;

    struct AccountData {
        // Currently locked balance. Each epoch the lock weight decays by this amount.
        uint32 locked;
        // Currently unlocked balance (from expired locks, can be withdrawn)
        uint32 unlocked;
        // Currently "frozen" balance. A frozen balance is equivalent to a `MAX_LOCK_EPOCHS` lock,
        // where the lock weight does not decay over time. An account may have a locked balance or a
        // frozen balance, never both at the same time.
        uint32 frozen;
        // Boolean indicating if the account is currently frozen.
        bool isFrozen;
        // Current epoch within `accountEpochUnlocks`. Lock durations decay as this value increases.
        uint16 epoch;
        // Array of bitfields, where each bit represents 1 epoch. A bit is set to true when the
        // account has a non-zero token balance unlocking in that epoch, and so a non-zero value
        // at the same index in `accountEpochUnlocks`. We use this bitarray to reduce gas costs
        // when iterating over the epoch unlocks.
        uint256[256] updateEpochs;
    }

    // structs used in function inputs
    struct LockData {
        uint256 amount;
        uint256 epochsToUnlock;
    }
    struct ExtendLockData {
        uint256 amount;
        uint256 currentEpochs;
        uint256 newEpochs;
    }

    // Rate at which the total lock weight decreases each epoch. The total decay rate may not
    // be equal to the total number of locked tokens, as it does not include frozen accounts.
    uint32 totalDecayRate;
    // Current epoch within `totalEpochWeights` and `totalEpochUnlocks`. When up-to-date
    // this value is always equal to `getEpoch()`
    uint16 totalUpdatedEpoch;

    // epoch -> total lock weight
    uint40[65535] totalEpochWeights;
    // epoch -> tokens to unlock in this epoch
    uint32[65535] totalEpochUnlocks;

    // account -> epoch -> lock weight
    mapping(address => uint40[65535]) accountEpochWeights;

    // account -> epoch -> token balance unlocking this epoch
    mapping(address => uint32[65535]) accountEpochUnlocks;

    // account -> primary account data structure
    mapping(address => AccountData) accountLockData;

    event LockCreated(address indexed account, uint256 amount, uint256 _epochs);
    event LockExtended(address indexed account, uint256 amount, uint256 _epochs, uint256 newEpochs);
    event LocksCreated(address indexed account, LockData[] newLocks);
    event LocksExtended(address indexed account, ExtendLockData[] locks);
    event LocksFrozen(address indexed account, uint256 amount);
    event LocksUnfrozen(address indexed account, uint256 amount);
    event LocksWithdrawn(address indexed account, uint256 withdrawn, uint256 penalty);

    constructor(IGovToken _token, IIncentiveVoting _voter, address _feeReceiver, uint256 _lockToTokenRatio) {
        govToken = _token;
        incentiveVoter = _voter;
        feeReceiver = _feeReceiver;

        LOCK_TO_TOKEN_RATIO = _lockToTokenRatio;

        require(_token.totalSupply() <= type(uint32).max * _lockToTokenRatio, "Total supply too large!");
    }

    modifier notFrozen(address account) {
        require(!accountLockData[account].isFrozen, "Lock is frozen");
        _;
    }

    /**
        @notice Allow or disallow early-exit of locks by paying a penalty
     */
    function setPenaltyWithdrawalsEnabled(bool _enabled) external onlyOwner returns (bool) {
        penaltyWithdrawalsEnabled = _enabled;
        return true;
    }

    /**
        @notice Set the address where early-exit penalty fees are sent
     */
    function setFeeReceiver(address _receiver) external onlyOwner returns (bool) {
        feeReceiver = _receiver;
        return true;
    }

    /**
        @notice Get the balances currently held in this contract for an account
        @return locked balance which is currently locked or frozen
        @return unlocked expired lock balance which may be withdrawn
     */
    function getAccountBalances(address account) external view returns (uint256 locked, uint256 unlocked) {
        AccountData storage accountData = accountLockData[account];
        uint256 frozen = accountData.frozen;
        unlocked = accountData.unlocked;
        if (frozen > 0) {
            return (frozen, unlocked);
        }

        locked = accountData.locked;
        if (locked > 0) {
            uint32[65535] storage epochUnlocks = accountEpochUnlocks[account];
            uint256 accountEpoch = accountData.epoch;
            uint256 systemEpoch = getEpoch();

            uint256 bitfield = accountData.updateEpochs[accountEpoch / 256] >> (accountEpoch % 256);

            while (accountEpoch < systemEpoch) {
                accountEpoch++;
                if (accountEpoch % 256 == 0) {
                    bitfield = accountData.updateEpochs[accountEpoch / 256];
                } else {
                    bitfield = bitfield >> 1;
                }
                if (bitfield & uint256(1) == 1) {
                    uint256 u = epochUnlocks[accountEpoch];
                    locked -= u;
                    unlocked += u;
                    if (locked == 0) break;
                }
            }
        }
        return (locked, unlocked);
    }

    function getAccountIsFrozen(address account) external view returns (bool isFrozen) {
        return accountLockData[account].isFrozen;
    }

    /**
        @notice Get the current lock weight for an account
     */
    function getAccountWeight(address account) external view returns (uint256) {
        return getAccountWeightAt(account, getEpoch());
    }

    /**
        @notice Get the lock weight for an account in a given epoch
     */
    function getAccountWeightAt(address account, uint256 epoch) public view returns (uint256) {
        if (epoch > getEpoch()) return 0;
        uint32[65535] storage epochUnlocks = accountEpochUnlocks[account];
        uint40[65535] storage epochWeights = accountEpochWeights[account];
        AccountData storage accountData = accountLockData[account];

        uint256 accountEpoch = accountData.epoch;
        if (accountEpoch >= epoch) return epochWeights[epoch];

        uint256 locked = accountData.locked;
        uint256 weight = epochWeights[accountEpoch];
        if (locked == 0 || accountData.frozen > 0) {
            return weight;
        }

        uint256 bitfield = accountData.updateEpochs[accountEpoch / 256] >> (accountEpoch % 256);
        while (accountEpoch < epoch) {
            accountEpoch++;
            weight -= locked;
            if (accountEpoch % 256 == 0) {
                bitfield = accountData.updateEpochs[accountEpoch / 256];
            } else {
                bitfield = bitfield >> 1;
            }
            if (bitfield & uint256(1) == 1) {
                uint256 amount = epochUnlocks[accountEpoch];
                locked -= amount;
                if (locked == 0) break;
            }
        }
        return weight;
    }

    /**
        @notice Get data on an accounts's active token locks and frozen balance
        @param account Address to query data for
        @return lockData dynamic array of [epochs until expiration, balance of lock]
        @return frozenAmount total frozen balance
     */
    function getAccountActiveLocks(
        address account,
        uint256 minEpochs
    ) external view returns (LockData[] memory lockData, uint256 frozenAmount) {
        AccountData storage accountData = accountLockData[account];
        frozenAmount = accountData.frozen;
        if (frozenAmount == 0) {
            if (minEpochs == 0) minEpochs = 1;
            uint32[65535] storage unlocks = accountEpochUnlocks[account];

            uint256 systemEpoch = getEpoch();
            uint256 currentEpoch = systemEpoch + minEpochs;
            uint256 maxLockEpoch = systemEpoch + MAX_LOCK_EPOCHS;

            uint256[] memory unlockEpochs = new uint256[](MAX_LOCK_EPOCHS);
            uint256 bitfield = accountData.updateEpochs[currentEpoch / 256] >> (currentEpoch % 256);

            uint256 length;
            while (currentEpoch <= maxLockEpoch) {
                if (bitfield & uint256(1) == 1) {
                    unlockEpochs[length] = currentEpoch;
                    length++;
                }
                currentEpoch++;
                if (currentEpoch % 256 == 0) {
                    bitfield = accountData.updateEpochs[currentEpoch / 256];
                } else {
                    bitfield = bitfield >> 1;
                }
            }

            lockData = new LockData[](length);
            uint256 x = length;
            // increment i, decrement x so LockData is ordered from longest to shortest duration
            for (uint256 i = 0; x != 0; i++) {
                x--;
                uint256 idx = unlockEpochs[x];
                lockData[i] = LockData({ epochsToUnlock: idx - systemEpoch, amount: unlocks[idx] });
            }
        }
        return (lockData, frozenAmount);
    }

    /**
        @notice Get withdrawal and penalty amounts when withdrawing locked tokens
        @param account Account that will withdraw locked tokens
        @param amountToWithdraw Desired withdrawal amount, divided by `LOCK_TO_TOKEN_RATIO`
        @return amountWithdrawn Actual amount withdrawn. If `amountToWithdraw` exceeds the
                                max possible withdrawal, the return value is the max
                                amount received after paying the penalty.
        @return penaltyAmountPaid The amount paid in penalty to perform this withdrawal
     */
    function getWithdrawWithPenaltyAmounts(
        address account,
        uint256 amountToWithdraw
    ) external view returns (uint256 amountWithdrawn, uint256 penaltyAmountPaid) {
        AccountData storage accountData = accountLockData[account];
        uint32[65535] storage unlocks = accountEpochUnlocks[account];
        if (amountToWithdraw != type(uint256).max) amountToWithdraw *= LOCK_TO_TOKEN_RATIO;

        // first we apply the unlocked balance without penalty
        uint256 unlocked = accountData.unlocked * LOCK_TO_TOKEN_RATIO;
        if (unlocked >= amountToWithdraw) {
            return (amountToWithdraw, 0);
        }

        uint256 remaining = amountToWithdraw - unlocked;
        uint256 penaltyTotal;

        uint256 accountEpoch = accountData.epoch;
        uint256 systemEpoch = getEpoch();
        uint256 offset = systemEpoch - accountEpoch;
        uint256 bitfield = accountData.updateEpochs[accountEpoch / 256];

        // `epochsToUnlock < MAX_LOCK_EPOCHS` stops iteration prior to the final epoch
        for (uint256 epochsToUnlock = 1; epochsToUnlock < MAX_LOCK_EPOCHS; epochsToUnlock++) {
            accountEpoch++;

            if (accountEpoch % 256 == 0) {
                bitfield = accountData.updateEpochs[accountEpoch / 256];
            }

            if ((bitfield >> (accountEpoch % 256)) & uint256(1) == 1) {
                uint256 lockAmount = unlocks[accountEpoch] * LOCK_TO_TOKEN_RATIO;

                uint256 penaltyOnAmount = 0;
                if (accountEpoch > systemEpoch) {
                    // only apply the penalty if the lock has not expired
                    penaltyOnAmount = (lockAmount * (epochsToUnlock - offset)) / MAX_LOCK_EPOCHS;
                }

                if (lockAmount - penaltyOnAmount > remaining) {
                    // after penalty, locked amount exceeds remaining required balance
                    // we can complete the withdrawal using only a portion of this lock
                    penaltyOnAmount =
                        (remaining * MAX_LOCK_EPOCHS) /
                        (MAX_LOCK_EPOCHS - (epochsToUnlock - offset)) -
                        remaining;
                    uint256 dust = ((penaltyOnAmount + remaining) % LOCK_TO_TOKEN_RATIO);
                    if (dust > 0) penaltyOnAmount += LOCK_TO_TOKEN_RATIO - dust;
                    penaltyTotal += penaltyOnAmount;
                    remaining = 0;
                } else {
                    // after penalty, locked amount does not exceed remaining required balance
                    // the entire lock must be used in the withdrawal
                    penaltyTotal += penaltyOnAmount;
                    remaining -= lockAmount - penaltyOnAmount;
                }

                if (remaining == 0) {
                    break;
                }
            }
        }
        amountToWithdraw -= remaining;
        return (amountToWithdraw, penaltyTotal);
    }

    /**
        @notice Get the current total lock weight
     */
    function getTotalWeight() external view returns (uint256) {
        return getTotalWeightAt(getEpoch());
    }

    /**
        @notice Get the total lock weight for a given epoch
     */
    function getTotalWeightAt(uint256 epoch) public view returns (uint256) {
        uint256 systemEpoch = getEpoch();
        if (epoch > systemEpoch) return 0;

        uint32 updatedEpoch = totalUpdatedEpoch;
        if (epoch <= updatedEpoch) return totalEpochWeights[epoch];

        uint32 rate = totalDecayRate;
        uint40 weight = totalEpochWeights[updatedEpoch];
        if (rate == 0 || updatedEpoch >= systemEpoch) {
            return weight;
        }

        while (updatedEpoch < epoch) {
            updatedEpoch++;
            weight -= rate;
            rate -= totalEpochUnlocks[updatedEpoch];
        }
        return weight;
    }

    /**
        @notice Get the current lock weight for an account
        @dev Also updates local storage values for this account. Using
             this function over it's `view` counterpart is preferred for
             contract -> contract interactions.
     */
    function getAccountWeightWrite(address account) external returns (uint256) {
        return _epochWeightWrite(account);
    }

    /**
        @notice Get the current total lock weight
        @dev Also updates local storage values for total weights. Using
             this function over it's `view` counterpart is preferred for
             contract -> contract interactions.
     */
    function getTotalWeightWrite() public returns (uint256) {
        uint256 epoch = getEpoch();
        uint32 rate = totalDecayRate;
        uint32 updatedEpoch = totalUpdatedEpoch;
        uint40 weight = totalEpochWeights[updatedEpoch];

        if (weight == 0) {
            totalUpdatedEpoch = uint16(epoch);
            return 0;
        }

        while (updatedEpoch < epoch) {
            updatedEpoch++;
            weight -= rate;
            totalEpochWeights[updatedEpoch] = weight;
            rate -= totalEpochUnlocks[updatedEpoch];
        }

        totalDecayRate = rate;
        totalUpdatedEpoch = uint16(epoch);

        return weight;
    }

    /**
        @notice Deposit tokens into the contract to create a new lock.
        @dev A lock is created for a given number of epochs. Minimum 1, maximum `MAX_LOCK_EPOCHS`.
             An account can have multiple locks active at the same time. The account's "lock weight"
             is calculated as the sum of [number of tokens] * [epochs until unlock] for all active
             locks. At the start of each new epoch, each lock's epochs until unlock is reduced by 1.
             Locks that reach 0 epochs no longer receive any weight, and tokens may be withdrawn by
             calling `withdrawExpiredLocks`.
        @param _account Address to create a new lock for (does not have to be the caller)
        @param _amount Amount of tokens to lock. This balance transfered from the caller.
        @param _epochs The number of epochs for the lock
     */
    function lock(address _account, uint256 _amount, uint256 _epochs) external returns (bool) {
        require(_epochs > 0, "Min 1 epoch");
        require(_amount > 0, "Amount must be nonzero");
        _lock(_account, _amount, _epochs);
        govToken.transferToLocker(msg.sender, _amount * LOCK_TO_TOKEN_RATIO);

        return true;
    }

    function _lock(address _account, uint256 _amount, uint256 _epochs) internal {
        require(_epochs <= MAX_LOCK_EPOCHS, "Exceeds MAX_LOCK_EPOCHS");
        AccountData storage accountData = accountLockData[_account];

        uint256 accountWeight = _epochWeightWrite(_account);
        uint256 totalWeight = getTotalWeightWrite();
        uint256 systemEpoch = getEpoch();
        if (accountData.isFrozen) {
            accountData.frozen += uint32(_amount);
            _epochs = MAX_LOCK_EPOCHS;
        } else {
            // disallow a 1 epoch lock in the final half of the epoch
            if (_epochs == 1 && block.timestamp % EPOCH_LENGTH > EPOCH_LENGTH / 2) _epochs = 2;

            accountData.locked = uint32(accountData.locked + _amount);
            totalDecayRate = uint32(totalDecayRate + _amount);

            uint32[65535] storage unlocks = accountEpochUnlocks[_account];
            uint256 unlockEpoch = systemEpoch + _epochs;
            uint256 previous = unlocks[unlockEpoch];

            // modify epoch unlocks and unlock bitfield
            unlocks[unlockEpoch] = uint32(previous + _amount);
            totalEpochUnlocks[unlockEpoch] += uint32(_amount);
            if (previous == 0) {
                uint256 idx = unlockEpoch / 256;
                uint256 bitfield = accountData.updateEpochs[idx] | (uint256(1) << (unlockEpoch % 256));
                accountData.updateEpochs[idx] = bitfield;
            }
        }

        // update and adjust account weight and decay rate
        accountEpochWeights[_account][systemEpoch] = uint40(accountWeight + _amount * _epochs);
        // update and modify total weight
        totalEpochWeights[systemEpoch] = uint40(totalWeight + _amount * _epochs);
        emit LockCreated(_account, _amount, _epochs);
    }

    /**
        @notice Extend the length of an existing lock.
        @param _amount Amount of tokens to extend the lock for. When the value given equals
                       the total size of the existing lock, the entire lock is moved.
                       If the amount is less, then the lock is effectively split into
                       two locks, with a portion of the balance extended to the new length
                       and the remaining balance at the old length.
        @param _epochs The number of epochs for the lock that is being extended.
        @param _newEpochs The number of epochs to extend the lock until.
     */
    function extendLock(
        uint256 _amount,
        uint256 _epochs,
        uint256 _newEpochs
    ) external notFrozen(msg.sender) returns (bool) {
        require(_epochs > 0, "Min 1 epoch");
        require(_newEpochs <= MAX_LOCK_EPOCHS, "Exceeds MAX_LOCK_EPOCHS");
        require(_epochs < _newEpochs, "newEpochs must be greater than epochs");
        require(_amount > 0, "Amount must be nonzero");

        AccountData storage accountData = accountLockData[msg.sender];
        uint256 systemEpoch = getEpoch();
        uint256 increase = (_newEpochs - _epochs) * _amount;
        uint32[65535] storage unlocks = accountEpochUnlocks[msg.sender];

        // update and adjust account weight
        // current decay rate is unaffected when extending
        uint256 weight = _epochWeightWrite(msg.sender);
        accountEpochWeights[msg.sender][systemEpoch] = uint40(weight + increase);

        // reduce account unlock for previous epoch and modify bitfield
        uint256 changedEpoch = systemEpoch + _epochs;
        uint256 previous = unlocks[changedEpoch];
        unlocks[changedEpoch] = uint32(previous - _amount);
        totalEpochUnlocks[changedEpoch] -= uint32(_amount);
        if (previous == _amount) {
            uint256 idx = changedEpoch / 256;
            uint256 bitfield = accountData.updateEpochs[idx] & ~(uint256(1) << (changedEpoch % 256));
            accountData.updateEpochs[idx] = bitfield;
        }

        // increase account unlock for new epoch and modify bitfield
        changedEpoch = systemEpoch + _newEpochs;
        previous = unlocks[changedEpoch];
        unlocks[changedEpoch] = uint32(previous + _amount);
        totalEpochUnlocks[changedEpoch] += uint32(_amount);
        if (previous == 0) {
            uint256 idx = changedEpoch / 256;
            uint256 bitfield = accountData.updateEpochs[idx] | (uint256(1) << (changedEpoch % 256));
            accountData.updateEpochs[idx] = bitfield;
        }

        // update and modify total weight
        totalEpochWeights[systemEpoch] = uint40(getTotalWeightWrite() + increase);
        emit LockExtended(msg.sender, _amount, _epochs, _newEpochs);

        return true;
    }

    /**
        @notice Deposit tokens into the contract to create multiple new locks.
        @param _account Address to create new locks for (does not have to be the caller)
        @param newLocks Array of [(amount, epochs), ...] where amount is the amount of
                        tokens to lock, and epochs is the number of epochs for the lock.
                        All tokens to be locked are transferred from the caller.
     */
    function lockMany(address _account, LockData[] calldata newLocks) external notFrozen(_account) returns (bool) {
        AccountData storage accountData = accountLockData[_account];
        uint32[65535] storage unlocks = accountEpochUnlocks[_account];

        // update account weight
        uint256 accountWeight = _epochWeightWrite(_account);
        uint256 systemEpoch = getEpoch();

        // copy maybe-updated bitfield entries to memory
        uint256[2] memory bitfield = [
            accountData.updateEpochs[systemEpoch / 256],
            accountData.updateEpochs[(systemEpoch / 256) + 1]
        ];

        uint256 increasedAmount;
        uint256 increasedWeight;

        // iterate new locks and store intermediate values in memory where possible
        uint256 length = newLocks.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 amount = newLocks[i].amount;
            uint256 epoch = newLocks[i].epochsToUnlock;
            require(amount > 0, "Amount must be nonzero");
            require(epoch > 0, "Min 1 epoch");
            require(epoch <= MAX_LOCK_EPOCHS, "Exceeds MAX_LOCK_EPOCHS");

            // disallow a 1 epoch lock in the final half of the epoch
            if (epoch == 1 && block.timestamp % EPOCH_LENGTH > EPOCH_LENGTH / 2) epoch = 2;

            increasedAmount += amount;
            increasedWeight += amount * epoch;

            uint256 unlockEpoch = systemEpoch + epoch;
            uint256 previous = unlocks[unlockEpoch];
            unlocks[unlockEpoch] = uint32(previous + amount);
            totalEpochUnlocks[unlockEpoch] += uint32(amount);

            if (previous == 0) {
                uint256 idx = (unlockEpoch / 256) - (systemEpoch / 256);
                bitfield[idx] = bitfield[idx] | (uint256(1) << (unlockEpoch % 256));
            }
        }

        // write updated bitfield to storage
        accountData.updateEpochs[systemEpoch / 256] = bitfield[0];
        accountData.updateEpochs[(systemEpoch / 256) + 1] = bitfield[1];

        govToken.transferToLocker(msg.sender, increasedAmount * LOCK_TO_TOKEN_RATIO);

        // update account and total weight / decay storage values
        accountEpochWeights[_account][systemEpoch] = uint40(accountWeight + increasedWeight);
        totalEpochWeights[systemEpoch] = uint40(getTotalWeightWrite() + increasedWeight);

        accountData.locked = uint32(accountData.locked + increasedAmount);
        totalDecayRate = uint32(totalDecayRate + increasedAmount);
        emit LocksCreated(_account, newLocks);

        return true;
    }

    /**
        @notice Extend the length of multiple existing locks.
        @param newExtendLocks Array of [(amount, epochs, newEpochs), ...] where amount is the amount
                              of tokens to extend the lock for, epochs is the current number of epochs
                              for the lock that is being extended, and newEpochs is the number of epochs
                              to extend the lock until.
     */
    function extendMany(ExtendLockData[] calldata newExtendLocks) external notFrozen(msg.sender) returns (bool) {
        AccountData storage accountData = accountLockData[msg.sender];
        uint32[65535] storage unlocks = accountEpochUnlocks[msg.sender];

        // update account weight
        uint256 accountWeight = _epochWeightWrite(msg.sender);
        uint256 systemEpoch = getEpoch();

        // copy maybe-updated bitfield entries to memory
        uint256[2] memory bitfield = [
            accountData.updateEpochs[systemEpoch / 256],
            accountData.updateEpochs[(systemEpoch / 256) + 1]
        ];
        uint256 increasedWeight;

        // iterate extended locks and store intermediate values in memory where possible
        uint256 length = newExtendLocks.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 amount = newExtendLocks[i].amount;
            uint256 oldEpochs = newExtendLocks[i].currentEpochs;
            uint256 newEpochs = newExtendLocks[i].newEpochs;

            require(oldEpochs > 0, "Min 1 epoch");
            require(newEpochs <= MAX_LOCK_EPOCHS, "Exceeds MAX_LOCK_EPOCHS");
            require(oldEpochs < newEpochs, "newEpochs must be greater than epochs");
            require(amount > 0, "Amount must be nonzero");

            increasedWeight += (newEpochs - oldEpochs) * amount;

            // reduce account unlock for previous epoch and modify bitfield
            oldEpochs += systemEpoch;
            uint256 previous = unlocks[oldEpochs];
            unlocks[oldEpochs] = uint32(previous - amount);
            totalEpochUnlocks[oldEpochs] -= uint32(amount);
            if (previous == amount) {
                uint256 idx = (oldEpochs / 256) - (systemEpoch / 256);
                bitfield[idx] = bitfield[idx] & ~(uint256(1) << (oldEpochs % 256));
            }

            // increase account unlock for new epoch and modify bitfield
            newEpochs += systemEpoch;
            previous = unlocks[newEpochs];
            unlocks[newEpochs] = uint32(previous + amount);
            totalEpochUnlocks[newEpochs] += uint32(amount);
            if (previous == 0) {
                uint256 idx = (newEpochs / 256) - (systemEpoch / 256);
                bitfield[idx] = bitfield[idx] | (uint256(1) << (newEpochs % 256));
            }
        }

        // write updated bitfield to storage
        accountData.updateEpochs[systemEpoch / 256] = bitfield[0];
        accountData.updateEpochs[(systemEpoch / 256) + 1] = bitfield[1];

        accountEpochWeights[msg.sender][systemEpoch] = uint40(accountWeight + increasedWeight);
        totalEpochWeights[systemEpoch] = uint40(getTotalWeightWrite() + increasedWeight);
        emit LocksExtended(msg.sender, newExtendLocks);

        return true;
    }

    /**
        @notice Freeze all locks for the caller
        @dev When an account's locks are frozen, the epochs-to-unlock does not decay.
             All other functionality remains the same; the account can continue to lock,
             extend locks, and withdraw tokens. Freezing greatly reduces gas costs for
             actions such as emissions voting.
     */
    function freeze() external notFrozen(msg.sender) {
        AccountData storage accountData = accountLockData[msg.sender];
        uint32[65535] storage unlocks = accountEpochUnlocks[msg.sender];

        uint256 accountWeight = _epochWeightWrite(msg.sender);
        uint256 totalWeight = getTotalWeightWrite();

        // remove account locked balance from the total decay rate
        uint256 locked = accountData.locked;
        emit LocksFrozen(msg.sender, locked);

        if (locked > 0) {
            totalDecayRate = uint32(totalDecayRate - locked);
            accountData.frozen = uint32(locked);
            accountData.locked = 0;

            uint256 systemEpoch = getEpoch();
            accountEpochWeights[msg.sender][systemEpoch] = uint40(locked * MAX_LOCK_EPOCHS);
            totalEpochWeights[systemEpoch] = uint40(totalWeight - accountWeight + locked * MAX_LOCK_EPOCHS);

            // use bitfield to iterate acount unlocks and subtract them from the total unlocks
            uint256 bitfield = accountData.updateEpochs[systemEpoch / 256] >> (systemEpoch % 256);
            while (locked > 0) {
                systemEpoch++;
                if (systemEpoch % 256 == 0) {
                    bitfield = accountData.updateEpochs[systemEpoch / 256];
                    accountData.updateEpochs[(systemEpoch / 256) - 1] = 0;
                } else {
                    bitfield = bitfield >> 1;
                }
                if (bitfield & uint256(1) == 1) {
                    uint32 amount = unlocks[systemEpoch];
                    unlocks[systemEpoch] = 0;
                    totalEpochUnlocks[systemEpoch] -= amount;
                    locked -= amount;
                }
            }
            accountData.updateEpochs[systemEpoch / 256] = 0;
        }
        accountData.isFrozen = true;
    }

    /**
        @notice Unfreeze all locks for the caller
        @dev When an account's locks are unfrozen, the epochs-to-unlock decay normally.
             This is the default locking behaviour for each account. Unfreezing locks
             also updates the frozen status within `IncentiveVoter` - otherwise it could be
             possible for accounts to have a larger registered vote weight than their actual
             lock weight.
        @param keepIncentivesVote If true, existing incentive votes are preserved when updating
                                  the frozen status within `IncentiveVoter`. Voting with unfrozen
                                  weight uses significantly more gas than voting with frozen weight.
                                  If the caller has many active locks and/or many votes, it will be
                                  much cheaper to set this value to false.

     */
    function unfreeze(bool keepIncentivesVote) external {
        AccountData storage accountData = accountLockData[msg.sender];
        uint32[65535] storage unlocks = accountEpochUnlocks[msg.sender];
        require(accountData.isFrozen, "Locks already unfrozen");

        uint256 frozen = accountData.frozen;
        if (frozen > 0) {
            // unfreeze the caller's registered vote weights
            incentiveVoter.unfreeze(msg.sender, keepIncentivesVote);

            // update account weights and get the current account epoch
            _epochWeightWrite(msg.sender);
            getTotalWeightWrite();

            // add account decay to the total decay rate
            totalDecayRate = uint32(totalDecayRate + frozen);
            accountData.locked = uint32(frozen);
            accountData.frozen = 0;

            uint256 systemEpoch = getEpoch();

            uint256 unlockEpoch = systemEpoch + MAX_LOCK_EPOCHS;

            // modify epoch unlocks and unlock bitfield
            unlocks[unlockEpoch] = uint32(frozen);
            totalEpochUnlocks[unlockEpoch] += uint32(frozen);
            uint256 idx = unlockEpoch / 256;
            uint256 bitfield = accountData.updateEpochs[idx] | (uint256(1) << (unlockEpoch % 256));
            accountData.updateEpochs[idx] = bitfield;
        }
        accountData.isFrozen = false;
        emit LocksUnfrozen(msg.sender, frozen);
    }

    /**
        @notice Withdraw tokens from locks that have expired
        @param _epochs Optional number of epochs for the re-locking.
                      If 0 the full amount is transferred back to the user.

     */
    function withdrawExpiredLocks(uint256 _epochs) external returns (bool) {
        _epochWeightWrite(msg.sender);
        getTotalWeightWrite();

        AccountData storage accountData = accountLockData[msg.sender];
        uint256 unlocked = accountData.unlocked;
        require(unlocked > 0, "No unlocked tokens");
        accountData.unlocked = 0;
        if (_epochs > 0) {
            _lock(msg.sender, unlocked, _epochs);
        } else {
            govToken.transfer(msg.sender, unlocked * LOCK_TO_TOKEN_RATIO);
            emit LocksWithdrawn(msg.sender, unlocked, 0);
        }
        return true;
    }

    /**
        @notice Pay a penalty to withdraw locked tokens
        @dev Withdrawals are processed starting with the lock that will expire soonest.
             The penalty starts at 100% and decays linearly based on the number of epochs
             remaining until the tokens unlock. The exact calculation used is:

             [total amount] * [epochs to unlock] / MAX_LOCK_EPOCHS = [penalty amount]

        @param amountToWithdraw Amount to withdraw, divided by `LOCK_TO_TOKEN_RATIO`. This
                                is the same number of tokens that will be received; the
                                penalty amount is taken on top of this. Reverts if the
                                caller's locked balances are insufficient to cover both
                                the withdrawal and penalty amounts. Setting this value as
                                `type(uint256).max` withdrawals the entire available locked
                                balance, excluding any lock at `MAX_LOCK_EPOCHS` as the
                                penalty on this lock would be 100%.
        @return uint256 Amount of tokens withdrawn
     */
    function withdrawWithPenalty(uint256 amountToWithdraw) external notFrozen(msg.sender) returns (uint256) {
        require(penaltyWithdrawalsEnabled, "Penalty withdrawals are disabled");
        AccountData storage accountData = accountLockData[msg.sender];
        uint32[65535] storage unlocks = accountEpochUnlocks[msg.sender];
        uint256 weight = _epochWeightWrite(msg.sender);
        if (amountToWithdraw != type(uint256).max) amountToWithdraw *= LOCK_TO_TOKEN_RATIO;

        // start by withdrawing unlocked balance without penalty
        uint256 unlocked = accountData.unlocked * LOCK_TO_TOKEN_RATIO;
        if (unlocked >= amountToWithdraw) {
            accountData.unlocked = uint32((unlocked - amountToWithdraw) / LOCK_TO_TOKEN_RATIO);
            govToken.transfer(msg.sender, amountToWithdraw);
            return amountToWithdraw;
        }

        // clear the caller's registered vote weight
        incentiveVoter.clearRegisteredWeight(msg.sender);

        uint256 remaining = amountToWithdraw;
        if (unlocked > 0) {
            remaining -= unlocked;
            accountData.unlocked = 0;
        }

        uint256 systemEpoch = getEpoch();
        uint256 bitfield = accountData.updateEpochs[systemEpoch / 256];
        uint256 penaltyTotal;
        uint256 decreasedWeight;

        // `epochsToUnlock < MAX_LOCK_EPOCHS` stops iteration prior to the final epoch
        for (uint256 epochsToUnlock = 1; epochsToUnlock < MAX_LOCK_EPOCHS; epochsToUnlock++) {
            systemEpoch++;
            if (systemEpoch % 256 == 0) {
                accountData.updateEpochs[systemEpoch / 256 - 1] = 0;
                bitfield = accountData.updateEpochs[systemEpoch / 256];
            }

            if ((bitfield >> (systemEpoch % 256)) & uint256(1) == 1) {
                uint256 lockAmount = unlocks[systemEpoch] * LOCK_TO_TOKEN_RATIO;
                uint256 penaltyOnAmount = (lockAmount * epochsToUnlock) / MAX_LOCK_EPOCHS;

                if (lockAmount - penaltyOnAmount > remaining) {
                    // after penalty, locked amount exceeds remaining required balance
                    // we can complete the withdrawal using only a portion of this lock
                    penaltyOnAmount = (remaining * MAX_LOCK_EPOCHS) / (MAX_LOCK_EPOCHS - epochsToUnlock) - remaining;
                    uint256 dust = ((penaltyOnAmount + remaining) % LOCK_TO_TOKEN_RATIO);
                    if (dust > 0) penaltyOnAmount += LOCK_TO_TOKEN_RATIO - dust;
                    penaltyTotal += penaltyOnAmount;
                    uint256 lockReduceAmount = (penaltyOnAmount + remaining) / LOCK_TO_TOKEN_RATIO;
                    decreasedWeight += lockReduceAmount * epochsToUnlock;
                    unlocks[systemEpoch] -= uint32(lockReduceAmount);
                    totalEpochUnlocks[systemEpoch] -= uint32(lockReduceAmount);
                    remaining = 0;
                } else {
                    // after penalty, locked amount does not exceed remaining required balance
                    // the entire lock must be used in the withdrawal
                    penaltyTotal += penaltyOnAmount;
                    decreasedWeight += (lockAmount / LOCK_TO_TOKEN_RATIO) * epochsToUnlock;
                    bitfield = bitfield & ~(uint256(1) << (systemEpoch % 256));
                    unlocks[systemEpoch] = 0;
                    totalEpochUnlocks[systemEpoch] -= uint32(lockAmount / LOCK_TO_TOKEN_RATIO);
                    remaining -= lockAmount - penaltyOnAmount;
                }

                if (remaining == 0) {
                    break;
                }
            }
        }

        accountData.updateEpochs[systemEpoch / 256] = bitfield;

        if (amountToWithdraw == type(uint256).max) {
            amountToWithdraw -= remaining;
        } else {
            require(remaining == 0, "Insufficient balance after fees");
        }

        accountData.locked -= uint32((amountToWithdraw + penaltyTotal - unlocked) / LOCK_TO_TOKEN_RATIO);
        totalDecayRate -= uint32((amountToWithdraw + penaltyTotal - unlocked) / LOCK_TO_TOKEN_RATIO);
        systemEpoch = getEpoch();
        accountEpochWeights[msg.sender][systemEpoch] = uint40(weight - decreasedWeight);
        totalEpochWeights[systemEpoch] = uint40(getTotalWeightWrite() - decreasedWeight);

        govToken.transfer(msg.sender, amountToWithdraw);
        govToken.transfer(feeReceiver, penaltyTotal);
        emit LocksWithdrawn(msg.sender, amountToWithdraw, penaltyTotal);

        return amountToWithdraw;
    }

    /**
        @dev Updates all data for a given account and returns the account's current weight and epoch
     */
    function _epochWeightWrite(address account) internal returns (uint256 weight) {
        AccountData storage accountData = accountLockData[account];
        uint32[65535] storage epochUnlocks = accountEpochUnlocks[account];
        uint40[65535] storage epochWeights = accountEpochWeights[account];

        uint256 systemEpoch = getEpoch();
        uint256 accountEpoch = accountData.epoch;
        weight = epochWeights[accountEpoch];
        if (accountEpoch == systemEpoch) return weight;

        if (accountData.frozen > 0) {
            while (systemEpoch > accountEpoch) {
                accountEpoch++;
                epochWeights[accountEpoch] = uint40(weight);
            }
            accountData.epoch = uint16(systemEpoch);
            return weight;
        }

        // if account is not frozen and locked balance is 0, we only need to update the account epoch
        uint256 locked = accountData.locked;
        if (locked == 0) {
            if (accountEpoch < systemEpoch) {
                accountData.epoch = uint16(systemEpoch);
            }
            return 0;
        }

        uint256 unlocked;
        uint256 bitfield = accountData.updateEpochs[accountEpoch / 256] >> (accountEpoch % 256);

        while (accountEpoch < systemEpoch) {
            accountEpoch++;
            weight -= locked;
            epochWeights[accountEpoch] = uint40(weight);
            if (accountEpoch % 256 == 0) {
                bitfield = accountData.updateEpochs[accountEpoch / 256];
            } else {
                bitfield = bitfield >> 1;
            }
            if (bitfield & uint256(1) == 1) {
                uint32 amount = epochUnlocks[accountEpoch];
                locked -= amount;
                unlocked += amount;
                if (locked == 0) {
                    // if locked balance hits 0, there are no further tokens to unlock
                    accountEpoch = systemEpoch;
                    break;
                }
            }
        }

        accountData.unlocked = uint32(accountData.unlocked + unlocked);
        accountData.locked = uint32(locked);
        accountData.epoch = uint16(accountEpoch);
        return weight;
    }
}
