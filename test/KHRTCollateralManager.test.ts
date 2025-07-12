import { expect } from "chai";
import { ethers } from "hardhat";
import { KHRTStablecoin, KHRTCollateralManager, MockERC20 } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("KHRTCollateralManager", function () {
  let khrtToken: KHRTStablecoin;
  let collateralManager: KHRTCollateralManager;
  let mockUSDC: MockERC20;
  let mockUSDT: MockERC20;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

const USDC_DECIMALS = 6;
const USDT_DECIMALS = 6;
const KHRT_DECIMALS = 18;
  
  // Collateral ratios (for 6-decimal tokens to 18-decimal KHRT)
  const STABLECOIN_RATIO = ethers.parseUnits("1", 12); // 1e12 (correct for 6->18 decimal conversion)

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy KHRT token
    const KHRTStablecoin = await ethers.getContractFactory("KHRTStablecoin");
    khrtToken = await KHRTStablecoin.deploy();
    await khrtToken.waitForDeployment();

    // Deploy collateral manager
    const KHRTCollateralManager = await ethers.getContractFactory("KHRTCollateralManager");
    collateralManager = await KHRTCollateralManager.deploy(await khrtToken.getAddress());
    await collateralManager.waitForDeployment();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", USDC_DECIMALS);
    await mockUSDC.waitForDeployment();
    
    mockUSDT = await MockERC20.deploy("Mock USDT", "USDT", USDT_DECIMALS);
    await mockUSDT.waitForDeployment();

    // Setup permissions and whitelisting
    await khrtToken.setCollateralMinter(await collateralManager.getAddress(), true);
    await khrtToken.setTokenWhitelist(await mockUSDC.getAddress(), true);
    await khrtToken.setTokenWhitelist(await mockUSDT.getAddress(), true);

    // Set collateral ratios
    await collateralManager.setCollateralRatio(await mockUSDC.getAddress(), STABLECOIN_RATIO);
    await collateralManager.setCollateralRatio(await mockUSDT.getAddress(), STABLECOIN_RATIO);

    // Mint mock tokens to users
    const mintAmount = ethers.parseUnits("1000000", 6); // 1M tokens with 6 decimals
    await mockUSDC.mint(user1.address, mintAmount);
    await mockUSDC.mint(user2.address, mintAmount);
    await mockUSDT.mint(user1.address, mintAmount);
    await mockUSDT.mint(user2.address, mintAmount);
  });

  describe("Deployment", function () {
    it("Should set correct KHRT token address", async function () {
      expect(await collateralManager.khrtToken()).to.equal(await khrtToken.getAddress());
    });

    it("Should set correct minimum collateral ratio", async function () {
      expect(await collateralManager.getMinimumCollateralRatio()).to.equal(10000); // 100%
    });

    it("Should set owner correctly", async function () {
      expect(await collateralManager.owner()).to.equal(owner.address);
    });
  });

  describe("Collateral Ratio Management", function () {
    it("Should allow owner to set collateral ratios", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const newRatio = ethers.parseUnits("2", 12);

      await expect(collateralManager.setCollateralRatio(tokenAddress, newRatio))
        .to.emit(collateralManager, "CollateralRatioSet")
        .withArgs(tokenAddress, newRatio);

      expect(await collateralManager.getCollateralRatio(tokenAddress)).to.equal(newRatio);
    });

    it("Should reject setting ratio for non-whitelisted tokens", async function () {
      const nonWhitelistedToken = user1.address;
      
      await expect(collateralManager.setCollateralRatio(nonWhitelistedToken, STABLECOIN_RATIO))
        .to.be.revertedWith("CollateralManager: Token not whitelisted in KHRT");
    });

    it("Should reject zero ratio", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      
      await expect(collateralManager.setCollateralRatio(tokenAddress, 0))
        .to.be.revertedWith("CollateralManager: Ratio must be greater than 0");
    });

    it("Should reject non-owner setting ratios", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      
      await expect(collateralManager.connect(user1).setCollateralRatio(tokenAddress, STABLECOIN_RATIO))
        .to.be.revertedWithCustomError(collateralManager, "OwnableUnauthorizedAccount");
    });
  });

  describe("Collateral Deposit", function () {
    it("Should allow users to deposit collateral and mint KHRT", async function () {
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS); // 1000 USDC
      const expectedKHRT = ethers.parseUnits("1000", KHRT_DECIMALS); // 1000 KHRT
      const tokenAddress = await mockUSDC.getAddress();

      // Approve collateral manager to spend USDC
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);

      await expect(collateralManager.connect(user1).depositCollateral(tokenAddress, depositAmount))
        .to.emit(collateralManager, "CollateralDeposited")
        .withArgs(user1.address, tokenAddress, depositAmount, expectedKHRT);

      // Check balances
      expect(await khrtToken.balanceOf(user1.address)).to.equal(expectedKHRT);
      expect(await collateralManager.userCollateralBalances(user1.address, tokenAddress)).to.equal(depositAmount);
      expect(await collateralManager.userMintedAmounts(user1.address, tokenAddress)).to.equal(expectedKHRT);
      expect(await collateralManager.totalCollateralDeposited(tokenAddress)).to.equal(depositAmount);
    });

    it("Should calculate correct KHRT amount for different token decimals", async function () {
      // Test with different amounts
      const smallDeposit = ethers.parseUnits("100", USDC_DECIMALS); // 100 USDC
      const expectedSmallKHRT = ethers.parseUnits("100", KHRT_DECIMALS); // 100 KHRT
      
      const calculatedAmount = await collateralManager.calculateMintAmount(await mockUSDC.getAddress(), smallDeposit);
      expect(calculatedAmount).to.equal(expectedSmallKHRT);
    });

    it("Should reject deposits with zero amount", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      
      await expect(collateralManager.connect(user1).depositCollateral(tokenAddress, 0))
        .to.be.revertedWith("CollateralManager: Amount must be greater than 0");
    });

    it("Should reject deposits for tokens without set ratio", async function () {
      // Deploy new token without setting ratio
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20.deploy("New Token", "NEW", 18);
      await newToken.waitForDeployment();
      
      const depositAmount = ethers.parseUnits("1000", 18);
      
      await expect(collateralManager.connect(user1).depositCollateral(await newToken.getAddress(), depositAmount))
        .to.be.revertedWith("CollateralManager: Token ratio not set");
    });

    it("Should reject deposits that result in insufficient mint amount", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const tinyAmount = 1; // 1 wei of USDC
      
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), tinyAmount);
      
      await expect(collateralManager.connect(user1).depositCollateral(tokenAddress, tinyAmount))
        .to.be.revertedWith("KHRT: Below minimum mint amount");
    });

    it("Should handle multiple deposits from same user", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const firstDeposit = ethers.parseUnits("500", USDC_DECIMALS);
      const secondDeposit = ethers.parseUnits("300", USDC_DECIMALS);
      const totalDeposit = firstDeposit + secondDeposit;
      const totalKHRT = ethers.parseUnits("800", KHRT_DECIMALS);

      // First deposit
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), firstDeposit);
      await collateralManager.connect(user1).depositCollateral(tokenAddress, firstDeposit);

      // Second deposit
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), secondDeposit);
      await collateralManager.connect(user1).depositCollateral(tokenAddress, secondDeposit);

      expect(await collateralManager.userCollateralBalances(user1.address, tokenAddress)).to.equal(totalDeposit);
      expect(await collateralManager.userMintedAmounts(user1.address, tokenAddress)).to.equal(totalKHRT);
      expect(await khrtToken.balanceOf(user1.address)).to.equal(totalKHRT);
    });
  });

  describe("Collateral Withdrawal", function () {
    beforeEach(async function () {
      // Setup: User1 deposits 1000 USDC and mints 1000 KHRT
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const tokenAddress = await mockUSDC.getAddress();
      
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(tokenAddress, depositAmount);
    });

    it("Should allow users to withdraw collateral by burning KHRT", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const burnAmount = ethers.parseUnits("500", KHRT_DECIMALS); // Burn 500 KHRT
      const expectedCollateral = ethers.parseUnits("500", USDC_DECIMALS); // Get 500 USDC back

      // Approve collateral manager to burn KHRT
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), burnAmount);

      const initialUSDCBalance = await mockUSDC.balanceOf(user1.address);

      await expect(collateralManager.connect(user1).withdrawCollateral(tokenAddress, burnAmount))
        .to.emit(collateralManager, "CollateralWithdrawn")
        .withArgs(user1.address, tokenAddress, expectedCollateral, burnAmount);

      // Check balances after withdrawal
      expect(await mockUSDC.balanceOf(user1.address)).to.equal(initialUSDCBalance + expectedCollateral);
      expect(await collateralManager.userCollateralBalances(user1.address, tokenAddress))
        .to.equal(ethers.parseUnits("500", USDC_DECIMALS));
      expect(await collateralManager.userMintedAmounts(user1.address, tokenAddress))
        .to.equal(ethers.parseUnits("500", KHRT_DECIMALS));
    });

    it("Should allow users to withdraw their entire position gradually", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const initialUSDCBalance = await mockUSDC.balanceOf(user1.address);
      const totalKHRT = await khrtToken.balanceOf(user1.address);

      // Withdraw in two parts
      const firstWithdraw = ethers.parseUnits("600", KHRT_DECIMALS);
      const secondWithdraw = ethers.parseUnits("400", KHRT_DECIMALS);

      // First withdrawal
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), firstWithdraw);
      await collateralManager.connect(user1).withdrawCollateral(tokenAddress, firstWithdraw);

      // Second withdrawal  
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), secondWithdraw);
      await collateralManager.connect(user1).withdrawCollateral(tokenAddress, secondWithdraw);

      // Check all balances are reset
      expect(await collateralManager.userCollateralBalances(user1.address, tokenAddress)).to.equal(0);
      expect(await collateralManager.userMintedAmounts(user1.address, tokenAddress)).to.equal(0);
      expect(await khrtToken.balanceOf(user1.address)).to.equal(0);
      expect(await mockUSDC.balanceOf(user1.address)).to.equal(initialUSDCBalance + ethers.parseUnits("1000", USDC_DECIMALS));
    });

    it("Should reject withdrawal of more KHRT than minted", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const excessAmount = ethers.parseUnits("1500", KHRT_DECIMALS); // More than minted

      await expect(collateralManager.connect(user1).withdrawCollateral(tokenAddress, excessAmount))
        .to.be.revertedWith("CollateralManager: Insufficient minted amount");
    });

    it("Should reject withdrawal without sufficient KHRT allowance", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const burnAmount = ethers.parseUnits("500", KHRT_DECIMALS);

      // Don't approve KHRT burning
      await expect(collateralManager.connect(user1).withdrawCollateral(tokenAddress, burnAmount))
        .to.be.revertedWith("KHRT: Insufficient allowance");
    });

    it("Should enforce minimum collateral ratio on partial withdrawals", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      
      // User has 1000 USDC collateral and 1000 KHRT minted
      // The current system enforces exact 1:1 backing (100% ratio)
      
      // Try to withdraw slightly more KHRT than the collateral can back
      // This should fail because there isn't enough collateral
      const excessAmount = ethers.parseUnits("1000.000001", KHRT_DECIMALS); // Just slightly more than 1000
      
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), excessAmount);
      
      // This should fail with "Insufficient minted amount" since user only has exactly 1000 KHRT
      await expect(collateralManager.connect(user1).withdrawCollateral(tokenAddress, excessAmount))
        .to.be.revertedWith("CollateralManager: Insufficient minted amount");
    });

    it("Should handle precision correctly with odd amounts", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      
      // First withdraw all existing collateral to start fresh
      const existingKHRT = await khrtToken.balanceOf(user1.address);
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), existingKHRT);
      await collateralManager.connect(user1).withdrawCollateral(tokenAddress, existingKHRT);
      
      // Create a scenario where rounding could cause issues
      const oddAmount = ethers.parseUnits("1000", USDC_DECIMALS) + 1n; // 1000 USDC + 1 wei
      
      // Make the odd deposit
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), oddAmount);
      await collateralManager.connect(user1).depositCollateral(tokenAddress, oddAmount);
      
      const khrtMinted = await khrtToken.balanceOf(user1.address);
      
      // Try to withdraw 1 wei more KHRT than what should be backed by collateral
      const withdrawAmount = khrtMinted + 1n;
      
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), withdrawAmount);
      
      await expect(collateralManager.connect(user1).withdrawCollateral(tokenAddress, withdrawAmount))
        .to.be.revertedWith("CollateralManager: Insufficient minted amount");
    });
  });

  describe("Position Management", function () {
    beforeEach(async function () {
      // Setup: User1 deposits 1000 USDC and mints 1000 KHRT
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const tokenAddress = await mockUSDC.getAddress();
      
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(tokenAddress, depositAmount);
    });

    it("Should return correct user position info", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const position = await collateralManager.getUserPosition(user1.address, tokenAddress);

      expect(position.collateralBalance).to.equal(ethers.parseUnits("1000", USDC_DECIMALS));
      expect(position.mintedAmount).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));
      expect(position.collateralRatio).to.equal(10000); // 100% in basis points
      expect(position.maxWithdrawableKHRT).to.equal(0); // At minimum ratio, can't withdraw more
    });

    it("Should calculate current collateral ratio correctly", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const ratio = await collateralManager.getCurrentCollateralRatio(user1.address, tokenAddress);
      
      expect(ratio).to.equal(10000); // 100% in basis points
    });

    it("Should check position health correctly", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      
      expect(await collateralManager.isPositionHealthy(user1.address, tokenAddress)).to.be.true;
    });

    it("Should handle additional deposits correctly", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      
      // Additional deposit to existing position
      const additionalDeposit = ethers.parseUnits("500", USDC_DECIMALS);
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), additionalDeposit);
      await collateralManager.connect(user1).depositCollateral(tokenAddress, additionalDeposit);

      const position = await collateralManager.getUserPosition(user1.address, tokenAddress);
      
      // Total collateral: 1500 USDC, Total minted: 1500 KHRT
      // Ratio should be 100% (10000 basis points)
      expect(position.collateralBalance).to.equal(ethers.parseUnits("1500", USDC_DECIMALS));
      expect(position.mintedAmount).to.equal(ethers.parseUnits("1500", KHRT_DECIMALS));
      expect(position.collateralRatio).to.equal(10000);
    });
  });

  describe("Multiple Collateral Types", function () {
    it("Should handle different collateral tokens independently", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const usdtAddress = await mockUSDT.getAddress();
      
      const depositAmount = ethers.parseUnits("1000", 6);

      // Deposit USDC
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(usdcAddress, depositAmount);

      // Deposit USDT
      await mockUSDT.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(usdtAddress, depositAmount);

      // Check separate positions
      const usdcPosition = await collateralManager.getUserPosition(user1.address, usdcAddress);
      const usdtPosition = await collateralManager.getUserPosition(user1.address, usdtAddress);

      expect(usdcPosition.collateralBalance).to.equal(depositAmount);
      expect(usdtPosition.collateralBalance).to.equal(depositAmount);
      expect(usdcPosition.mintedAmount).to.equal(ethers.parseUnits("1000", 18));
      expect(usdtPosition.mintedAmount).to.equal(ethers.parseUnits("1000", 18));

      // Total KHRT should be 2000
      expect(await khrtToken.balanceOf(user1.address)).to.equal(ethers.parseUnits("2000", 18));
    });

    it("Should allow independent withdrawals from different collateral types", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const usdtAddress = await mockUSDT.getAddress();
      
      const depositAmount = ethers.parseUnits("1000", 6);

      // Setup positions in both tokens
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(usdcAddress, depositAmount);

      await mockUSDT.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(usdtAddress, depositAmount);

      // Withdraw entire USDC position using partial withdrawals
      const usdcMintedAmount = await collateralManager.userMintedAmounts(user1.address, usdcAddress);
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), usdcMintedAmount);
      await collateralManager.connect(user1).withdrawCollateral(usdcAddress, usdcMintedAmount);

      // Check USDC position is cleared but USDT remains
      const usdcPosition = await collateralManager.getUserPosition(user1.address, usdcAddress);
      const usdtPosition = await collateralManager.getUserPosition(user1.address, usdtAddress);

      expect(usdcPosition.collateralBalance).to.equal(0);
      expect(usdcPosition.mintedAmount).to.equal(0);
      expect(usdtPosition.collateralBalance).to.equal(depositAmount);
      expect(usdtPosition.mintedAmount).to.equal(ethers.parseUnits("1000", 18));
      
      // User should have only 1000 KHRT left (from USDT position)
      expect(await khrtToken.balanceOf(user1.address)).to.equal(ethers.parseUnits("1000", 18));
    });
  });

  describe("Administrative Functions", function () {
    it("Should allow owner to perform emergency withdrawal", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      
      // User deposits collateral
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(tokenAddress, depositAmount);

      const ownerInitialBalance = await mockUSDC.balanceOf(owner.address);
      
      await expect(collateralManager.emergencyWithdraw(tokenAddress, depositAmount))
        .to.emit(collateralManager, "EmergencyWithdrawal")
        .withArgs(tokenAddress, depositAmount);

      expect(await mockUSDC.balanceOf(owner.address)).to.equal(ownerInitialBalance + depositAmount);
    });

    it("Should reject emergency withdrawal from non-owner", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const amount = ethers.parseUnits("1000", USDC_DECIMALS);
      
      await expect(collateralManager.connect(user1).emergencyWithdraw(tokenAddress, amount))
        .to.be.revertedWithCustomError(collateralManager, "OwnableUnauthorizedAccount");
    });

    it("Should allow owner to pause and unpause", async function () {
      await collateralManager.pause();
      expect(await collateralManager.paused()).to.be.true;

      // Should reject operations when paused
      const tokenAddress = await mockUSDC.getAddress();
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      
      await expect(collateralManager.connect(user1).depositCollateral(tokenAddress, depositAmount))
        .to.be.revertedWithCustomError(collateralManager, "EnforcedPause");

      // Unpause and operations should work
      await collateralManager.unpause();
      expect(await collateralManager.paused()).to.be.false;
    });
  });

  describe("View Functions", function () {
    it("Should return correct total collateral deposited", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const depositAmount1 = ethers.parseUnits("1000", USDC_DECIMALS);
      const depositAmount2 = ethers.parseUnits("500", USDC_DECIMALS);

      // User1 deposits
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount1);
      await collateralManager.connect(user1).depositCollateral(tokenAddress, depositAmount1);

      // User2 deposits
      await mockUSDC.connect(user2).approve(await collateralManager.getAddress(), depositAmount2);
      await collateralManager.connect(user2).depositCollateral(tokenAddress, depositAmount2);

      expect(await collateralManager.getTotalCollateralDeposited(tokenAddress))
        .to.equal(depositAmount1 + depositAmount2);
    });

    it("Should calculate collateral needed correctly", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      const khrtAmount = ethers.parseUnits("500", KHRT_DECIMALS);
      const expectedCollateral = ethers.parseUnits("500", USDC_DECIMALS);

      expect(await collateralManager.calculateCollateralNeeded(tokenAddress, khrtAmount))
        .to.equal(expectedCollateral);
    });
  });

  describe("Edge Cases", function () {
    it("Should handle very small amounts correctly", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      // Deposit amount that results in exactly 1 KHRT (1e18 wei)
      const minDeposit = BigInt(1); // 1 wei of USDC
      
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), minDeposit);
      
      // This should fail with "KHRT: Below minimum mint amount" because 1 wei * 1e12 = 1e12 wei KHRT
      // which is less than MIN_MINT_AMOUNT (1e18)
      await expect(collateralManager.connect(user1).depositCollateral(tokenAddress, minDeposit))
        .to.be.revertedWith("KHRT: Below minimum mint amount");
    });

    it("Should handle positions with zero minted amount", async function () {
      const tokenAddress = await mockUSDC.getAddress();
      
      const position = await collateralManager.getUserPosition(user2.address, tokenAddress);
      expect(position.collateralBalance).to.equal(0);
      expect(position.mintedAmount).to.equal(0);
      expect(position.collateralRatio).to.equal(0);
      
      expect(await collateralManager.isPositionHealthy(user2.address, tokenAddress)).to.be.true;
    });

    it("Should reject operations with invalid addresses", async function () {
      await expect(collateralManager.connect(user1).depositCollateral(ethers.ZeroAddress, 1000))
        .to.be.revertedWith("CollateralManager: Invalid token address");
    });
  });
});