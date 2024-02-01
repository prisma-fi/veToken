// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
    @title Fee Claim Callback
    @notice Allows boost fee claimants to trigger a callback. 
            Callback should adhere to the following interface.
 */
interface IFeeClaimCallback {

    /**
        @notice Callback function for boost fee claimants
        @dev Optional. Only called if a callback is supplied during fee claim.
        @param claimant Address that performed the claim
        @param receiver Address receiving the claimed amount
        @param amount Amount that claimed
     */
    function feeClaimCallback(
        address claimant,
        address receiver,
        uint amount
    ) external returns (bool success);
}
