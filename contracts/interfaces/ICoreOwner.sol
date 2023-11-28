// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface ICoreOwner {
    function owner() external view returns (address);

    function START_TIME() external view returns (uint256);

    function EPOCH_LENGTH() external view returns (uint256);

    function feeReceiver() external view returns (address);
}
