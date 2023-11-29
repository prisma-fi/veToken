// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
    @dev Minimal interface required for `EmissionSchedule` implementation
 */
interface IEmissionSchedule {
    function getReceiverEpochEmissions(
        uint256 id,
        uint256 epoch,
        uint256 totalEpochEmissions
    ) external returns (uint256);

    function getTotalEpochEmissions(
        uint256 epoch,
        uint256 unallocatedTotal
    ) external returns (uint256 amount, uint256 lock);

    function getExpectedNextEpochEmissions(
        uint256 epoch,
        uint256 unallocatedTotal
    ) external view returns (uint256 amount);
}
