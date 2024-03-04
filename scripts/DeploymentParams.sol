// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Vault} from "../contracts/Vault.sol";

library DeploymentParams {
    /*//////////////////////////////////////////////////////////////
                             1. CORE OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of seconds within one "epoch" (a locking / voting period).
    /// Contracts permanently break from array out-of-bounds after 65535 epochs,
    /// so the duration of one epoch must be long enough that this issue will
    /// not occur until the distant future.
    uint256 public constant EPOCH_LENGTH = 1 weeks;

    /// @notice Seconds to subtract when calculating `START_TIME`. With an epoch length
    /// of one week, an offset of 3.5 days means that a new epoch begins every
    /// Sunday at 12:00:00 UTC.
    uint256 public constant START_OFFSET = 0;

    /*//////////////////////////////////////////////////////////////
                          2. GOVERNANCE TOKEN
    //////////////////////////////////////////////////////////////*/

    string public constant NAME = "Valueless Governance Token";

    string public constant SYMBOL = "VGT";

    uint256 public constant SUPPLY = 100_000_000 ether;

    /*//////////////////////////////////////////////////////////////
                            3. TOKEN LOCKER
    //////////////////////////////////////////////////////////////*/

    uint256 public constant LOCK_TO_TOKEN_RATIO = 1 ether;

    /// @notice are penalty withdrawals of locked positions enabled initially?
    bool public constant PENALTY_WITHDRAWAL_ENABLED = true;

    /*//////////////////////////////////////////////////////////////
                          4. INCENTIVE VOTING
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                                5. VAULT
    //////////////////////////////////////////////////////////////*/

    /// @notice list of initial fixed per-epoch emissions, once this many epochs have passed
    /// the `EmissionSchedule` takes effect
    function fixedInitialAmounts() public pure returns (uint128[] memory) {
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = 100_000 ether;
        amounts[1] = 100_000 ether;

        return amounts;
    }

    /// @notice list of `(address, amount)` for approvals to transfer tokens out of the vault
    /// used for allocating tokens outside of normal emissions, e.g airdrops, vests, team treasury
    /// IMPORTANT: you must allocate some balance to the deployer that can be locked in the first
    /// epoch and used to vote for the initial round of emissions
    function initialAllowances() public pure returns (Vault.InitialAllowance[] memory) {
        Vault.InitialAllowance[] memory allowances = new Vault.InitialAllowance[](0);

        return allowances;
    }

    function initialReceivers() public pure returns (Vault.InitialReceiver[] memory) {
        Vault.InitialReceiver[] memory receivers = new Vault.InitialReceiver[](0);

        return receivers;
    }

    /*//////////////////////////////////////////////////////////////
                          6. BOOST CALCULATOR
    //////////////////////////////////////////////////////////////*/

    /// @notice number of initial epochs where all claims recieve maximum boost
    /// should be >=2, because in the first epoch there are no emissions and in the second
    /// epoch users have not have a chance to lock yet
    uint256 public constant BOOST_GRACE_EPOCHS = 2;

    /// @notice max boost multiplier
    uint8 public constant MAX_BOOST_MULTIPLIER = 2;

    /// @notice percentage of the total epoch emissions that an account can claim with max
    /// boost, expressed as a percent relative to the account's percent of the total
    /// lock weight. For example, if an account has 5% of the lock weight and the
    /// max boostable percent is 150, the account can claim 7.5% (5% * 150%) of the
    /// epoch's emissions at a max boost.
    uint16 public constant MAX_BOOSTABLE_PCT = 10000; // 100%

    /// @notice percentage of the total epoch emissions that an account can claim with decaying boost
    uint16 public constant DECAY_BOOST_PCT = 10000; // 100%

    /*//////////////////////////////////////////////////////////////
                          7. EMISSION SCHEDULE
    //////////////////////////////////////////////////////////////*/

    /// @notice emissions are initially locked for this many epochs upon claim
    uint64 public constant INITIAL_LOCK_DURATION = 26 weeks;

    /// @notice each time this many epochs pass, the lock-on-claim duration decreases by 1 epoch
    uint64 public constant LOCK_EPOCHS_DECAY_RATE = 2;

    /// @notice initial percent of the unallocated supply to be given as per-epoch emissions,
    /// once the fixed initial amounts are finished
    uint64 public constant INITIAL_PER_EPOCH_PCT = 100; // 1%

    /// @notice  list of `(epoch, percent)` for scheduled changes to the percent of the unallocated
    /// supply to be used as per-epoch emissions. Need to be in descending order by epoch
    function scheduleWeeklyPct() public pure returns (uint64[2][] memory) {
        uint64[2][] memory schedule = new uint64[2][](6);
        schedule[0] = [uint64(167), uint64(50)]; // After 167 weeks, 0.5% per week
        schedule[1] = [uint64(115), uint64(60)]; // After 115 weeks, 0.6% per week
        schedule[2] = [uint64(63), uint64(70)]; // After 63 weeks, 0.7% per week
        schedule[3] = [uint64(50), uint64(80)]; // After 50 weeks, 0.8% per week
        schedule[4] = [uint64(37), uint64(90)]; // After 37 weeks, 0.9% per week
        schedule[5] = [uint64(24), uint64(100)]; // After 24 weeks, 1% per week

        return schedule;
    }

    /*//////////////////////////////////////////////////////////////
                            8. ADMIN VOTING
    //////////////////////////////////////////////////////////////*/

    /// @notice minimum percentage of the total supply required to create a proposal
    uint256 public constant MIN_CREATE_PROPOSAL_PCT = 10; // 0.1%

    /// @notice minimum percentage of the total supply required for a proposal to pass
    uint256 public constant PASSING_PCT = 300; // 3%
}
