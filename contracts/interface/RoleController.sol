// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRoleController {
    // Role checking
    function checkRole(bytes32 role, address account) external view returns (bool);
    function isEmergencyMode() external view returns (bool);
    
    // Role constants
    function MINTER_ROLE() external view returns (bytes32);
    function BURNER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function BLACKLIST_ROLE() external view returns (bytes32);
    function GOVERNANCE_ROLE() external view returns (bytes32);
    
    // Contract authorization
    function authorizeContract(address contractAddr, bool status) external;
    
    // Role management (governance only)
    function grantRoleWithReason(
        bytes32 role,
        address account,
        string calldata reason
    ) external;
    
    function revokeRoleWithReason(
        bytes32 role,
        address account,
        string calldata reason
    ) external;
    
    // Governance integration functions
    function proposeRoleChange(
        bytes32 role,
        address account,
        bool isGrant
    ) external returns (uint256);
    
    function executeGovernanceRoleChange(uint256 changeId) external;
    
    function getGovernanceStatus()
        external
        view
        returns (bool isActive, address contractAddr);
    
    function isRoleGovernanceControlled(bytes32 role)
        external
        view
        returns (bool);
    
    function getPendingRoleChange(uint256 changeId)
        external
        view
        returns (
            bytes32 role,
            address account,
            bool isGrant,
            uint256 timestamp,
            bool executed
        );
    
    // Emergency controls
    function toggleEmergencyMode(bool status) external;
    function pause() external;
    function unpause() external;
    function getEmergencyAdmin() external view returns (address);
    
    // Governance updates
    function updateGovernanceContract(address _newGovernanceContract) external;
}