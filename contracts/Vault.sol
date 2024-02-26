// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./dependencies/BaseConfig.sol";
import "./dependencies/CoreOwnable.sol";
import "./dependencies/DelegatedOps.sol";
import "./dependencies/SystemStart.sol";
import "./interfaces/IEmissionSchedule.sol";
import "./interfaces/IIncentiveVoting.sol";
import "./interfaces/ITokenLocker.sol";
import "./interfaces/IBoostCallback.sol";
import "./interfaces/IBoostCalculator.sol";
import "./interfaces/IEmissionReceiver.sol";

/**
    @title Vault
    @notice The total supply of `GovernanceToken` is initially minted to this contract.
            The govToken balance held here can be considered "uncirculating". The
            vault gradually releases tokens to registered emissions receivers
            as determined by `EmissionSchedule` and `BoostCalculator`.
 */
contract Vault is BaseConfig, CoreOwnable, DelegatedOps, SystemStart {
    using SafeERC20 for IERC20;

    IERC20 public immutable govToken;
    ITokenLocker public immutable tokenLocker;
    IIncentiveVoting public immutable voter;
    uint256 immutable LOCK_TO_TOKEN_RATIO;

    IEmissionSchedule public emissionSchedule;
    IBoostCalculator public boostCalculator;

    // `govToken` balance within the treasury that is not yet allocated.
    // Starts as `govToken.totalSupply()` and decreases over time.
    uint128 public unallocatedTotal;
    // most recent epoch that `unallocatedTotal` was reduced by a call to
    // `emissionSchedule.getTotalEpochEmissions`
    uint64 public totalUpdateEpoch;
    // number of epochs that govToken is locked for when transferred using
    // `transferAllocatedTokens`. updated each epoch by the emission schedule.
    uint64 public lockDuration;

    // id -> receiver data
    uint16[65535] public receiverUpdatedEpoch;
    // id -> address of receiver
    // not bi-directional, one receiver can have multiple ids
    mapping(uint256 => Receiver) public idToReceiver;

    // epoch -> total amount of tokens to be released in that epoch
    uint128[65535] public epochEmissions;

    // receiver -> remaining tokens which have been allocated but not yet distributed
    mapping(address => uint256) public receiverAllocated;

    // account -> epoch -> govToken amount claimed in that epoch (used for calculating boost)
    mapping(address => uint128[65535]) accountEpochEarned;

    // pending rewards for an address (dust after locking, fees from delegation)
    mapping(address => uint256) private storedPendingReward;

    mapping(address => Delegation) public boostDelegation;

    struct Receiver {
        address account;
        uint16 maxEmissionPct;
    }

    struct Delegation {
        bool isDelegationEnabled;
        bool hasDelegateCallback;
        bool hasReceiverCallback;
        uint16 feePct;
        IBoostCallback callback;
    }

    struct InitialAllowance {
        address receiver;
        uint256 amount;
    }

    struct InitialReceiver {
        address receiver;
        uint256 count;
        uint256[] maxEmissionPct;
    }

    event NewReceiverRegistered(address receiver, uint256 id);
    event ReceiverMaxEmissionPctSet(uint256 indexed id, uint256 maxPct);
    event UnallocatedSupplyReduced(uint256 reducedAmount, uint256 unallocatedTotal);
    event UnallocatedSupplyIncreased(uint256 increasedAmount, uint256 unallocatedTotal);
    event IncreasedReceiverAllocation(address indexed receiver, uint256 increasedAmount);
    event EmissionScheduleSet(address emissionScheduler);
    event BoostCalculatorSet(address boostCalculator);
    event BoostDelegationSet(
        address indexed boostDelegate,
        bool isDelegationEnabled,
        bool hasDelegateCallback,
        bool hasReceiverCallback,
        uint256 feePct,
        address indexed callback
    );
    event RewardClaimed(
        address indexed claimant,
        address indexed receiver,
        address indexed boostDelegate,
        uint256 claimedAmount,
        uint256 receivedAmount,
        uint256 delegateFeeAmount
    );
    event DelegateFeePaid(address indexed claimant, address indexed delegate, uint256 feeAmount);

    constructor(
        address core,
        IERC20 _token,
        ITokenLocker _locker,
        IIncentiveVoting _voter,
        IEmissionSchedule _emissionSchedule,
        IBoostCalculator _boostCalculator,
        uint64 initialLockDuration,
        uint128[] memory _fixedInitialAmounts,
        InitialAllowance[] memory initialAllowances,
        InitialReceiver[] memory initialReceivers
    ) CoreOwnable(core) SystemStart(core) {
        govToken = _token;
        tokenLocker = _locker;
        voter = _voter;
        LOCK_TO_TOKEN_RATIO = _locker.LOCK_TO_TOKEN_RATIO();

        emissionSchedule = _emissionSchedule;
        boostCalculator = _boostCalculator;

        uint256 totalSupply = _token.totalSupply();
        require(_token.balanceOf(address(this)) == totalSupply);

        // set initial fixed epoch emissions
        uint256 totalAllocated;
        uint256 length = _fixedInitialAmounts.length;
        for (uint256 i = 0; i < length; i++) {
            uint128 amount = _fixedInitialAmounts[i];
            // +1 because in the first epoch there are no votes, so no emissions possible
            epochEmissions[i + 1] = amount;
            totalAllocated += amount;
        }

        // set initial transfer allowances for e.g. airdrops, vests, team treasury
        length = initialAllowances.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 amount = initialAllowances[i].amount;
            address receiver = initialAllowances[i].receiver;
            totalAllocated += amount;
            // initial allocations are given as approvals
            govToken.approve(receiver, amount);
        }

        unallocatedTotal = uint128(totalSupply - totalAllocated);
        totalUpdateEpoch = uint64(_fixedInitialAmounts.length);
        lockDuration = initialLockDuration;

        emit EmissionScheduleSet(address(_emissionSchedule));
        emit BoostCalculatorSet(address(_boostCalculator));
        emit UnallocatedSupplyReduced(totalAllocated, unallocatedTotal);

        length = initialReceivers.length;
        for (uint i = 0; i < length; i++) {
            _registerReceiver(
                initialReceivers[i].receiver,
                initialReceivers[i].count,
                initialReceivers[i].maxEmissionPct
            );
        }
    }

    function receiverCount() external view returns (uint256) {
        return voter.receiverCount();
    }

    /**
        @notice Get the current expected total emissions for the next epoch
        @dev Changes to `unallocatedTotal` during the epoch can affect this number
     */
    function getExpectedNextEpochEmissions() external view returns (uint256) {
        return emissionSchedule.getExpectedNextEpochEmissions(getEpoch() + 1, unallocatedTotal);
    }

    /**
        @notice Get information on account's boost for the current epoch
        @return currentBoost Accounts's current boost, as a whole number where 10000 represents 1x
        @return claimed Amount claimed so far this epoch (without any adjustments for boost)
        @return maxBoosted Total claimable amount this epoch that can recieve maximum boost
        @return boosted Total claimable amount this epoch that can receive >1x boost.
                        This value also includes the `maxBoosted` amount.
     */
    function getAccountBoostData(
        address account
    ) external view returns (uint256 currentBoost, uint256 claimed, uint256 maxBoosted, uint256 boosted) {
        uint256 epoch = getEpoch();
        uint256 epochTotal = epochEmissions[epoch];
        uint256 previousAmount = accountEpochEarned[account][epoch];
        (currentBoost, maxBoosted, boosted) = boostCalculator.getAccountBoostData(account, previousAmount, epochTotal);
        return (currentBoost, previousAmount, maxBoosted, boosted);
    }

    /**
        @notice Claimable govToken amount for `account` in `rewardContract` after applying boost
        @dev Returns (0, 0) if the boost delegate is invalid, or the delgate's callback fee
             function is incorrectly configured.
        @param account Address claiming rewards
        @param boostDelegate Address to delegate boost from when claiming. Set as
                             `address(0)` to use the boost of the claimer.
        @param rewardContracts Array of addresses of receiver contracts where the caller has
                               rewards to claim.
        @return adjustedAmount Amount received after boost, prior to paying delegate fee
        @return feeToDelegate Fee amount paid to `boostDelegate`

     */
    function getAdjustedClaimableReward(
        address account,
        address receiver,
        address boostDelegate,
        IEmissionReceiver[] calldata rewardContracts
    ) external view returns (uint256 adjustedAmount, uint256 feeToDelegate) {
        uint256 amount;
        for (uint i = 0; i < rewardContracts.length; i++) {
            amount += rewardContracts[i].claimableReward(account);
        }
        uint256 epoch = getEpoch();
        uint256 epochTotal = epochEmissions[epoch];
        address claimant = boostDelegate == address(0) ? account : boostDelegate;
        uint256 previousAmount = accountEpochEarned[claimant][epoch];

        uint256 fee;
        if (boostDelegate != address(0)) {
            Delegation memory data = boostDelegation[boostDelegate];
            if (!data.isDelegationEnabled) return (0, 0);
            fee = data.feePct;
            if (fee == type(uint16).max) {
                try
                    data.callback.getFeePct(claimant, receiver, boostDelegate, amount, previousAmount, epochTotal)
                returns (uint256 _fee) {
                    fee = _fee;
                } catch {
                    return (0, 0);
                }
            }
            if (fee > MAX_PCT) return (0, 0);
        }

        adjustedAmount = boostCalculator.getBoostedAmount(claimant, amount, previousAmount, epochTotal);
        fee = (adjustedAmount * fee) / MAX_PCT;

        return (adjustedAmount, fee);
    }

    /**
        @notice Get the claimable amount that `claimant` has earned boost delegation fees
     */
    function getClaimableBoostDelegationFees(address claimant) external view returns (uint256 amount) {
        amount = storedPendingReward[claimant];
        // only return values `>= LOCK_TO_TOKEN_RATIO` so we do not report "dust" stored for normal users
        return amount >= LOCK_TO_TOKEN_RATIO ? amount : 0;
    }

    /**
        @notice Register a new emission receiver
        @dev Once a receiver is registered, the receiver ID is immediately eligible
             for votes within `IncentiveVoting`. Receiver IDs are ordered sequentially
             starting from 1. An ID of 0 is considered unset.
        @param receiver Address of the receiver
        @param count Number of IDs to assign to the receiver
        @param maxEmissionPct Array of maximum percent of emissions for each new receiver.
                              Can be left empty for receivers that are not restricted.
     */
    function registerReceiver(
        address receiver,
        uint256 count,
        uint256[] memory maxEmissionPct
    ) external onlyOwner returns (bool) {
        _registerReceiver(receiver, count, maxEmissionPct);

        return true;
    }

    function _registerReceiver(address receiver, uint256 count, uint256[] memory maxEmissionPct) internal {
        require(maxEmissionPct.length == count, "Invalid maxEmissionPct.length");
        uint256[] memory assignedIds = new uint256[](count);
        uint16 epoch = uint16(getEpoch());
        for (uint256 i = 0; i < count; i++) {
            uint256 maxPct = maxEmissionPct[i];
            if (maxPct == 0) maxPct = MAX_PCT;
            else require(maxPct <= MAX_PCT, "Invalid maxEmissionPct");
            uint256 id = voter.registerNewReceiver();
            assignedIds[i] = id;
            receiverUpdatedEpoch[id] = epoch;
            idToReceiver[id] = Receiver({ account: receiver, maxEmissionPct: uint16(maxPct) });
            emit NewReceiverRegistered(receiver, id);
        }
        // notify the receiver contract of the newly registered ID
        // also serves as a sanity check to ensure the contract is capable of receiving emissions
        IEmissionReceiver(receiver).notifyRegisteredId(assignedIds);
    }

    /**
        @notice Set the max emission percent a receiver is eligible to receiver each epoch
        @dev Excess emissions directed to a receiver are instead returned to
             the unallocated supply. This way potential emissions are not lost
             due to old emissions votes pointing at a receiver that was phased out.
             Receivers are effectively removed by setting the max percent to zero.
        @param id ID of the receiver to modify the max emission percent for
        @param maxEmissionPct Maximum percent of emissions received per epoch
                              as a whole number out of MAX_PCT
     */
    function setReceiverMaxEmissionPct(uint256 id, uint256 maxEmissionPct) external onlyOwner returns (bool) {
        require(maxEmissionPct <= MAX_PCT, "Invalid maxEmissionPct");
        Receiver memory receiver = idToReceiver[id];
        require(receiver.account != address(0), "ID not set");
        receiver.maxEmissionPct = uint16(maxEmissionPct);
        idToReceiver[id] = receiver;
        emit ReceiverMaxEmissionPctSet(id, maxEmissionPct);

        return true;
    }

    /**
        @notice Set the `emissionSchedule` contract
        @dev Callable only by the owner (the DAO admin voter, to change the emission schedule).
             The new schedule is applied from the start of the next epoch.
     */
    function setEmissionSchedule(IEmissionSchedule _emissionSchedule) external onlyOwner returns (bool) {
        _allocateTotalEpoch(emissionSchedule, getEpoch());
        emissionSchedule = _emissionSchedule;
        emit EmissionScheduleSet(address(_emissionSchedule));

        return true;
    }

    function setBoostCalculator(IBoostCalculator _boostCalculator) external onlyOwner returns (bool) {
        boostCalculator = _boostCalculator;
        emit BoostCalculatorSet(address(_boostCalculator));

        return true;
    }

    /**
        @notice Transfer tokens out of the vault
     */
    function transferTokens(IERC20 token, address receiver, uint256 amount) external onlyOwner returns (bool) {
        if (address(token) == address(govToken)) {
            require(receiver != address(this), "Self transfer denied");
            uint256 unallocated = unallocatedTotal - amount;
            unallocatedTotal = uint128(unallocated);
            emit UnallocatedSupplyReduced(amount, unallocated);
        }
        token.safeTransfer(receiver, amount);

        return true;
    }

    /**
        @notice Receive `govToken` tokens and add them to the unallocated supply
     */
    function increaseUnallocatedSupply(uint256 amount) external returns (bool) {
        govToken.transferFrom(msg.sender, address(this), amount);
        uint256 unallocated = unallocatedTotal + amount;
        unallocatedTotal = uint128(unallocated);
        emit UnallocatedSupplyIncreased(amount, unallocated);

        return true;
    }

    function _allocateTotalEpoch(IEmissionSchedule _emissionSchedule, uint256 currentEpoch) internal {
        uint256 epoch = totalUpdateEpoch;
        if (epoch >= currentEpoch) return;

        if (address(_emissionSchedule) == address(0)) {
            totalUpdateEpoch = uint64(currentEpoch);
            return;
        }

        uint256 lock;
        uint256 amount;
        uint256 unallocated = unallocatedTotal;
        while (epoch < currentEpoch) {
            ++epoch;
            (amount, lock) = _emissionSchedule.getTotalEpochEmissions(epoch, unallocated);
            epochEmissions[epoch] = uint128(amount);

            unallocated = unallocated - amount;
            emit UnallocatedSupplyReduced(amount, unallocated);
        }

        unallocatedTotal = uint128(unallocated);
        totalUpdateEpoch = uint64(currentEpoch);
        lockDuration = uint64(lock);
    }

    /**
        @notice Allocate additional `govToken` allowance to an emission reciever
                based on the emission schedule
        @param id Receiver ID. The caller must be the receiver mapped to this ID.
        @return uint256 Additional `govToken` allowance for the receiver. The receiver
                        accesses the tokens using `Vault.transferAllocatedTokens`
     */
    function allocateNewEmissions(uint256 id) external returns (uint256) {
        // avoid reverting in case of a call from an unregistered receiver
        if (id == 0) return 0;

        Receiver memory receiver = idToReceiver[id];
        require(receiver.account == msg.sender, "Receiver not registered");
        uint256 epoch = receiverUpdatedEpoch[id];
        uint256 currentEpoch = getEpoch();
        if (epoch == currentEpoch) return 0;

        IEmissionSchedule _emissionSchedule = emissionSchedule;
        _allocateTotalEpoch(_emissionSchedule, currentEpoch);

        if (address(_emissionSchedule) == address(0)) {
            receiverUpdatedEpoch[id] = uint16(currentEpoch);
            return 0;
        }

        uint256 maxPct = receiver.maxEmissionPct;
        uint256 allocated;
        uint256 unallocated;
        while (epoch < currentEpoch) {
            ++epoch;
            uint256 totalEpochEmissions = epochEmissions[epoch];
            uint256 epochAmount = _emissionSchedule.getReceiverEpochEmissions(id, epoch, totalEpochEmissions);
            if (maxPct < MAX_PCT) {
                uint256 cappedAmount = (totalEpochEmissions * maxPct) / MAX_PCT;
                if (epochAmount > cappedAmount) {
                    unallocated += epochAmount - cappedAmount;
                    epochAmount = cappedAmount;
                }
            }
            allocated = allocated + epochAmount;
        }

        receiverUpdatedEpoch[id] = uint16(currentEpoch);

        if (allocated > 0) {
            receiverAllocated[msg.sender] = receiverAllocated[msg.sender] + allocated;
            emit IncreasedReceiverAllocation(msg.sender, allocated);
        }
        if (unallocated > 0) {
            uint256 newUnallocatedTotal = unallocatedTotal + unallocated;
            unallocatedTotal = uint128(newUnallocatedTotal);
            emit UnallocatedSupplyIncreased(unallocated, newUnallocatedTotal);
        }
        return allocated;
    }

    /**
        @notice Transfer `govToken` tokens previously allocated to the caller
        @dev Callable only by registered receiver contracts which were previously
             allocated tokens using `allocateNewEmissions`.
        @param claimant Address that is claiming the tokens
        @param receiver Address to transfer tokens to
        @param amount Desired amount of tokens to transfer. This value always assumes max boost.
        @return bool success
     */
    function transferAllocatedTokens(address claimant, address receiver, uint256 amount) external returns (bool) {
        if (amount > 0) {
            receiverAllocated[msg.sender] -= amount;
            _transferAllocated(0, claimant, receiver, address(0), amount);
        }
        return true;
    }

    /**
        @notice Claim earned tokens from multiple reward contracts, optionally with delegated boost
        @param receiver Address to transfer tokens to. Any earned 3rd-party rewards
                        are also sent to this address.
        @param boostDelegate Address to delegate boost from during this claim. Set as
                             `address(0)` to use the boost of the claimer.
        @param rewardContracts Array of addresses of registered receiver contracts where
                               the caller has pending rewards to claim.
        @param maxFeePct Maximum fee percent to pay to delegate, as a whole number out of 10000
        @return bool success
     */
    function batchClaimRewards(
        address account,
        address receiver,
        address boostDelegate,
        IEmissionReceiver[] calldata rewardContracts,
        uint256 maxFeePct
    ) external callerOrDelegated(account) returns (bool) {
        require(maxFeePct <= MAX_PCT, "Invalid maxFeePct");

        uint256 total;
        uint256 length = rewardContracts.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 amount = rewardContracts[i].vaultClaimReward(account, receiver);
            receiverAllocated[address(rewardContracts[i])] -= amount;
            total += amount;
        }
        _transferAllocated(maxFeePct, account, receiver, boostDelegate, total);
        return true;
    }

    /**
        @notice Claim tokens earned from boost delegation fees
        @param receiver Address to transfer the tokens to
        @return bool Success
     */
    function claimBoostDelegationFees(
        address account,
        address receiver
    ) external callerOrDelegated(account) returns (bool) {
        uint256 amount = storedPendingReward[account];
        require(amount >= LOCK_TO_TOKEN_RATIO, "Nothing to claim");
        Delegation memory data = boostDelegation[receiver];
        if (data.hasReceiverCallback) {
            require(
                data.callback.receiverCallback(account, receiver, address(0), amount),
                "Fee claim callback rejected"
            );
        }
        _transferOrLock(account, receiver, amount);
        return true;
    }

    function _transferAllocated(
        uint256 maxFeePct,
        address account,
        address receiver,
        address boostDelegate,
        uint256 amount
    ) internal {
        if (amount > 0) {
            uint256 epoch = getEpoch();
            uint256 epochTotal = epochEmissions[epoch];
            address claimant = boostDelegate == address(0) ? account : boostDelegate;
            uint256 previousAmount = accountEpochEarned[claimant][epoch];

            // if boost delegation is active, get the fee and optional callback address
            uint256 fee;
            IBoostCallback delegateCallback;
            if (boostDelegate != address(0)) {
                Delegation memory data = boostDelegation[boostDelegate];

                require(data.isDelegationEnabled, "Invalid delegate");
                if (data.feePct == type(uint16).max) {
                    fee = data.callback.getFeePct(account, receiver, boostDelegate, amount, previousAmount, epochTotal);
                    require(fee <= MAX_PCT, "Invalid delegate fee");
                } else fee = data.feePct;
                require(fee <= maxFeePct, "fee exceeds maxFeePct");
                if (data.hasDelegateCallback) delegateCallback = data.callback;
            }

            // calculate adjusted amount with actual boost applied
            uint256 adjustedAmount = boostCalculator.getBoostedAmountWrite(
                claimant,
                amount,
                previousAmount,
                epochTotal
            );
            {
                // remaining tokens from unboosted claims are added to the unallocated total
                // context avoids stack-too-deep
                uint256 boostUnclaimed = amount - adjustedAmount;
                if (boostUnclaimed > 0) {
                    uint256 unallocated = unallocatedTotal + boostUnclaimed;
                    unallocatedTotal = uint128(unallocated);
                    emit UnallocatedSupplyIncreased(boostUnclaimed, unallocated);
                }
            }
            accountEpochEarned[claimant][epoch] = uint128(previousAmount + amount);

            // apply boost delegation fee
            if (fee != 0) {
                fee = (adjustedAmount * fee) / MAX_PCT;
                adjustedAmount -= fee;
            }

            // add `storedPendingReward` to `adjustedAmount`
            // this happens after any boost modifiers or delegation fees, since
            // these effects were already applied to the stored value
            adjustedAmount += storedPendingReward[account];

            _transferOrLock(account, receiver, adjustedAmount);

            // apply delegate fee and optionally perform delegate callback
            if (fee != 0) {
                storedPendingReward[boostDelegate] += fee;
                emit DelegateFeePaid(account, boostDelegate, fee);
            }
            if (address(delegateCallback) != address(0)) {
                require(
                    delegateCallback.delegateCallback(
                        account,
                        receiver,
                        boostDelegate,
                        amount,
                        adjustedAmount,
                        fee,
                        previousAmount,
                        epochTotal
                    ),
                    "Delegate callback rejected"
                );
            }
            // if claimant is not receiver, optionally perform receiver callback
            if (account != receiver) {
                Delegation memory data = boostDelegation[receiver];
                if (data.hasReceiverCallback) {
                    require(
                        data.callback.receiverCallback(account, receiver, boostDelegate, adjustedAmount),
                        "Receiver callback rejected"
                    );
                }
            }
            emit RewardClaimed(account, receiver, boostDelegate, amount, adjustedAmount, fee);
        }
    }

    function _transferOrLock(address claimant, address receiver, uint256 amount) internal {
        uint256 _lockDuration = lockDuration;
        if (_lockDuration == 0) {
            storedPendingReward[claimant] = 0;
            govToken.transfer(receiver, amount);
        } else {
            // lock for receiver and store remaining balance in `storedPendingReward`
            uint256 lockAmount = amount / LOCK_TO_TOKEN_RATIO;
            storedPendingReward[claimant] = amount - lockAmount * LOCK_TO_TOKEN_RATIO;
            if (lockAmount > 0) tokenLocker.lock(receiver, lockAmount, _lockDuration);
        }
    }

    /**
        @notice Enable or disable boost delegation, and set boost callback parameters
        @param account Address to modify delegation params for
        @param isDelegationEnabled is boost delegation enabled?
        @param hasDelegateCallback If true, each time `account` is used as a boost delegate
                                   a call is sent to `IBoostCallback(callback).delegateCallback`
        @param hasReceiverCallback If true, each time `account` is used as a claim receiver
                                   a call is sent to `IBoostCallback(callback).receiverCallback`.
                                   Note that if enabled, the receiver callback occurs even if
                                   delegation is not enabled.
        @param feePct Fee % charged when claims are made that delegate to the caller's boost.
                      Given as a whole number out of 10000. If set to type(uint16).max, the fee
                      is set by calling `IBoostCallback(callback).getFeePct` prior to each claim.
        @param callback Optional contract address for feePct, receiver and delegate callbacks.
                        Must adhere to the `IBoostCallback` interface.
     */
    function setBoostDelegationParams(
        address account,
        bool isDelegationEnabled,
        bool hasDelegateCallback,
        bool hasReceiverCallback,
        uint256 feePct,
        address callback
    ) external callerOrDelegated(account) returns (bool) {
        if (isDelegationEnabled) {
            require(feePct <= MAX_PCT || feePct == type(uint16).max, "Invalid feePct");
            boostDelegation[account] = Delegation({
                isDelegationEnabled: true,
                hasDelegateCallback: hasDelegateCallback,
                hasReceiverCallback: hasReceiverCallback,
                feePct: uint16(feePct),
                callback: IBoostCallback(callback)
            });
        } else {
            boostDelegation[account] = Delegation({
                isDelegationEnabled: false,
                hasDelegateCallback: false,
                hasReceiverCallback: hasReceiverCallback,
                feePct: 0,
                callback: IBoostCallback(callback)
            });
        }
        emit BoostDelegationSet(
            account,
            isDelegationEnabled,
            hasDelegateCallback,
            hasReceiverCallback,
            feePct,
            callback
        );

        return true;
    }
}
