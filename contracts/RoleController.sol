// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title RoleController
 * @dev Decentralized role management contract for the stablecoin ecosystem.
 * Includes governance-based role control and limited emergency pause mechanism.
 */
contract RoleController is AccessControl, ReentrancyGuard {
    using Address for address;

    // ====== ROLE CONSTANTS ======
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant BLACKLIST_ROLE = keccak256("BLACKLIST_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // ====== STATE VARIABLES ======

    /// @notice Emergency mode flag
    bool public emergencyMode;

    /// @notice Immutable emergency admin
    address public immutable emergencyAdmin;

    /// @notice Governance contract (assigned GOV_ROLE)
    address public governanceContract;

    /// @notice Fixed: Allow authorized contracts to query roles
    mapping(address => bool) public authorizedContracts;

    /// @notice Setup phase state
    bool public setupPhase = true;
    uint256 public setupDeadline;

    /// @notice Pending role change proposals
    struct PendingRoleChange {
        bytes32 role;
        address account;
        bool isGrant;
        uint256 timestamp;
        bool executed;
    }

    mapping(uint256 => PendingRoleChange) public pendingRoleChanges;
    uint256 public pendingChangeCounter;

    // ====== CONSTANTS ======
    bool public constant governanceActive = true;

    // ====== EVENTS ======

    event EmergencyModeToggled(bool status, address indexed admin);
    event ContractAuthorized(address indexed contractAddr, bool status);
    event RoleGrantedWithReason(bytes32 indexed role, address indexed account, address indexed sender, string reason);
    event RoleRevokedWithReason(bytes32 indexed role, address indexed account, address indexed sender, string reason);
    event GovernanceContractUpdated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceRoleChangeProposed(uint256 indexed changeId, bytes32 indexed role, address indexed account, bool isGrant);
    event GovernanceRoleChangeExecuted(uint256 indexed changeId, bytes32 indexed role, address indexed account, bool isGrant);
    event SetupPhaseEnded(address indexed caller, uint256 timestamp);

    // ====== ERRORS ======

    error UnauthorizedContract(address caller);
    error EmergencyModeActive();
    error InvalidAddress();
    error UnauthorizedGovernanceAction();
    error PendingChangeNotFound();
    error PendingChangeAlreadyExecuted();
    error OnlyEmergencyAdmin();
    error SetupPhaseExpired();
    error SetupPhaseEndedError();

    // ====== MODIFIERS ======

    modifier onlyAuthorizedContractOrSetup() {
        if (!setupPhase && !authorizedContracts[msg.sender]) {
            revert UnauthorizedContract(msg.sender);
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

    modifier validAddress(address account) {
        if (account == address(0)) {
            revert InvalidAddress();
        }
        _;
    }

    modifier whenNotEmergency() {
        if (emergencyMode) {
            revert EmergencyModeActive();
        }
        _;
    }

    modifier duringSetupPhase() {
        if (!setupPhase) revert SetupPhaseEndedError();
        if (block.timestamp > setupDeadline) revert SetupPhaseExpired();
        _;
    }

    // ====== CONSTRUCTOR ======

    constructor(
        address _governanceContract,
        address _emergencyAdmin,
        address[] memory _initialAuthorizedContracts
    ) {
        require(_emergencyAdmin != address(0), "Invalid emergency admin");

        emergencyAdmin = _emergencyAdmin;
        setupDeadline = block.timestamp + 1 hours;

        if (_governanceContract != address(0)) {
            governanceContract = _governanceContract;
            _grantRole(GOVERNANCE_ROLE, _governanceContract);
        }

        _setRoleAdmin(MINTER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(BURNER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(BLACKLIST_ROLE, GOVERNANCE_ROLE);

        for (uint i = 0; i < _initialAuthorizedContracts.length; i++) {
            address c = _initialAuthorizedContracts[i];
            if (c != address(0)) {
                authorizedContracts[c] = true;
                emit ContractAuthorized(c, true);
            }
        }
    }

    // ====== GOVERNANCE FUNCTIONS ======

    function updateGovernanceContract(address newGov)
        external
        validAddress(newGov)
    {
        if (!setupPhase && msg.sender != governanceContract) {
            revert UnauthorizedGovernanceAction();
        }

        address oldGov = governanceContract;
        governanceContract = newGov;

        if (oldGov != address(0)) {
            _revokeRole(GOVERNANCE_ROLE, oldGov);
        }
        _grantRole(GOVERNANCE_ROLE, newGov);

        emit GovernanceContractUpdated(oldGov, newGov);
    }

    function authorizeContract(address contractAddr, bool status)
        external
        validAddress(contractAddr)
    {
        if (!setupPhase && msg.sender != governanceContract) {
            revert UnauthorizedGovernanceAction();
        }

        authorizedContracts[contractAddr] = status;
        emit ContractAuthorized(contractAddr, status);
    }

    function endSetupPhase() external {
        require(setupPhase, "Already ended");
        require(governanceContract != address(0), "Governance not set");
        setupPhase = false;
        emit SetupPhaseEnded(msg.sender, block.timestamp);
    }

    function grantRoleWithReason(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyGovernance validAddress(account) whenNotEmergency {
        _grantRole(role, account);
        emit RoleGrantedWithReason(role, account, msg.sender, reason);
    }

    function revokeRoleWithReason(
        bytes32 role,
        address account,
        string calldata reason
    ) external onlyGovernance validAddress(account) {
        _revokeRole(role, account);
        emit RoleRevokedWithReason(role, account, msg.sender, reason);
    }

    function proposeRoleChange(
        bytes32 role,
        address account,
        bool isGrant
    ) external onlyGovernance validAddress(account) returns (uint256 changeId) {
        changeId = ++pendingChangeCounter;
        pendingRoleChanges[changeId] = PendingRoleChange({
            role: role,
            account: account,
            isGrant: isGrant,
            timestamp: block.timestamp,
            executed: false
        });

        emit GovernanceRoleChangeProposed(changeId, role, account, isGrant);
    }

    function executeGovernanceRoleChange(uint256 changeId)
        external
        onlyGovernance
        nonReentrant
    {
        PendingRoleChange storage change = pendingRoleChanges[changeId];

        if (change.timestamp == 0) revert PendingChangeNotFound();
        if (change.executed) revert PendingChangeAlreadyExecuted();

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

    // ====== EMERGENCY ADMIN ======

    function toggleEmergencyMode(bool status) external onlyEmergencyAdmin {
        emergencyMode = status;
        emit EmergencyModeToggled(status, msg.sender);
    }

    // ====== VIEW FUNCTIONS ======

    function checkRole(bytes32 role, address account)
        external
        view
        onlyAuthorizedContractOrSetup
        returns (bool)
    {
        return hasRole(role, account);
    }

    function isEmergencyMode() external view returns (bool) {
        return emergencyMode;
    }

    function getAllRoles() external pure returns (bytes32[] memory) {
        bytes32[] memory roles = new bytes32[](5);
        roles[0] = MINTER_ROLE;
        roles[1] = BURNER_ROLE;
        roles[2] = BLACKLIST_ROLE;
        roles[3] = GOVERNANCE_ROLE;
        return roles;
    }

    function getGovernanceStatus() external view returns (bool isActive, address contractAddr) {
        return (governanceActive, governanceContract);
    }

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

    function getEmergencyAdmin() external view returns (address) {
        return emergencyAdmin;
    }

    function isAuthorizedContract(address contractAddr) external view returns (bool) {
        return authorizedContracts[contractAddr];
    }

    function getSetupInfo() external view returns (bool isActive, uint256 deadline) {
        return (setupPhase, setupDeadline);
    }
}
