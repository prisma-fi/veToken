// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

/**
    @title Prisma System Start Time
    @dev Provides a unified `startTime` and `getWeek`, used for emissions.
 */
contract SystemStart {
    uint256 immutable startTime;

    constructor() {
        startTime = (block.timestamp / 1 weeks) * 1 weeks; // TODO
    }

    function getWeek() public view returns (uint256 week) {
        return (block.timestamp - startTime) / 1 weeks;
    }
}
