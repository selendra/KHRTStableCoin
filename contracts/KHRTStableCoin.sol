// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interface/IRoleController.sol";

/**
 * @title KHRTStableCoin
 * @dev A secure ERC20 stablecoin with governance-based role management
 * Features:
 * - Governance-controlled role-based access control via RoleController
 * - Emergency pause (emergency admin only)
 * - Maximum supply protection
 * - Blacklist functionality
 * - Role controller upgradeability (governance controlled)
 */
contract KHRTStableCoin is ERC20, ReentrancyGuard, ERC20Pausable {
    IRoleController public roleController;
    address public immutable emergencyAdmin; // Only for local emergency pause/unpause
    
    uint256 public maxSupply;

    // Security features
    mapping(address => bool) public blacklisted;

    // Emergency controls (simplified)
    bool public roleControllerLocked;

    // Events
    event Mint(address indexed to, uint256 amount, address indexed minter);
    event Burn(address indexed from, uint256 amount, address indexed burner);
    event BlacklistUpdated(address indexed account, bool status);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event RoleControllerUpdated(address indexed oldController, address indexed newController);
    event RoleControllerLocked(address indexed caller);
    
    // Custom errors
    error ExceedsMaxSupply(uint256 requested, uint256 available);
    error AccountBlacklisted(address account);
    error InvalidAmount();
    error InvalidAddress();
    error UnauthorizedAccess(address caller, bytes32 role);
    error RoleControllerNotSet();
    error RoleControllerIsLocked();
    error OnlyEmergencyAdmin();
    error OnlyGovernance();

    modifier hasRole(bytes32 role) {
        if (address(roleController) == address(0)) {
            revert RoleControllerNotSet();
        }
        if (!roleController.checkRole(role, msg.sender)) {
            revert UnauthorizedAccess(msg.sender, role);
        }
        _;
    }

    modifier onlyGovernance() {
        if (address(roleController) == address(0)) {
            revert RoleControllerNotSet();
        }
        (, address governanceContract) = roleController.getGovernanceStatus();
        if (msg.sender != governanceContract) {
            revert OnlyGovernance();
        }
        _;
    }

    modifier onlyEmergencyAdmin() {
        if (msg.sender != emergencyAdmin) {
            revert OnlyEmergencyAdmin();
        }
        _;
    }
    
    modifier notBlacklisted(address account) {
        if (blacklisted[account]) {
            revert AccountBlacklisted(account);
        }
        _;
    }
    
    modifier validAmount(uint256 amount) {
        if (amount == 0) {
            revert InvalidAmount();
        }
        _;
    }
    
    modifier validAddress(address account) {
        if (account == address(0)) {
            revert InvalidAddress();
        }
        _;
    }

    modifier whenNotEmergencyPaused() {
        // Check both local pause and role controller emergency mode
        if (address(roleController) != address(0) && roleController.isEmergencyMode()) {
            revert("Emergency mode active");
        }
        _;
    }

    constructor(
        uint256 _maxSupply,
        address _emergencyAdmin,
        address _roleController
    ) ERC20("KHR Token (Official)", "KHRT") {
        require(_maxSupply > 0, "Max supply must be greater than 0");
        require(_emergencyAdmin != address(0), "Invalid emergency admin address");
        
        maxSupply = _maxSupply;
        emergencyAdmin = _emergencyAdmin;
        
        // Set role controller (required for governance-controlled operations)
        if (_roleController != address(0)) {
            roleController = IRoleController(_roleController);
        }
    }

    /**
     * @dev Set or update the role controller (governance only)
     * @param newRoleController Address of the new role controller
     */
    function setRoleController(address newRoleController) 
        external 
        onlyGovernance
        validAddress(newRoleController)
    {
        if (roleControllerLocked) {
            revert RoleControllerIsLocked();
        }
        
        address oldController = address(roleController);
        roleController = IRoleController(newRoleController);
        
        emit RoleControllerUpdated(oldController, newRoleController);
    }

    /**
     * @dev Lock the role controller to prevent further changes (governance only)
     * This is irreversible and should only be done when the system is stable
     */
    function lockRoleController() external onlyGovernance {
        roleControllerLocked = true;
        emit RoleControllerLocked(msg.sender);
    }

    /**
     * @dev Emergency pause function (emergency admin only)
     * This is separate from the role controller's emergency mode
     */
    function pause() external onlyEmergencyAdmin {
        _pause();
    }

    /**
     * @dev Emergency unpause function (emergency admin only)
     */
    function unpause() external onlyEmergencyAdmin {
        _unpause();
    }

    /**
     * @dev Mint tokens to a specified address
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) 
        external 
        hasRole(roleController.MINTER_ROLE())
        validAddress(to)
        validAmount(amount)
        notBlacklisted(to)
        nonReentrant
        whenNotPaused
        whenNotEmergencyPaused
    {
        // Check max supply
        if (totalSupply() + amount > maxSupply) {
            revert ExceedsMaxSupply(amount, maxSupply - totalSupply());
        }

        _mint(to, amount);
        
        emit Mint(to, amount, msg.sender);
    }

    /**
     * @dev Burn tokens from caller's balance
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) 
        external 
        validAmount(amount)
        nonReentrant
        whenNotEmergencyPaused
    {
        _burn(msg.sender, amount);
        emit Burn(msg.sender, amount, msg.sender);
    }

    /**
     * @dev Burn tokens from a specified address (requires allowance or BURNER_ROLE)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) 
        external 
        validAddress(from)
        validAmount(amount)
        nonReentrant
        whenNotEmergencyPaused
    {
        bool hasBurnerRole = false;
        
        // Check if caller has burner role
        if (address(roleController) != address(0)) {
            try roleController.checkRole(roleController.BURNER_ROLE(), msg.sender) returns (bool roleExists) {
                hasBurnerRole = roleExists;
            } catch {
                // If role controller fails, continue with allowance check
            }
        }
        
        if (!hasBurnerRole) {
            // If not a burner, check allowance
            uint256 currentAllowance = allowance(from, msg.sender);
            require(currentAllowance >= amount, "Insufficient allowance");
            _approve(from, msg.sender, currentAllowance - amount);
        }
        
        _burn(from, amount);
        emit Burn(from, amount, msg.sender);
    }

    /**
     * @dev Emergency burn function for compliance (BURNER_ROLE only)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function emergencyBurn(address from, uint256 amount) 
        external 
        hasRole(roleController.BURNER_ROLE())
        validAddress(from)
        validAmount(amount)
        nonReentrant
    {
        _burn(from, amount);
        emit Burn(from, amount, msg.sender);
    }
    
    /**
     * @dev Add or remove an address from blacklist
     * @param account Address to update
     * @param status True to blacklist, false to remove from blacklist
     */
    function updateBlacklist(address account, bool status) 
        external 
        hasRole(roleController.BLACKLIST_ROLE())
        validAddress(account)
        whenNotEmergencyPaused
    {
        blacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    /**
     * @dev Update maximum supply (governance only)
     * @param newMaxSupply New maximum supply
     */
    function updateMaxSupply(uint256 newMaxSupply) 
        external 
        onlyGovernance
        whenNotEmergencyPaused
    {
        require(newMaxSupply >= totalSupply(), "New max supply below current supply");
        uint256 oldMaxSupply = maxSupply;
        maxSupply = newMaxSupply;
        emit MaxSupplyUpdated(oldMaxSupply, newMaxSupply);
    }

    /**
     * @dev Override required by Solidity due to multiple inheritance
     * Replaces _beforeTokenTransfer for newer OpenZeppelin versions
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        // Check emergency mode from role controller
        if (address(roleController) != address(0) && roleController.isEmergencyMode()) {
            revert("Emergency mode active");
        }
        
        // Check blacklist for transfers (not for minting/burning)
        if (from != address(0) && to != address(0)) {
            if (blacklisted[from] || blacklisted[to]) {
                revert AccountBlacklisted(blacklisted[from] ? from : to);
            }
        }
        
        // Call parent implementations
        super._update(from, to, value);
    }

    // ====== VIEW FUNCTIONS ======

    /**
     * @dev Get role controller status
     * @return controller Address of the role controller
     * @return isSet True if role controller is set
     * @return isLocked True if role controller is locked
     */
    function getRoleControllerStatus() 
        external 
        view 
        returns (address controller, bool isSet, bool isLocked) 
    {
        controller = address(roleController);
        isSet = controller != address(0);
        isLocked = roleControllerLocked;
    }

    /**
     * @dev Get emergency admin address
     * @return Address of the emergency admin
     */
    function getEmergencyAdmin() external view returns (address) {
        return emergencyAdmin;
    }

    /**
     * @dev Check if emergency mode is active (from role controller)
     * @return True if emergency mode is active
     */
    function isEmergencyMode() external view returns (bool) {
        if (address(roleController) != address(0)) {
            return roleController.isEmergencyMode();
        }
        return false;
    }

    /**
     * @dev Get governance contract address
     * @return Address of the governance contract (from role controller)
     */
    function getGovernanceContract() external view returns (address) {
        if (address(roleController) != address(0)) {
            (, address governanceContract) = roleController.getGovernanceStatus();
            return governanceContract;
        }
        return address(0);
    }

    /**
     * @dev Check if an address has a specific role
     * @param role Role to check
     * @param account Account to check
     * @return True if account has the role
     */
    function hasRoleView(bytes32 role, address account) external view returns (bool) {
        if (address(roleController) == address(0)) {
            return false;
        }
        try roleController.checkRole(role, account) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
}