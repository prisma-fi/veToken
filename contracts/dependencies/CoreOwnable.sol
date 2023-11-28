// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../interfaces/ICoreOwner.sol";

/**
    @title Core Ownable
    @author Prisma Finance
    @notice Contracts inheriting `CoreOwnable` have the same owner as `CoreOwner`.
            The ownership cannot be independently modified or renounced.
 */
abstract contract CoreOwnable {
    ICoreOwner public immutable CORE_OWNER;

    constructor(address _core) {
        CORE_OWNER = ICoreOwner(_core);
    }

    modifier onlyOwner() {
        require(msg.sender == address(CORE_OWNER.owner()), "Only owner");
        _;
    }

    function owner() public view returns (address) {
        return address(CORE_OWNER.owner());
    }
}
