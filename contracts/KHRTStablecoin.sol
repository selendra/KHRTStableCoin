// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract KHRTStablecoin is ERC20, Ownable, Pausable, ReentrancyGuard {
    mapping(address => bool) public whitelistedTokens;
    mapping(address => bool) public collateralMinters;
    mapping(address => bool) public normalMinters;
    
    // Events
    event TokenWhitelisted(address indexed token, bool status);
    event CollateralMinterAuthorized(address indexed minter, bool status);
    event NormalMinterAuthorized(address indexed minter, bool status);
    event TokensMintedWithCollateral(address indexed to, uint256 amount, address indexed collateralToken);
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event TokensBurnedFrom(address indexed owner, address indexed burner, uint256 amount);

    constructor() ERC20("Khmer Riel Token", "KHRT") Ownable(msg.sender) {
        collateralMinters[msg.sender] = true;
        normalMinters[msg.sender] = true;
    }

    /**
     * @dev Add or remove a token from whitelist
     * @param token Address of the ERC20 token
     * @param status True to whitelist, false to remove
     */
    function setTokenWhitelist(address token, bool status) external onlyOwner {
        require(token != address(0), "KHRT: Invalid token address");
        whitelistedTokens[token] = status;
        emit TokenWhitelisted(token, status);
    }

    /**
     * @dev Authorize or revoke collateral minting permissions
     * @param minter Address to authorize/revoke
     * @param status True to authorize, false to revoke
     */
    function setCollateralMinter(address minter, bool status) external onlyOwner {
        require(minter != address(0), "KHRT: Invalid minter address");
        collateralMinters[minter] = status;
        emit CollateralMinterAuthorized(minter, status);
    }

    /**
     * @dev Authorize or revoke normal minting permissions
     * @param minter Address to authorize/revoke
     * @param status True to authorize, false to revoke
     */
    function setNormalMinter(address minter, bool status) external onlyOwner {
        require(minter != address(0), "KHRT: Invalid minter address");
        normalMinters[minter] = status;
        emit NormalMinterAuthorized(minter, status);
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
     * @dev Mint KHRT tokens with collateral backing - only callable by authorized collateral minters
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     * @param collateralToken Address of collateral token (for verification)
     */
    function mintWithCollateral(
        address to, 
        uint256 amount, 
        address collateralToken
    ) external nonReentrant whenNotPaused {
        require(collateralMinters[msg.sender], "KHRT: Unauthorized collateral minter");
        require(whitelistedTokens[collateralToken], "KHRT: Token not whitelisted");
        require(to != address(0), "KHRT: Cannot mint to zero address");
        require(amount > 0, "KHRT: Amount must be greater than 0");

        _mint(to, amount);
        emit TokensMintedWithCollateral(to, amount, collateralToken);
    }

    /**
     * @dev Mint KHRT tokens - only callable by authorized normal minters
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external nonReentrant whenNotPaused {
        require(normalMinters[msg.sender], "KHRT: Unauthorized normal minter");
        require(to != address(0), "KHRT: Cannot mint to zero address");
        require(amount > 0, "KHRT: Amount must be greater than 0");

        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @dev Burn KHRT tokens from another address using allowance
     * @param owner Address that owns the tokens to burn
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address owner, uint256 amount) external nonReentrant whenNotPaused {
        require(owner != address(0), "KHRT: Cannot burn from zero address");
        require(amount > 0, "KHRT: Amount must be greater than 0");
        require(balanceOf(owner) >= amount, "KHRT: Insufficient balance to burn");
        
        uint256 currentAllowance = allowance(owner, msg.sender);
        require(currentAllowance >= amount, "KHRT: Insufficient allowance");

        _spendAllowance(owner, msg.sender, amount);
        _burn(owner, amount);
        emit TokensBurnedFrom(owner, msg.sender, amount);
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
     * @dev Override transfer to add pause functionality
     */
    function transfer(address to, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transfer(to, amount);
    }

    /**
     * @dev Override transferFrom to add pause functionality
     */
    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}