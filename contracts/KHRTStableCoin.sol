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
 * FIXED: Integration issues, emergency coordination, and authorization problems
 */
contract KHRTStableCoin is ERC20, ReentrancyGuard, ERC20Pausable {
    IRoleController public roleController;
    address public immutable emergencyAdmin; // Only for local emergency pause/unpause
    
    uint256 public maxSupply;

    // Security features
    mapping(address => bool) public blacklisted;

    // Emergency controls (simplified)
    bool public roleControllerLocked;

    // FIXED: Emergency coordination state
    bool public localEmergencyMode;

    // Events
    event Mint(address indexed to, uint256 amount, address indexed minter);
    event Burn(address indexed from, uint256 amount, address indexed burner);
    event BlacklistUpdated(address indexed account, bool status);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event RoleControllerUpdated(address indexed oldController, address indexed newController);
    event RoleControllerLocked(address indexed caller);
    event LocalEmergencyToggled(bool status, address indexed admin);
    
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
    error EmergencyModeActive();

    modifier hasRole(bytes32 role) {
        if (address(roleController) == address(0)) {
            revert RoleControllerNotSet();
        }
        
        // FIXED: Better error handling for role checking
        try roleController.checkRole(role, msg.sender) returns (bool hasRoleResult) {
            if (!hasRoleResult) {
                revert UnauthorizedAccess(msg.sender, role);
            }
        } catch {
            revert UnauthorizedAccess(msg.sender, role);
        }
        _;
    }

    modifier onlyGovernance() {
        if (address(roleController) == address(0)) {
            revert RoleControllerNotSet();
        }
        
        try roleController.getGovernanceStatus() returns (bool isActive, address governanceContract) {
            if (!isActive || msg.sender != governanceContract) {
                revert OnlyGovernance();
            }
        } catch {
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

    // FIXED: Hierarchical emergency check
    modifier whenNotEmergencyPaused() {
        // Check local pause first
        if (paused()) {
            revert("Locally paused");
        }
        
        // Check local emergency mode
        if (localEmergencyMode) {
            revert EmergencyModeActive();
        }
        
        // Check role controller emergency mode
        if (address(roleController) != address(0)) {
            try roleController.isEmergencyMode() returns (bool roleControllerEmergency) {
                if (roleControllerEmergency) {
                    revert EmergencyModeActive();
                }
            } catch {
                // If we can't check role controller emergency status, be conservative
                revert("Cannot verify emergency status");
            }
        }
        _;
    }

    constructor(
        uint256 _maxSupply,
        address _emergencyAdmin,
        address _roleController,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
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
     */
    function lockRoleController() external onlyGovernance {
        roleControllerLocked = true;
        emit RoleControllerLocked(msg.sender);
    }

    // FIXED: Separate local emergency controls from contract pause
    /**
     * @dev Toggle local emergency mode (emergency admin only)
     */
    function toggleLocalEmergency(bool status) external onlyEmergencyAdmin {
        localEmergencyMode = status;
        emit LocalEmergencyToggled(status, msg.sender);
    }

    /**
     * @dev Emergency pause function (emergency admin only)
     * This pauses the ERC20 functionality
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
     */
    function mint(address to, uint256 amount) 
        external 
        hasRole(_getMinterRole())
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
            try roleController.checkRole(_getBurnerRole(), msg.sender) returns (bool roleExists) {
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
     */
    function emergencyBurn(address from, uint256 amount) 
        external 
        hasRole(_getBurnerRole())
        validAddress(from)
        validAmount(amount)
        nonReentrant
    {
        _burn(from, amount);
        emit Burn(from, amount, msg.sender);
    }
    
    /**
     * @dev Add or remove an address from blacklist
     */
    function updateBlacklist(address account, bool status) 
        external 
        hasRole(_getBlacklistRole())
        validAddress(account)
        whenNotEmergencyPaused
    {
        blacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    /**
     * @dev Update maximum supply (governance only)
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
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        // FIXED: Better emergency mode coordination
        if (localEmergencyMode) {
            revert EmergencyModeActive();
        }
        
        // Check role controller emergency mode
        if (address(roleController) != address(0)) {
            try roleController.isEmergencyMode() returns (bool roleControllerEmergency) {
                if (roleControllerEmergency) {
                    revert EmergencyModeActive();
                }
            } catch {
                // If we can't verify, allow transfer but log
                // In production you might want to be more restrictive
            }
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

    // ====== ROLE HELPERS (FIXED) ======
    
    /**
     * @dev Get MINTER_ROLE from role controller safely
     */
    function _getMinterRole() internal view returns (bytes32) {
        if (address(roleController) != address(0)) {
            try roleController.MINTER_ROLE() returns (bytes32 role) {
                return role;
            } catch {
                // Fallback to hardcoded value
                return keccak256("MINTER_ROLE");
            }
        }
        return keccak256("MINTER_ROLE");
    }
    
    /**
     * @dev Get BURNER_ROLE from role controller safely
     */
    function _getBurnerRole() internal view returns (bytes32) {
        if (address(roleController) != address(0)) {
            try roleController.BURNER_ROLE() returns (bytes32 role) {
                return role;
            } catch {
                return keccak256("BURNER_ROLE");
            }
        }
        return keccak256("BURNER_ROLE");
    }
    
    /**
     * @dev Get BLACKLIST_ROLE from role controller safely
     */
    function _getBlacklistRole() internal view returns (bytes32) {
        if (address(roleController) != address(0)) {
            try roleController.BLACKLIST_ROLE() returns (bytes32 role) {
                return role;
            } catch {
                return keccak256("BLACKLIST_ROLE");
            }
        }
        return keccak256("BLACKLIST_ROLE");
    }

    // ====== VIEW FUNCTIONS ======

    /**
     * @dev Get role controller status
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
     */
    function getEmergencyAdmin() external view returns (address) {
        return emergencyAdmin;
    }

    /**
     * @dev Check if any emergency mode is active
     * FIXED: Comprehensive emergency status
     */
    function isEmergencyMode() external view returns (bool) {
        // Check local emergency
        if (localEmergencyMode) {
            return true;
        }
        
        // Check contract pause
        if (paused()) {
            return true;
        }
        
        // Check role controller emergency
        if (address(roleController) != address(0)) {
            try roleController.isEmergencyMode() returns (bool roleControllerEmergency) {
                return roleControllerEmergency;
            } catch {
                // If we can't check, assume emergency for safety
                return true;
            }
        }
        
        return false;
    }

    /**
     * @dev Get governance contract address
     */
    function getGovernanceContract() external view returns (address) {
        if (address(roleController) != address(0)) {
            try roleController.getGovernanceStatus() returns (bool, address governanceContract) {
                return governanceContract;
            } catch {
                return address(0);
            }
        }
        return address(0);
    }

    /**
     * @dev Check if an address has a specific role
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

    /**
     * @dev Get comprehensive emergency status
     * FIXED: Detailed emergency information
     */
    function getEmergencyStatus() external view returns (
        bool localEmergency,
        bool contractPaused,
        bool roleControllerEmergency,
        bool anyEmergencyActive
    ) {
        localEmergency = localEmergencyMode;
        contractPaused = paused();
        
        if (address(roleController) != address(0)) {
            try roleController.isEmergencyMode() returns (bool rcEmergency) {
                roleControllerEmergency = rcEmergency;
            } catch {
                roleControllerEmergency = true; // Conservative approach
            }
        }
        
        anyEmergencyActive = localEmergency || contractPaused || roleControllerEmergency;
    }
}