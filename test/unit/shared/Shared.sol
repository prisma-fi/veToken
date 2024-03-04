// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// DAO contracts
import {Vault} from "../../../contracts/Vault.sol";
import {GovToken} from "../../../contracts/GovToken.sol";
import {CoreOwner} from "../../../contracts/CoreOwner.sol";
import {AdminVoting} from "../../../contracts/AdminVoting.sol";
import {TokenLocker} from "../../../contracts/TokenLocker.sol";
import {BoostCalculator} from "../../../contracts/BoostCalculator.sol";
import {IncentiveVoting} from "../../../contracts/IncentiveVoting.sol";
import {EmissionSchedule} from "../../../contracts/EmissionSchedule.sol";

import {IGovToken} from "../../../contracts/interfaces/IGovToken.sol";
import {ITokenLocker} from "../../../contracts/interfaces/ITokenLocker.sol";
import {IBoostCalculator} from "../../../contracts/interfaces/IBoostCalculator.sol";
import {IIncentiveVoting} from "../../../contracts/interfaces/IIncentiveVoting.sol";
import {IEmissionSchedule} from "../../../contracts/interfaces/IEmissionSchedule.sol";

// Test imports
import {Base_Test_} from "../../Base.sol";
import {Environment as ENV} from "../../utils/Environment.sol";
import {DeploymentParams as DP} from "../../../scripts/DeploymentParams.sol";

contract Unit_Shared_Test_ is Base_Test_ {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct DeploymentInfos {
        Predicted vault;
        Predicted govToken;
        Predicted coreOwner;
        Predicted adminVoting;
        Predicted tokenLocker;
        Predicted boostCalculator;
        Predicted incentiveVoting;
        Predicted emissionSchedule;
    }

    struct Predicted {
        address predicted;
        bytes1 nonce;
    }

    /*//////////////////////////////////////////////////////////////
                               VARIABLES
    //////////////////////////////////////////////////////////////*/

    DeploymentInfos public DI;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual override {
        super.setUp();

        // 1. Set up realistic environment test
        _setUpRealisticEnvironment();

        // 2. Generate user addresses
        _generateAddresses();

        // 3. Deploy contracts
        _deployContracts();

        // 4. Check predicted and deployed address match
        _checkPredictedAndDeployedAddress();
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setUpRealisticEnvironment() internal {
        vm.warp(ENV.TIMESTAMP); // Setup realistic environment Timestamp
        vm.roll(ENV.BLOCKNUMBER); // Setup realistic environment Blocknumber
    }

    function _generateAddresses() internal {
        alice = makeAddr("alice");
        manager = makeAddr("manager");
        deployer = makeAddr("deployer");
        multisig = makeAddr("multisig");
        guardian = makeAddr("guardian");
        feeReceiver = makeAddr("feeReceiver");
    }

    function _deployContracts() internal {
        // 1. Set nonces
        _setNonces();

        // 2. Predict addresses
        _predictAddresses();

        vm.startPrank(deployer);
        // 3. Deploy contracts

        // 1. Core Owner
        vm.setNonce(deployer, uint8(DI.coreOwner.nonce));
        coreOwner = new CoreOwner(multisig, feeReceiver, DP.EPOCH_LENGTH, DP.START_OFFSET);

        // 2.GovToken
        vm.setNonce(deployer, uint8(DI.govToken.nonce));
        govToken = new GovToken(DP.NAME, DP.SYMBOL, DI.vault.predicted, DI.tokenLocker.predicted, DP.SUPPLY);

        // 3. Token Locker
        vm.setNonce(deployer, uint8(DI.tokenLocker.nonce));
        tokenLocker = new TokenLocker(
            DI.coreOwner.predicted,
            IGovToken(DI.govToken.predicted),
            IIncentiveVoting(DI.incentiveVoting.predicted),
            DP.LOCK_TO_TOKEN_RATIO,
            DP.PENALTY_WITHDRAWAL_ENABLED
        );

        // 4. Incentive Voting
        vm.setNonce(deployer, uint8(DI.incentiveVoting.nonce));
        incentiveVoting =
            new IncentiveVoting(DI.coreOwner.predicted, ITokenLocker(DI.tokenLocker.predicted), DI.vault.predicted);

        // 5. Vault
        vm.setNonce(deployer, uint8(DI.vault.nonce));
        vault = new Vault(
            DI.coreOwner.predicted,
            IGovToken(DI.govToken.predicted),
            ITokenLocker(DI.tokenLocker.predicted),
            IIncentiveVoting(DI.incentiveVoting.predicted),
            IEmissionSchedule(DI.emissionSchedule.predicted),
            IBoostCalculator(DI.boostCalculator.predicted),
            DP.INITIAL_LOCK_DURATION,
            DP.fixedInitialAmounts(),
            DP.initialAllowances(),
            DP.initialReceivers()
        );

        // 6. Boost Calculator
        vm.setNonce(deployer, uint8(DI.boostCalculator.nonce));
        boostCalculator = new BoostCalculator(
            DI.coreOwner.predicted,
            ITokenLocker(DI.tokenLocker.predicted),
            DP.BOOST_GRACE_EPOCHS,
            DP.MAX_BOOST_MULTIPLIER,
            DP.MAX_BOOSTABLE_PCT,
            DP.DECAY_BOOST_PCT
        );

        // 7. Emission Schedule
        vm.setNonce(deployer, uint8(DI.emissionSchedule.nonce));
        emissionSchedule = new EmissionSchedule(
            DI.coreOwner.predicted,
            IIncentiveVoting(DI.incentiveVoting.predicted),
            DI.vault.predicted,
            DP.INITIAL_LOCK_DURATION,
            DP.LOCK_EPOCHS_DECAY_RATE,
            DP.INITIAL_PER_EPOCH_PCT,
            DP.scheduleWeeklyPct()
        );

        // 8. Admin Voting
        vm.setNonce(deployer, uint8(DI.adminVoting.nonce));
        adminVoting = new AdminVoting(
            DI.coreOwner.predicted,
            ITokenLocker(DI.tokenLocker.predicted),
            guardian,
            DP.MIN_CREATE_PROPOSAL_PCT,
            DP.PASSING_PCT
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setNonces() internal {
        DI.coreOwner.nonce = bytes1(0x01); // 1. Core Owner
        DI.govToken.nonce = bytes1(0x02); // 2. GovToken
        DI.tokenLocker.nonce = bytes1(0x03); // 3. Token Locker
        DI.incentiveVoting.nonce = bytes1(0x04); // 4. Incentive Voting
        DI.vault.nonce = bytes1(0x05); // 5. Vault
        DI.boostCalculator.nonce = bytes1(0x06); // 6. Boost Calculator
        DI.emissionSchedule.nonce = bytes1(0x07); // 7. Emission Schedule
        DI.adminVoting.nonce = bytes1(0x08); // 8. Admin Voting
    }

    function _predictAddresses() internal {
        DI.coreOwner.predicted = _computeAddress(deployer, DI.coreOwner.nonce); // 1. Core Owner
        DI.govToken.predicted = _computeAddress(deployer, DI.govToken.nonce); // 2. GovToken
        DI.tokenLocker.predicted = _computeAddress(deployer, DI.tokenLocker.nonce); // 3. Token Locker
        DI.incentiveVoting.predicted = _computeAddress(deployer, DI.incentiveVoting.nonce); // 4. Incentive Voting
        DI.vault.predicted = _computeAddress(deployer, DI.vault.nonce); // 5. Vault
        DI.boostCalculator.predicted = _computeAddress(deployer, DI.boostCalculator.nonce); // 6. Boost Calculator
        DI.emissionSchedule.predicted = _computeAddress(deployer, DI.emissionSchedule.nonce); // 7. Emission Schedule
        DI.adminVoting.predicted = _computeAddress(deployer, DI.adminVoting.nonce); // 8. Admin Voting
    }

    function _computeAddress(address _deployer, bytes1 _nonce) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), _deployer, _nonce)))));
    }

    function _checkPredictedAndDeployedAddress() internal view {
        require(address(coreOwner) == DI.coreOwner.predicted, "CoreOwner address mismatch");
        require(address(govToken) == DI.govToken.predicted, "GovToken address mismatch");
        require(address(tokenLocker) == DI.tokenLocker.predicted, "TokenLocker address mismatch");
        require(address(incentiveVoting) == DI.incentiveVoting.predicted, "IncentiveVoting address mismatch");
        require(address(vault) == DI.vault.predicted, "Vault address mismatch");
        require(address(boostCalculator) == DI.boostCalculator.predicted, "BoostCalculator address mismatch");
        require(address(emissionSchedule) == DI.emissionSchedule.predicted, "EmissionSchedule address mismatch");
        require(address(adminVoting) == DI.adminVoting.predicted, "AdminVoting address mismatch");
    }

    function test() public {}
}
