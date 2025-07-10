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
 * - Fixed stack depth issues
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
    
    // NEW: Parameter structs to avoid stack depth issues
    struct ProposalParams {
        string title;
        string description;
        ProposalType proposalType;
        bytes executionData;
        address targetContract;
        uint256 value;
    }
    
    struct RoleProposalParams {
        bytes32 role;
        address account;
        string reason;
        bool isGrant;
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
        _validateConstructorParams(_roleController, _governanceToken, _initialCouncil, _initialCouncilNames);
        _initializeContracts(_roleController, _governanceToken);
        _initializeCouncil(_initialCouncil, _initialCouncilNames);
    }
    
    // ====== CONSTRUCTOR HELPERS (FIXED FOR STACK DEPTH) ======
    
    function _validateConstructorParams(
        address _roleController,
        address _governanceToken,
        address[] memory _initialCouncil,
        string[] memory _initialCouncilNames
    ) internal pure {
        require(_roleController != address(0), "Invalid role controller");
        require(_governanceToken != address(0), "Invalid governance token");
        require(_initialCouncil.length >= MIN_COUNCIL_SIZE, "Council too small");
        require(_initialCouncil.length <= MAX_COUNCIL_SIZE, "Council too large");
        require(_initialCouncil.length == _initialCouncilNames.length, "Length mismatch");
    }
    
    function _initializeContracts(address _roleController, address _governanceToken) internal {
        roleController = IRoleController(_roleController);
        governanceToken = IERC20(_governanceToken);
    }
    
    function _initializeCouncil(
        address[] memory _initialCouncil,
        string[] memory _initialCouncilNames
    ) internal {
        for (uint256 i = 0; i < _initialCouncil.length; i++) {
            _addCouncilMember(_initialCouncil[i], _initialCouncilNames[i]);
        }
    }
    
    function _addCouncilMember(address memberAddr, string memory name) internal {
        require(memberAddr != address(0), "Invalid council member");
        
        uint256 termStart = block.timestamp;
        uint256 termEnd = block.timestamp + COUNCIL_TERM_LENGTH;
        
        councilMembers.push(CouncilMember({
            memberAddress: memberAddr,
            termStart: termStart,
            termEnd: termEnd,
            isActive: true,
            votesReceived: 0,
            name: name,
            contactInfo: ""
        }));
        
        isCouncilMember[memberAddr] = true;
        councilMemberIndex[memberAddr] = councilMembers.length - 1;
        
        emit CouncilMemberElected(memberAddr, termStart, termEnd);
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
        _validateElectionStart(availableSeats);
        _createNewElection(availableSeats);
    }
    
    function _validateElectionStart(uint256 availableSeats) internal pure {
        require(availableSeats > 0 && availableSeats <= MAX_COUNCIL_SIZE, "Invalid seat count");
    }
    
    function _createNewElection(uint256 availableSeats) internal {
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
     * @dev Vote in council election (FIXED FOR STACK DEPTH)
     * @param electionId ID of the election
     * @param candidate Address of the candidate to vote for
     */
    function voteInElection(uint256 electionId, address candidate) external nonReentrant {
        _validateElectionVote(electionId, candidate);
        _recordElectionVote(electionId, candidate);
    }
    
    function _validateElectionVote(uint256 electionId, address candidate) internal view {
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
    }
    
    function _recordElectionVote(uint256 electionId, address candidate) internal {
        Election storage election = elections[electionId];
        uint256 votingPower = governanceToken.balanceOf(msg.sender);
        require(votingPower > 0, "No voting power");
        
        election.hasVoted[msg.sender] = true;
        election.candidateVotes[candidate] += votingPower;
        
        _addCandidateIfNew(electionId, candidate);
        
        emit VoteCast(electionId, msg.sender, candidate, votingPower);
    }
    
    function _addCandidateIfNew(uint256 electionId, address candidate) internal {
        Election storage election = elections[electionId];
        
        // Check if candidate already exists
        for (uint256 i = 0; i < election.candidates.length; i++) {
            if (election.candidates[i] == candidate) {
                return; // Candidate already exists
            }
        }
        
        // Add new candidate
        election.candidates.push(candidate);
    }
    
    /**
     * @dev Finalize election and update council (FIXED FOR STACK DEPTH)
     * @param electionId ID of the election to finalize
     */
    function finalizeElection(uint256 electionId) external onlyCouncilMember nonReentrant {
        _validateElectionForFinalization(electionId);
        _processElectionResults(electionId);
    }
    
    function _validateElectionForFinalization(uint256 electionId) internal {
        Election storage election = elections[electionId];
        
        if (!election.isActive) {
            revert InvalidElection();
        }
        if (block.timestamp <= election.endTime) {
            revert VotingPeriodActive();
        }
        
        election.isActive = false;
    }
    
    function _processElectionResults(uint256 electionId) internal {
        Election storage election = elections[electionId];
        address[] memory winners = _selectElectionWinners(electionId, election.availableSeats);
        _updateCouncilWithWinners(winners);
        emit ElectionEnded(electionId, winners);
    }
    
    /**
     * @dev Remove a council member for misconduct (FIXED FOR STACK DEPTH)
     * @param member Address of the council member to remove
     * @param reason Reason for removal
     * @return proposalId ID of the created removal proposal
     */
    function removeCouncilMember(address member, string calldata reason) external onlyCouncilMember returns (uint256) {
        require(isCouncilMember[member], "Not a council member");
        return _createRemovalProposal(member, reason);
    }
    
    function _createRemovalProposal(address member, string memory reason) internal returns (uint256) {
        bytes memory executionData = abi.encodeWithSignature(
            "_executeCouncilRemoval(address,string)",
            member,
            reason
        );
        
        ProposalParams memory params = ProposalParams({
            title: "Remove Council Member",
            description: string(abi.encodePacked("Remove ", reason)),
            proposalType: ProposalType.CouncilRemoval,
            executionData: executionData,
            targetContract: address(this),
            value: 0
        });
        
        return _createProposal(params);
    }
    
    // ====== PROPOSAL SYSTEM (FIXED FOR STACK DEPTH) ======
    
    /**
     * @dev Create a new governance proposal (FIXED SIGNATURE FOR STACK DEPTH)
     * @param params Proposal parameters struct
     */
    function createProposal(ProposalParams calldata params) 
        external 
        onlyCouncilMember 
        returns (uint256) 
    {
        return _createProposal(params);
    }
    
    function _createProposal(ProposalParams memory params) internal returns (uint256) {
        proposalCounter++;
        uint256 proposalId = proposalCounter;
        
        // Initialize proposal in smaller chunks to avoid stack depth
        _initializeProposalBasic(proposalId, params.title, params.description);
        _initializeProposalType(proposalId, params.proposalType);
        _setProposalExecution(proposalId, params.executionData, params.targetContract, params.value);
        _setProposalTiming(proposalId);
        
        emit ProposalCreated(proposalId, msg.sender, params.title, params.proposalType, 
            block.timestamp + PROPOSAL_VOTING_PERIOD);
        
        return proposalId;
    }
    
    function _initializeProposalBasic(
        uint256 proposalId,
        string memory title,
        string memory description
    ) internal {
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = title;
        proposal.description = description;
    }
    
    function _initializeProposalType(
        uint256 proposalId,
        ProposalType proposalType
    ) internal {
        proposals[proposalId].proposalType = proposalType;
        proposals[proposalId].status = ProposalStatus.Active;
    }
    
    function _setProposalExecution(
        uint256 proposalId,
        bytes memory executionData,
        address targetContract,
        uint256 value
    ) internal {
        Proposal storage proposal = proposals[proposalId];
        proposal.executionData = executionData;
        proposal.targetContract = targetContract;
        proposal.value = value;
    }
    
    function _setProposalTiming(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        proposal.createdAt = block.timestamp;
        proposal.votingEndsAt = block.timestamp + PROPOSAL_VOTING_PERIOD;
        proposal.executionTime = proposal.votingEndsAt + EXECUTION_DELAY;
    }
    
    /**
     * @dev Vote on a proposal
     * @param proposalId ID of the proposal
     * @param choice Vote choice (For, Against, Abstain)
     */
    function voteOnProposal(uint256 proposalId, VoteChoice choice) external onlyCouncilMember {
        _validateVoteOnProposal(proposalId, choice);
        _recordVote(proposalId, choice);
    }
    
    function _validateVoteOnProposal(uint256 proposalId, VoteChoice choice) internal view {
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
    }
    
    function _recordVote(uint256 proposalId, VoteChoice choice) internal {
        Proposal storage proposal = proposals[proposalId];
        
        proposal.hasVoted[msg.sender] = true;
        proposal.votes[msg.sender] = choice;
        
        if (choice == VoteChoice.For) {
            proposal.votesFor++;
        } else if (choice == VoteChoice.Against) {
            proposal.votesAgainst++;
        } else if (choice == VoteChoice.Abstain) {
            proposal.votesAbstain++;
        }
        
        emit ProposalVoteCast(proposalId, msg.sender, choice, 1);
    }
    
    /**
     * @dev Execute a passed proposal (FIXED FOR STACK DEPTH)
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        // Step 1: Basic validation
        _validateProposalExists(proposalId);
        
        // Step 2: Timing and status validation  
        _validateProposalTiming(proposalId);
        
        // Step 3: Voting validation
        _validateProposalVotes(proposalId);
        
        // Step 4: Execute
        _executeProposalAction(proposalId);
    }
    
    function _validateProposalExists(uint256 proposalId) internal view {
        if (proposals[proposalId].status != ProposalStatus.Active) {
            revert InvalidProposal();
        }
    }
    
    function _validateProposalTiming(uint256 proposalId) internal view {
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp < proposal.executionTime) {
            revert ExecutionDelayNotMet();
        }
        if (block.timestamp <= proposal.votingEndsAt) {
            revert VotingPeriodActive();
        }
    }
    
    function _validateProposalVotes(uint256 proposalId) internal view {
        Proposal storage proposal = proposals[proposalId];
        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst + proposal.votesAbstain;
        uint256 requiredQuorum = (_getActiveCouncilSize() * QUORUM_PERCENTAGE) / 100;
        
        if (totalVotes < requiredQuorum) {
            revert QuorumNotMet();
        }
        if (proposal.votesFor <= proposal.votesAgainst) {
            revert ProposalNotPassed();
        }
    }
    
    function _executeProposalAction(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        proposal.status = ProposalStatus.Executed;
        
        bool success = true;
        if (proposal.targetContract != address(0) && proposal.executionData.length > 0) {
            (success,) = proposal.targetContract.call{value: proposal.value}(proposal.executionData);
        }
        
        emit ProposalExecuted(proposalId, success);
    }
    
    // ====== ROLE CONTROLLER INTEGRATION (FIXED FOR STACK DEPTH) ======
    
    /**
     * @dev Grant a role through governance proposal (FIXED FOR STACK DEPTH)
     * @param role Role to grant
     * @param account Account to grant role to
     * @param reason Reason for granting the role
     */
    function proposeGrantRole(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyCouncilMember returns (uint256) {
        return _proposeRoleChange(RoleProposalParams({
            role: role,
            account: account,
            reason: reason,
            isGrant: true
        }));
    }
    
    /**
     * @dev Revoke a role through governance proposal (FIXED FOR STACK DEPTH)
     * @param role Role to revoke
     * @param account Account to revoke role from
     * @param reason Reason for revoking the role
     */
    function proposeRevokeRole(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyCouncilMember returns (uint256) {
        return _proposeRoleChange(RoleProposalParams({
            role: role,
            account: account,
            reason: reason,
            isGrant: false
        }));
    }
    
    function _proposeRoleChange(RoleProposalParams memory params) internal returns (uint256) {
        string memory action = params.isGrant ? "Grant" : "Revoke";
        string memory functionSig = params.isGrant ? 
            "grantRoleWithReason(bytes32,address,string)" : 
            "revokeRoleWithReason(bytes32,address,string)";
            
        bytes memory executionData = abi.encodeWithSignature(
            functionSig,
            params.role,
            params.account,
            params.reason
        );
        
        ProposalParams memory proposalParams = ProposalParams({
            title: string(abi.encodePacked(action, " Role")),
            description: string(abi.encodePacked(action, " role: ", params.reason)),
            proposalType: params.isGrant ? ProposalType.RoleGranting : ProposalType.RoleRevoking,
            executionData: executionData,
            targetContract: address(roleController),
            value: 0
        });
        
        return _createProposal(proposalParams);
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
        for (uint256 i = 0; i < winners.length; i++) {
            _addNewCouncilMember(winners[i]);
        }
    }
    
    function _addNewCouncilMember(address winner) internal {
        if (!isCouncilMember[winner]) {
            uint256 termStart = block.timestamp;
            uint256 termEnd = block.timestamp + COUNCIL_TERM_LENGTH;
            
            councilMembers.push(CouncilMember({
                memberAddress: winner,
                termStart: termStart,
                termEnd: termEnd,
                isActive: true,
                votesReceived: 0,
                name: candidateProfiles[winner],
                contactInfo: ""
            }));
            
            isCouncilMember[winner] = true;
            councilMemberIndex[winner] = councilMembers.length - 1;
            
            emit CouncilMemberElected(winner, termStart, termEnd);
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
    
    // ====== OPTIMIZED VIEW FUNCTIONS (ALREADY FIXED FOR STACK DEPTH) ======
    
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
    
    /**
     * @dev Get basic proposal information (avoids stack too deep)
     */
    function getProposalBasicInfo(uint256 proposalId) external view returns (
        uint256 id,
        address proposer,
        string memory title,
        string memory description,
        ProposalType proposalType,
        ProposalStatus status
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.proposalType,
            proposal.status
        );
    }
    
    /**
     * @dev Get proposal voting information (avoids stack too deep)
     */
    function getProposalVotingInfo(uint256 proposalId) external view returns (
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        uint256 createdAt,
        uint256 votingEndsAt,
        uint256 executionTime
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.votesFor,
            proposal.votesAgainst,
            proposal.votesAbstain,
            proposal.createdAt,
            proposal.votingEndsAt,
            proposal.executionTime
        );
    }
    
    /**
     * @dev Get proposal execution data (avoids stack too deep)
     */
    function getProposalExecutionData(uint256 proposalId) external view returns (
        bytes memory executionData,
        address targetContract,
        uint256 value
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.executionData,
            proposal.targetContract,
            proposal.value
        );
    }
    
    /**
     * @dev Get election candidates
     */
    function getElectionCandidates(uint256 electionId) external view returns (address[] memory) {
        return elections[electionId].candidates;
    }
    
    /**
     * @dev Get vote counts for election candidates
     */
    function getElectionVotes(uint256 electionId) external view returns (uint256[] memory) {
        Election storage election = elections[electionId];
        uint256[] memory votes = new uint256[](election.candidates.length);
        
        for (uint256 i = 0; i < election.candidates.length; i++) {
            votes[i] = election.candidateVotes[election.candidates[i]];
        }
        
        return votes;
    }
    
    /**
     * @dev Get election basic info
     */
    function getElectionInfo(uint256 electionId) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 availableSeats,
        bool isActive
    ) {
        Election storage election = elections[electionId];
        return (
            election.startTime,
            election.endTime,
            election.availableSeats,
            election.isActive
        );
    }
    
    /**
     * @dev Get combined election results (replaces old getElectionResults)
     */
    function getElectionResults(uint256 electionId) external view returns (
        address[] memory candidates,
        uint256[] memory votes
    ) {
        candidates = this.getElectionCandidates(electionId);
        votes = this.getElectionVotes(electionId);
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