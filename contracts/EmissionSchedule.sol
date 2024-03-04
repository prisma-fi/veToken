// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "./interfaces/IIncentiveVoting.sol";
import "./interfaces/IEmissionSchedule.sol";
import "./dependencies/CoreOwnable.sol";
import "./dependencies/BaseConfig.sol";
import "./dependencies/SystemStart.sol";

/**
    @title Emission Schedule
    @author Prisma Finance
    @dev Initial implementation used within Prisma. Can be modified to taste.
    @notice Calculates per-epoch GovToken emissions. The amount is determined
            as a percentage of the remaining unallocated supply. Over time the
            reward rate will decay to dust as it approaches the maximum supply,
            but should not reach zero for a Very Long Time.
 */
contract EmissionSchedule is IEmissionSchedule, BaseConfig, CoreOwnable, SystemStart {
    event EpochPctScheduleSet(uint64[2][] schedule);
    event LockParametersSet(uint256 lockDuration, uint256 lockDecayEpochs);

    IIncentiveVoting public immutable incentiveVoter;
    address public immutable vault;

    // current number of epochs that emissions are locked for when they are claimed
    uint64 public lockDuration;
    // every `lockDecayEpochs`, the number of lock epochs is decreased by one
    uint64 public lockDecayEpochs;

    // percentage of the unallocated token supply given as emissions in a epoch
    uint64 public perEpochPct;

    // [(epoch, perEpochPct)... ] ordered by epoch descending
    // schedule of changes to `perEpochPct` to be applied in future epochs
    uint64[2][] private scheduledEpochPct;

    constructor(
        address core,
        IIncentiveVoting _voter,
        address _vault,
        uint64 _initialLockDuration,
        uint64 _lockDecayEpochs,
        uint64 _perEpochPct,
        uint64[2][] memory _scheduledEpochPct
    ) CoreOwnable(core) SystemStart(core) {
        incentiveVoter = _voter;
        vault = _vault;

        lockDuration = _initialLockDuration;
        lockDecayEpochs = _lockDecayEpochs;
        perEpochPct = _perEpochPct;
        _setEpochPctSchedule(_scheduledEpochPct);
        emit LockParametersSet(_initialLockDuration, _lockDecayEpochs);
    }

    function getEpochPctSchedule() external view returns (uint64[2][] memory) {
        return scheduledEpochPct;
    }

    /**
        @notice Set a schedule for future updates to `perEpochPct`
        @dev The given schedule replaces any existing one
        @param _schedule Dynamic array of (epoch, perEpochPct) ordered by epoch descending.
                         Each `epoch` indicates the number of epochs after the current epoch.
     */
    function setEpochPctSchedule(uint64[2][] memory _schedule) external onlyOwner returns (bool) {
        _setEpochPctSchedule(_schedule);
        return true;
    }

    /**
        @notice Set the number of lock epochs and rate at which lock epochs decay
     */
    function setLockParameters(uint64 _lockDuration, uint64 _lockDecayEpochs) external onlyOwner returns (bool) {
        require(_lockDuration <= MAX_LOCK_EPOCHS, "Cannot exceed MAX_LOCK_EPOCHS");
        require(_lockDecayEpochs > 0, "Decay epochs cannot be 0");

        lockDuration = _lockDuration;
        lockDecayEpochs = _lockDecayEpochs;
        emit LockParametersSet(_lockDuration, _lockDecayEpochs);
        return true;
    }

    /**
        @dev Called by the vault exactly once per receiver each epoch, to get
             epoch emissions for that specific receiver.
     */
    function getReceiverEpochEmissions(
        uint256 id,
        uint256 epoch,
        uint256 totalEpochEmissions
    ) external returns (uint256) {
        require(msg.sender == vault);
        uint256 pct = incentiveVoter.getReceiverVotePct(id, epoch);

        return (totalEpochEmissions * pct) / 1e18;
    }

    /**
        @dev Called exactly once per epoch by the vault, to get emission data for that epoch
     */
    function getTotalEpochEmissions(
        uint256 epoch,
        uint256 unallocatedTotal
    ) external returns (uint256 amount, uint256 lock) {
        require(msg.sender == vault);

        // apply the lock epoch decay
        lock = lockDuration;
        if (lock > 0 && epoch % lockDecayEpochs == 0) {
            lock -= 1;
            lockDuration = uint64(lock);
        }

        // check for and apply scheduled update to `perEpochPct`
        uint256 length = scheduledEpochPct.length;
        uint256 pct = perEpochPct;
        if (length > 0) {
            uint64[2] memory nextUpdate = scheduledEpochPct[length - 1];
            if (nextUpdate[0] == epoch) {
                scheduledEpochPct.pop();
                pct = nextUpdate[1];
                perEpochPct = nextUpdate[1];
            }
        }

        // calculate the epoch emissions as a percentage of the unallocated supply
        amount = (unallocatedTotal * pct) / MAX_PCT;

        return (amount, lock);
    }

    /**
        @dev View method implementation of `getTotalEpochEmissions`, called via the vault.
     */
    function getExpectedNextEpochEmissions(
        uint256 epoch,
        uint256 unallocatedTotal
    ) external view returns (uint256 amount) {
        // check for and apply scheduled update to `perEpochPct`
        uint256 length = scheduledEpochPct.length;
        uint256 pct = perEpochPct;
        if (length > 0) {
            uint64[2] memory nextUpdate = scheduledEpochPct[length - 1];
            if (nextUpdate[0] == epoch) pct = nextUpdate[1];
        }

        // calculate the epoch emissions as a percentage of the unallocated supply
        amount = (unallocatedTotal * pct) / MAX_PCT;

        return amount;
    }

    function _setEpochPctSchedule(uint64[2][] memory _scheduledEpochPct) internal {
        uint256 length = _scheduledEpochPct.length;
        if (length > 0) {
            uint256 epoch = _scheduledEpochPct[0][0];
            uint256 currentEpoch = getEpoch();
            for (uint256 i = 0; i < length; i++) {
                if (i > 0) {
                    require(_scheduledEpochPct[i][0] < epoch, "Must sort by epoch descending");
                    epoch = _scheduledEpochPct[i][0];
                }
                _scheduledEpochPct[i][0] = uint64(epoch + currentEpoch);
                require(_scheduledEpochPct[i][1] <= MAX_PCT, "Cannot exceed MAX_PCT");
            }
            require(epoch > 0, "Cannot schedule past epochs");
        }
        scheduledEpochPct = _scheduledEpochPct;
        emit EpochPctScheduleSet(_scheduledEpochPct);
    }
}
