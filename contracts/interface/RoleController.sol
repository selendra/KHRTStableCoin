// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRoleController {
    function checkRole(bytes32 role, address account) external view returns (bool);
    function isEmergencyMode() external view returns (bool);
    function MINTER_ROLE() external view returns (bytes32);
    function BURNER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function BLACKLIST_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
}
