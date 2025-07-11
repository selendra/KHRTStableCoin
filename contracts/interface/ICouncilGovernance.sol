// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ICouncilGovernance
 * @dev Interface for the Council Governance system
 * FIXED: Now matches the actual CouncilGovernance implementation
 */
interface ICouncilGovernance {
    
    // Enums for proposal types and states
    enum ProposalType {
        RoleChange,      // 0
        MemberAdd,       // 1
        MemberRemove,    // 2
        Execution        // 3
    }
    
    enum ProposalState {
        Pending,         // 0
        Active,          // 1
        Defeated,        // 2
        Succeeded,       // 3
        Executed         // 4
    }
    
    // Structs
    struct Council {
        bool isActive;
        uint256 votingPower;
        uint256 joinedAt;
    }
    
    struct ProposalInfo {
        address proposer;
        uint8 proposalType;
        uint8 state;
        uint256 deadline;
        uint256 executeTime;
        uint256 forVotes;
        uint256 againstVotes;
    }
    
    struct ProposalAction {
        address target;
        bytes32 role;
        bool isGrant;
        string description;
    }
    
    // ====== PROPOSAL CREATION ======
    
    function proposeRoleChange(
        bytes32 role,
        address account,
        bool isGrant,
        string calldata description
    ) external returns (uint256);
    
    function proposeAddMember(
        address newMember,
        uint256 power,
        string calldata description
    ) external returns (uint256);
    
    function proposeRemoveMember(
        address member,
        string calldata description
    ) external returns (uint256);
    
    function proposeExecution(
        address target,
        bytes calldata data,
        string calldata description
    ) external returns (uint256);
    
    // ====== VOTING ======
    
    function vote(uint256 id, bool support) external;
    function execute(uint256 id) external;
    function retryRoleChange(uint256 proposalId) external returns (bool);
    
    // ====== CONFIGURATION ======
    
    function updateConfig(
        uint256 _votingPeriod,
        uint256 _timeLock,
        uint256 _quorumPercent
    ) external;
    
    // ====== VIEW FUNCTIONS ======
    
    function getProposalState(uint256 id) external view returns (
        address proposer,
        uint8 proposalType,
        uint8 state,
        uint256 deadline,
        uint256 executeTime,
        uint256 forVotes,
        uint256 againstVotes
    );
    
    function getProposalAction(uint256 id) external view returns (
        address target,
        bytes32 role,
        bool isGrant,
        string memory description
    );
    
    function getCouncilInfo(address member) external view returns (
        bool isActive,
        uint256 votingPower,
        uint256 joinedAt
    );
    
    function getCouncilList() external view returns (address[] memory);
    
    function hasVotedOn(uint256 id, address voter) external view returns (bool voted, bool choice);
    
    function getIntegrationStatus() external view returns (
        address roleControllerAddr,
        bool isRoleControllerSet,
        bool isGovernanceInitialized,
        bool hasGovernanceRole
    );
    
    function getRoleChangeId(uint256 proposalId) external view returns (uint256);
    
    function systemHealthCheck() external view returns (
        bool councilHealthy,
        bool roleControllerHealthy,
        bool governanceRoleActive,
        string memory statusMessage
    );
    
    // ====== CONFIGURATION GETTERS ======
    
    function votingPeriod() external view returns (uint256);
    function timeLock() external view returns (uint256);
    function quorumPercent() external view returns (uint256);
    function nextProposalId() external view returns (uint256);
    function totalVotingPower() external view returns (uint256);
    function activeMembers() external view returns (uint256);
    
    // ====== CONSTANTS ======
    
    function MIN_COUNCIL() external view returns (uint256);
    function MAX_COUNCIL() external view returns (uint256);
    function BASIS_POINTS() external view returns (uint256);
    
    // ====== EMERGENCY FUNCTIONS ======
    
    function emergencyPause() external;
    function emergencyUnpause() external;
    function paused() external view returns (bool);
    
    // ====== EVENTS ======
    
    event ProposalCreated(uint256 indexed id, address indexed proposer, uint8 proposalType);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 power);
    event ProposalExecuted(uint256 indexed id, bool success);
    event CouncilAdded(address indexed member, uint256 power);
    event CouncilRemoved(address indexed member);
    event ConfigUpdated(uint256 votingPeriod, uint256 timeLock, uint256 quorum);
    event SystemInitialized(address indexed roleController);
    event RoleChangeProposed(uint256 indexed proposalId, uint256 indexed roleChangeId);
}