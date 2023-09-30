from brownie import TokenLocker, IncentiveVoting, AdminVoting, accounts


# you can also optionally modify the constants in `BaseConfig` prior to deployment
LOCK_TOKEN = "0x0000000000000000000000000000000000000000"
FEE_RECEIVER = "0x0000000000000000000000000000000000000000"
GUARDIAN = "0x0000000000000000000000000000000000000000"
LOCK_TO_TOKEN_RATIO = 10**18
MIN_CREATE_PROPOSAL_PCT = 0.1
PASSING_PCT = 30


def main():
    deployer = accounts[0]

    nonce = deployer.nonce
    voter = deployer.get_deployment_address(nonce + 1)

    locker = TokenLocker.deploy(LOCK_TOKEN, voter, FEE_RECEIVER, LOCK_TO_TOKEN_RATIO, {'from': deployer})
    voter = IncentiveVoting.deploy(locker, {'from': deployer})

    create_pct = voter.MAX_PCT() * MIN_CREATE_PROPOSAL_PCT // 100
    pass_pct = voter.MAX_PCT() * PASSING_PCT // 100
    admin = AdminVoting.deploy(locker, GUARDIAN, create_pct, pass_pct, {'from': deployer})

    return locker, voter, admin
