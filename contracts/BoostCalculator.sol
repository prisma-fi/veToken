// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "./interfaces/IBoostCalculator.sol";
import "./interfaces/ITokenLocker.sol";
import "./dependencies/SystemStart.sol";

/**
    @title Boost Calculator
    @author Prisma Finance
    @dev Initial implementation used within Prisma. Can be modified to taste.
    @notice "Boost" refers to a bonus to claimable tokens that an account
            receives based on it's lock weight. An account with "Max boost"
            is earning rewards at 2x the rate of an account that is unboosted.
            Boost works as follows:

            * In a given epoch, the percentage of the epoch's rewards that an
            account can claim with maximum boost is the same as the percentage
            of lock weight that the account has, relative to the total lock
            weight.
            * Once an account's claims per epoch exceed the amount allowed with max boost,
            the boost rate decays linearly from 2x to 1x. This decay occurs over the same
            amount of tokens that were available for maximum boost.
            * Once an account's claims per epoch are more than double the amount allowed for
            max boost, the boost bonus is fully depleted.
            * At the start of the next epoch, boost amounts are recalculated.

            As an example:

            * At the end of epoch 1, Alice has a lock weight of 100. There is a total
              lock weight of 1,000. Alice controls 10% of the total lock weight.
            * During epoch 2, a total of 500,000 new tokens are made available
            * Because Alice has 10% of the lock weight in epoch 1, during epoch 2 she
              can claim up to 10% of the rewards (50,000 tokens) with her full boost.
            * Once Alice's total claims in the epoch exceed 50,000 tokens, her boost
              decays linearly over the next 50,000 tokens that she claims.
            * Once Alice's claims in the epoch exceed 100,000 tokens, any further claims are
              "unboosted" and receive only half as many tokens as they would have boosted.
            * At the start of the next epoch, Alice's boost is fully replenished. She still
              controls 10% of the total lock weight, so she can claim another 10% of this
              epoch's emissions at full boost.

            Note that boost is applied at the time of claiming a reward, not at the time
            the reward was earned. An account that has depleted it's boost may opt to wait
            for the start of the next epoch in order to claim with a larger boost.

            On a technical level, we consider the full earned reward to be the maximum
            boosted amount. "Unboosted" is more accurately described as "paying a 50%
            penalty". Rewards that go undistributed due to claims with lowered boost
            are returned to the unallocated token supply, and distributed again in the
            emissions of future epochs.
 */
contract BoostCalculator is IBoostCalculator, SystemStart {
    ITokenLocker public immutable tokenLocker;

    // initial number of epochs where all accounts recieve max boost
    uint256 public immutable MAX_BOOST_GRACE_EPOCHS;

    // epoch -> total epoch lock weight
    // tracked locally to avoid repeated external calls
    uint40[65535] totalEpochWeights;
    // account -> epoch -> % of lock weight (where 1e9 represents 100%)
    mapping(address account => uint32[65535]) accountEpochLockPct;

    constructor(address core, ITokenLocker _locker, uint256 _graceEpochs) SystemStart(core) {
        require(_graceEpochs > 0, "Grace epochs cannot be 0");
        tokenLocker = _locker;
        MAX_BOOST_GRACE_EPOCHS = _graceEpochs + getEpoch();
    }

    /**
        @notice Get information on account's boost for the current epoch
        @param account Address to query boost data for
        @param previousAmount Amount claimed by account in the current epoch
        @param totalEpochEmissions Total emissions released this epoch
        @return currentBoost Accounts's current boost, as a whole number where 10000 represents 1x
        @return maxBoosted Total claimable amount this epoch that can recieve maximum boost
        @return boosted Total claimable amount this epoch that can receive >1x boost.
                        This value also includes the `maxBoosted` amount.
     */
    function getAccountBoostData(
        address account,
        uint256 previousAmount,
        uint256 totalEpochEmissions
    ) external view returns (uint256 currentBoost, uint256 maxBoosted, uint256 boosted) {
        uint256 epoch = getEpoch();
        if (epoch < MAX_BOOST_GRACE_EPOCHS) {
            uint256 remaining = totalEpochEmissions - previousAmount;
            return (20000, remaining, remaining);
        }
        epoch -= 1;

        uint256 accountWeight = tokenLocker.getAccountWeightAt(account, epoch);
        uint256 totalWeight = tokenLocker.getTotalWeightAt(epoch);
        if (totalWeight == 0) totalWeight = 1;
        uint256 pct = (1e9 * accountWeight) / totalWeight;
        if (pct == 0) return (10000, 0, 0);

        uint256 maxBoostable = (totalEpochEmissions * pct) / 1e9;
        uint256 fullDecay = maxBoostable * 2;

        return (_getBoostedAmount(20000, previousAmount, totalEpochEmissions, pct), maxBoosted, fullDecay);
    }

    /**
        @notice Get the adjusted claim amount after applying an account's boost
        @param account Address claiming the reward
        @param amount Amount being claimed (assuming maximum boost)
        @param previousAmount Amount that was already claimed in the current epoch
        @param totalEpochEmissions Total emissions released this epoch
        @return adjustedAmount Amount of received after applying boost
     */
    function getBoostedAmount(
        address account,
        uint256 amount,
        uint256 previousAmount,
        uint256 totalEpochEmissions
    ) external view returns (uint256 adjustedAmount) {
        uint256 epoch = getEpoch();
        if (epoch < MAX_BOOST_GRACE_EPOCHS) return amount;
        epoch -= 1;

        uint256 accountWeight = tokenLocker.getAccountWeightAt(account, epoch);
        uint256 totalWeight = tokenLocker.getTotalWeightAt(epoch);
        if (totalWeight == 0) totalWeight = 1;
        uint256 pct = (1e9 * accountWeight) / totalWeight;
        if (pct == 0) pct = 1;
        return _getBoostedAmount(amount, previousAmount, totalEpochEmissions, pct);
    }

    /**
        @notice Get the adjusted claim amount after applying an account's boost
        @dev Stores lock weights and percents to reduce cost on future calls
        @param account Address claiming the reward
        @param amount Amount being claimed (assuming maximum boost)
        @param previousAmount Amount that was already claimed in the current epoch
        @param totalEpochEmissions Total token emissions released this epoch
        @return adjustedAmount Amount of tokens received after applying boost
     */
    function getBoostedAmountWrite(
        address account,
        uint256 amount,
        uint256 previousAmount,
        uint256 totalEpochEmissions
    ) external returns (uint256 adjustedAmount) {
        uint256 epoch = getEpoch();
        if (epoch < MAX_BOOST_GRACE_EPOCHS) return amount;
        epoch -= 1;

        uint256 pct = accountEpochLockPct[account][epoch];
        if (pct == 0) {
            uint256 totalWeight = totalEpochWeights[epoch];
            if (totalWeight == 0) {
                totalWeight = tokenLocker.getTotalWeightAt(epoch);
                if (totalWeight == 0) totalWeight = 1;
                totalEpochWeights[epoch] = uint40(totalWeight);
            }

            uint256 accountWeight = tokenLocker.getAccountWeightAt(account, epoch);
            pct = (1e9 * accountWeight) / totalWeight;
            if (pct == 0) pct = 1;
            accountEpochLockPct[account][epoch] = uint32(pct);
        }

        return _getBoostedAmount(amount, previousAmount, totalEpochEmissions, pct);
    }

    function _getBoostedAmount(
        uint256 amount,
        uint256 previousAmount,
        uint256 totalEpochEmissions,
        uint256 pct
    ) internal pure returns (uint256 adjustedAmount) {
        // we use 1 to indicate no lock weight: no boost
        if (pct == 1) return amount / 2;

        uint256 total = amount + previousAmount;
        uint256 maxBoostable = (totalEpochEmissions * pct) / 1e9;
        uint256 fullDecay = maxBoostable * 2;

        // entire claim receives max boost
        if (maxBoostable >= total) return amount;

        // entire claim receives no boost
        if (fullDecay <= previousAmount) return amount / 2;

        // apply max boost for partial claim
        if (previousAmount < maxBoostable) {
            adjustedAmount = maxBoostable - previousAmount;
            amount -= adjustedAmount;
            previousAmount = maxBoostable;
        }

        // apply no boost for partial claim
        if (total > fullDecay) {
            adjustedAmount += (total - fullDecay) / 2;
            amount -= (total - fullDecay);
        }

        // simplified calculation if remaining claim is the entire decay amount
        if (amount == maxBoostable) return adjustedAmount + ((maxBoostable * 3) / 4);

        // remaining calculations handle claim that spans only part of the decay

        // get adjusted amount based on the final boost
        uint256 finalBoosted = amount - (amount * (previousAmount + amount - maxBoostable)) / maxBoostable / 2;
        adjustedAmount += finalBoosted;

        // get adjusted amount based on the initial boost
        uint256 initialBoosted = amount - (amount * (previousAmount - maxBoostable)) / maxBoostable / 2;
        // with linear decay, adjusted amount is half of the difference between initial and final boost amounts
        adjustedAmount += (initialBoosted - finalBoosted) / 2;

        return adjustedAmount;
    }
}
