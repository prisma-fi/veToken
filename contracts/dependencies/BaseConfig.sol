// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

abstract contract BaseConfig {
    // Maximum number of epochs that tokens may be locked for. Also determines the maximum number
    // of active locks that a single account may open. Weight is calculated as:
    // `[balance] * [epochs to unlock]`. Weights are stored as `uint40` and balances as `uint32`,
    // so max lock epochs must be less than 256 or the system will break due to overflow.
    uint256 public constant MAX_LOCK_EPOCHS = 52;

    // Whole number representing 100% in the system. Changing this could break things weirdly.
    uint256 public constant MAX_PCT = 10000;

    constructor() {
        require(MAX_LOCK_EPOCHS < 256, "BaseConfig: MAX_LOCK_EPOCHS >= 256");
    }
}
