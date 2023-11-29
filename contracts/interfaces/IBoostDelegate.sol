// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
    @title Prisma Boost Delegate Interface
    @notice When enabling boost delegation via `Vault.setBoostDelegationParams`,
            you may optionally set a `callback` contract. If set, it should adhere
            to the following interface.
 */
interface IBoostDelegate {
    /**
        @notice Get the current fee percent charged to use this boost delegate
        @dev Optional. Only called if the feePct is set to `type(uint16).max` when
             enabling delegation.
        @param claimant Address that will perform the claim
        @param amount Amount to be claimed (before applying boost or fee)
        @param previousAmount Previous amount claimed this epoch by this contract
        @param totalEpochEmissions Total emissions released this epoch
        @return feePct Fee % charged for claims that use this contracts' delegated boost.
                      Given as a whole number out of 10000. If a claim would be rejected,
                      the preferred return value is `type(uint256).max`.
     */
    function getFeePct(
        address claimant,
        address receiver,
        uint amount,
        uint previousAmount,
        uint totalEpochEmissions
    ) external view returns (uint256 feePct);

    /**
        @notice Callback function for boost delegators
        @dev MUST BE INCLUDED. Called after each successful claim which used
             this contract's delegated boost.
        @param claimant Address that performed the claim
        @param receiver Address receiving the claimed rewards
        @param boostDelegate Address that was delegated to
        @param amount Amount that claimed (before applying boost or fee)
        @param adjustedAmount Actual amount received by `claimant`
        @param fee Fee amount paid by `claimant`
        @param previousAmount Previous amount claimed this epoch by this contract
        @param totalEpochEmissions Total emissions released this epoch
     */
    function delegatedBoostCallback(
        address claimant,
        address receiver,
        address boostDelegate,
        uint amount,
        uint adjustedAmount,
        uint fee,
        uint previousAmount,
        uint totalEpochEmissions
    ) external returns (bool success);
}
