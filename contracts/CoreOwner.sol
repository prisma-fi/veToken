// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

/**
    @title Core Owner
    @author Prisma Finance
    @notice Single source of truth for system-wide values and contract ownership.

            Ownership of this contract should be the DAO via `AdminVoting`.
            Other ownable contracts inherit their ownership from this contract
            using `CoreOwnable`.
 */
contract CoreOwner {
    address public owner;
    address public pendingOwner;
    uint256 public ownershipTransferDeadline;

    address public feeReceiver;

    // We enforce a three day delay between committing and accepting
    // an ownership change, as a sanity check on a proposed new owner
    // and to give users time to react in case the act is malicious.
    uint256 public constant OWNERSHIP_TRANSFER_DELAY = 86400 * 3;

    // System-wide start time. Contracts that require this must inherit `SystemStart`.
    uint256 public immutable START_TIME;

    // Number of seconds within one "epoch" (a locking / voting period).
    // Contracts permanently break from array out-of-bounds after 65535 epochs,
    // so the duration of one epoch must be long enough that this issue will
    // not occur until the distant future.
    uint256 public immutable EPOCH_LENGTH;

    event NewOwnerCommitted(address owner, address pendingOwner, uint256 deadline);

    event NewOwnerAccepted(address oldOwner, address owner);

    event NewOwnerRevoked(address owner, address revokedOwner);

    event FeeReceiverSet(address feeReceiver);

    /**
        @param epochLength Number of seconds within one epoch
        @param startOffset Seconds to subtract when calculating `START_TIME`. With
                           an epoch length of one week and 0 offset, the new epoch
                           starts Thursday at 00:00:00 UTC. With an offset of 302400
                           (3 days, 12 hours) the epoch starts Sunday at 12:00:00 UTC.
     */
    constructor(address _owner, address _feeReceiver, uint256 epochLength, uint256 startOffset) {
        owner = _owner;

        uint256 start = (block.timestamp / epochLength) * epochLength - startOffset;
        if (start + epochLength < block.timestamp) start += epochLength;
        START_TIME = start;
        EPOCH_LENGTH = epochLength;

        feeReceiver = _feeReceiver;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /**
     * @notice Set the receiver of all fees across the protocol
     * @param _feeReceiver Address of the fee's recipient
     */
    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = _feeReceiver;
        emit FeeReceiverSet(_feeReceiver);
    }

    function commitTransferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        ownershipTransferDeadline = block.timestamp + OWNERSHIP_TRANSFER_DELAY;

        emit NewOwnerCommitted(msg.sender, newOwner, block.timestamp + OWNERSHIP_TRANSFER_DELAY);
    }

    function acceptTransferOwnership() external {
        require(msg.sender == pendingOwner, "Only new owner");
        require(block.timestamp >= ownershipTransferDeadline, "Deadline not passed");

        emit NewOwnerAccepted(owner, msg.sender);

        owner = pendingOwner;
        pendingOwner = address(0);
        ownershipTransferDeadline = 0;
    }

    function revokeTransferOwnership() external onlyOwner {
        emit NewOwnerRevoked(msg.sender, pendingOwner);

        pendingOwner = address(0);
        ownershipTransferDeadline = 0;
    }
}
