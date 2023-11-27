// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

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
}
