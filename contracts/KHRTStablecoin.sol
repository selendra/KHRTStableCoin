// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract KHRTStablecoin is ERC20, Ownable, Pausable, ReentrancyGuard {
    
    // Constants
    uint256 public constant MIN_MINT_AMOUNT = 1e6; // 1 KHRT minimum mint (6 decimals)
    uint256 public constant MIN_BURN_AMOUNT = 1e6; // 1 KHRT minimum burn (6 decimals)
    
    // State variables
    uint256 public maxSupply = 1_000_000_000 * 1e6; // 1B KHRT with 6 decimals
    mapping(address => bool) public authorizedMinters;
    mapping(address => bool) public blacklistedUsers;
    
    // Events
    event MinterAuthorized(address indexed minter, bool status);
    event UserBlacklisted(address indexed user, bool status);
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event TokensBurnedFrom(address indexed owner, address indexed burner, uint256 amount);
    event MaxSupplyIncreased(uint256 oldMaxSupply, uint256 newMaxSupply, address indexed increasedBy);

    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {
        authorizedMinters[msg.sender] = true;
    }

    /**
     * @dev Override decimals to return 6 instead of default 18
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

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

    /**
     * @dev Increase the maximum supply of KHRT tokens - only callable by owner
     * @param additionalSupply Amount to increase the max supply by
     */
    function increaseMaxSupply(uint256 additionalSupply) external onlyOwner validAmount(additionalSupply) {
        uint256 oldMaxSupply = maxSupply;
        uint256 newMaxSupply = oldMaxSupply + additionalSupply;
        
        // Check for overflow
        require(newMaxSupply > oldMaxSupply, "KHRT: Max supply overflow");
        
        maxSupply = newMaxSupply;
        emit MaxSupplyIncreased(oldMaxSupply, newMaxSupply, msg.sender);
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
        require(amount >= MIN_MINT_AMOUNT, "KHRT: Below minimum mint amount");

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
        notBlacklisted(msg.sender)
    {
        require(amount >= MIN_BURN_AMOUNT, "KHRT: Below minimum burn amount");
        require(balanceOf(msg.sender) >= amount, "KHRT: Insufficient balance to burn");

        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    /**
     * @dev Burn KHRT tokens from another address using allowance
     * @param owner Address that owns the tokens to burn
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address owner, uint256 amount) external 
        nonReentrant 
        whenNotPaused 
        validAddress(owner)
        validAmount(amount)
        neitherBlacklisted(owner, msg.sender)
    {
        require(amount >= MIN_BURN_AMOUNT, "KHRT: Below minimum burn amount");
        require(balanceOf(owner) >= amount, "KHRT: Insufficient balance to burn");
        
        uint256 currentAllowance = allowance(owner, msg.sender);
        require(currentAllowance >= amount, "KHRT: Insufficient allowance");

        _spendAllowance(owner, msg.sender, amount);
        _burn(owner, amount);
        emit TokensBurnedFrom(owner, msg.sender, amount);
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
    function transfer(address to, uint256 amount) public override whenNotPaused validAddress(to) neitherBlacklisted(msg.sender, to) returns (bool) {
        require(amount > 0, "KHRT: Transfer amount must be greater than 0");
        return super.transfer(to, amount);
    }

    /**
     * @dev Override transferFrom to add pause functionality and minimum transfer amount
     */
    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused validAddress(to) neitherBlacklisted(from, to) returns (bool) {
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
     * @dev Batch transfer function for efficiency
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to transfer
     */
    function batchTransfer(address[] calldata recipients, uint256[] calldata amounts) external whenNotPaused notBlacklisted(msg.sender) returns (bool) {
        require(recipients.length == amounts.length, "KHRT: Arrays length mismatch");
        require(recipients.length <= 100, "KHRT: Too many recipients");
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(recipients[i] != address(0), "KHRT: Invalid recipient");
            require(!blacklistedUsers[recipients[i]], "KHRT: Recipient is blacklisted");
            require(amounts[i] > 0, "KHRT: Invalid amount");
            totalAmount += amounts[i];
        }
        
        require(balanceOf(msg.sender) >= totalAmount, "KHRT: Insufficient balance for batch transfer");
        
        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(msg.sender, recipients[i], amounts[i]);
        }
        
        return true;
    }
}