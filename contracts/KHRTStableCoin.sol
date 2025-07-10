// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interface/RoleController.sol";

/**
 * @title KHRTStableCoin
 * @dev A secure ERC20 stablecoin with external role management
 * Features:
 * - External role-based access control via RoleController
 * - Pausable transfers
 * - Maximum supply protection
 * - Blacklist functionality
 * - Emergency controls
 * - Role controller upgradeability
 */
contract KHRTStableCoin is ERC20, ReentrancyGuard, ERC20Pausable {
    IRoleController public roleController;
    address public admin; // Fallback admin for emergency situations
    
    uint256 public maxSupply;

    // Security features
    mapping(address => bool) public blacklisted;

    // Emergency controls
    bool public emergencyPause;
    bool public roleControllerLocked;

    // Events
    event Mint(address indexed to, uint256 amount, address indexed minter);
    event Burn(address indexed from, uint256 amount, address indexed burner);
    event BlacklistUpdated(address indexed account, bool status);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event RoleControllerUpdated(address indexed oldController, address indexed newController);
    event EmergencyPauseToggled(bool status, address indexed admin);
    event RoleControllerLocked(address indexed admin);
    
    // Custom errors
    error ExceedsMaxSupply(uint256 requested, uint256 available);
    error AccountBlacklisted(address account);
    error InvalidAmount();
    error InvalidAddress();
    error UnauthorizedAccess(address caller, bytes32 role);
    error RoleControllerNotSet();
    error EmergencyPauseActive();
    error RoleControllerIsLocked();

    modifier hasRole(bytes32 role) {
        if (address(roleController) == address(0)) {
            // Fallback: only admin can perform actions if role controller not set
            if (msg.sender != admin) {
                revert RoleControllerNotSet();
            }
        } else {
            if (!roleController.checkRole(role, msg.sender)) {
                revert UnauthorizedAccess(msg.sender, role);
            }
        }
        _;
    }

    modifier onlyAdmin() {
        if (address(roleController) != address(0)) {
            if (!roleController.checkRole(roleController.DEFAULT_ADMIN_ROLE(), msg.sender)) {
                revert UnauthorizedAccess(msg.sender, roleController.DEFAULT_ADMIN_ROLE());
            }
        } else {
            if (msg.sender != admin) {
                revert UnauthorizedAccess(msg.sender, bytes32(0));
            }
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
        if (emergencyPause) {
            revert EmergencyPauseActive();
        }
        _;
    }

    constructor(
        uint256 _maxSupply,
        address _admin,
        address _roleController
    ) ERC20("KHR Token (Official)", "KHRT") {
        require(_maxSupply > 0, "Max supply must be greater than 0");
        require(_admin != address(0), "Invalid admin address");
        
        maxSupply = _maxSupply;
        admin = _admin;
        
        // Set role controller (can be zero initially)
        if (_roleController != address(0)) {
            roleController = IRoleController(_roleController);
        }
    }

    /**
     * @dev Set or update the role controller
     * @param newRoleController Address of the new role controller
     */
    function setRoleController(address newRoleController) 
        external 
        onlyAdmin 
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
     * @dev Lock the role controller to prevent further changes
     * This is irreversible and should only be done when the system is stable
     */
    function lockRoleController() external onlyAdmin {
        roleControllerLocked = true;
        emit RoleControllerLocked(msg.sender);
    }

    /**
     * @dev Emergency pause function that doesn't require role controller
     * Can be called by admin or emergency admin
     */
    function toggleEmergencyPause(bool status) external {
        bool isAuthorized = false;
        
        // Check if caller is admin
        if (msg.sender == admin) {
            isAuthorized = true;
        }
        
        // Check if caller has emergency admin role in role controller
        if (address(roleController) != address(0)) {
            try roleController.checkRole(roleController.PAUSER_ROLE(), msg.sender) returns (bool hasPauserRole) {
                if (hasPauserRole) {
                    isAuthorized = true;
                }
            } catch {
                // If role controller fails, only admin can proceed
            }
        }
        
        require(isAuthorized, "Not authorized for emergency pause");
        
        emergencyPause = status;
        emit EmergencyPauseToggled(status, msg.sender);
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
        // Check if role controller is in emergency mode
        if (address(roleController) != address(0) && roleController.isEmergencyMode()) {
            revert EmergencyPauseActive();
        }

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
     * @dev Update maximum supply
     * @param newMaxSupply New maximum supply
     */
    function updateMaxSupply(uint256 newMaxSupply) 
        external 
        onlyAdmin
        whenNotEmergencyPaused
    {
        require(newMaxSupply >= totalSupply(), "New max supply below current supply");
        uint256 oldMaxSupply = maxSupply;
        maxSupply = newMaxSupply;
        emit MaxSupplyUpdated(oldMaxSupply, newMaxSupply);
    }
    
    /**
     * @dev Pause all token transfers
     */
    function pause() external hasRole(roleController.PAUSER_ROLE()) {
        _pause();
    }
    
    /**
     * @dev Unpause all token transfers
     */
    function unpause() external hasRole(roleController.PAUSER_ROLE()) {
        _unpause();
    }

    /**
     * @dev Update the fallback admin (only current admin)
     * @param newAdmin Address of the new admin
     */
    function updateAdmin(address newAdmin) 
        external 
        validAddress(newAdmin)
    {
        require(msg.sender == admin, "Only current admin");
        admin = newAdmin;
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
        // Check emergency pause
        if (emergencyPause) {
            revert EmergencyPauseActive();
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
}