// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/Address.sol";
import "./dependencies/DelegatedOps.sol";
import "./dependencies/BaseConfig.sol";
import "./interfaces/ITokenLocker.sol";

/**
    @title DAO Admin Voter
    @author Prisma Finance
    @notice Ownership contract that maybe be used for some or all protocol contracts.
            Allows executing arbitrary function calls only after a required percentage
            of token lockers have signalled in favor of performing the action.
 */
contract AdminVoting is DelegatedOps, BaseConfig {
    using Address for address;

    uint256 public constant BOOTSTRAP_PERIOD = 30 days;
    uint256 public constant VOTING_PERIOD = 1 weeks;
    uint256 public constant MIN_TIME_TO_EXECUTION = 1 days;
    uint256 public constant MAX_TIME_TO_EXECUTION = 3 weeks;
    uint256 public constant MIN_TIME_BETWEEN_PROPOSALS = 1 weeks;
    uint256 public constant SET_GUARDIAN_PASSING_PCT = (MAX_PCT * 51) / 100;

    ITokenLocker public immutable tokenLocker;
    address public guardian;

    // percent of total weight required to create a new proposal
    uint256 public minCreateProposalPct;
    // percent of total weight that must vote for a proposal before it can be executed
    uint256 public passingPct;

    struct Proposal {
        uint16 epoch; // epoch which vote weights are based upon
        uint32 createdAt; // timestamp when the proposal was created
        uint32 canExecuteAfter; // earliest timestamp when proposal can be executed (0 if not passed)
        uint40 currentWeight; //  amount of weight currently voting in favor
        uint40 requiredWeight; // amount of weight required for the proposal to be executed
        bool processed; // set to true once the proposal is processed
    }

    struct Action {
        address target;
        bytes data;
    }

    Proposal[] proposalData;
    mapping(uint256 id => Action[]) proposalPayloads;

    mapping(address account => mapping(uint256 id => uint256 weight)) public accountVoteWeights;
    mapping(address account => uint256 timestamp) public latestProposalTimestamp;

    event ProposalCreated(
        address indexed account,
        uint256 proposalId,
        Action[] payload,
        uint256 epoch,
        uint256 requiredWeight
    );
    event ProposalHasMetQuorum(uint256 id, uint256 canExecuteAfter);
    event ProposalExecuted(uint256 proposalId);
    event ProposalCancelled(uint256 proposalId);
    event VoteCast(
        address indexed account,
        uint256 indexed id,
        uint256 weight,
        uint256 proposalCurrentWeight,
        bool hasPassed
    );
    event ProposalCreationMinPctSet(uint256 weight);
    event ProposalPassingPctSet(uint256 pct);
    event GuardianSet(address guardian);

    constructor(ITokenLocker _tokenLocker, address _guardian, uint256 _minCreateProposalPct, uint256 _passingPct) {
        tokenLocker = _tokenLocker;
        guardian = _guardian;

        minCreateProposalPct = _minCreateProposalPct;
        passingPct = _passingPct;

        emit GuardianSet(_guardian);
    }

    /**
        @notice The total number of votes created
     */
    function getProposalCount() external view returns (uint256) {
        return proposalData.length;
    }

    function minCreateProposalWeight() public view returns (uint256) {
        uint256 epoch = getEpoch();
        if (epoch == 0) return 0;
        epoch -= 1;

        uint256 totalWeight = tokenLocker.getTotalWeightAt(epoch);
        return (totalWeight * minCreateProposalPct) / MAX_PCT;
    }

    /**
        @notice Gets information on a specific proposal
     */
    function getProposalData(
        uint256 id
    )
        external
        view
        returns (
            uint256 epoch,
            uint256 createdAt,
            uint256 currentWeight,
            uint256 requiredWeight,
            uint256 canExecuteAfter,
            bool executed,
            bool canExecute,
            Action[] memory payload
        )
    {
        Proposal memory proposal = proposalData[id];
        payload = proposalPayloads[id];
        canExecute = (!proposal.processed &&
            proposal.currentWeight >= proposal.requiredWeight &&
            proposal.canExecuteAfter < block.timestamp &&
            proposal.canExecuteAfter + MAX_TIME_TO_EXECUTION > block.timestamp);

        return (
            proposal.epoch,
            proposal.createdAt,
            proposal.currentWeight,
            proposal.requiredWeight,
            proposal.canExecuteAfter,
            proposal.processed,
            canExecute,
            payload
        );
    }

    /**
        @notice Create a new proposal
        @param payload Tuple of [(target address, calldata), ... ] to be
                       executed if the proposal is passed.
     */
    function createNewProposal(address account, Action[] calldata payload) external callerOrDelegated(account) {
        require(payload.length > 0, "Empty payload");

        require(
            latestProposalTimestamp[account] + MIN_TIME_BETWEEN_PROPOSALS < block.timestamp,
            "MIN_TIME_BETWEEN_PROPOSALS"
        );

        // epoch is set at -1 to the active epoch so that weights are finalized
        uint256 epoch = getEpoch();
        require(epoch > 0, "No proposals in first epoch");
        epoch -= 1;

        uint256 accountWeight = tokenLocker.getAccountWeightAt(account, epoch);
        require(accountWeight >= minCreateProposalWeight(), "Not enough weight to propose");

        // if the only action is `setGuardian()`, use `SET_GUARDIAN_PASSING_PCT` instead of `passingPct`
        uint256 _passingPct;
        bool isSetGuardianPayload = _isSetGuardianPayload(payload.length, payload[0]);
        if (isSetGuardianPayload) {
            require(block.timestamp > START_TIME + BOOTSTRAP_PERIOD, "Cannot change guardian during bootstrap");
            _passingPct = SET_GUARDIAN_PASSING_PCT;
        } else _passingPct = passingPct;

        uint256 totalWeight = tokenLocker.getTotalWeightAt(epoch);
        uint40 requiredWeight = uint40((totalWeight * _passingPct) / MAX_PCT);
        uint256 idx = proposalData.length;
        proposalData.push(
            Proposal({
                epoch: uint16(epoch),
                createdAt: uint32(block.timestamp),
                canExecuteAfter: 0,
                currentWeight: 0,
                requiredWeight: requiredWeight,
                processed: false
            })
        );

        for (uint256 i = 0; i < payload.length; i++) {
            proposalPayloads[idx].push(payload[i]);
        }
        latestProposalTimestamp[account] = block.timestamp;
        emit ProposalCreated(account, idx, payload, epoch, requiredWeight);
    }

    /**
        @notice Vote in favor of a proposal
        @dev Each account can vote once per proposal
        @param id Proposal ID
        @param weight Weight to allocate to this action. If set to zero, the full available
                      account weight is used. Integrating protocols may wish to use partial
                      weight to reflect partial support from their own users.
     */
    function voteForProposal(address account, uint256 id, uint256 weight) external callerOrDelegated(account) {
        require(id < proposalData.length, "Invalid ID");
        require(accountVoteWeights[account][id] == 0, "Already voted");

        Proposal memory proposal = proposalData[id];
        require(!proposal.processed, "Proposal already processed");
        require(proposal.createdAt + VOTING_PERIOD > block.timestamp, "Voting period has closed");

        uint256 accountWeight = tokenLocker.getAccountWeightAt(account, proposal.epoch);
        if (weight == 0) {
            weight = accountWeight;
            require(weight > 0, "No vote weight");
        } else {
            require(weight <= accountWeight, "Weight exceeds account weight");
        }

        accountVoteWeights[account][id] = weight;
        uint40 updatedWeight = uint40(proposal.currentWeight + weight);
        proposalData[id].currentWeight = updatedWeight;
        bool hasPassed = updatedWeight >= proposal.requiredWeight;

        if (proposal.canExecuteAfter == 0 && hasPassed) {
            uint256 canExecuteAfter = block.timestamp + MIN_TIME_TO_EXECUTION;
            proposalData[id].canExecuteAfter = uint32(canExecuteAfter);
            emit ProposalHasMetQuorum(id, canExecuteAfter);
        }

        emit VoteCast(account, id, weight, updatedWeight, hasPassed);
    }

    /**
        @notice Cancels a pending proposal
        @dev Can only be called by the guardian to avoid malicious proposals
             The guardian cannot cancel a proposal where the only action is
             changing the guardian.
        @param id Proposal ID
     */
    function cancelProposal(uint256 id) external {
        require(msg.sender == guardian, "Only guardian can cancel proposals");
        require(id < proposalData.length, "Invalid ID");

        Action[] storage payload = proposalPayloads[id];
        require(!_isSetGuardianPayload(payload.length, payload[0]), "Guardian replacement not cancellable");
        proposalData[id].processed = true;
        emit ProposalCancelled(id);
    }

    /**
        @notice Execute a proposal's payload
        @dev Can only be called if the proposal has received sufficient vote weight,
             and has been active for at least `MIN_TIME_TO_EXECUTION`
        @param id Proposal ID
     */
    function executeProposal(uint256 id) external {
        require(id < proposalData.length, "Invalid ID");

        Proposal memory proposal = proposalData[id];
        require(!proposal.processed, "Already processed");

        uint256 executeAfter = proposal.canExecuteAfter;
        require(executeAfter != 0, "Not passed");
        require(executeAfter < block.timestamp, "MIN_TIME_TO_EXECUTION");
        require(executeAfter + MAX_TIME_TO_EXECUTION > block.timestamp, "MAX_TIME_TO_EXECUTION");

        proposalData[id].processed = true;

        Action[] storage payload = proposalPayloads[id];
        uint256 payloadLength = payload.length;

        for (uint256 i = 0; i < payloadLength; i++) {
            payload[i].target.functionCall(payload[i].data);
        }
        emit ProposalExecuted(id);
    }

    /**
        @notice Set the minimum % of the total weight required to create a new proposal
        @dev Only callable via a passing proposal that includes a call
             to this contract and function within it's payload
     */
    function setMinCreateProposalPct(uint256 pct) external returns (bool) {
        require(msg.sender == address(this), "Only callable via proposal");
        require(pct <= MAX_PCT, "Invalid value");
        minCreateProposalPct = pct;
        emit ProposalCreationMinPctSet(pct);
        return true;
    }

    /**
        @notice Set the required % of the total weight that must vote
                for a proposal prior to being able to execute it
        @dev Only callable via a passing proposal that includes a call
             to this contract and function within it's payload
     */
    function setPassingPct(uint256 pct) external returns (bool) {
        require(msg.sender == address(this), "Only callable via proposal");
        require(pct <= MAX_PCT, "Invalid value");
        passingPct = pct;
        emit ProposalPassingPctSet(pct);
        return true;
    }

    /**
     * @notice Set the guardian address
       @dev Only callable via a passing proposal that includes a call
             to this contract and function within it's payload
     * @param _guardian Guardian address
     */
    function setGuardian(address _guardian) external returns (bool) {
        require(msg.sender == address(this), "Only callable via proposal");
        guardian = _guardian;
        emit GuardianSet(_guardian);
        return true;
    }

    function _isSetGuardianPayload(uint256 payloadLength, Action memory action) internal view returns (bool) {
        if (payloadLength == 1 && action.target == address(this)) {
            bytes memory data = action.data;
            // Extract the call sig from payload data
            bytes4 sig;
            assembly {
                sig := mload(add(data, 0x20))
            }
            return sig == AdminVoting.setGuardian.selector;
        }
        return false;
    }
}
