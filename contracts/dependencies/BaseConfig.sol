// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

abstract contract BaseConfig {
    // Number of seconds within one "epoch" (a locking / voting period). Contracts permanently
    // break from array out-of-bounds after 65535 epochs, so the duration of one epoch must be
    // long enough that this issue will not occur until the distant future.
    uint256 public constant EPOCH_LENGTH = 1 weeks;

    // Maximum number of epochs that tokens may be locked for. Also determines the maximum number
    // of active locks that a single account may open. Weight is calculated as:
    // `[balance] * [epochs to unlock]`. Weights are stored as `uint40` and balances as `uint32`,
    // so max lock epochs must be less than 256 or the system will break due to overflow.
    uint256 public constant MAX_LOCK_EPOCHS = 52;

    // Whole number representing 100% in the contracts. Must be less than 65535.
    uint256 public constant MAX_PCT = 10000;

    // Number of seconds to subtract when calculating `START_TIME`. With an epoch length of
    // one week, an offset of 4 days means that a new epoch begins every Sunday at 00:00:00 UTC.
    uint256 private constant START_OFFSET = 4 days;

    uint256 public immutable START_TIME;

    constructor() {
        require(MAX_LOCK_EPOCHS < 256, "BaseConfig: MAX_LOCK_EPOCHS >= 256");
        require(MAX_PCT < 65535, "BaseConfig: MAX_PCT >= 65535");
        require(EPOCH_LENGTH * 65535 >= 52 weeks * 100, "BaseConfig: EPOCH_LENGTH too small");
        require(START_OFFSET < EPOCH_LENGTH, "BaseConfig: START_OFFSET >= EPOCH_LENGTH");
        START_TIME = (block.timestamp / EPOCH_LENGTH) * EPOCH_LENGTH - START_OFFSET;
    }

    function getEpoch() public view returns (uint256 epoch) {
        return (block.timestamp - START_TIME) / 1 weeks;
    }
}
