// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interface/IRoleController.sol";

/**
 * @title CouncilGovernance
 * @dev Decentralized governance contract for managing stablecoin ecosystem.
 * Includes secure voting, quorum enforcement, and safe RoleController execution.
 */
contract CouncilGovernance is ReentrancyGuard, Pausable {
    using Address for address;

    enum ProposalType {
        RoleChange,
        AddMember,
        RemoveMember,
        Execute
    }

    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Executed
    }

    struct Council {
        bool isActive;
        uint256 votingPower;
        uint256 joinedAt;
    }

    struct ProposalCore {
        address proposer;
        ProposalType proposalType;
        ProposalState state;
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

    // Governance configuration
    IRoleController public immutable roleController;

    uint256 public votingPeriod = 3 days;
    uint256 public timeLock = 1 days;
    uint256 public quorumPercent = 6000; // 60% in basis points (10000 = 100%)
    uint256 public majorityPercent = 5100; // 51% in basis points

    uint256 public constant MIN_COUNCIL = 3;
    uint256 public constant MAX_COUNCIL = 15;
    uint256 public constant BASIS_POINTS = 10_000;

    // Council state
    mapping(address => Council) public councils;
    address[] public councilList;
    uint256 public totalVotingPower;
    uint256 public activeMembers;

    // Proposals
    mapping(uint256 => ProposalCore) public proposalCore;
    mapping(uint256 => ProposalVotes) public proposalVotes;
    mapping(uint256 => ProposalAction) public proposalActions;
    mapping(uint256 => bytes) public proposalData;
    mapping(uint256 => string) public proposalDescriptions;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public voteChoice;
    mapping(uint256 => uint256) public roleChangeIds;

    uint256 public nextProposalId;
    bool public isInitialized;

    // ====== EVENTS ======
    event ProposalCreated(uint256 indexed id, address indexed proposer, ProposalType proposalType);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 power);
    event ProposalExecuted(uint256 indexed id, bool success);
    event CouncilAdded(address indexed member, uint256 power);
    event CouncilRemoved(address indexed member);
    event ConfigUpdated(uint256 votingPeriod, uint256 timeLock, uint256 quorum);
    event SystemInitialized(address indexed roleController);
    event RoleChangeProposed(uint256 indexed proposalId, uint256 indexed roleChangeId);
    event RoleChangeError(uint256 indexed proposalId, string reason);
    event RetryRoleChangeFailed(uint256 indexed proposalId, uint256 indexed changeId);

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

    constructor(address _roleController, address[] memory _members, uint256[] memory _powers) {
        require(_members.length >= MIN_COUNCIL, "Too few members");
        require(_members.length == _powers.length, "Length mismatch");

        roleController = IRoleController(_roleController);

        for (uint256 i = 0; i < _members.length; i++) {
            _addCouncilInternal(_members[i], _powers[i]);
        }

        isInitialized = true;
        emit SystemInitialized(_roleController);
    }

    // ====== INTERNAL COUNCIL MGMT ======

    function _addCouncilInternal(address member, uint256 power) internal {
        require(member != address(0), "Invalid address");
        require(power > 0, "Invalid power");
        require(!councils[member].isActive, "Already member");
        require(activeMembers < MAX_COUNCIL, "Too many members");

        councils[member] = Council(true, power, block.timestamp);
        councilList.push(member);
        totalVotingPower += power;
        activeMembers++;

        emit CouncilAdded(member, power);
    }

    function _removeCouncilInternal(address member) internal {
        require(councils[member].isActive, "Not member");
        require(activeMembers > MIN_COUNCIL, "Below minimum");

        totalVotingPower -= councils[member].votingPower;
        councils[member].isActive = false;
        activeMembers--;

        for (uint256 i = 0; i < councilList.length; i++) {
            if (councilList[i] == member) {
                councilList[i] = councilList[councilList.length - 1];
                councilList.pop();
                break;
            }
        }

        emit CouncilRemoved(member);
    }

    // ====== PROPOSALS ======

    function proposeRoleChange(bytes32 role, address account, bool isGrant, string calldata description)
        external
        onlyCouncil
        whenNotPaused
        whenInitialized
        returns (uint256)
    {
        require(account != address(0), "Invalid account");

        uint256 id = _initProposal(ProposalType.RoleChange);
        proposalActions[id] = ProposalAction(account, role, isGrant);
        proposalDescriptions[id] = description;

        emit ProposalCreated(id, msg.sender, ProposalType.RoleChange);
        return id;
    }

    function proposeAddMember(address newMember, uint256 power, string calldata description)
        external
        onlyCouncil
        whenNotPaused
        whenInitialized
        returns (uint256)
    {
        require(newMember != address(0), "Invalid member");
        require(power > 0, "Invalid power");
        require(!councils[newMember].isActive, "Already member");
        require(activeMembers < MAX_COUNCIL, "Too many members");

        uint256 id = _initProposal(ProposalType.AddMember);
        proposalActions[id] = ProposalAction(newMember, bytes32(0), true);
        proposalData[id] = abi.encode(power);
        proposalDescriptions[id] = description;

        emit ProposalCreated(id, msg.sender, ProposalType.AddMember);
        return id;
    }

    function proposeRemoveMember(address member, string calldata description)
        external
        onlyCouncil
        whenNotPaused
        whenInitialized
        returns (uint256)
    {
        require(member != address(0), "Invalid member");
        require(councils[member].isActive, "Not member");
        require(member != msg.sender, "Cannot remove self");
        require(activeMembers > MIN_COUNCIL, "Below minimum");

        uint256 id = _initProposal(ProposalType.RemoveMember);
        proposalActions[id] = ProposalAction(member, bytes32(0), false);
        proposalDescriptions[id] = description;

        emit ProposalCreated(id, msg.sender, ProposalType.RemoveMember);
        return id;
    }

    function proposeExecution(address target, bytes calldata data, string calldata description)
        external
        onlyCouncil
        whenNotPaused
        whenInitialized
        returns (uint256)
    {
        require(target != address(0), "Invalid target");
        require(target != address(this), "Cannot self-call");

        uint256 id = _initProposal(ProposalType.Execute);
        proposalActions[id] = ProposalAction(target, bytes32(0), false);
        proposalData[id] = data;
        proposalDescriptions[id] = description;

        emit ProposalCreated(id, msg.sender, ProposalType.Execute);
        return id;
    }

    function _initProposal(ProposalType ptype) internal returns (uint256 id) {
        id = nextProposalId++;

        proposalCore[id] = ProposalCore({
            proposer: msg.sender,
            proposalType: ptype,
            state: ProposalState.Active,
            deadline: uint32(block.timestamp + votingPeriod),
            executeTime: uint32(block.timestamp + votingPeriod + timeLock)
        });
    }

    // ====== VOTING ======

    function vote(uint256 id, bool support) external onlyCouncil validProposal(id) whenInitialized {
        ProposalCore storage core = proposalCore[id];

        if (core.state != ProposalState.Active) revert InvalidProposal();
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
        uint256 quorum = (totalVotingPower * quorumPercent) / BASIS_POINTS;

        if (totalVotes >= quorum) {
            if (votes.forVotes * 2 >= totalVotes) {
                proposalCore[id].state = ProposalState.Succeeded;
            } else {
                proposalCore[id].state = ProposalState.Defeated;
            }
        }
    }

    // ====== EXECUTION ======

    function execute(uint256 id) external validProposal(id) nonReentrant whenInitialized {
        ProposalCore storage core = proposalCore[id];
        ProposalAction memory action = proposalActions[id];

        if (core.state != ProposalState.Succeeded) revert NotReady();
        if (block.timestamp < core.executeTime) revert NotReady();
        if (core.state == ProposalState.Executed) revert AlreadyExecuted();

        core.state = ProposalState.Executed;

        bool success;
        if (core.proposalType == ProposalType.RoleChange) {
            success = _executeRoleChange(id, action.role, action.target, action.isGrant);
        } else if (core.proposalType == ProposalType.AddMember) {
            uint256 power = abi.decode(proposalData[id], (uint256));
            _addCouncilInternal(action.target, power);
            success = true;
        } else if (core.proposalType == ProposalType.RemoveMember) {
            _removeCouncilInternal(action.target);
            success = true;
        } else if (core.proposalType == ProposalType.Execute) {
            (success, ) = action.target.call(proposalData[id]);
        }

        emit ProposalExecuted(id, success);
        if (!success) revert ExecutionFailed();
    }

    function _executeRoleChange(uint256 proposalId, bytes32 role, address account, bool isGrant)
        internal
        returns (bool)
    {
        try roleController.proposeRoleChange(role, account, isGrant) returns (uint256 changeId) {
            roleChangeIds[proposalId] = changeId;
            emit RoleChangeProposed(proposalId, changeId);

            try roleController.executeGovernanceRoleChange(changeId) {
                return true;
            } catch Error(string memory reason) {
                emit RoleChangeError(proposalId, reason);
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

    function retryRoleChange(uint256 proposalId) external onlyCouncil returns (bool) {
        ProposalCore memory core = proposalCore[proposalId];

        require(core.state == ProposalState.Executed, "Not executed");
        require(core.proposalType == ProposalType.RoleChange, "Invalid type");
        uint256 changeId = roleChangeIds[proposalId];
        require(changeId > 0, "No changeId");

        try roleController.executeGovernanceRoleChange(changeId) {
            return true;
        } catch {
            emit RetryRoleChangeFailed(proposalId, changeId);
            return false;
        }
    }

    // ====== CONFIGURATION ======

    function updateConfig(uint256 _votingPeriod, uint256 _timeLock, uint256 _quorumPercent)
        external
        onlyCouncil
        whenInitialized
    {
        if (_votingPeriod < 1 hours || _votingPeriod > 30 days) revert InvalidConfig();
        if (_timeLock > 7 days) revert InvalidConfig();
        if (_quorumPercent < 100 || _quorumPercent > BASIS_POINTS) revert InvalidConfig();

        votingPeriod = _votingPeriod;
        timeLock = _timeLock;
        quorumPercent = _quorumPercent;

        emit ConfigUpdated(_votingPeriod, _timeLock, _quorumPercent);
    }

    // ====== VIEW FUNCTIONS ======

    function getProposalState(uint256 id)
        external
        view
        returns (
            address proposer,
            ProposalType proposalType,
            ProposalState state,
            uint256 deadline,
            uint256 executeTime,
            uint256 forVotes,
            uint256 againstVotes
        )
    {
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

    function getCouncilInfo(address member)
        external
        view
        returns (bool isActive, uint256 power, uint256 joinedAt)
    {
        Council memory c = councils[member];
        return (c.isActive, c.votingPower, c.joinedAt);
    }

    function getCouncilList() external view returns (address[] memory) {
        return councilList;
    }

    function hasVotedOn(uint256 id, address voter) external view returns (bool voted, bool choice) {
        return (hasVoted[id][voter], voteChoice[id][voter]);
    }

    function getProposalAction(uint256 id)
        external
        view
        returns (address target, bytes32 role, bool isGrant, string memory description)
    {
        ProposalAction memory action = proposalActions[id];
        return (action.target, action.role, action.isGrant, proposalDescriptions[id]);
    }

    function getIntegrationStatus()
        external
        view
        returns (address controller, bool isSet, bool initialized, bool hasGovernanceRole)
    {
        controller = address(roleController);
        isSet = controller != address(0);
        initialized = isInitialized;

        if (isSet) {
            try roleController.checkRole(roleController.GOVERNANCE_ROLE(), address(this)) returns (bool ok) {
                hasGovernanceRole = ok;
            } catch {
                hasGovernanceRole = false;
            }
        }
    }

    function getRoleChangeId(uint256 id) external view returns (uint256) {
        return roleChangeIds[id];
    }

    // ====== EMERGENCY ======

    function emergencyPause() external {
        if (!councils[msg.sender].isActive) revert NotCouncil();
        _pause();
    }

    function emergencyUnpause() external onlyCouncil {
        _unpause();
    }
}
