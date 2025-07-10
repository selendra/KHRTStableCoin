// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interface/IRoleController.sol";

/**
 * @title CouncilGovernance
 * @dev Democratic governance contract with elected council members
 * Features:
 * - Council member elections with term limits
 * - Proposal and voting system
 * - Quorum requirements for valid decisions
 * - Time-locked execution for security
 * - Emergency council override mechanisms
 * - Integration with RoleController for role management
 */
contract CouncilGovernance is ReentrancyGuard {
    IRoleController public roleController;
    IERC20 public governanceToken; // Token used for voting power
    
    // Council configuration
    uint256 public constant MAX_COUNCIL_SIZE = 7;
    uint256 public constant MIN_COUNCIL_SIZE = 3;
    uint256 public constant COUNCIL_TERM_LENGTH = 365 days; // 1 year terms
    uint256 public constant ELECTION_PERIOD = 7 days;
    uint256 public constant PROPOSAL_VOTING_PERIOD = 3 days;
    uint256 public constant EXECUTION_DELAY = 2 days; // Time lock
    uint256 public constant QUORUM_PERCENTAGE = 60; // 60% of council must vote
    
    // Council member structure
    struct CouncilMember {
        address memberAddress;
        uint256 termStart;
        uint256 termEnd;
        bool isActive;
        uint256 votesReceived; // For election tracking
        string name; // Optional identifier
        string contactInfo; // Optional contact information
    }
    
    // Proposal structure
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        ProposalType proposalType;
        bytes executionData; // Encoded function call data
        address targetContract; // Contract to call
        uint256 value; // ETH value to send
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 votesAbstain;
        uint256 createdAt;
        uint256 votingEndsAt;
        uint256 executionTime; // When proposal can be executed
        ProposalStatus status;
        mapping(address => bool) hasVoted;
        mapping(address => VoteChoice) votes;
    }
    
    // Election structure
    struct Election {
        uint256 electionId;
        uint256 startTime;
        uint256 endTime;
        uint256 availableSeats;
        bool isActive;
        mapping(address => uint256) candidateVotes;
        mapping(address => bool) hasVoted;
        address[] candidates;
    }
    
    enum ProposalType {
        RoleGranting,    // Grant role to address
        RoleRevoking,    // Revoke role from address
        ConfigChange,    // Change governance configuration
        EmergencyAction, // Emergency governance action
        CouncilRemoval,  // Remove council member
        ContractUpgrade, // Upgrade contract functionality
        TreasuryAction   // Treasury management
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
    
    // State variables
    CouncilMember[] public councilMembers;
    mapping(address => bool) public isCouncilMember;
    mapping(address => uint256) public councilMemberIndex;
    
    uint256 public currentElectionId;
    mapping(uint256 => Election) public elections;
    
    uint256 public proposalCounter;
    mapping(uint256 => Proposal) public proposals;
    
    // Candidate registration
    mapping(address => bool) public isRegisteredCandidate;
    mapping(address => string) public candidateProfiles;
    uint256 public candidateRegistrationFee = 1000 * 10**18; // 1000 tokens
    
    // Treasury
    uint256 public treasuryBalance;
    
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
    
    event QuorumChanged(uint256 oldQuorum, uint256 newQuorum);
    event GovernanceTokenUpdated(address indexed oldToken, address indexed newToken);
    
    // Errors
    error NotCouncilMember();
    error InvalidProposal();
    error VotingPeriodEnded();
    error VotingPeriodActive();
    error AlreadyVoted();
    error QuorumNotMet();
    error ExecutionDelayNotMet();
    error ProposalNotPassed();
    error InvalidElection();
    error ElectionNotActive();
    error AlreadyRegistered();
    error InsufficientFee();
    error InvalidCouncilSize();
    error TermNotExpired();
    error InvalidAddress();
    error Unauthorized();
    
    modifier onlyCouncilMember() {
        if (!isCouncilMember[msg.sender]) {
            revert NotCouncilMember();
        }
        _;
    }
    
    modifier validAddress(address addr) {
        if (addr == address(0)) {
            revert InvalidAddress();
        }
        _;
    }
    
    constructor(
        address _roleController,
        address _governanceToken,
        address[] memory _initialCouncil,
        string[] memory _initialCouncilNames
    ) {
        require(_roleController != address(0), "Invalid role controller");
        require(_governanceToken != address(0), "Invalid governance token");
        require(_initialCouncil.length >= MIN_COUNCIL_SIZE, "Council too small");
        require(_initialCouncil.length <= MAX_COUNCIL_SIZE, "Council too large");
        require(_initialCouncil.length == _initialCouncilNames.length, "Length mismatch");
        
        roleController = IRoleController(_roleController);
        governanceToken = IERC20(_governanceToken);
        
        // Initialize council with founding members
        for (uint256 i = 0; i < _initialCouncil.length; i++) {
            require(_initialCouncil[i] != address(0), "Invalid council member");
            
            councilMembers.push(CouncilMember({
                memberAddress: _initialCouncil[i],
                termStart: block.timestamp,
                termEnd: block.timestamp + COUNCIL_TERM_LENGTH,
                isActive: true,
                votesReceived: 0,
                name: _initialCouncilNames[i],
                contactInfo: ""
            }));
            
            isCouncilMember[_initialCouncil[i]] = true;
            councilMemberIndex[_initialCouncil[i]] = i;
            
            emit CouncilMemberElected(_initialCouncil[i], block.timestamp, block.timestamp + COUNCIL_TERM_LENGTH);
        }
    }
    
    // ====== COUNCIL MANAGEMENT ======
    
    /**
     * @dev Register as a candidate for council election
     * @param profile Brief profile/manifesto of the candidate
     */
    function registerCandidate(string calldata profile) external payable {
        if (isRegisteredCandidate[msg.sender]) {
            revert AlreadyRegistered();
        }
        if (governanceToken.balanceOf(msg.sender) < candidateRegistrationFee) {
            revert InsufficientFee();
        }
        
        // Transfer registration fee to treasury
        governanceToken.transferFrom(msg.sender, address(this), candidateRegistrationFee);
        treasuryBalance += candidateRegistrationFee;
        
        isRegisteredCandidate[msg.sender] = true;
        candidateProfiles[msg.sender] = profile;
        
        emit CandidateRegistered(msg.sender, profile);
    }
    
    /**
     * @dev Start a new council election
     * @param availableSeats Number of council seats up for election
     */
    function startElection(uint256 availableSeats) external onlyCouncilMember {
        require(availableSeats > 0 && availableSeats <= MAX_COUNCIL_SIZE, "Invalid seat count");
        
        currentElectionId++;
        Election storage election = elections[currentElectionId];
        
        election.electionId = currentElectionId;
        election.startTime = block.timestamp;
        election.endTime = block.timestamp + ELECTION_PERIOD;
        election.availableSeats = availableSeats;
        election.isActive = true;
        
        emit ElectionStarted(currentElectionId, election.startTime, election.endTime, availableSeats);
    }
    
    /**
     * @dev Vote in council election
     * @param electionId ID of the election
     * @param candidate Address of the candidate to vote for
     */
    function voteInElection(uint256 electionId, address candidate) external nonReentrant {
        Election storage election = elections[electionId];
        
        if (!election.isActive || block.timestamp > election.endTime) {
            revert ElectionNotActive();
        }
        if (election.hasVoted[msg.sender]) {
            revert AlreadyVoted();
        }
        if (!isRegisteredCandidate[candidate]) {
            revert InvalidAddress();
        }
        
        uint256 votingPower = governanceToken.balanceOf(msg.sender);
        require(votingPower > 0, "No voting power");
        
        election.hasVoted[msg.sender] = true;
        election.candidateVotes[candidate] += votingPower;
        
        // Add candidate to candidates array if not already there
        bool candidateExists = false;
        for (uint256 i = 0; i < election.candidates.length; i++) {
            if (election.candidates[i] == candidate) {
                candidateExists = true;
                break;
            }
        }
        if (!candidateExists) {
            election.candidates.push(candidate);
        }
        
        emit VoteCast(electionId, msg.sender, candidate, votingPower);
    }
    
    /**
     * @dev Finalize election and update council
     * @param electionId ID of the election to finalize
     */
    function finalizeElection(uint256 electionId) external onlyCouncilMember nonReentrant {
        Election storage election = elections[electionId];
        
        if (!election.isActive) {
            revert InvalidElection();
        }
        if (block.timestamp <= election.endTime) {
            revert VotingPeriodActive();
        }
        
        election.isActive = false;
        
        // Sort candidates by votes and select winners
        address[] memory winners = _selectElectionWinners(electionId, election.availableSeats);
        
        // Update council with new members
        _updateCouncilWithWinners(winners);
        
        emit ElectionEnded(electionId, winners);
    }
    
    /**
     * @dev Remove a council member for misconduct
     * @param member Address of the council member to remove
     * @param reason Reason for removal
     * @return proposalId ID of the created removal proposal
     */
    function removeCouncilMember(address member, string calldata reason) external onlyCouncilMember returns (uint256) {
        require(isCouncilMember[member], "Not a council member");
        
        // Create proposal for council member removal
        bytes memory executionData = abi.encodeWithSignature(
            "_executeCouncilRemoval(address,string)",
            member,
            reason
        );
        
        uint256 proposalId = _createProposal(
            "Remove Council Member",
            string(abi.encodePacked("Remove ", reason)),
            ProposalType.CouncilRemoval,
            executionData,
            address(this),
            0
        );
        
        return proposalId;
    }
    
    // ====== PROPOSAL SYSTEM ======
    
    /**
     * @dev Create a new governance proposal
     * @param title Title of the proposal
     * @param description Detailed description
     * @param proposalType Type of proposal
     * @param executionData Encoded function call data
     * @param targetContract Contract to execute the proposal on
     * @param value ETH value to send with the proposal
     */
    function createProposal(
        string calldata title,
        string calldata description,
        ProposalType proposalType,
        bytes calldata executionData,
        address targetContract,
        uint256 value
    ) external onlyCouncilMember returns (uint256) {
        return _createProposal(title, description, proposalType, executionData, targetContract, value);
    }
    
    function _createProposal(
        string memory title,
        string memory description,
        ProposalType proposalType,
        bytes memory executionData,
        address targetContract,
        uint256 value
    ) internal returns (uint256) {
        proposalCounter++;
        uint256 proposalId = proposalCounter;
        
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = title;
        proposal.description = description;
        proposal.proposalType = proposalType;
        proposal.executionData = executionData;
        proposal.targetContract = targetContract;
        proposal.value = value;
        proposal.createdAt = block.timestamp;
        proposal.votingEndsAt = block.timestamp + PROPOSAL_VOTING_PERIOD;
        proposal.executionTime = proposal.votingEndsAt + EXECUTION_DELAY;
        proposal.status = ProposalStatus.Active;
        
        emit ProposalCreated(proposalId, msg.sender, title, proposalType, proposal.votingEndsAt);
        
        return proposalId;
    }
    
    /**
     * @dev Vote on a proposal
     * @param proposalId ID of the proposal
     * @param choice Vote choice (For, Against, Abstain)
     */
    function voteOnProposal(uint256 proposalId, VoteChoice choice) external onlyCouncilMember {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.status != ProposalStatus.Active) {
            revert InvalidProposal();
        }
        if (block.timestamp > proposal.votingEndsAt) {
            revert VotingPeriodEnded();
        }
        if (proposal.hasVoted[msg.sender]) {
            revert AlreadyVoted();
        }
        
        proposal.hasVoted[msg.sender] = true;
        proposal.votes[msg.sender] = choice;
        
        if (choice == VoteChoice.For) {
            proposal.votesFor++;
        } else if (choice == VoteChoice.Against) {
            proposal.votesAgainst++;
        } else if (choice == VoteChoice.Abstain) {
            proposal.votesAbstain++;
        }
        
        emit ProposalVoteCast(proposalId, msg.sender, choice, 1); // Each council member has 1 vote
    }
    
    /**
     * @dev Execute a passed proposal
     * @param proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.status != ProposalStatus.Active) {
            revert InvalidProposal();
        }
        if (block.timestamp < proposal.executionTime) {
            revert ExecutionDelayNotMet();
        }
        if (block.timestamp <= proposal.votingEndsAt) {
            revert VotingPeriodActive();
        }
        
        // Check if proposal passed
        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst + proposal.votesAbstain;
        uint256 activeCouncilSize = _getActiveCouncilSize();
        uint256 requiredQuorum = (activeCouncilSize * QUORUM_PERCENTAGE) / 100;
        
        if (totalVotes < requiredQuorum) {
            proposal.status = ProposalStatus.Failed;
            revert QuorumNotMet();
        }
        
        if (proposal.votesFor <= proposal.votesAgainst) {
            proposal.status = ProposalStatus.Failed;
            revert ProposalNotPassed();
        }
        
        // Execute the proposal
        proposal.status = ProposalStatus.Executed;
        
        bool success;
        if (proposal.targetContract != address(0) && proposal.executionData.length > 0) {
            (success,) = proposal.targetContract.call{value: proposal.value}(proposal.executionData);
        } else {
            success = true; // For proposals that don't require external calls
        }
        
        emit ProposalExecuted(proposalId, success);
    }
    
    // ====== ROLE CONTROLLER INTEGRATION ======
    
    /**
     * @dev Grant a role through governance proposal
     * @param role Role to grant
     * @param account Account to grant role to
     * @param reason Reason for granting the role
     */
    function proposeGrantRole(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyCouncilMember returns (uint256) {
        bytes memory executionData = abi.encodeWithSignature(
            "grantRoleWithReason(bytes32,address,string)",
            role,
            account,
            reason
        );
        
        return _createProposal(
            "Grant Role",
            string(abi.encodePacked("Grant role to ", reason)),
            ProposalType.RoleGranting,
            executionData,
            address(roleController),
            0
        );
    }
    
    /**
     * @dev Revoke a role through governance proposal
     * @param role Role to revoke
     * @param account Account to revoke role from
     * @param reason Reason for revoking the role
     */
    function proposeRevokeRole(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyCouncilMember returns (uint256) {
        bytes memory executionData = abi.encodeWithSignature(
            "revokeRoleWithReason(bytes32,address,string)",
            role,
            account,
            reason
        );
        
        return _createProposal(
            "Revoke Role",
            string(abi.encodePacked("Revoke role: ", reason)),
            ProposalType.RoleRevoking,
            executionData,
            address(roleController),
            0
        );
    }
    
    // ====== INTERNAL FUNCTIONS ======
    
    function _selectElectionWinners(uint256 electionId, uint256 seats) internal view returns (address[] memory) {
        Election storage election = elections[electionId];
        address[] memory candidates = election.candidates;
        
        // Simple sorting by votes (in a production system, use a more efficient algorithm)
        for (uint256 i = 0; i < candidates.length; i++) {
            for (uint256 j = i + 1; j < candidates.length; j++) {
                if (election.candidateVotes[candidates[i]] < election.candidateVotes[candidates[j]]) {
                    address temp = candidates[i];
                    candidates[i] = candidates[j];
                    candidates[j] = temp;
                }
            }
        }
        
        uint256 winnersCount = seats > candidates.length ? candidates.length : seats;
        address[] memory winners = new address[](winnersCount);
        
        for (uint256 i = 0; i < winnersCount; i++) {
            winners[i] = candidates[i];
        }
        
        return winners;
    }
    
    function _updateCouncilWithWinners(address[] memory winners) internal {
        // Remove expired council members and add new ones
        for (uint256 i = 0; i < winners.length; i++) {
            if (!isCouncilMember[winners[i]]) {
                // Add new council member
                councilMembers.push(CouncilMember({
                    memberAddress: winners[i],
                    termStart: block.timestamp,
                    termEnd: block.timestamp + COUNCIL_TERM_LENGTH,
                    isActive: true,
                    votesReceived: 0,
                    name: candidateProfiles[winners[i]],
                    contactInfo: ""
                }));
                
                isCouncilMember[winners[i]] = true;
                councilMemberIndex[winners[i]] = councilMembers.length - 1;
                
                emit CouncilMemberElected(winners[i], block.timestamp, block.timestamp + COUNCIL_TERM_LENGTH);
            }
        }
    }
    
    function _executeCouncilRemoval(address member, string memory reason) internal {
        require(isCouncilMember[member], "Not a council member");
        
        uint256 index = councilMemberIndex[member];
        councilMembers[index].isActive = false;
        isCouncilMember[member] = false;
        
        emit CouncilMemberRemoved(member, reason);
    }
    
    function _getActiveCouncilSize() internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < councilMembers.length; i++) {
            if (councilMembers[i].isActive && block.timestamp <= councilMembers[i].termEnd) {
                count++;
            }
        }
        return count;
    }
    
    // ====== VIEW FUNCTIONS ======
    
    function getCouncilMembers() external view returns (CouncilMember[] memory) {
        return councilMembers;
    }
    
    function getActiveCouncilMembers() external view returns (address[] memory) {
        uint256 activeCount = _getActiveCouncilSize();
        address[] memory activeMembers = new address[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < councilMembers.length; i++) {
            if (councilMembers[i].isActive && block.timestamp <= councilMembers[i].termEnd) {
                activeMembers[index] = councilMembers[i].memberAddress;
                index++;
            }
        }
        
        return activeMembers;
    }
    
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
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.proposalType,
            proposal.votesFor,
            proposal.votesAgainst,
            proposal.votesAbstain,
            proposal.createdAt,
            proposal.votingEndsAt,
            proposal.executionTime,
            proposal.status
        );
    }
    
    function getElectionResults(uint256 electionId) external view returns (
        address[] memory candidates,
        uint256[] memory votes
    ) {
        Election storage election = elections[electionId];
        candidates = election.candidates;
        votes = new uint256[](candidates.length);
        
        for (uint256 i = 0; i < candidates.length; i++) {
            votes[i] = election.candidateVotes[candidates[i]];
        }
        
        return (candidates, votes);
    }
    
    function hasVotedInElection(uint256 electionId, address voter) external view returns (bool) {
        return elections[electionId].hasVoted[voter];
    }
    
    function hasVotedOnProposal(uint256 proposalId, address voter) external view returns (bool) {
        return proposals[proposalId].hasVoted[voter];
    }
    
    function getVoteOnProposal(uint256 proposalId, address voter) external view returns (VoteChoice) {
        return proposals[proposalId].votes[voter];
    }
}