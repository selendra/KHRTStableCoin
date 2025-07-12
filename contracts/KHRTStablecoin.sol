// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract KHRTStablecoin is ERC20, Ownable, Pausable, ReentrancyGuard {
    
    // Constants
    uint256 public constant MIN_MINT_AMOUNT = 1e18; // 1 KHRT minimum mint
    uint256 public constant MIN_BURN_AMOUNT = 1e18; // 1 KHRT minimum burn
    
    // State variables
    uint256 public maxSupply = 1_000_000_000 * 1e18; // 1 billion KHRT initial max supply
    mapping(address => bool) public whitelistedTokens;
    mapping(address => bool) public collateralMinters;
    mapping(address => bool) public normalMinters;
    mapping(address => bool) public blacklistedUsers;
    
    // Events
    event TokenWhitelisted(address indexed token, bool status);
    event CollateralMinterAuthorized(address indexed minter, bool status);
    event NormalMinterAuthorized(address indexed minter, bool status);
    event UserBlacklisted(address indexed user, bool status);
    event TokensMintedWithCollateral(address indexed to, uint256 amount, address indexed collateralToken);
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event TokensBurnedFrom(address indexed owner, address indexed burner, uint256 amount);
    event MaxSupplyIncreased(uint256 oldMaxSupply, uint256 newMaxSupply, address indexed increasedBy);

    constructor() ERC20("Khmer Riel Token", "KHRT") Ownable(msg.sender) {
        collateralMinters[msg.sender] = true;
        normalMinters[msg.sender] = true;
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
     * @dev Add or remove a token from whitelist
     * @param token Address of the ERC20 token
     * @param status True to whitelist, false to remove
     */
    function setTokenWhitelist(address token, bool status) external onlyOwner validAddress(token) {
        whitelistedTokens[token] = status;
        emit TokenWhitelisted(token, status);
    }

    /**
     * @dev Batch whitelist multiple tokens
     * @param tokens Array of token addresses
     * @param statuses Array of corresponding statuses
     */
    function batchSetTokenWhitelist(address[] calldata tokens, bool[] calldata statuses) external onlyOwner {
        require(tokens.length == statuses.length, "KHRT: Arrays length mismatch");
        require(tokens.length <= 50, "KHRT: Too many tokens");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "KHRT: Invalid token address");
            whitelistedTokens[tokens[i]] = statuses[i];
            emit TokenWhitelisted(tokens[i], statuses[i]);
        }
    }

    /**
     * @dev Authorize or revoke collateral minting permissions
     * @param minter Address to authorize/revoke
     * @param status True to authorize, false to revoke
     */
    function setCollateralMinter(address minter, bool status) external onlyOwner validAddress(minter) {
        collateralMinters[minter] = status;
        emit CollateralMinterAuthorized(minter, status);
    }

    /**
     * @dev Authorize or revoke normal minting permissions
     * @param minter Address to authorize/revoke
     * @param status True to authorize, false to revoke
     */
    function setNormalMinter(address minter, bool status) external onlyOwner validAddress(minter) {
        normalMinters[minter] = status;
        emit NormalMinterAuthorized(minter, status);
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
     * @dev Check if a token is whitelisted
     * @param token Address of the token to check
     */
    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelistedTokens[token];
    }

    /**
     * @dev Check if an address is a collateral minter
     * @param minter Address to check
     */
    function isCollateralMinter(address minter) external view returns (bool) {
        return collateralMinters[minter];
    }

    /**
     * @dev Check if an address is a normal minter
     * @param minter Address to check
     */
    function isNormalMinter(address minter) external view returns (bool) {
        return normalMinters[minter];
    }

    /**
     * @dev Check if a user is blacklisted
     * @param user Address to check
     */
    function isUserBlacklisted(address user) external view returns (bool) {
        return blacklistedUsers[user];
    }

    /**
     * @dev Mint KHRT tokens with collateral backing - only callable by authorized collateral minters
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     * @param collateralToken Address of collateral token (for verification)
     */
    function mintWithCollateral(
        address to, 
        uint256 amount, 
        address collateralToken
    ) external 
        nonReentrant 
        whenNotPaused 
        validAddress(to)
        validAmount(amount)
        checkSupplyLimit(amount)
        notBlacklisted(to)
    {
        require(collateralMinters[msg.sender], "KHRT: Unauthorized collateral minter");
        require(whitelistedTokens[collateralToken], "KHRT: Token not whitelisted");
        require(amount >= MIN_MINT_AMOUNT, "KHRT: Below minimum mint amount");

        _mint(to, amount);
        emit TokensMintedWithCollateral(to, amount, collateralToken);
    }

    /**
     * @dev Mint KHRT tokens - only callable by authorized normal minters
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
        require(normalMinters[msg.sender], "KHRT: Unauthorized normal minter");
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