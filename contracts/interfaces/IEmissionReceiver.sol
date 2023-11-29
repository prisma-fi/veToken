// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IEmissionReceiver {
    function notifyRegisteredId(uint256[] memory assignedIds) external returns (bool);

    function vaultClaimReward(address claimant, address receiver) external returns (uint256);

    function claimableReward(address account) external view returns (uint256);
}
