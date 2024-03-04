// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// External imports
import {Test} from "forge-std/Test.sol";

// DAO contracts
import {Vault} from "../contracts/Vault.sol";
import {GovToken} from "../contracts/GovToken.sol";
import {CoreOwner} from "../contracts/CoreOwner.sol";
import {AdminVoting} from "../contracts/AdminVoting.sol";
import {TokenLocker} from "../contracts/TokenLocker.sol";
import {BoostCalculator} from "../contracts/BoostCalculator.sol";
import {IncentiveVoting} from "../contracts/IncentiveVoting.sol";
import {EmissionSchedule} from "../contracts/EmissionSchedule.sol";

abstract contract Base_Test_ is Test {
    Vault public vault;
    GovToken public govToken;
    CoreOwner public coreOwner;
    AdminVoting public adminVoting;
    TokenLocker public tokenLocker;
    BoostCalculator public boostCalculator;
    IncentiveVoting public incentiveVoting;
    EmissionSchedule public emissionSchedule;

    address public alice;
    address public manager;
    address public deployer;
    address public multisig;
    address public guardian;
    address public feeReceiver;

    function setUp() public virtual {}
}
