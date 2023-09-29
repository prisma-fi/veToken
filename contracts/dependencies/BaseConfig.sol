// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

contract BaseConfig {
    // The number of seconds within one "epoch" (locking / voting period).
    uint256 public constant EPOCH_LENGTH = 1 weeks;

    // The maximum number of epochs that tokens may be locked for. Also determines the maximum
    // number of active locks that a single account may open. Weight is calculated as:
    // `[balance] * [epochs to unlock]`. Weights are stored as `uint40` and balances as `uint32`,
    // so max lock epochs must be less than 256 or the system will break due to overflow.
    uint256 public constant MAX_LOCK_EPOCHS = 52;

    // The total number of epochs. Contracts will break permanently after this
    // many epochs have passed. We do not recommend adjusting this value.
    uint256 public constant EPOCHS = 65535;

    // Whole number representing 100% in the contracts. Must be lower than `EPOCHS`.
    uint256 public constant MAX_PCT = 10000;

    uint256 public immutable START_TIME;

    constructor() {
        require(MAX_LOCK_EPOCHS < 256, "BaseConfig: MAX_LOCK_EPOCHS >= 256");
        require(MAX_PCT < EPOCHS, "BaseConfig: MAX_PCT >= EPOCHS");
        require(EPOCH_LENGTH * EPOCHS >= 52 weeks * 50, "BaseConfig: EPOCH_LENGTH * EPOCHS < 50 years");
        START_TIME = (block.timestamp / EPOCH_LENGTH) * EPOCH_LENGTH;
    }

    function getEpoch() public view returns (uint256 epoch) {
        return (block.timestamp - START_TIME) / 1 weeks;
    }
}
