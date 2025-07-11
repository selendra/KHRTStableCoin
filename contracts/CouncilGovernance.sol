// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interface/IRoleController.sol";

/**
 * @title CouncilGovernance
 * @dev Decentralized governance contract for managing stablecoin ecosystem
 * ENHANCED: Better integration with RoleController and improved error handling
 */
contract CouncilGovernance is ReentrancyGuard, Pausable {
    
    struct Council {
        bool isActive;
        uint256 votingPower;
        uint256 joinedAt;
    }
    
    struct ProposalCore {
        address proposer;
        uint8 proposalType; // 0=role, 1=member_add, 2=member_remove, 3=execution
        uint8 state; // 0=pending, 1=active, 2=defeated, 3=succeeded, 4=executed
        uint32 deadline;
        uint32 executeTime;
    }
    
    struct ProposalVotes {
        uint128 forVotes;
        uint128 againstVotes;
    }
    
    struct ProposalAction {
        address target;
        bytes32 role;
        bool isGrant;
    }
    
    // ====== STATE VARIABLES ======
    
    IRoleController public roleController;
    
    // Council management
    mapping(address => Council) public councils;
    address[] public councilList;
    uint256 public totalVotingPower;
    uint256 public activeMembers;
    
    // Proposal management (split to avoid stack issues)
    mapping(uint256 => ProposalCore) public proposalCore;
    mapping(uint256 => ProposalVotes) public proposalVotes;
    mapping(uint256 => ProposalAction) public proposalActions;
    mapping(uint256 => bytes) public proposalData;
    mapping(uint256 => string) public proposalDescriptions;
    
    // Voting tracking
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public voteChoice; // true=for, false=against
    
    uint256 public nextProposalId;
    
    // Configuration
    uint256 public votingPeriod = 3 days;
    uint256 public timeLock = 1 days;
    uint256 public quorumPercent = 60; // 60%
    uint256 public majorityPercent = 51; // 51%
    
    // Constants
    uint256 public constant MIN_COUNCIL = 3;
    uint256 public constant MAX_COUNCIL = 15;
    uint256 public constant BASIS_POINTS = 100;
    
    // ENHANCED: Integration tracking
    bool public isInitialized;
    mapping(uint256 => uint256) public roleChangeIds; // proposal -> roleController changeId
    
    // ====== EVENTS ======
    
    event ProposalCreated(uint256 indexed id, address indexed proposer, uint8 proposalType);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 power);
    event ProposalExecuted(uint256 indexed id, bool success);
    event CouncilAdded(address indexed member, uint256 power);
    event CouncilRemoved(address indexed member);
    event ConfigUpdated(uint256 votingPeriod, uint256 timeLock, uint256 quorum);
    event SystemInitialized(address indexed roleController);
    event RoleChangeProposed(uint256 indexed proposalId, uint256 indexed roleChangeId);
    event RoleChangeError(uint256 indexed proposalId, string reason);
    
    // ====== ERRORS ======
    
    error NotCouncil();
    error InvalidProposal();
    error AlreadyVoted();
    error VotingEnded();
    error NotReady();
    error AlreadyExecuted();
    error InsufficientQuorum();
    error ExecutionFailed();
    error InvalidMember();
    error InvalidConfig();
    error NotInitialized();
    error AlreadyInitialized();
    error IntegrationFailed();
    
    // ====== MODIFIERS ======
    
    modifier onlyCouncil() {
        if (!councils[msg.sender].isActive) revert NotCouncil();
        _;
    }
    
    modifier validProposal(uint256 id) {
        if (id >= nextProposalId) revert InvalidProposal();
        _;
    }
    
    modifier whenInitialized() {
        if (!isInitialized) revert NotInitialized();
        _;
    }
    
    // ====== CONSTRUCTOR ======
    
    constructor(
        address _roleController,
        address[] memory _members,
        uint256[] memory _powers
    ) {
        require(_roleController != address(0), "Invalid controller");
        require(_members.length >= MIN_COUNCIL, "Too few members");
        require(_members.length == _powers.length, "Length mismatch");
        
        roleController = IRoleController(_roleController);
        
        for (uint256 i = 0; i < _members.length; i++) {
            _addCouncilInternal(_members[i], _powers[i]);
        }
        
        // ENHANCED: Mark as initialized once setup is complete
        isInitialized = true;
        emit SystemInitialized(_roleController);
    }
    
    // ====== COUNCIL MANAGEMENT ======
    
    function _addCouncilInternal(address member, uint256 power) internal {
        require(member != address(0), "Invalid address");
        require(power > 0, "Invalid power");
        require(!councils[member].isActive, "Already member");
        require(activeMembers < MAX_COUNCIL, "Too many members");
        
        councils[member] = Council({
            isActive: true,
            votingPower: power,
            joinedAt: block.timestamp
        });
        
        councilList.push(member);
        totalVotingPower += power;
        activeMembers++;
        
        emit CouncilAdded(member, power);
    }
    
    function _removeCouncilInternal(address member) internal {
        require(councils[member].isActive, "Not member");
        require(activeMembers > MIN_COUNCIL, "Below minimum");
        
        uint256 power = councils[member].votingPower;
        councils[member].isActive = false;
        totalVotingPower -= power;
        activeMembers--;
        
        // Remove from list
        for (uint256 i = 0; i < councilList.length; i++) {
            if (councilList[i] == member) {
                councilList[i] = councilList[councilList.length - 1];
                councilList.pop();
                break;
            }
        }
        
        emit CouncilRemoved(member);
    }
    
    // ====== PROPOSAL CREATION ======
    
    function proposeRoleChange(
        bytes32 role,
        address account,
        bool isGrant,
        string calldata description
    ) external onlyCouncil whenNotPaused whenInitialized returns (uint256) {
        require(account != address(0), "Invalid account");
        
        uint256 id = nextProposalId++;
        
        proposalCore[id] = ProposalCore({
            proposer: msg.sender,
            proposalType: 0, // ROLE_CHANGE
            state: 1, // ACTIVE
            deadline: uint32(block.timestamp + votingPeriod),
            executeTime: uint32(block.timestamp + votingPeriod + timeLock)
        });
        
        proposalActions[id] = ProposalAction({
            target: account,
            role: role,
            isGrant: isGrant
        });
        
        proposalDescriptions[id] = description;
        
        emit ProposalCreated(id, msg.sender, 0);
        return id;
    }
    
    function proposeAddMember(
        address newMember,
        uint256 power,
        string calldata description
    ) external onlyCouncil whenNotPaused whenInitialized returns (uint256) {
        require(newMember != address(0), "Invalid member");
        require(!councils[newMember].isActive, "Already member");
        require(power > 0, "Invalid power");
        require(activeMembers < MAX_COUNCIL, "Too many members");
        
        uint256 id = nextProposalId++;
        
        proposalCore[id] = ProposalCore({
            proposer: msg.sender,
            proposalType: 1, // MEMBER_ADD
            state: 1, // ACTIVE
            deadline: uint32(block.timestamp + votingPeriod),
            executeTime: uint32(block.timestamp + votingPeriod + timeLock)
        });
        
        proposalActions[id] = ProposalAction({
            target: newMember,
            role: bytes32(0),
            isGrant: true
        });
        
        proposalData[id] = abi.encode(power);
        proposalDescriptions[id] = description;
        
        emit ProposalCreated(id, msg.sender, 1);
        return id;
    }
    
    function proposeRemoveMember(
        address member,
        string calldata description
    ) external onlyCouncil whenNotPaused whenInitialized returns (uint256) {
        require(member != address(0), "Invalid member");
        require(councils[member].isActive, "Not member");
        require(member != msg.sender, "Cannot remove self");
        require(activeMembers > MIN_COUNCIL, "Below minimum");
        
        uint256 id = nextProposalId++;
        
        proposalCore[id] = ProposalCore({
            proposer: msg.sender,
            proposalType: 2, // MEMBER_REMOVE
            state: 1, // ACTIVE
            deadline: uint32(block.timestamp + votingPeriod),
            executeTime: uint32(block.timestamp + votingPeriod + timeLock)
        });
        
        proposalActions[id] = ProposalAction({
            target: member,
            role: bytes32(0),
            isGrant: false
        });
        
        proposalDescriptions[id] = description;
        
        emit ProposalCreated(id, msg.sender, 2);
        return id;
    }
    
    function proposeExecution(
        address target,
        bytes calldata data,
        string calldata description
    ) external onlyCouncil whenNotPaused whenInitialized returns (uint256) {
        require(target != address(0), "Invalid target");
        
        uint256 id = nextProposalId++;
        
        proposalCore[id] = ProposalCore({
            proposer: msg.sender,
            proposalType: 3, // EXECUTION
            state: 1, // ACTIVE
            deadline: uint32(block.timestamp + votingPeriod),
            executeTime: uint32(block.timestamp + votingPeriod + timeLock)
        });
        
        proposalActions[id] = ProposalAction({
            target: target,
            role: bytes32(0),
            isGrant: false
        });
        
        proposalData[id] = data;
        proposalDescriptions[id] = description;
        
        emit ProposalCreated(id, msg.sender, 3);
        return id;
    }
    
    // ====== VOTING ======
    
    function vote(uint256 id, bool support) external onlyCouncil validProposal(id) whenInitialized {
        ProposalCore memory core = proposalCore[id];
        
        if (core.state != 1) revert InvalidProposal(); // Must be ACTIVE
        if (block.timestamp > core.deadline) revert VotingEnded();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        
        hasVoted[id][msg.sender] = true;
        voteChoice[id][msg.sender] = support;
        
        uint256 power = councils[msg.sender].votingPower;
        
        if (support) {
            proposalVotes[id].forVotes += uint128(power);
        } else {
            proposalVotes[id].againstVotes += uint128(power);
        }
        
        emit VoteCast(id, msg.sender, support, power);
        
        _checkProposalState(id);
    }
    
    function _checkProposalState(uint256 id) internal {
        ProposalVotes memory votes = proposalVotes[id];
        uint256 totalVotes = uint256(votes.forVotes) + uint256(votes.againstVotes);
        uint256 requiredQuorum = (totalVotingPower * quorumPercent) / BASIS_POINTS;
        
        if (totalVotes >= requiredQuorum) {
            if (votes.forVotes > votes.againstVotes) {
                proposalCore[id].state = 3; // SUCCEEDED
            } else {
                proposalCore[id].state = 2; // DEFEATED
            }
        }
    }
    
    function execute(uint256 id) external validProposal(id) nonReentrant whenInitialized {
        ProposalCore memory core = proposalCore[id];
        ProposalAction memory action = proposalActions[id];
        
        if (core.state != 3) revert NotReady(); // Must be SUCCEEDED
        if (block.timestamp < core.executeTime) revert NotReady();
        if (core.state == 4) revert AlreadyExecuted(); // Already executed
        
        proposalCore[id].state = 4; // EXECUTED
        
        bool success;
        
        if (core.proposalType == 0) { // ROLE_CHANGE
            success = _executeRoleChange(id, action.role, action.target, action.isGrant);
        } else if (core.proposalType == 1) { // MEMBER_ADD
            uint256 power = abi.decode(proposalData[id], (uint256));
            _addCouncilInternal(action.target, power);
            success = true;
        } else if (core.proposalType == 2) { // MEMBER_REMOVE
            _removeCouncilInternal(action.target);
            success = true;
        } else if (core.proposalType == 3) { // EXECUTION
            (success,) = action.target.call(proposalData[id]);
        }
        
        emit ProposalExecuted(id, success);
        
        if (!success) revert ExecutionFailed();
    }
    
    // ENHANCED: Better role change execution with proper tracking
    function _executeRoleChange(uint256 proposalId, bytes32 role, address account, bool isGrant) internal returns (bool) {
        try roleController.proposeRoleChange(role, account, isGrant) returns (uint256 changeId) {
            // Store the role change ID for tracking
            roleChangeIds[proposalId] = changeId;
            emit RoleChangeProposed(proposalId, changeId);
            
            try roleController.executeGovernanceRoleChange(changeId) {
                return true;
            } catch Error(string memory reason) {
               emit RoleChangeError(proposalId, reason); // Now using the reason
                return false;
            } catch {
                return false;
            }
        } catch Error(string memory reason) {
            emit RoleChangeError(proposalId, reason);
            return false;
        } catch {
            return false;
        }
    }
    
    // ENHANCED: Allow manual retry of failed role changes
    function retryRoleChange(uint256 proposalId) external onlyCouncil returns (bool) {
        require(proposalCore[proposalId].state == 4, "Proposal not executed");
        require(proposalCore[proposalId].proposalType == 0, "Not a role change proposal");
        require(roleChangeIds[proposalId] > 0, "No role change ID found");
        
        try roleController.executeGovernanceRoleChange(roleChangeIds[proposalId]) {
            return true;
        } catch {
            return false;
        }
    }
    
    function updateConfig(
        uint256 _votingPeriod,
        uint256 _timeLock,
        uint256 _quorumPercent
    ) external onlyCouncil whenInitialized {
        require(_votingPeriod >= 1 hours && _votingPeriod <= 30 days, "Invalid voting period");
        require(_timeLock >= 0 && _timeLock <= 7 days, "Invalid timelock");
        require(_quorumPercent >= 1 && _quorumPercent <= 100, "Invalid quorum");
        
        votingPeriod = _votingPeriod;
        timeLock = _timeLock;
        quorumPercent = _quorumPercent;
        
        emit ConfigUpdated(_votingPeriod, _timeLock, _quorumPercent);
    }
    
    // ====== VIEW FUNCTIONS ======
    
    function getProposalState(uint256 id) external view returns (
        address proposer,
        uint8 proposalType,
        uint8 state,
        uint256 deadline,
        uint256 executeTime,
        uint256 forVotes,
        uint256 againstVotes
    ) {
        ProposalCore memory core = proposalCore[id];
        ProposalVotes memory votes = proposalVotes[id];
        
        return (
            core.proposer,
            core.proposalType,
            core.state,
            core.deadline,
            core.executeTime,
            votes.forVotes,
            votes.againstVotes
        );
    }
    
    function getProposalAction(uint256 id) external view returns (
        address target,
        bytes32 role,
        bool isGrant,
        string memory description
    ) {
        ProposalAction memory action = proposalActions[id];
        return (action.target, action.role, action.isGrant, proposalDescriptions[id]);
    }
    
    function getCouncilInfo(address member) external view returns (
        bool isActive,
        uint256 votingPower,
        uint256 joinedAt
    ) {
        Council memory council = councils[member];
        return (council.isActive, council.votingPower, council.joinedAt);
    }
    
    function getCouncilList() external view returns (address[] memory) {
        return councilList;
    }
    
    function hasVotedOn(uint256 id, address voter) external view returns (bool voted, bool choice) {
        return (hasVoted[id][voter], voteChoice[id][voter]);
    }
    
    // ENHANCED: Integration status checking
    function getIntegrationStatus() external view returns (
        address roleControllerAddr,
        bool isRoleControllerSet,
        bool isGovernanceInitialized,
        bool hasGovernanceRole
    ) {
        roleControllerAddr = address(roleController);
        isRoleControllerSet = roleControllerAddr != address(0);
        isGovernanceInitialized = isInitialized;
        
        if (isRoleControllerSet) {
            try roleController.checkRole(roleController.GOVERNANCE_ROLE(), address(this)) returns (bool hasRole) {
                hasGovernanceRole = hasRole;
            } catch {
                hasGovernanceRole = false;
            }
        }
    }
    
    function getRoleChangeId(uint256 proposalId) external view returns (uint256) {
        return roleChangeIds[proposalId];
    }
    
    function emergencyPause() external {
        require(councils[msg.sender].isActive, "Only council");
        _pause();
    }
    
    function emergencyUnpause() external onlyCouncil {
        _unpause();
    }

}