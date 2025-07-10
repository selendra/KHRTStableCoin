// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICouncilGovernance {
    // Enums
    enum ProposalType {
        RoleGranting,
        RoleRevoking,
        ConfigChange,
        EmergencyAction,
        CouncilRemoval,
        ContractUpgrade,
        TreasuryAction
    }
    
    enum ProposalStatus {
        Active,
        Executed,
        Cancelled,
        Failed,
        Expired
    }
    
    enum VoteChoice {
        None,
        For,
        Against,
        Abstain
    }
    
    // Structs
    struct CouncilMember {
        address memberAddress;
        uint256 termStart;
        uint256 termEnd;
        bool isActive;
        uint256 votesReceived;
        string name;
        string contactInfo;
    }
    
    // Council Management
    function registerCandidate(string calldata profile) external payable;
    function startElection(uint256 availableSeats) external;
    function voteInElection(uint256 electionId, address candidate) external;
    function finalizeElection(uint256 electionId) external;
    function removeCouncilMember(address member, string calldata reason) external;
    
    // Proposal System
    function createProposal(
        string calldata title,
        string calldata description,
        ProposalType proposalType,
        bytes calldata executionData,
        address targetContract,
        uint256 value
    ) external returns (uint256);
    
    function voteOnProposal(uint256 proposalId, VoteChoice choice) external;
    function executeProposal(uint256 proposalId) external;
    
    // Role Controller Integration
    function proposeGrantRole(
        bytes32 role,
        address account,
        string calldata reason
    ) external returns (uint256);
    
    function proposeRevokeRole(
        bytes32 role,
        address account,
        string calldata reason
    ) external returns (uint256);
    
    // View Functions
    function getCouncilMembers() external view returns (CouncilMember[] memory);
    function getActiveCouncilMembers() external view returns (address[] memory);
    function isCouncilMember(address member) external view returns (bool);
    
    function getProposal(uint256 proposalId) external view returns (
        uint256 id,
        address proposer,
        string memory title,
        string memory description,
        ProposalType proposalType,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        uint256 createdAt,
        uint256 votingEndsAt,
        uint256 executionTime,
        ProposalStatus status
    );
    
    function getElectionResults(uint256 electionId) external view returns (
        address[] memory candidates,
        uint256[] memory votes
    );
    
    function hasVotedInElection(uint256 electionId, address voter) external view returns (bool);
    function hasVotedOnProposal(uint256 proposalId, address voter) external view returns (bool);
    function getVoteOnProposal(uint256 proposalId, address voter) external view returns (VoteChoice);
    
    // Constants
    function MAX_COUNCIL_SIZE() external view returns (uint256);
    function MIN_COUNCIL_SIZE() external view returns (uint256);
    function COUNCIL_TERM_LENGTH() external view returns (uint256);
    function ELECTION_PERIOD() external view returns (uint256);
    function PROPOSAL_VOTING_PERIOD() external view returns (uint256);
    function EXECUTION_DELAY() external view returns (uint256);
    function QUORUM_PERCENTAGE() external view returns (uint256);
    
    // Events
    event CouncilMemberElected(address indexed member, uint256 indexed termStart, uint256 indexed termEnd);
    event CouncilMemberTermEnded(address indexed member, uint256 indexed termEnd);
    event CouncilMemberRemoved(address indexed member, string reason);
    
    event ElectionStarted(uint256 indexed electionId, uint256 startTime, uint256 endTime, uint256 availableSeats);
    event ElectionEnded(uint256 indexed electionId, address[] winners);
    event CandidateRegistered(address indexed candidate, string profile);
    event VoteCast(uint256 indexed electionId, address indexed voter, address indexed candidate, uint256 votingPower);
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        ProposalType proposalType,
        uint256 votingEndsAt
    );
    event ProposalVoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        VoteChoice choice,
        uint256 votingPower
    );
    event ProposalExecuted(uint256 indexed proposalId, bool success);
    event ProposalCancelled(uint256 indexed proposalId, string reason);
}