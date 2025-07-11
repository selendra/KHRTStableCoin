// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IKHRTStablecoin {
    function mintWithCollateral(address to, uint256 amount, address collateralToken) external;
    function burnFrom(address owner, uint256 amount) external;
    function isTokenWhitelisted(address token) external view returns (bool);
    function isCollateralMinter(address minter) external view returns (bool);
}

contract KHRTCollateralManager is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IKHRTStablecoin public immutable khrtToken;
    
    // Collateral token address => ratio (how many collateral tokens = 1 KHRT)
    mapping(address => uint256) public collateralRatios;
    
    // User address => collateral token => deposited amount
    mapping(address => mapping(address => uint256)) public userCollateralBalances;
    
    // Collateral token => total deposited amount
    mapping(address => uint256) public totalCollateralDeposited;
    
    // User address => collateral token => minted KHRT amount
    mapping(address => mapping(address => uint256)) public userMintedAmounts;

    // Events
    event CollateralRatioSet(address indexed token, uint256 ratio);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount, uint256 mintedKHRT);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 burnedKHRT);
    event EmergencyWithdrawal(address indexed token, uint256 amount);

    constructor(address _khrtToken) Ownable(msg.sender) {
        require(_khrtToken != address(0), "CollateralManager: Invalid KHRT token address");
        khrtToken = IKHRTStablecoin(_khrtToken);
    }

    /**
     * @dev Set collateral ratio for a token
     * @param token Address of the collateral token
     * @param ratio How many collateral tokens equal 1 KHRT (e.g., 1000 for 1000:1 ratio)
     */
    function setCollateralRatio(address token, uint256 ratio) external onlyOwner {
        require(token != address(0), "CollateralManager: Invalid token address");
        require(ratio > 0, "CollateralManager: Ratio must be greater than 0");
        require(khrtToken.isTokenWhitelisted(token), "CollateralManager: Token not whitelisted in KHRT");
        
        collateralRatios[token] = ratio;
        emit CollateralRatioSet(token, ratio);
    }

    /**
     * @dev Deposit collateral and mint KHRT tokens
     * @param token Address of the collateral token
     * @param amount Amount of collateral tokens to deposit
     */
    function depositCollateral(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(token != address(0), "CollateralManager: Invalid token address");
        require(amount > 0, "CollateralManager: Amount must be greater than 0");
        require(collateralRatios[token] > 0, "CollateralManager: Token ratio not set");
        require(khrtToken.isTokenWhitelisted(token), "CollateralManager: Token not whitelisted");
        require(khrtToken.isCollateralMinter(address(this)), "CollateralManager: Not authorized as collateral minter");

        // Calculate KHRT amount to mint based on ratio
        uint256 khrtAmount = amount / collateralRatios[token];
        require(khrtAmount > 0, "CollateralManager: Insufficient collateral for minimum mint");

        // Transfer collateral from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        userCollateralBalances[msg.sender][token] += amount;
        totalCollateralDeposited[token] += amount;
        userMintedAmounts[msg.sender][token] += khrtAmount;

        // Mint KHRT tokens
        khrtToken.mintWithCollateral(msg.sender, khrtAmount, token);

        emit CollateralDeposited(msg.sender, token, amount, khrtAmount);
    }

    /**
     * @dev Withdraw collateral by burning KHRT tokens
     * @param token Address of the collateral token
     * @param khrtAmount Amount of KHRT tokens to burn
     */
    function withdrawCollateral(address token, uint256 khrtAmount) external nonReentrant whenNotPaused {
        require(token != address(0), "CollateralManager: Invalid token address");
        require(khrtAmount > 0, "CollateralManager: Amount must be greater than 0");
        require(collateralRatios[token] > 0, "CollateralManager: Token ratio not set");
        require(userMintedAmounts[msg.sender][token] >= khrtAmount, "CollateralManager: Insufficient minted amount");

        // Calculate collateral amount to return
        uint256 collateralAmount = khrtAmount * collateralRatios[token];
        require(userCollateralBalances[msg.sender][token] >= collateralAmount, "CollateralManager: Insufficient collateral balance");

        // Burn KHRT tokens first
        khrtToken.burnFrom(msg.sender, khrtAmount);

        // Update balances
        userCollateralBalances[msg.sender][token] -= collateralAmount;
        totalCollateralDeposited[token] -= collateralAmount;
        userMintedAmounts[msg.sender][token] -= khrtAmount;

        // Transfer collateral back to user
        IERC20(token).safeTransfer(msg.sender, collateralAmount);

        emit CollateralWithdrawn(msg.sender, token, collateralAmount, khrtAmount);
    }

    /**
     * @dev Withdraw all collateral for a specific token by burning all corresponding KHRT
     * @param token Address of the collateral token
     */
    function withdrawAllCollateral(address token) external nonReentrant whenNotPaused {
        require(token != address(0), "CollateralManager: Invalid token address");
        
        uint256 userCollateral = userCollateralBalances[msg.sender][token];
        uint256 userMinted = userMintedAmounts[msg.sender][token];
        
        require(userCollateral > 0, "CollateralManager: No collateral to withdraw");
        require(userMinted > 0, "CollateralManager: No minted tokens to burn");

        // Burn all KHRT tokens
        khrtToken.burnFrom(msg.sender, userMinted);

        // Update balances
        userCollateralBalances[msg.sender][token] = 0;
        totalCollateralDeposited[token] -= userCollateral;
        userMintedAmounts[msg.sender][token] = 0;

        // Transfer all collateral back to user
        IERC20(token).safeTransfer(msg.sender, userCollateral);

        emit CollateralWithdrawn(msg.sender, token, userCollateral, userMinted);
    }

    /**
     * @dev Get user's collateral balance and minted amount for a token
     * @param user Address of the user
     * @param token Address of the collateral token
     */
    function getUserPosition(address user, address token) external view returns (
        uint256 collateralBalance,
        uint256 mintedAmount,
        uint256 withdrawableCollateral
    ) {
        collateralBalance = userCollateralBalances[user][token];
        mintedAmount = userMintedAmounts[user][token];
        
        // Calculate how much collateral can be withdrawn with current minted amount
        if (collateralRatios[token] > 0) {
            withdrawableCollateral = mintedAmount * collateralRatios[token];
        }
    }

    /**
     * @dev Get collateral ratio for a token
     * @param token Address of the collateral token
     */
    function getCollateralRatio(address token) external view returns (uint256) {
        return collateralRatios[token];
    }

    /**
     * @dev Calculate how much KHRT can be minted with given collateral amount
     * @param token Address of the collateral token
     * @param collateralAmount Amount of collateral tokens
     */
    function calculateMintAmount(address token, uint256 collateralAmount) external view returns (uint256) {
        if (collateralRatios[token] == 0) return 0;
        return collateralAmount / collateralRatios[token];
    }

    /**
     * @dev Calculate how much collateral is needed to mint given KHRT amount
     * @param token Address of the collateral token
     * @param khrtAmount Amount of KHRT tokens to mint
     */
    function calculateCollateralNeeded(address token, uint256 khrtAmount) external view returns (uint256) {
        return khrtAmount * collateralRatios[token];
    }

    /**
     * @dev Get total collateral deposited for a token
     * @param token Address of the collateral token
     */
    function getTotalCollateralDeposited(address token) external view returns (uint256) {
        return totalCollateralDeposited[token];
    }

    /**
     * @dev Emergency withdrawal function - only owner can use this
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "CollateralManager: Invalid token address");
        require(amount > 0, "CollateralManager: Amount must be greater than 0");
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amount, "CollateralManager: Insufficient balance");

        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(token, amount);
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
}