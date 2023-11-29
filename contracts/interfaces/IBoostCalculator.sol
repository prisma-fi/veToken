// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
    @dev Minimal interface required for `BoostCalculator` implementation
 */
interface IBoostCalculator {
    function getBoostedAmountWrite(
        address account,
        uint256 amount,
        uint256 previousAmount,
        uint256 totalEpochEmissions
    ) external returns (uint256 adjustedAmount);

    function MAX_BOOST_GRACE_EPOCHS() external view returns (uint256);

    function getBoostedAmount(
        address account,
        uint256 amount,
        uint256 previousAmount,
        uint256 totalEpochEmissions
    ) external view returns (uint256 adjustedAmount);

    function getAccountBoostData(
        address claimant,
        uint256 previousAmount,
        uint256 totalEpochEmissions
    ) external view returns (uint256 currentBoost, uint256 maxBoosted, uint256 boosted);
}
