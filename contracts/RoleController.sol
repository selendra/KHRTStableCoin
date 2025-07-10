// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RoleController
 * @dev Decentralized role management contract for the stablecoin ecosystem with limited emergency powers
 * Features:
 * - Governance-controlled role management
 * - Limited emergency controls (pause only)
 * - Role delegation
 * - Audit trail for role changes
 * - No centralized admin role
 */
contract RoleController is AccessControl, ReentrancyGuard {
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BLACKLIST_ROLE = keccak256("BLACKLIST_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // Emergency controls - limited to pause only
    bool public emergencyMode;
    address public immutable emergencyAdmin;
    address public governanceContract;

    // Authorized contracts that can query roles
    mapping(address => bool) public authorizedContracts;
    
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
    event EmergencyAdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // Custom errors
    error UnauthorizedContract(address caller);
    error EmergencyModeActive();
    error InvalidAddress();
    error GovernanceRequired();
    error UnauthorizedGovernanceAction();
    error PendingChangeNotFound();
    error PendingChangeAlreadyExecuted();
    error OnlyEmergencyAdmin();
    error OnlyEmergencyMode();

    modifier onlyAuthorizedContract() {
        if (!authorizedContracts[msg.sender]) {
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

    constructor(
        address _governanceContract,
        address _emergencyAdmin,
        address[] memory _initialAuthorizedContracts
    ) {
        require(_governanceContract != address(0), "Invalid governance address");
        require(_emergencyAdmin != address(0), "Invalid emergency admin address");
        
        // Set governance contract
        governanceContract = _governanceContract;
        emergencyAdmin = _emergencyAdmin;
        
        // Grant governance role to the governance contract
        _grantRole(GOVERNANCE_ROLE, _governanceContract);
        
        // Set governance as admin for all operational roles
        _setRoleAdmin(MINTER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(BURNER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(BLACKLIST_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(PAUSER_ROLE, GOVERNANCE_ROLE);
        
        // Authorize initial contracts
        for (uint i = 0; i < _initialAuthorizedContracts.length; i++) {
            if (_initialAuthorizedContracts[i] != address(0)) {
                authorizedContracts[_initialAuthorizedContracts[i]] = true;
                emit ContractAuthorized(_initialAuthorizedContracts[i], true);
            }
        }
    }

    /**
     * @dev Update the governance contract address (only governance can do this)
     * @param _newGovernanceContract Address of the new governance contract
     */
    function updateGovernanceContract(address _newGovernanceContract) 
        external 
        onlyGovernance
        validAddress(_newGovernanceContract)
    {
        address oldGovernance = governanceContract;
        governanceContract = _newGovernanceContract;
        
        // Transfer governance role
        _revokeRole(GOVERNANCE_ROLE, oldGovernance);
        _grantRole(GOVERNANCE_ROLE, _newGovernanceContract);
        
        emit GovernanceContractUpdated(oldGovernance, _newGovernanceContract);
    }

    /**
     * @dev Grant a role with reason logging (governance only)
     * @param role Role to grant
     * @param account Account to grant role to
     * @param reason Reason for granting the role
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
     * @param role Role to revoke
     * @param account Account to revoke role from
     * @param reason Reason for revoking the role
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
     * @param role Role to change
     * @param account Account to grant/revoke role to/from
     * @param isGrant True for grant, false for revoke
     * @return changeId Unique identifier for this change
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
     * @param changeId ID of the pending change to execute
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
     * @param role Role to check
     * @param account Account to check
     * @return bool True if account has the role
     */
    function checkRole(bytes32 role, address account) 
        external 
        view 
        onlyAuthorizedContract 
        returns (bool) 
    {
        return hasRole(role, account);
    }

    /**
     * @dev Authorize a contract to query roles (governance only)
     * @param contractAddr Contract address to authorize
     * @param status True to authorize, false to deauthorize
     */
    function authorizeContract(address contractAddr, bool status) 
        external 
        onlyGovernance
        validAddress(contractAddr)
    {
        authorizedContracts[contractAddr] = status;
        emit ContractAuthorized(contractAddr, status);
    }

    // ====== LIMITED EMERGENCY FUNCTIONS ======

    /**
     * @dev Toggle emergency mode (emergency admin only)
     * Can only pause/unpause - no role modifications
     * @param status True to enable emergency mode, false to disable
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

    /**
     * @dev Update emergency admin (governance only)
     * @param newEmergencyAdmin New emergency admin address
     * @notice This function always reverts since emergency admin is immutable
     */
    function updateEmergencyAdmin(address newEmergencyAdmin) 
        external 
        view
        onlyGovernance
        validAddress(newEmergencyAdmin)
    {
        // Note: emergencyAdmin is immutable, so this function will revert
        // This is intentional - emergency admin should be set at deployment
        // Keeping function for interface compatibility but it will always revert
        revert("Emergency admin is immutable");
    }

    // ====== VIEW FUNCTIONS ======

    /**
     * @dev Check if emergency mode is active
     * @return bool True if emergency mode is active
     */
    function isEmergencyMode() external view returns (bool) {
        return emergencyMode;
    }

    /**
     * @dev Get all defined roles
     * @return bytes32[] Array of all role identifiers
     */
    function getAllRoles() external pure returns (bytes32[] memory) {
        bytes32[] memory roles = new bytes32[](5);
        roles[0] = MINTER_ROLE;
        roles[1] = BURNER_ROLE;
        roles[2] = PAUSER_ROLE;
        roles[3] = BLACKLIST_ROLE;
        roles[4] = GOVERNANCE_ROLE;
        return roles;
    }
    
    /**
     * @dev Get governance status
     * @return isActive True if governance is active (always true)
     * @return contractAddr Address of the governance contract
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
     * @param changeId ID of the pending change
     * @return role Role being changed
     * @return account Account being granted/revoked
     * @return isGrant True for grant, false for revoke
     * @return timestamp When the change was proposed
     * @return executed Whether the change has been executed
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
     * @return address Emergency admin address
     */
    function getEmergencyAdmin() external view returns (address) {
        return emergencyAdmin;
    }
}