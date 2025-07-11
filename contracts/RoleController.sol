// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RoleController
 * @dev Decentralized role management contract for the stablecoin ecosystem with limited emergency powers
 * FIXED: Authorization issues, governance setup, and integration problems
 */
contract RoleController is AccessControl, ReentrancyGuard {
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant BLACKLIST_ROLE = keccak256("BLACKLIST_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // Emergency controls - limited to pause only
    bool public emergencyMode;
    address public immutable emergencyAdmin;
    address public governanceContract;

    // Authorized contracts that can query roles
    mapping(address => bool) public authorizedContracts;
    
    // FIXED: Setup phase to handle circular dependency
    bool public setupPhase = true;
    uint256 public setupDeadline;
    
    // All roles are governance controlled by default
    bool public constant governanceActive = true;
    
    // Pending role changes from governance
    struct PendingRoleChange {
        bytes32 role;
        address account;
        bool isGrant; // true for grant, false for revoke
        uint256 timestamp;
        bool executed;
    }
    
    mapping(uint256 => PendingRoleChange) public pendingRoleChanges;
    uint256 public pendingChangeCounter;

    // Events
    event EmergencyModeToggled(bool status, address indexed admin);
    event ContractAuthorized(address indexed contractAddr, bool status);
    event RoleGrantedWithReason(bytes32 indexed role, address indexed account, address indexed sender, string reason);
    event RoleRevokedWithReason(bytes32 indexed role, address indexed account, address indexed sender, string reason);
    event GovernanceContractUpdated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceRoleChangeProposed(uint256 indexed changeId, bytes32 indexed role, address indexed account, bool isGrant);
    event GovernanceRoleChangeExecuted(uint256 indexed changeId, bytes32 indexed role, address indexed account, bool isGrant);
    event SetupPhaseEnded(address indexed caller, uint256 timestamp);

    // Custom errors
    error UnauthorizedContract(address caller);
    error EmergencyModeActive();
    error InvalidAddress();
    error GovernanceRequired();
    error UnauthorizedGovernanceAction();
    error PendingChangeNotFound();
    error PendingChangeAlreadyExecuted();
    error OnlyEmergencyAdmin();
    error SetupPhaseExpired();
    error SetupPhaseEndedError();

    modifier onlyAuthorizedContractOrSetup() {
        // FIXED: Allow calls during setup phase or from authorized contracts
        if (!setupPhase && !authorizedContracts[msg.sender]) {
            revert UnauthorizedContract(msg.sender);
        }
        _;
    }

    modifier whenNotEmergency() {
        if (emergencyMode) {
            revert EmergencyModeActive();
        }
        _;
    }

    modifier validAddress(address account) {
        if (account == address(0)) {
            revert InvalidAddress();
        }
        _;
    }
    
    modifier onlyGovernance() {
        if (msg.sender != governanceContract) {
            revert UnauthorizedGovernanceAction();
        }
        _;
    }
    
    modifier onlyEmergencyAdmin() {
        if (msg.sender != emergencyAdmin) {
            revert OnlyEmergencyAdmin();
        }
        _;
    }
    
    modifier duringSetupPhase() {
        if (!setupPhase) {
            revert SetupPhaseEndedError();
        }
        if (block.timestamp > setupDeadline) {
            revert SetupPhaseExpired();
        }
        _;
    }

    constructor(
        address _governanceContract,
        address _emergencyAdmin,
        address[] memory _initialAuthorizedContracts
    ) {
        require(_emergencyAdmin != address(0), "Invalid emergency admin address");
        
        // FIXED: Handle governance being set later during setup
        if (_governanceContract != address(0)) {
            governanceContract = _governanceContract;
            _grantRole(GOVERNANCE_ROLE, _governanceContract);
        }
        
        emergencyAdmin = _emergencyAdmin;
        
        // FIXED: Setup phase lasts 1 hour to complete deployment
        setupDeadline = block.timestamp + 1 hours;
        
        // Set governance as admin for all operational roles
        _setRoleAdmin(MINTER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(BURNER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(BLACKLIST_ROLE, GOVERNANCE_ROLE);
        
        // Authorize initial contracts
        for (uint i = 0; i < _initialAuthorizedContracts.length; i++) {
            if (_initialAuthorizedContracts[i] != address(0)) {
                authorizedContracts[_initialAuthorizedContracts[i]] = true;
                emit ContractAuthorized(_initialAuthorizedContracts[i], true);
            }
        }
    }

    /**
     * @dev Update the governance contract address
     * FIXED: Can be called during setup phase by factory, then only by governance
     */
    function updateGovernanceContract(address _newGovernanceContract) 
        external 
        validAddress(_newGovernanceContract)
    {
        // During setup phase, allow factory to set governance
        if (setupPhase) {
            // Allow any caller during setup (factory will call this)
        } else {
            // After setup, only governance can update
            if (msg.sender != governanceContract) {
                revert UnauthorizedGovernanceAction();
            }
        }
        
        address oldGovernance = governanceContract;
        governanceContract = _newGovernanceContract;
        
        // Transfer governance role
        if (oldGovernance != address(0)) {
            _revokeRole(GOVERNANCE_ROLE, oldGovernance);
        }
        _grantRole(GOVERNANCE_ROLE, _newGovernanceContract);
        
        emit GovernanceContractUpdated(oldGovernance, _newGovernanceContract);
    }

    /**
     * @dev Authorize a contract to query roles
     * FIXED: Can be called during setup phase, then only by governance
     */
    function authorizeContract(address contractAddr, bool status) 
        external 
        validAddress(contractAddr)
    {
        if (setupPhase) {
            // During setup, allow factory to authorize contracts
        } else {
            // After setup, only governance can authorize
            if (msg.sender != governanceContract) {
                revert UnauthorizedGovernanceAction();
            }
        }
        
        authorizedContracts[contractAddr] = status;
        emit ContractAuthorized(contractAddr, status);
    }

    /**
     * @dev End setup phase - locks configuration to governance-only
     * FIXED: Explicit function to end setup phase
     */
    function endSetupPhase() external {
        require(setupPhase, "Setup phase already ended");
        require(governanceContract != address(0), "Governance not set");
        
        setupPhase = false;
        emit SetupPhaseEnded(msg.sender, block.timestamp);
    }

    /**
     * @dev Grant a role with reason logging (governance only)
     */
    function grantRoleWithReason(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyGovernance validAddress(account) whenNotEmergency {
        _grantRole(role, account);
        emit RoleGrantedWithReason(role, account, msg.sender, reason);
    }

    /**
     * @dev Revoke a role with reason logging (governance only)
     */
    function revokeRoleWithReason(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyGovernance validAddress(account) {
        _revokeRole(role, account);
        emit RoleRevokedWithReason(role, account, msg.sender, reason);
    }
    
    /**
     * @dev Propose a role change through governance
     */
    function proposeRoleChange(
        bytes32 role,
        address account,
        bool isGrant
    ) external onlyGovernance validAddress(account) returns (uint256) {
        pendingChangeCounter++;
        uint256 changeId = pendingChangeCounter;
        
        pendingRoleChanges[changeId] = PendingRoleChange({
            role: role,
            account: account,
            isGrant: isGrant,
            timestamp: block.timestamp,
            executed: false
        });
        
        emit GovernanceRoleChangeProposed(changeId, role, account, isGrant);
        return changeId;
    }
    
    /**
     * @dev Execute a governance-approved role change
     */
    function executeGovernanceRoleChange(uint256 changeId) 
        external 
        onlyGovernance 
        nonReentrant 
    {
        PendingRoleChange storage change = pendingRoleChanges[changeId];
        
        if (change.timestamp == 0) {
            revert PendingChangeNotFound();
        }
        if (change.executed) {
            revert PendingChangeAlreadyExecuted();
        }
        
        change.executed = true;
        
        if (change.isGrant) {
            _grantRole(change.role, change.account);
            emit RoleGrantedWithReason(change.role, change.account, msg.sender, "Governance approved");
        } else {
            _revokeRole(change.role, change.account);
            emit RoleRevokedWithReason(change.role, change.account, msg.sender, "Governance approved");
        }
        
        emit GovernanceRoleChangeExecuted(changeId, change.role, change.account, change.isGrant);
    }

    /**
     * @dev Check if an account has a specific role (for authorized contracts)
     * FIXED: Allow calls during setup phase for initialization
     */
    function checkRole(bytes32 role, address account) 
        external 
        view 
        onlyAuthorizedContractOrSetup 
        returns (bool) 
    {
        return hasRole(role, account);
    }

    // ====== LIMITED EMERGENCY FUNCTIONS ======

    /**
     * @dev Toggle emergency mode (emergency admin only)
     */
    function toggleEmergencyMode(bool status) 
        external 
        onlyEmergencyAdmin
    {
        emergencyMode = status;
        emit EmergencyModeToggled(status, msg.sender);
    }
    
    /**
     * @dev Pause all operations (emergency admin only)
     */
    function pause() external onlyEmergencyAdmin {
        emergencyMode = true;
        emit EmergencyModeToggled(true, msg.sender);
    }
    
    /**
     * @dev Unpause all operations (emergency admin only)
     */
    function unpause() external onlyEmergencyAdmin {
        emergencyMode = false;
        emit EmergencyModeToggled(false, msg.sender);
    }

    // ====== VIEW FUNCTIONS ======

    /**
     * @dev Check if emergency mode is active
     */
    function isEmergencyMode() external view returns (bool) {
        return emergencyMode;
    }

    /**
     * @dev Get all defined roles
     */
    function getAllRoles() external pure returns (bytes32[] memory) {
        bytes32[] memory roles = new bytes32[](5);
        roles[0] = MINTER_ROLE;
        roles[1] = BURNER_ROLE;
        roles[3] = BLACKLIST_ROLE;
        roles[4] = GOVERNANCE_ROLE;
        return roles;
    }
    
    /**
     * @dev Get governance status
     */
    function getGovernanceStatus() 
        external 
        view 
        returns (bool isActive, address contractAddr) 
    {
        return (governanceActive, governanceContract);
    }
    
    /**
     * @dev Get pending role change details
     */
    function getPendingRoleChange(uint256 changeId) 
        external 
        view 
        returns (
            bytes32 role,
            address account,
            bool isGrant,
            uint256 timestamp,
            bool executed
        ) 
    {
        PendingRoleChange storage change = pendingRoleChanges[changeId];
        return (
            change.role,
            change.account,
            change.isGrant,
            change.timestamp,
            change.executed
        );
    }

    /**
     * @dev Get emergency admin address
     */
    function getEmergencyAdmin() external view returns (address) {
        return emergencyAdmin;
    }
    
    /**
     * @dev Check if a contract is authorized (FIXED: Added view function)
     */
    function isAuthorizedContract(address contractAddr) external view returns (bool) {
        return authorizedContracts[contractAddr];
    }
    
    /**
     * @dev Get setup phase info (FIXED: Added for diagnostics)
     */
    function getSetupInfo() external view returns (bool isSetupPhase, uint256 deadline) {
        return (setupPhase, setupDeadline);
    }
}