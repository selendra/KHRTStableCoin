// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RoleController
 * @dev Centralized role management contract for the stablecoin ecosystem
 * Features:
 * - Centralized role management
 * - Emergency controls
 * - Role delegation
 * - Audit trail for role changes
 */
contract RoleController is AccessControl, ReentrancyGuard {
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BLACKLIST_ROLE = keccak256("BLACKLIST_ROLE");
    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");

    // Emergency controls
    bool public emergencyMode;
    address public emergencyAdmin;

    // Authorized contracts that can query roles
    mapping(address => bool) public authorizedContracts;

    // Events
    event EmergencyModeToggled(bool status, address indexed admin);
    event EmergencyAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event ContractAuthorized(address indexed contractAddr, bool status);
    event RoleGrantedWithReason(bytes32 indexed role, address indexed account, address indexed sender, string reason);
    event RoleRevokedWithReason(bytes32 indexed role, address indexed account, address indexed sender, string reason);

    // Custom errors
    error UnauthorizedContract(address caller);
    error EmergencyModeActive();
    error InvalidAddress();
    error InvalidRole();

    modifier onlyAuthorizedContract() {
        if (!authorizedContracts[msg.sender] && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
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

    constructor(address admin, address _emergencyAdmin) {
        require(admin != address(0), "Invalid admin address");
        require(_emergencyAdmin != address(0), "Invalid emergency admin address");
        
        // Grant admin roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROLE_ADMIN, admin);
        
        // Set emergency admin
        emergencyAdmin = _emergencyAdmin;
        
        // Grant emergency admin the ability to pause in emergencies
        _grantRole(PAUSER_ROLE, _emergencyAdmin);
    }

    /**
     * @dev Grant a role with reason logging
     * @param role Role to grant
     * @param account Account to grant role to
     * @param reason Reason for granting the role
     */
    function grantRoleWithReason(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyRole(getRoleAdmin(role)) validAddress(account) whenNotEmergency {
        grantRole(role, account);
        emit RoleGrantedWithReason(role, account, msg.sender, reason);
    }

    /**
     * @dev Revoke a role with reason logging
     * @param role Role to revoke
     * @param account Account to revoke role from
     * @param reason Reason for revoking the role
     */
    function revokeRoleWithReason(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyRole(getRoleAdmin(role)) validAddress(account) {
        revokeRole(role, account);
        emit RoleRevokedWithReason(role, account, msg.sender, reason);
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
     * @dev Authorize a contract to query roles
     * @param contractAddr Contract address to authorize
     * @param status True to authorize, false to deauthorize
     */
    function authorizeContract(address contractAddr, bool status) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        validAddress(contractAddr)
    {
        authorizedContracts[contractAddr] = status;
        emit ContractAuthorized(contractAddr, status);
    }

    /**
     * @dev Toggle emergency mode
     * @param status True to enable emergency mode, false to disable
     */
    function toggleEmergencyMode(bool status) 
        external 
    {
        require(
            msg.sender == emergencyAdmin || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Not authorized for emergency controls"
        );
        
        emergencyMode = status;
        emit EmergencyModeToggled(status, msg.sender);
    }

    /**
     * @dev Update emergency admin
     * @param newEmergencyAdmin New emergency admin address
     */
    function updateEmergencyAdmin(address newEmergencyAdmin) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE)
        validAddress(newEmergencyAdmin)
    {
        address oldAdmin = emergencyAdmin;
        emergencyAdmin = newEmergencyAdmin;
        
        // Transfer pauser role
        if (hasRole(PAUSER_ROLE, oldAdmin)) {
            revokeRole(PAUSER_ROLE, oldAdmin);
        }
        grantRole(PAUSER_ROLE, newEmergencyAdmin);
        
        emit EmergencyAdminUpdated(oldAdmin, newEmergencyAdmin);
    }

    /**
     * @dev Emergency role revocation (emergency admin only)
     * @param role Role to revoke
     * @param account Account to revoke role from
     */
    function emergencyRevokeRole(bytes32 role, address account) 
        external 
        validAddress(account)
    {
        require(msg.sender == emergencyAdmin, "Only emergency admin");
        revokeRole(role, account);
        emit RoleRevokedWithReason(role, account, msg.sender, "Emergency revocation");
    }

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
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = MINTER_ROLE;
        roles[2] = BURNER_ROLE;
        roles[3] = PAUSER_ROLE;
        roles[4] = BLACKLIST_ROLE;
        return roles;
    }
}