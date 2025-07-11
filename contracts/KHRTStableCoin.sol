// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interface/IRoleController.sol";

/**
 * @title KHRTStableCoin
 * @dev A secure, role-governed ERC20 stablecoin with blacklisting, max supply, and emergency control features.
 */
contract KHRTStableCoin is ERC20, ERC20Pausable, ReentrancyGuard {
    using Address for address;

    /// @notice Role controller contract (governance and access)
    IRoleController public roleController;

    /// @notice Immutable emergency admin with override powers
    address public immutable emergencyAdmin;

    /// @notice Hard cap on mintable supply
    uint256 public maxSupply;

    /// @notice Blacklist mapping for compliance
    mapping(address => bool) public blacklisted;

    /// @notice Local emergency pause flag
    bool public localEmergencyMode;

    /// @notice Lock flag for role controller updates
    bool public roleControllerLocked;

    // ====== CONSTANTS ======

    bytes32 private constant DEFAULT_MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 private constant DEFAULT_BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 private constant DEFAULT_BLACKLIST_ROLE = keccak256("BLACKLIST_ROLE");

    // ====== EVENTS ======

    event Mint(address indexed to, uint256 amount, address indexed minter);
    event Burn(address indexed from, uint256 amount, address indexed burner);
    event BlacklistUpdated(address indexed account, bool status);
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);
    event RoleControllerUpdated(address indexed oldController, address indexed newController);
    event RoleControllerLocked(address indexed caller);
    event LocalEmergencyToggled(bool status, address indexed admin);

    // ====== ERRORS ======

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
    error LocalPauseActive();
    error EmergencyStatusUnknown();

    // ====== MODIFIERS ======

    modifier hasRole(bytes32 role) {
        if (address(roleController) == address(0)) revert RoleControllerNotSet();
        try roleController.checkRole(role, msg.sender) returns (bool ok) {
            if (!ok) revert UnauthorizedAccess(msg.sender, role);
        } catch {
            revert UnauthorizedAccess(msg.sender, role);
        }
        _;
    }

    modifier onlyGovernance() {
        if (address(roleController) == address(0)) revert RoleControllerNotSet();
        try roleController.getGovernanceStatus() returns (bool active, address gov) {
            if (!active || msg.sender != gov) revert OnlyGovernance();
        } catch {
            revert OnlyGovernance();
        }
        _;
    }

    modifier onlyEmergencyAdmin() {
        if (msg.sender != emergencyAdmin) revert OnlyEmergencyAdmin();
        _;
    }

    modifier notBlacklisted(address account) {
        if (blacklisted[account]) revert AccountBlacklisted(account);
        _;
    }

    modifier validAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier validAddress(address account) {
        if (account == address(0)) revert InvalidAddress();
        _;
    }

    modifier whenNotEmergencyPaused() {
        if (paused()) revert LocalPauseActive();
        if (localEmergencyMode) revert EmergencyModeActive();
        if (address(roleController) != address(0)) {
            try roleController.isEmergencyMode() returns (bool emergency) {
                if (emergency) revert EmergencyModeActive();
            } catch {
                revert EmergencyStatusUnknown();
            }
        }
        _;
    }

    // ====== CONSTRUCTOR ======

    constructor(
        uint256 _maxSupply,
        address _emergencyAdmin,
        address _roleController,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        require(_maxSupply > 0, "Max supply must be greater than 0");
        require(_emergencyAdmin != address(0), "Invalid emergency admin address");
        if (_roleController != address(0)) {
            roleController = IRoleController(_roleController);
        }

        emergencyAdmin = _emergencyAdmin;
        maxSupply = _maxSupply;
    }

    // ====== CORE FUNCTIONS ======

    function mint(address to, uint256 amount)
        external
        hasRole(_getMinterRole())
        validAddress(to)
        validAmount(amount)
        notBlacklisted(to)
        nonReentrant
        whenNotEmergencyPaused
    {
        if (totalSupply() + amount > maxSupply) {
            revert ExceedsMaxSupply(amount, maxSupply - totalSupply());
        }
        _mint(to, amount);
        emit Mint(to, amount, msg.sender);
    }

    function burn(uint256 amount)
        external
        validAmount(amount)
        notBlacklisted(msg.sender)
        nonReentrant
        whenNotEmergencyPaused
    {
        _burn(msg.sender, amount);
        emit Burn(msg.sender, amount, msg.sender);
    }

    function burnFrom(address from, uint256 amount)
        external
        validAddress(from)
        validAmount(amount)
        notBlacklisted(from)
        notBlacklisted(msg.sender)
        nonReentrant
        whenNotEmergencyPaused
    {
        bool hasBurner = false;
        if (address(roleController) != address(0)) {
            try roleController.checkRole(_getBurnerRole(), msg.sender) returns (bool ok) {
                hasBurner = ok;
            } catch {}
        }

        if (!hasBurner) {
            uint256 currentAllowance = allowance(from, msg.sender);
            require(currentAllowance >= amount, "Insufficient allowance");
            _approve(from, msg.sender, currentAllowance - amount);
        }

        _burn(from, amount);
        emit Burn(from, amount, msg.sender);
    }

    function emergencyBurn(address from, uint256 amount)
        external
        hasRole(_getBurnerRole())
        validAddress(from)
        validAmount(amount)
        notBlacklisted(msg.sender)
        notBlacklisted(from)
        nonReentrant
    {
        _burn(from, amount);
        emit Burn(from, amount, msg.sender);
    }

    // ====== ADMIN & EMERGENCY ======

    function setRoleController(address newController)
        external
        onlyGovernance
        validAddress(newController)
    {
        if (roleControllerLocked) revert RoleControllerIsLocked();
        address old = address(roleController);
        roleController = IRoleController(newController);
        emit RoleControllerUpdated(old, newController);
    }

    function lockRoleController() external onlyGovernance {
        roleControllerLocked = true;
        emit RoleControllerLocked(msg.sender);
    }

    function toggleLocalEmergency(bool status) external onlyEmergencyAdmin {
        localEmergencyMode = status;
        emit LocalEmergencyToggled(status, msg.sender);
    }

    function pause() external onlyEmergencyAdmin {
        _pause();
    }

    function unpause() external onlyEmergencyAdmin {
        _unpause();
    }

    // ====== CONFIG ======

    function updateBlacklist(address account, bool status)
        external
        hasRole(_getBlacklistRole())
        validAddress(account)
        whenNotEmergencyPaused
    {
        blacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function updateMaxSupply(uint256 newMax)
        external
        onlyGovernance
        whenNotEmergencyPaused
    {
        require(newMax >= totalSupply(), "New max supply below total");
        uint256 old = maxSupply;
        maxSupply = newMax;
        emit MaxSupplyUpdated(old, newMax);
    }

    // ====== INTERNAL HOOK ======

    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Pausable)
    {
        if (localEmergencyMode) revert EmergencyModeActive();

        if (address(roleController) != address(0)) {
            try roleController.isEmergencyMode() returns (bool emergency) {
                if (emergency) revert EmergencyModeActive();
            } catch {}
        }

        if (from != address(0) && to != address(0)) {
            if (blacklisted[from] || blacklisted[to]) {
                revert AccountBlacklisted(blacklisted[from] ? from : to);
            }
        }

        super._update(from, to, amount);
    }

    // ====== ROLE HELPERS ======

    function _getMinterRole() internal view returns (bytes32) {
        if (address(roleController) != address(0)) {
            try roleController.MINTER_ROLE() returns (bytes32 role) {
                return role;
            } catch {}
        }
        return DEFAULT_MINTER_ROLE;
    }

    function _getBurnerRole() internal view returns (bytes32) {
        if (address(roleController) != address(0)) {
            try roleController.BURNER_ROLE() returns (bytes32 role) {
                return role;
            } catch {}
        }
        return DEFAULT_BURNER_ROLE;
    }

    function _getBlacklistRole() internal view returns (bytes32) {
        if (address(roleController) != address(0)) {
            try roleController.BLACKLIST_ROLE() returns (bytes32 role) {
                return role;
            } catch {}
        }
        return DEFAULT_BLACKLIST_ROLE;
    }

    // ====== VIEW HELPERS ======

    function isEmergencyMode() external view returns (bool) {
        if (localEmergencyMode || paused()) return true;

        if (address(roleController) != address(0)) {
            try roleController.isEmergencyMode() returns (bool e) {
                return e;
            } catch {
                return true;
            }
        }

        return false;
    }

    function getGovernanceContract() external view returns (address) {
        if (address(roleController) != address(0)) {
            try roleController.getGovernanceStatus() returns (bool, address gov) {
                return gov;
            } catch {}
        }
        return address(0);
    }

    function hasRoleView(bytes32 role, address account) external view returns (bool) {
        if (address(roleController) != address(0)) {
            try roleController.checkRole(role, account) returns (bool ok) {
                return ok;
            } catch {}
        }
        return false;
    }

    function getRoleControllerStatus()
        external
        view
        returns (address controller, bool isSet, bool isLocked)
    {
        controller = address(roleController);
        isSet = controller != address(0);
        isLocked = roleControllerLocked;
    }

    function getEmergencyStatus()
        external
        view
        returns (
            bool localEmergency,
            bool contractPaused,
            bool roleControllerEmergency,
            bool anyEmergencyActive
        )
    {
        localEmergency = localEmergencyMode;
        contractPaused = paused();
        if (address(roleController) != address(0)) {
            try roleController.isEmergencyMode() returns (bool rcEmergency) {
                roleControllerEmergency = rcEmergency;
            } catch {
                roleControllerEmergency = true;
            }
        }
        anyEmergencyActive = localEmergency || contractPaused || roleControllerEmergency;
    }
}
