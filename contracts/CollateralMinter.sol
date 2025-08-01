// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IKHRTStablecoin {
    function mint(address to, uint256 amount) external;
    function burnFrom(address owner, uint256 amount) external;
    function isAuthorizedMinter(address minter) external view returns (bool);
    function decimals() external view returns (uint8);
}

contract CollateralMinter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IKHRTStablecoin public immutable khrtToken;
    
    // Minimum collateral ratio (100% = 10000 basis points)
    uint256 public constant MIN_COLLATERAL_RATIO = 10000; // 100%
    
    // Scaling factor for ratio precision (18 decimals)
    uint256 public constant RATIO_PRECISION = 1e18;
    
    // Whitelist for collateral tokens
    mapping(address => bool) public whitelistedTokens;
    
    // Collateral token address => ratio (KHRT amount per 1 collateral token, scaled by RATIO_PRECISION)
    // Example: 1 USDT = 4000 KHRT would be stored as 4000 * 1e18
    mapping(address => uint256) public collateralRatios;
    
    // User address => collateral token => deposited amount
    mapping(address => mapping(address => uint256)) public userCollateralBalances;
    
    // Collateral token => total deposited amount
    mapping(address => uint256) public totalCollateralDeposited;
    
    // User address => collateral token => minted KHRT amount
    mapping(address => mapping(address => uint256)) public userMintedAmounts;

    // Events
    event TokenWhitelisted(address indexed token, bool status);
    event CollateralRatioSet(address indexed token, uint256 ratio);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount, uint256 mintedKHRT);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 burnedKHRT);
    event TokensMinted(address indexed to, uint256 amount);
    event EmergencyWithdrawal(address indexed token, uint256 amount);

    constructor(address _khrtToken) Ownable(msg.sender) {
        require(_khrtToken != address(0), "CollateralManager: Invalid KHRT token address");
        khrtToken = IKHRTStablecoin(_khrtToken);
    }

    /**
     * @dev Add or remove a token from whitelist
     * @param token Address of the ERC20 token
     * @param status True to whitelist, false to remove
     */
    function setTokenWhitelist(address token, bool status) external onlyOwner {
        require(token != address(0), "CollateralManager: Invalid token address");
        whitelistedTokens[token] = status;
        emit TokenWhitelisted(token, status);
    }

    /**
     * @dev Check if a token is whitelisted
     * @param token Address of the token to check
     */
    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelistedTokens[token];
    }

    /**
     * @dev Set collateral ratio for a token
     * @param token Address of the collateral token
     * @param khrtPerToken How many KHRT tokens are minted per 1 unit of collateral token
     * Example: setCollateralRatio(USDT, 4000) for 1 USDT = 4000 KHRT
     * Example: setCollateralRatio(ETH, 8000000) for 1 ETH = 8,000,000 KHRT
     */
    function setCollateralRatio(address token, uint256 khrtPerToken) external onlyOwner {
        require(token != address(0), "CollateralManager: Invalid token address");
        require(khrtPerToken > 0, "CollateralManager: Ratio must be greater than 0");
        require(whitelistedTokens[token], "CollateralManager: Token not whitelisted");
        
        // Store the ratio scaled by precision factor
        collateralRatios[token] = khrtPerToken * RATIO_PRECISION;
        emit CollateralRatioSet(token, khrtPerToken);
    }

    /**
     * @dev Get token decimals, with fallback to 18 if not available
     */
    function getTokenDecimals(address token) public view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // Default fallback
        }
    }

    /**
     * @dev Calculate KHRT amount to mint based on collateral amount and ratio
     * @param token Address of the collateral token
     * @param collateralAmount Amount of collateral tokens (in token's native decimals)
     * @return khrtAmount Amount of KHRT to mint (in KHRT's native decimals)
     */
    function calculateKHRTAmount(address token, uint256 collateralAmount) public view returns (uint256 khrtAmount) {
        if (collateralRatios[token] == 0) return 0;
        
        uint8 collateralDecimals = getTokenDecimals(token);
        uint8 khrtDecimals = khrtToken.decimals();
        
        // Formula: khrtAmount = (collateralAmount * ratio * 10^khrtDecimals) / (RATIO_PRECISION * 10^collateralDecimals)
        khrtAmount = (collateralAmount * collateralRatios[token] * (10 ** khrtDecimals)) / 
                     (RATIO_PRECISION * (10 ** collateralDecimals));
    }

    /**
     * @dev Calculate collateral amount needed for given KHRT amount
     * @param token Address of the collateral token
     * @param khrtAmount Amount of KHRT tokens (in KHRT's native decimals)
     * @return collateralAmount Amount of collateral needed (in token's native decimals)
     */
    function calculateCollateralAmount(address token, uint256 khrtAmount) public view returns (uint256 collateralAmount) {
        if (collateralRatios[token] == 0) return 0;
        
        uint8 collateralDecimals = getTokenDecimals(token);
        uint8 khrtDecimals = khrtToken.decimals();
        
        // Formula: collateralAmount = (khrtAmount * RATIO_PRECISION * 10^collateralDecimals) / (ratio * 10^khrtDecimals)
        // Use ceiling division to ensure sufficient collateral
        uint256 numerator = khrtAmount * RATIO_PRECISION * (10 ** collateralDecimals);
        uint256 denominator = collateralRatios[token] * (10 ** khrtDecimals);
        
        collateralAmount = (numerator + denominator - 1) / denominator; // Ceiling division
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
        require(whitelistedTokens[token], "CollateralManager: Token not whitelisted");
        require(khrtToken.isAuthorizedMinter(address(this)), "CollateralManager: Not authorized as minter");

        // Calculate KHRT amount to mint based on ratio and decimals
        uint256 khrtAmount = calculateKHRTAmount(token, amount);
        require(khrtAmount > 0, "CollateralManager: Insufficient collateral for minimum mint");

        // Transfer collateral from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        userCollateralBalances[msg.sender][token] += amount;
        totalCollateralDeposited[token] += amount;
        userMintedAmounts[msg.sender][token] += khrtAmount;

        // Mint KHRT tokens
        khrtToken.mint(msg.sender, khrtAmount);

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

        // Calculate collateral amount with protocol-favorable rounding
        uint256 collateralAmount = calculateCollateralAmount(token, khrtAmount);
        
        require(userCollateralBalances[msg.sender][token] >= collateralAmount, "CollateralManager: Insufficient collateral balance");

        // Check minimum collateral ratio (100%) - ensure remaining position is properly collateralized
        uint256 remainingMinted = userMintedAmounts[msg.sender][token] - khrtAmount;
        if (remainingMinted > 0) {
            uint256 remainingCollateral = userCollateralBalances[msg.sender][token] - collateralAmount;
            uint256 requiredCollateral = calculateCollateralAmount(token, remainingMinted);
            require(remainingCollateral >= requiredCollateral, "CollateralManager: Would violate minimum collateral ratio");
        }

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
     * @dev Get user's collateral balance and minted amount for a token
     * @param user Address of the user
     * @param token Address of the collateral token
     */
    function getUserPosition(address user, address token) external view returns (
        uint256 collateralBalance,
        uint256 mintedAmount,
        uint256 collateralRatio,
        uint256 maxWithdrawableKHRT
    ) {
        collateralBalance = userCollateralBalances[user][token];
        mintedAmount = userMintedAmounts[user][token];
        
        // Calculate current collateral ratio (in basis points, 10000 = 100%)
        if (mintedAmount > 0 && collateralRatios[token] > 0) {
            uint256 requiredCollateral = calculateCollateralAmount(token, mintedAmount);
            if (requiredCollateral > 0) {
                collateralRatio = (collateralBalance * 10000) / requiredCollateral;
            } else {
                collateralRatio = 0;
            }
        } else {
            collateralRatio = 0;
        }
        
        // Calculate maximum KHRT that can be withdrawn while maintaining minimum ratio
        if (mintedAmount > 0 && collateralBalance > 0 && collateralRatios[token] > 0) {
            uint256 requiredCollateral = calculateCollateralAmount(token, mintedAmount);
            if (collateralBalance > requiredCollateral) {
                uint256 maxWithdrawableCollateral = collateralBalance - requiredCollateral;
                maxWithdrawableKHRT = calculateKHRTAmount(token, maxWithdrawableCollateral);
            } else {
                maxWithdrawableKHRT = 0;
            }
        } else {
            maxWithdrawableKHRT = mintedAmount; // Can withdraw all if no collateral restrictions
        }
    }

    /**
     * @dev Get collateral ratio for a token (KHRT per 1 token)
     * @param token Address of the collateral token
     */
    function getCollateralRatio(address token) external view returns (uint256) {
        return collateralRatios[token] / RATIO_PRECISION;
    }

    /**
     * @dev Calculate how much KHRT can be minted with given collateral amount
     * @param token Address of the collateral token
     * @param collateralAmount Amount of collateral tokens
     */
    function calculateMintAmount(address token, uint256 collateralAmount) external view returns (uint256) {
        return calculateKHRTAmount(token, collateralAmount);
    }

     /**
     * @dev Calculate how much collateral is needed to mint given KHRT amount
     * @param token Address of the collateral token
     * @param khrtAmount Amount of KHRT tokens to mint
     */
    function calculateCollateralNeeded(address token, uint256 khrtAmount) external view returns (uint256) {
        return calculateCollateralAmount(token, khrtAmount);
    }

    /**
     * @dev Get the minimum collateral ratio requirement
     * @return ratio Minimum collateral ratio in basis points (10000 = 100%)
     */
    function getMinimumCollateralRatio() external pure returns (uint256) {
        return MIN_COLLATERAL_RATIO;
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