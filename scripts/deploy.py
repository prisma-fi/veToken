from brownie import (
    CoreOwner,
    TokenLocker,
    IncentiveVoting,
    AdminVoting,
    GovToken,
    Vault,
    EmissionSchedule,
    BoostCalculator,
    accounts,
)


# you can also optionally modify the constants in `BaseConfig` prior to deployment
FEE_RECEIVER = "0x0000000000000000000000000000000000000000"
GUARDIAN = "0x0000000000000000000000000000000000000000"
LOCK_TO_TOKEN_RATIO = 10**18
MIN_CREATE_PROPOSAL_PCT = 0.1
PASSING_PCT = 30

TOKEN_NAME = "Valueless Governance Token"
TOKEN_SYMBOL = "VGT"
TOKEN_TOTAL_SUPPLY = 100_000_000 * 10**18

#  Number of seconds within one "epoch" (a locking / voting period).
# Contracts permanently break from array out-of-bounds after 65535 epochs,
# so the duration of one epoch must be long enough that this issue will
# not occur until the distant future.
EPOCH_LENGTH = 86400 * 7

# Seconds to subtract when calculating `START_TIME`. With an epoch length
# of one week, an offset of 3.5 days means that a new epoch begins every
# Sunday at 12:00:00 UTC.
START_OFFSET = 86400 * 3.5


# list of `(address, amount)` for approvals to transfer tokens out of the vault
# used for allocating tokens outside of normal emissions, e.g airdrops, vests, team treasury
# IMPORTANT: you must allocate some balance to the deployer that can be locked in the first
# epoch and used to vote for the initial round of emissions
ALLOWANCES = []

# emissions are initially locked for this many epochs upon claim
INITIAL_LOCK_DURATION = 26

# are penalty withdrawals of locked positions enabled initially?
PENALTY_WITHDRAWAL_ENABLED = True

# each time this many epochs pass, the lock-on-claim duration decreases by 1 epoch
LOCK_EPOCHS_DECAY_RATE = 2

# list of initial fixed per-epoch emissions, once this many epochs have passed
# the `EmissionSchedule` takes effect
FIXED_INITIAL_AMOUNTS = [1_000_000 * 10**18, 1_000_000 * 10**18]

# initial percent of the unallocated supply to be given as per-epoch emissions,
# once the fixed initial amounts are finished
INITIAL_PER_EPOCH_PCT = 1.00

# list of `(epoch, percent)` for scheduled changes to the percent of the unallocated
# supply to be used as per-epoch emissions
EPOCH_PCT_SCHEDULE = [(13, 0.9), (26, 0.8), (39, 0.7), (52, 0.5)]

# number of initial epochs where all claims recieve maximum boost
# should be >=2, because in the first epoch there are no emissions and in the second
# epoch users have not have a chance to lock yet
BOOST_GRACE_EPOCHS = 2

# max boost multiplier
MAX_BOOST_MULTIPLIER = 2

# percentage of the total epoch emissions that an account can claim with max
# boost, expressed as a percent relative to the account's percent of the total
# lock weight. For example, if an account has 5% of the lock weight and the
# max boostable percent is 150, the account can claim 7.5% (5% * 150%) of the
# epoch's emissions at a max boost.
MAX_BOOSTABLE_PCT = 100

# percentage of the total epoch emissions that an account can claim with decaying boost
DECAY_BOOST_PCT = 100


def main():
    deployer = accounts[0]

    nonce = deployer.nonce

    core = deployer.get_deployment_address(nonce)
    token = deployer.get_deployment_address(nonce + 1)
    locker = deployer.get_deployment_address(nonce + 2)
    voter = deployer.get_deployment_address(nonce + 3)
    vault = deployer.get_deployment_address(nonce + 4)
    boost = deployer.get_deployment_address(nonce + 5)
    emission_schedule = deployer.get_deployment_address(nonce + 6)
    admin = deployer.get_deployment_address(nonce + 7)

    core = CoreOwner.deploy(admin, FEE_RECEIVER, 86400 * 7, 86400 * 4, {"from": deployer})
    token = GovToken.deploy(
        TOKEN_NAME, TOKEN_SYMBOL, vault, locker, TOKEN_TOTAL_SUPPLY, {"from": deployer}
    )
    locker = TokenLocker.deploy(
        core, token, voter, LOCK_TO_TOKEN_RATIO, PENALTY_WITHDRAWAL_ENABLED, {"from": deployer}
    )
    voter = IncentiveVoting.deploy(core, locker, vault, {"from": deployer})
    vault = Vault.deploy(
        core,
        token,
        locker,
        voter,
        emission_schedule,
        boost,
        INITIAL_LOCK_DURATION,
        FIXED_INITIAL_AMOUNTS,
        ALLOWANCES,
        {"from": deployer},
    )
    boost = BoostCalculator.deploy(
        core,
        locker,
        BOOST_GRACE_EPOCHS,
        MAX_BOOST_MULTIPLIER,
        MAX_BOOSTABLE_PCT,
        DECAY_BOOST_PCT,
        {"from": deployer},
    )

    max_pct = voter.MAX_PCT()
    pct_schedule = [(i[0], max_pct * i[1] // 100) for i in EPOCH_PCT_SCHEDULE[::-1]]
    emission_schedule = EmissionSchedule.deploy(
        core,
        voter,
        vault,
        INITIAL_LOCK_DURATION,
        LOCK_EPOCHS_DECAY_RATE,
        max_pct * INITIAL_PER_EPOCH_PCT // 100,
        pct_schedule,
        {"from": deployer},
    )

    create_pct = max_pct * MIN_CREATE_PROPOSAL_PCT // 100
    pass_pct = max_pct * PASSING_PCT // 100
    admin = AdminVoting.deploy(core, locker, GUARDIAN, create_pct, pass_pct, {"from": deployer})

    return locker, voter, admin
