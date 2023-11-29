// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./dependencies/SystemStart.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IEmissionReceiver.sol";

/**
    @title Emission Receiver Abstract Base
    @author Prisma Finance
    @notice Outlines the minimal functionality required to implement a receiver.
            This contract is designed to be inherited or used a starting point
            in writing a new implementation.

            See the Prisma Finance repo for examples of how you can implement
            receivers: https://github.com/prisma-fi/prisma-contracts
 */
abstract contract EmissionReceiverBase is IEmissionReceiver, SystemStart {
    IVault public immutable vault;

    uint256 private emissionUpdateEpoch;
    // it is suggested to expose the receiver ID, however it is not required
    // by any other smart contracts within the system
    uint256 public receiverId;

    constructor(address _core, IVault _vault) SystemStart(_core) {
        vault = _vault;
    }

    /**
        @dev Called via `Vault` to notify the receiver that it is eligible for emissions
              * The assigned ID will never be zero. You can trust that when the
                locally stored ID is zero, the receiver has not been registered.
              * This implementation only supports 1 ID, however it is possible to
                design a receiver that uses multiple IDs.
     */
    function notifyRegisteredId(uint256[] memory assignedIds) external returns (bool) {
        require(msg.sender == address(vault), "Only vault");
        require(receiverId == 0, "Already registered");
        require(assignedIds.length == 1, "Incorrect ID count");
        receiverId = assignedIds[0];

        return true;
    }

    function claimableReward(address account) external view returns (uint256) {
        return _claimableReward(account);
    }

    /**
        @dev Claim rewards directly from this contract. Receivers do not directly
             hold reward tokens, they instead call `vault.transferAllocatedTokens`
             where boost is applied and then tokens are transferred to the receiver.
     */
    function claimReward(address receiver) external returns (uint256) {
        uint256 amount = _claimReward(msg.sender, receiver);
        vault.transferAllocatedTokens(msg.sender, receiver, amount);

        //emit RewardClaimed(receiver);
        return amount;
    }

    /**
        @dev A batch reward claim initiated from `Vault`. Logic here should be identical
             to `claimReward`, excluding the call to `vault.transferAllocatedTokens`.
     */
    function vaultClaimReward(address claimant, address receiver) external returns (uint256) {
        require(msg.sender == address(vault), "Only vault");
        uint256 amount = _claimReward(claimant, receiver);

        //emit RewardClaimed(receiver, 0, amounts[1]);
        return amount;
    }

    /**
        @dev Internal logic to claim available rewards for `claimant`
              * Only called from `claimReward` or `vaultClaimReward`
              * The claimable `govToken` amount is returned. The receiver does not
                directly handle transfer of the tokens. Local storage must be updated
                assuming a successful claim.
              * Any other claimable reward tokens must be transferred to `receiver`
     */
    function _claimReward(address claimant, address receiver) internal virtual returns (uint256 amount);

    /**
        @dev Internal view method for calculating claimable rewards for `claimant`
              * `_claimReward` should implement a call to this function to ensure
                consistency between the view and the actual claim
     */
    function _claimableReward(address claimant) internal view virtual returns (uint256 amount);

    /**
        @dev Once per epoch, call the vault to receive the total amount
             of `govToken` allocated to the receiver for that epoch
              * Should be triggered within a normal user action, to ensure
                ongoing reward distribution happens without admin intervention
              * Can optionally be exposed via an extrnal `fetchRewards` function
     */
    function _fetchWeeklyEmissions() internal returns (uint256 amount) {
        uint256 id = receiverId;
        // do not try to allocate new emissions prior to the receiver being registered
        if (id != 0) {
            uint256 epoch = getEpoch();
            if (epoch > emissionUpdateEpoch) {
                emissionUpdateEpoch = epoch;
                return vault.allocateNewEmissions(id);
            }
        }
        return 0;
    }
}
