// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../interfaces/ICoreOwner.sol";

/**
    @title System Start Time
    @author Prisma Finance
    @dev Provides a unified `START_TIME` and `getEpoch`
 */
contract SystemStart {
    uint256 immutable START_TIME;
    uint256 immutable EPOCH_LENGTH;

    constructor(address core) {
        START_TIME = ICoreOwner(core).START_TIME();
        EPOCH_LENGTH = ICoreOwner(core).EPOCH_LENGTH();
    }

    function getEpoch() internal view returns (uint256 epoch) {
        return (block.timestamp - START_TIME) / EPOCH_LENGTH;
    }
}
