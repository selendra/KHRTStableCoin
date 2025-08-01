// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract KHRTStablecoinV1 is 
    Initializable, 
    ERC20Upgradeable, 
    OwnableUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    
    // State variables
    uint256 public maxSupply;
    mapping(address => bool) public authorizedMinters;
    mapping(address => bool) public authorizedBurners; // NEW: Authorized burners
    mapping(address => bool) public blacklistedUsers;
    
    // Events
    event MinterAuthorized(address indexed minter, bool status);
    event BurnerAuthorized(address indexed burner, bool status); // NEW: Burner authorization event
    event UserBlacklisted(address indexed user, bool status);
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event TokensBurnedFrom(address indexed owner, address indexed burner, uint256 amount);
    event AdminBurnedBlacklisted(address indexed blacklistedUser, uint256 amount, address indexed admin); // NEW EVENT
    event MaxSupplyChanged(uint256 oldMaxSupply, uint256 newMaxSupply, address indexed changedBy); // UPDATED EVENT

    // Storage gap for future upgrades (reduced by 1 for authorizedBurners)
    uint256[46] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract - replaces constructor
     * @param name Token name
     * @param symbol Token symbol
     * @param initialOwner Initial owner address
     */
    function initialize(
        string memory name, 
        string memory symbol,
        address initialOwner
    ) public initializer {
        require(initialOwner != address(0), "KHRT: Invalid initial owner");
        
        __ERC20_init(name, symbol);
        __Ownable_init(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        maxSupply = 40_000_000_000 * 1e6; // 40B KHRT with 6 decimals
        authorizedMinters[initialOwner] = true;
    }

    /**
     * @dev Override decimals to return 6 instead of default 18
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    /**
     * @dev Required override for UUPS proxy pattern
     * Only owner can authorize upgrades
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Modifiers
    modifier validAddress(address addr) {
        require(addr != address(0), "KHRT: Invalid address");
        _;
    }

    modifier validAmount(uint256 amount) {
        require(amount > 0, "KHRT: Amount must be greater than 0");
        _;
    }

    modifier checkSupplyLimit(uint256 amount) {
        require(totalSupply() + amount <= maxSupply, "KHRT: Exceeds maximum supply");
        _;
    }

    modifier notBlacklisted(address addr) {
        require(!blacklistedUsers[addr], "KHRT: Address is blacklisted");
        _;
    }

    modifier neitherBlacklisted(address addr1, address addr2) {
        require(!blacklistedUsers[addr1] && !blacklistedUsers[addr2], "KHRT: Address is blacklisted");
        _;
    }

    // FIX 2: Replace increaseMaxSupply with flexible setMaxSupply
    /**
     * @dev Set the maximum supply of KHRT tokens - only callable by owner
     * @param newMaxSupply New maximum supply (can be higher or lower than current)
     */
    function setMaxSupply(uint256 newMaxSupply) external onlyOwner validAmount(newMaxSupply) {
        require(newMaxSupply >= totalSupply(), "KHRT: New max supply below current total supply");
        require(newMaxSupply != maxSupply, "KHRT: New max supply same as current");
        
        uint256 oldMaxSupply = maxSupply;
        maxSupply = newMaxSupply;
        emit MaxSupplyChanged(oldMaxSupply, newMaxSupply, msg.sender);
    }

    /**
     * @dev Get the current maximum supply
     */
    function getMaxSupply() external view returns (uint256) {
        return maxSupply;
    }

    /**
     * @dev Authorize or revoke minting permissions
     * @param minter Address to authorize/revoke
     * @param status True to authorize, false to revoke
     */
    function setAuthorizedMinter(address minter, bool status) external onlyOwner validAddress(minter) {
        authorizedMinters[minter] = status;
        emit MinterAuthorized(minter, status);
    }

    /**
     * @dev Authorize or revoke burning permissions
     * @param burner Address to authorize/revoke
     * @param status True to authorize, false to revoke
     */
    function setAuthorizedBurner(address burner, bool status) external onlyOwner validAddress(burner) {
        authorizedBurners[burner] = status;
        emit BurnerAuthorized(burner, status);
    }

    /**
     * @dev Add or remove a user from blacklist
     * @param user Address of the user
     * @param status True to blacklist, false to remove from blacklist
     */
    function setUserBlacklist(address user, bool status) external onlyOwner validAddress(user) {
        blacklistedUsers[user] = status;
        emit UserBlacklisted(user, status);
    }

    /**
     * @dev Batch blacklist multiple users
     * @param users Array of user addresses
     * @param statuses Array of corresponding blacklist statuses
     */
    function batchSetUserBlacklist(address[] calldata users, bool[] calldata statuses) external onlyOwner {
        require(users.length == statuses.length, "KHRT: Arrays length mismatch");
        require(users.length <= 100, "KHRT: Too many users");
        
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "KHRT: Invalid user address");
            blacklistedUsers[users[i]] = statuses[i];
            emit UserBlacklisted(users[i], statuses[i]);
        }
    }

    /**
     * @dev Check if an address is an authorized minter
     * @param minter Address to check
     */
    function isAuthorizedMinter(address minter) external view returns (bool) {
        return authorizedMinters[minter];
    }

    /**
     * @dev Check if an address is an authorized burner
     * @param burner Address to check
     */
    function isAuthorizedBurner(address burner) external view returns (bool) {
        return authorizedBurners[burner];
    }

    /**
     * @dev Check if a user is blacklisted
     * @param user Address to check
     */
    function isUserBlacklisted(address user) external view returns (bool) {
        return blacklistedUsers[user];
    }

    /**
     * @dev Mint KHRT tokens - only callable by authorized minters
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external 
        nonReentrant 
        whenNotPaused 
        validAddress(to)
        validAmount(amount)
        checkSupplyLimit(amount)
        notBlacklisted(to)
    {
        require(authorizedMinters[msg.sender], "KHRT: Unauthorized minter");

        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @dev Burn KHRT tokens from sender's balance
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external 
        nonReentrant 
        whenNotPaused 
        validAmount(amount)
    {
        require(balanceOf(msg.sender) >= amount, "KHRT: Insufficient balance to burn");

        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    /**
     * @dev Burn KHRT tokens from another address using allowance
     * Owner and authorized burners can burn without allowance
     * @param tokenOwner Address that owns the tokens to burn
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address tokenOwner, uint256 amount) external 
        nonReentrant 
        whenNotPaused 
        validAddress(tokenOwner)
        validAmount(amount)
    {
        require(balanceOf(tokenOwner) >= amount, "KHRT: Insufficient balance to burn");
        
        if (msg.sender == owner() || authorizedBurners[msg.sender]) {
            // Owner or authorized burner can burn without allowance
            _burn(tokenOwner, amount);
        } else {
            // Normal burnFrom with allowance check and blacklist validation
            require(!blacklistedUsers[tokenOwner] && !blacklistedUsers[msg.sender], "KHRT: Address is blacklisted");
            
            uint256 currentAllowance = allowance(tokenOwner, msg.sender);
            require(currentAllowance >= amount, "KHRT: Insufficient allowance");

            _spendAllowance(tokenOwner, msg.sender, amount);
            _burn(tokenOwner, amount);
        }

        emit TokensBurnedFrom(tokenOwner, msg.sender, amount);
    }

    /**
     * @dev Check if an amount can be minted (within supply limits)
     * @param amount Amount to check
     */
    function canMint(uint256 amount) external view returns (bool) {
        return totalSupply() + amount <= maxSupply;
    }

    /**
     * @dev Emergency pause function
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause function
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Override transfer to add pause functionality and minimum transfer amount
     */
    function transfer(address to, uint256 amount) public override 
        whenNotPaused 
        validAddress(to) 
        neitherBlacklisted(msg.sender, to) 
    returns (bool) {
        require(amount > 0, "KHRT: Transfer amount must be greater than 0");
        return super.transfer(to, amount);
    }

    /**
     * @dev Override transferFrom to add pause functionality and minimum transfer amount
     */
    function transferFrom(address from, address to, uint256 amount) public override 
        whenNotPaused 
        validAddress(to) 
        neitherBlacklisted(from, to) 
    returns (bool) {
        require(amount > 0, "KHRT: Transfer amount must be greater than 0");
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Override approve to prevent zero address approvals
     */
    function approve(address spender, uint256 amount) public override validAddress(spender) neitherBlacklisted(msg.sender, spender) returns (bool) {
        return super.approve(spender, amount);
    }

    /**
     * @dev Returns the current implementation version
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}