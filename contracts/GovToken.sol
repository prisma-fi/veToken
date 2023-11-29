// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
    @title Valueless Governance Token
    @author Prisma Finance
    @notice Minimal version of governance token used in Prisma's veToken implementation
 */
contract GovToken is ERC20 {
    address public immutable tokenLocker;

    constructor(
        string memory name,
        string memory symbol,
        address vault,
        address locker,
        uint256 supply
    ) ERC20(name, symbol) {
        tokenLocker = locker;

        // the entire total supply is minted to the Vault at the time of deployment
        // minting tokens after deployment could have weird side effectsm, we do not recommend
        _mint(vault, supply);
    }

    function transferToLocker(address sender, uint256 amount) external returns (bool) {
        require(msg.sender == tokenLocker, "Not locker");
        _transfer(sender, tokenLocker, amount);
        return true;
    }
}
