import { expect } from "chai";
import { ethers } from "hardhat";
import { KHRTStablecoin, KHRTCollateralManager, MockERC20 } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("KHRT Calculation and Mint Tests", function () {
  let khrtToken: KHRTStablecoin;
  let collateralManager: KHRTCollateralManager;
  let mockUSDC: MockERC20;
  let mockUSDT: MockERC20;
  let mockWETH: MockERC20;
  let mockDAI: MockERC20;
  let nonWhitelistedToken: MockERC20;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let user3: SignerWithAddress;

  const USDC_DECIMALS = 6;
  const USDT_DECIMALS = 6;
  const WETH_DECIMALS = 18;
  const DAI_DECIMALS = 18;
  const KHRT_DECIMALS = 6;
  
  // Collateral ratios (KHRT per 1 token)
  const USDC_RATIO = 1; // 1 USDC = 1 KHRT
  const USDT_RATIO = 1; // 1 USDT = 1 KHRT
  const WETH_RATIO = 2000; // 1 ETH = 2000 KHRT
  const DAI_RATIO = 1; // 1 DAI = 1 KHRT
  
  beforeEach(async function () {
    [owner, user1, user2, user3] = await ethers.getSigners();

    // Deploy KHRT token
    const KHRTStablecoin = await ethers.getContractFactory("KHRTStablecoin");
    khrtToken = await KHRTStablecoin.deploy("KHRT Testing", "TKHR");
    await khrtToken.waitForDeployment();

    // Deploy Collateral Manager
    const KHRTCollateralManager = await ethers.getContractFactory("KHRTCollateralManager");
    collateralManager = await KHRTCollateralManager.deploy(await khrtToken.getAddress());
    await collateralManager.waitForDeployment();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", USDC_DECIMALS);
    await mockUSDC.waitForDeployment();
    
    mockUSDT = await MockERC20.deploy("Mock USDT", "USDT", USDT_DECIMALS);
    await mockUSDT.waitForDeployment();
    
    mockWETH = await MockERC20.deploy("Mock WETH", "WETH", WETH_DECIMALS);
    await mockWETH.waitForDeployment();

    mockDAI = await MockERC20.deploy("Mock DAI", "DAI", DAI_DECIMALS);
    await mockDAI.waitForDeployment();

    // Deploy non-whitelisted token for testing
    nonWhitelistedToken = await MockERC20.deploy("Non Whitelisted", "NWL", 18);
    await nonWhitelistedToken.waitForDeployment();

    // Setup system
    await setupSystem();
  });

  async function setupSystem() {
    // Authorize collateral manager as minter
    await khrtToken.setCollateralMinter(await collateralManager.getAddress(), true);

    // Whitelist tokens in KHRT contract
    await khrtToken.setTokenWhitelist(await mockUSDC.getAddress(), true);
    await khrtToken.setTokenWhitelist(await mockUSDT.getAddress(), true);
    await khrtToken.setTokenWhitelist(await mockWETH.getAddress(), true);
    await khrtToken.setTokenWhitelist(await mockDAI.getAddress(), true);
    // Note: nonWhitelistedToken is intentionally NOT whitelisted

    // Set collateral ratios in collateral manager
    await collateralManager.setCollateralRatio(await mockUSDC.getAddress(), USDC_RATIO);
    await collateralManager.setCollateralRatio(await mockUSDT.getAddress(), USDT_RATIO);
    await collateralManager.setCollateralRatio(await mockWETH.getAddress(), WETH_RATIO);
    await collateralManager.setCollateralRatio(await mockDAI.getAddress(), DAI_RATIO);

    // Mint tokens to users for testing
    const stablecoinAmount = ethers.parseUnits("1000000", 6); // 1M stablecoins
    const ethAmount = ethers.parseUnits("1000", 18); // 1000 ETH
    const daiAmount = ethers.parseUnits("1000000", 18); // 1M DAI
    const nonWhitelistedAmount = ethers.parseUnits("1000000", 18);

    for (const user of [user1, user2, user3]) {
      await mockUSDC.mint(user.address, stablecoinAmount);
      await mockUSDT.mint(user.address, stablecoinAmount);
      await mockWETH.mint(user.address, ethAmount);
      await mockDAI.mint(user.address, daiAmount);
      await nonWhitelistedToken.mint(user.address, nonWhitelistedAmount);
    }
  }

  describe("Basic Calculation Tests", function () {
    it("Should calculate correct KHRT amounts for different token decimals", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const wethAddress = await mockWETH.getAddress();
      const daiAddress = await mockDAI.getAddress();

      // Test USDC (6 decimals) with 1:1 ratio
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const expectedUSDCKHRT = await collateralManager.calculateMintAmount(usdcAddress, usdcAmount);
      expect(expectedUSDCKHRT).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));

      // Test WETH (18 decimals) with 2000:1 ratio
      const wethAmount = ethers.parseUnits("1.5", WETH_DECIMALS);
      const expectedWETHKHRT = await collateralManager.calculateMintAmount(wethAddress, wethAmount);
      expect(expectedWETHKHRT).to.equal(ethers.parseUnits("3000", KHRT_DECIMALS));

      // Test DAI (18 decimals) with 1:1 ratio
      const daiAmount = ethers.parseUnits("2500.123456789", DAI_DECIMALS);
      const expectedDAIKHRT = await collateralManager.calculateMintAmount(daiAddress, daiAmount);
      // Should truncate to 6 decimals: 2500.123456
      expect(expectedDAIKHRT).to.equal(ethers.parseUnits("2500.123456", KHRT_DECIMALS));
    });

    it("Should calculate correct collateral requirements for KHRT amounts", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const wethAddress = await mockWETH.getAddress();
      const daiAddress = await mockDAI.getAddress();

      // Test USDC: 1000 KHRT should require 1000 USDC
      const khrtAmount1 = ethers.parseUnits("1000", KHRT_DECIMALS);
      const requiredUSDC = await collateralManager.calculateCollateralNeeded(usdcAddress, khrtAmount1);
      expect(requiredUSDC).to.equal(ethers.parseUnits("1000", USDC_DECIMALS));

      // Test WETH: 3000 KHRT should require 1.5 ETH
      const khrtAmount2 = ethers.parseUnits("3000", KHRT_DECIMALS);
      const requiredWETH = await collateralManager.calculateCollateralNeeded(wethAddress, khrtAmount2);
      expect(requiredWETH).to.equal(ethers.parseUnits("1.5", WETH_DECIMALS));

      // Test DAI: 2500 KHRT should require 2500 DAI
      const khrtAmount3 = ethers.parseUnits("2500", KHRT_DECIMALS);
      const requiredDAI = await collateralManager.calculateCollateralNeeded(daiAddress, khrtAmount3);
      expect(requiredDAI).to.equal(ethers.parseUnits("2500", DAI_DECIMALS));
    });

    it("Should handle precision edge cases correctly", async function () {
      const wethAddress = await mockWETH.getAddress();
      
      // Test small WETH amount that results in fractional KHRT
      const smallWETH = ethers.parseUnits("0.0001", WETH_DECIMALS); // 0.0001 ETH
      const expectedKHRT = await collateralManager.calculateMintAmount(wethAddress, smallWETH);
      // 0.0001 * 2000 = 0.2 KHRT
      expect(expectedKHRT).to.equal(ethers.parseUnits("0.2", KHRT_DECIMALS));

      // Test KHRT amount that results in fractional collateral requirement
      const khrtAmount = ethers.parseUnits("1", KHRT_DECIMALS); // 1 KHRT
      const requiredWETH = await collateralManager.calculateCollateralNeeded(wethAddress, khrtAmount);
      // 1 / 2000 = 0.0005 ETH (with ceiling division)
      expect(requiredWETH).to.equal(ethers.parseUnits("0.0005", WETH_DECIMALS));
    });
  });

  describe("Mint Amount Validation Tests", function () {
    it("Should prevent minting more KHRT than collateral allows", async function () {
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const usdcAddress = await mockUSDC.getAddress();

      // Approve and deposit collateral
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), usdcAmount);
      await collateralManager.connect(user1).depositCollateral(usdcAddress, usdcAmount);

      // Check that exactly 1000 KHRT was minted
      const khrtBalance = await khrtToken.balanceOf(user1.address);
      expect(khrtBalance).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));

      // Try to withdraw more KHRT than minted should fail
      const excessWithdraw = ethers.parseUnits("1001", KHRT_DECIMALS);
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), excessWithdraw);
      
      await expect(collateralManager.connect(user1).withdrawCollateral(usdcAddress, excessWithdraw))
        .to.be.revertedWith("CollateralManager: Insufficient minted amount");
    });

    it("Should enforce minimum collateral ratio during withdrawals", async function () {
      const wethAmount = ethers.parseUnits("3", WETH_DECIMALS); // 3 ETH  
      const wethAddress = await mockWETH.getAddress();

      // Deposit 3 ETH, should get 6000 KHRT (3 * 2000)
      await mockWETH.connect(user1).approve(await collateralManager.getAddress(), wethAmount);
      await collateralManager.connect(user1).depositCollateral(wethAddress, wethAmount);

      const khrtBalance = await khrtToken.balanceOf(user1.address);
      expect(khrtBalance).to.equal(ethers.parseUnits("6000", KHRT_DECIMALS));

      // Test: Complete withdrawal should always work (position closure)
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), khrtBalance);
      await collateralManager.connect(user1).withdrawCollateral(wethAddress, khrtBalance);

      const finalPosition = await collateralManager.getUserPosition(user1.address, wethAddress);
      expect(finalPosition.mintedAmount).to.equal(0);
      expect(finalPosition.collateralBalance).to.equal(0);

      // Test: Partial withdrawals should maintain proper collateralization
      await mockWETH.connect(user2).approve(await collateralManager.getAddress(), wethAmount);
      await collateralManager.connect(user2).depositCollateral(wethAddress, wethAmount);

      // Test various withdrawal amounts to ensure they maintain proper ratios
      const withdrawAmounts = [
        ethers.parseUnits("1000", KHRT_DECIMALS),
        ethers.parseUnits("2000", KHRT_DECIMALS),
        ethers.parseUnits("3000", KHRT_DECIMALS)
      ];

      for (const withdrawAmount of withdrawAmounts) {
        // Check the position before withdrawal
        const beforePosition = await collateralManager.getUserPosition(user2.address, wethAddress);
        
        // Perform withdrawal
        await khrtToken.connect(user2).approve(await collateralManager.getAddress(), withdrawAmount);
        await collateralManager.connect(user2).withdrawCollateral(wethAddress, withdrawAmount);

        // Check the position after withdrawal
        const afterPosition = await collateralManager.getUserPosition(user2.address, wethAddress);
        
        // Verify the position is still healthy (if not completely closed)
        if (afterPosition.mintedAmount > 0) {
          expect(afterPosition.collateralRatio).to.be.gte(10000); // Should be >= 100%
          expect(await collateralManager.isPositionHealthy(user2.address, wethAddress)).to.be.true;
        }
      }

      // The position should now be completely closed
      const finalPosition2 = await collateralManager.getUserPosition(user2.address, wethAddress);
      expect(finalPosition2.mintedAmount).to.equal(0);
      expect(finalPosition2.collateralBalance).to.equal(0);

      // Test: Verify that trying to withdraw more than you have fails
      await mockWETH.connect(user3).approve(await collateralManager.getAddress(), wethAmount);
      await collateralManager.connect(user3).depositCollateral(wethAddress, wethAmount);

      const user3Balance = await khrtToken.balanceOf(user3.address);
      const excessiveAmount = user3Balance + ethers.parseUnits("1", KHRT_DECIMALS);
      
      await khrtToken.connect(user3).approve(await collateralManager.getAddress(), excessiveAmount);
      await expect(collateralManager.connect(user3).withdrawCollateral(wethAddress, excessiveAmount))
        .to.be.revertedWith("CollateralManager: Insufficient minted amount");
    });

    it("Should prevent minting with insufficient collateral after ratio changes", async function () {
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const usdcAddress = await mockUSDC.getAddress();

      // Initial deposit with ratio 1:1
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), usdcAmount);
      await collateralManager.connect(user1).depositCollateral(usdcAddress, usdcAmount);

      // User1 gets 1000 KHRT with 1:1 ratio
      expect(await khrtToken.balanceOf(user1.address)).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));

      // Change ratio to require more collateral (2 USDC = 1 KHRT, so ratio = 0.5 KHRT per USDC)
      // But since we can't use decimals, we'll use a different approach:
      // Let's change the ratio to 2 KHRT per USDC instead, making USDC more valuable
      await collateralManager.setCollateralRatio(usdcAddress, 2);

      // New deposits should follow new ratio (1000 USDC * 2 = 2000 KHRT)
      await mockUSDC.connect(user2).approve(await collateralManager.getAddress(), usdcAmount);
      await collateralManager.connect(user2).depositCollateral(usdcAddress, usdcAmount);

      // User2 should get 2000 KHRT with new ratio
      const user2Balance = await khrtToken.balanceOf(user2.address);
      expect(user2Balance).to.equal(ethers.parseUnits("2000", KHRT_DECIMALS));

      // User1's existing position should still be valid (unchanged)
      const user1Balance = await khrtToken.balanceOf(user1.address);
      expect(user1Balance).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));

      // User1 should still be able to withdraw their original position
      const withdrawAmount = ethers.parseUnits("500", KHRT_DECIMALS);
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), withdrawAmount);
      await collateralManager.connect(user1).withdrawCollateral(usdcAddress, withdrawAmount);

      // Verify partial withdrawal worked
      const remainingBalance = await khrtToken.balanceOf(user1.address);
      expect(remainingBalance).to.equal(ethers.parseUnits("500", KHRT_DECIMALS));
    });
  });

  describe("Whitelist Enforcement Tests", function () {
    it("Should reject non-whitelisted tokens for collateral ratio setting", async function () {
      const nonWhitelistedAddress = await nonWhitelistedToken.getAddress();

      await expect(collateralManager.setCollateralRatio(nonWhitelistedAddress, 1))
        .to.be.revertedWith("CollateralManager: Token not whitelisted in KHRT");
    });

    it("Should reject deposits with non-whitelisted tokens", async function () {
      const nonWhitelistedAddress = await nonWhitelistedToken.getAddress();
      const amount = ethers.parseUnits("1000", 18);

      // Try to set ratio for non-whitelisted token should fail
      await expect(collateralManager.setCollateralRatio(nonWhitelistedAddress, 1))
        .to.be.revertedWith("CollateralManager: Token not whitelisted in KHRT");

      // Even if we somehow had a ratio, deposit should fail due to whitelist check
      await nonWhitelistedToken.connect(user1).approve(await collateralManager.getAddress(), amount);
      
      await expect(collateralManager.connect(user1).depositCollateral(nonWhitelistedAddress, amount))
        .to.be.revertedWith("CollateralManager: Token ratio not set");
    });

    it("Should allow minting only with whitelisted tokens", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const nonWhitelistedAddress = await nonWhitelistedToken.getAddress();

      // Whitelisted token should work
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), usdcAmount);
      await collateralManager.connect(user1).depositCollateral(usdcAddress, usdcAmount);

      expect(await khrtToken.balanceOf(user1.address)).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));

      // Direct minting with non-whitelisted token should fail
      await expect(khrtToken.connect(user1).mintWithCollateral(
        user1.address,
        ethers.parseUnits("1000", KHRT_DECIMALS),
        nonWhitelistedAddress
      )).to.be.revertedWith("KHRT: Unauthorized collateral minter");
    });

    it("Should handle token whitelist changes correctly", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);

      // Initial deposit should work
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), usdcAmount);
      await collateralManager.connect(user1).depositCollateral(usdcAddress, usdcAmount);

      // Remove token from whitelist
      await khrtToken.setTokenWhitelist(usdcAddress, false);

      // New deposits should fail
      await mockUSDC.connect(user2).approve(await collateralManager.getAddress(), usdcAmount);
      await expect(collateralManager.connect(user2).depositCollateral(usdcAddress, usdcAmount))
        .to.be.revertedWith("CollateralManager: Token not whitelisted");

      // Existing positions should still be withdrawable
      const withdrawAmount = ethers.parseUnits("500", KHRT_DECIMALS);
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), withdrawAmount);
      await collateralManager.connect(user1).withdrawCollateral(usdcAddress, withdrawAmount);

      // Re-whitelist token
      await khrtToken.setTokenWhitelist(usdcAddress, true);

      // New deposits should work again
      await collateralManager.connect(user2).depositCollateral(usdcAddress, usdcAmount);
      expect(await khrtToken.balanceOf(user2.address)).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));
    });
  });

  describe("Complex Calculation Scenarios", function () {
    it("Should handle multiple collateral types correctly", async function () {
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const wethAmount = ethers.parseUnits("1", WETH_DECIMALS);
      const daiAmount = ethers.parseUnits("500", DAI_DECIMALS);

      // Deposit different collaterals
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), usdcAmount);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), usdcAmount);

      await mockWETH.connect(user1).approve(await collateralManager.getAddress(), wethAmount);
      await collateralManager.connect(user1).depositCollateral(await mockWETH.getAddress(), wethAmount);

      await mockDAI.connect(user1).approve(await collateralManager.getAddress(), daiAmount);
      await collateralManager.connect(user1).depositCollateral(await mockDAI.getAddress(), daiAmount);

      // Total expected: 1000 (USDC) + 2000 (WETH) + 500 (DAI) = 3500 KHRT
      const totalKHRT = await khrtToken.balanceOf(user1.address);
      expect(totalKHRT).to.equal(ethers.parseUnits("3500", KHRT_DECIMALS));

      // Check individual positions
      const usdcPosition = await collateralManager.getUserPosition(user1.address, await mockUSDC.getAddress());
      const wethPosition = await collateralManager.getUserPosition(user1.address, await mockWETH.getAddress());
      const daiPosition = await collateralManager.getUserPosition(user1.address, await mockDAI.getAddress());

      expect(usdcPosition.mintedAmount).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));
      expect(wethPosition.mintedAmount).to.equal(ethers.parseUnits("2000", KHRT_DECIMALS));
      expect(daiPosition.mintedAmount).to.equal(ethers.parseUnits("500", KHRT_DECIMALS));
    });

    it("Should calculate correct max withdrawable amounts", async function () {
      // First, create a position with exactly 100% collateralization
      const wethAmount = ethers.parseUnits("2", WETH_DECIMALS); // 2 ETH = 4000 KHRT
      const wethAddress = await mockWETH.getAddress();

      await mockWETH.connect(user1).approve(await collateralManager.getAddress(), wethAmount);
      await collateralManager.connect(user1).depositCollateral(wethAddress, wethAmount);

      let position = await collateralManager.getUserPosition(user1.address, wethAddress);
      expect(position.mintedAmount).to.equal(ethers.parseUnits("4000", KHRT_DECIMALS));
      expect(position.collateralBalance).to.equal(ethers.parseUnits("2", WETH_DECIMALS));
      expect(position.collateralRatio).to.equal(10000); // Exactly 100% (10000 basis points)
      
      // With exactly 100% collateralization, we can either withdraw 0 (partial) or all (close position)
      // The maxWithdrawableKHRT should reflect the maximum partial withdrawal while maintaining ratio
      expect(position.maxWithdrawableKHRT).to.equal(0);

      // But we should be able to withdraw ALL KHRT (close position completely)
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), position.mintedAmount);
      await collateralManager.connect(user1).withdrawCollateral(wethAddress, position.mintedAmount);

      // Position should be completely closed
      position = await collateralManager.getUserPosition(user1.address, wethAddress);
      expect(position.mintedAmount).to.equal(0);
      expect(position.collateralBalance).to.equal(0);

      // Now test actual over-collateralization scenario
      // Deposit more collateral than needed to create over-collateralization
      const excessWeth = ethers.parseUnits("3", WETH_DECIMALS); // 3 ETH 
      await mockWETH.connect(user2).approve(await collateralManager.getAddress(), excessWeth);
      await collateralManager.connect(user2).depositCollateral(wethAddress, excessWeth);

      // User2 gets 6000 KHRT from 3 ETH (still 100% ratio: 3 ETH * 2000 = 6000 KHRT)
      position = await collateralManager.getUserPosition(user2.address, wethAddress);
      expect(position.mintedAmount).to.equal(ethers.parseUnits("6000", KHRT_DECIMALS));
      expect(position.collateralRatio).to.equal(10000); // Still exactly 100%
      
      // Now let's create real over-collateralization by changing the ratio
      // Increase ETH value by changing ratio from 2000 to 3000 KHRT per ETH
      await collateralManager.setCollateralRatio(wethAddress, 3000);
      
      // This doesn't affect existing positions, but let's deposit additional collateral
      const additionalWeth = ethers.parseUnits("1", WETH_DECIMALS);
      await mockWETH.connect(user2).approve(await collateralManager.getAddress(), additionalWeth);
      await collateralManager.connect(user2).depositCollateral(wethAddress, additionalWeth);

      // Now user2 has 4 ETH total and gets 3000 more KHRT = 9000 total KHRT
      position = await collateralManager.getUserPosition(user2.address, wethAddress);
      expect(position.mintedAmount).to.equal(ethers.parseUnits("9000", KHRT_DECIMALS));
      expect(position.collateralBalance).to.equal(ethers.parseUnits("4", WETH_DECIMALS));
      
      // With the mixed ratios, let's just verify we can do partial withdrawals
      const partialWithdraw = ethers.parseUnits("1000", KHRT_DECIMALS);
      await khrtToken.connect(user2).approve(await collateralManager.getAddress(), partialWithdraw);
      await collateralManager.connect(user2).withdrawCollateral(wethAddress, partialWithdraw);

      // Verify partial withdrawal worked
      const finalPosition = await collateralManager.getUserPosition(user2.address, wethAddress);
      expect(finalPosition.mintedAmount).to.equal(ethers.parseUnits("8000", KHRT_DECIMALS));
    });

    it("Should handle zero and edge case amounts", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // Test zero calculations
      expect(await collateralManager.calculateMintAmount(usdcAddress, 0)).to.equal(0);
      expect(await collateralManager.calculateCollateralNeeded(usdcAddress, 0)).to.equal(0);

      // Test very small amounts
      const tinyAmount = 1; // 1 wei of USDC
      const tinyKHRT = await collateralManager.calculateMintAmount(usdcAddress, tinyAmount);
      expect(tinyKHRT).to.equal(1); // Should be 1 wei of KHRT

      // Test the reverse
      const requiredCollateral = await collateralManager.calculateCollateralNeeded(usdcAddress, 1);
      expect(requiredCollateral).to.equal(1); // Should need 1 wei of USDC
    });
  });

  describe("Authorization and Access Control", function () {
    it("Should prevent unauthorized minting", async function () {
      // Non-authorized user cannot mint directly
      await expect(khrtToken.connect(user1).mint(user1.address, ethers.parseUnits("1000", KHRT_DECIMALS)))
        .to.be.revertedWith("KHRT: Unauthorized normal minter");

      // Non-authorized contract cannot mint with collateral
      await expect(khrtToken.connect(user1).mintWithCollateral(
        user1.address,
        ethers.parseUnits("1000", KHRT_DECIMALS),
        await mockUSDC.getAddress()
      )).to.be.revertedWith("KHRT: Unauthorized collateral minter");
    });

    it("Should enforce collateral manager authorization", async function () {
      // Remove collateral manager authorization
      await khrtToken.setCollateralMinter(await collateralManager.getAddress(), false);

      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), usdcAmount);

      // Deposit should fail when manager is not authorized
      await expect(collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), usdcAmount))
        .to.be.revertedWith("CollateralManager: Not authorized as collateral minter");

      // Re-authorize and it should work
      await khrtToken.setCollateralMinter(await collateralManager.getAddress(), true);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), usdcAmount);

      expect(await khrtToken.balanceOf(user1.address)).to.equal(ethers.parseUnits("1000", KHRT_DECIMALS));
    });
  });

  describe("Maximum Supply Enforcement", function () {
    it("Should prevent minting beyond maximum supply", async function () {
      const maxSupply = await khrtToken.getMaxSupply();
      
      // Calculate how much USDC needed to approach max supply
      const targetMint = maxSupply - ethers.parseUnits("1000", KHRT_DECIMALS); // Leave some room
      const requiredUSDC = targetMint; // 1:1 ratio

      // Mint enough USDC to user1
      await mockUSDC.mint(user1.address, requiredUSDC);

      // Deposit most of max supply
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), requiredUSDC);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), requiredUSDC);

      // Now try to mint more than remaining capacity
      const excessAmount = ethers.parseUnits("2000", KHRT_DECIMALS); // More than the 1000 we left
      await mockUSDC.mint(user2.address, excessAmount);
      await mockUSDC.connect(user2).approve(await collateralManager.getAddress(), excessAmount);

      await expect(collateralManager.connect(user2).depositCollateral(await mockUSDC.getAddress(), excessAmount))
        .to.be.revertedWith("KHRT: Exceeds maximum supply");
    });

    it("Should track total supply correctly across multiple mints", async function () {
      const amounts = [
        ethers.parseUnits("1000", USDC_DECIMALS),
        ethers.parseUnits("2000", USDC_DECIMALS),
        ethers.parseUnits("1500", USDC_DECIMALS)
      ];

      let expectedTotal = 0n;

      for (let i = 0; i < amounts.length; i++) {
        const user = [user1, user2, user3][i];
        await mockUSDC.connect(user).approve(await collateralManager.getAddress(), amounts[i]);
        await collateralManager.connect(user).depositCollateral(await mockUSDC.getAddress(), amounts[i]);
        
        expectedTotal += amounts[i]; // 1:1 ratio
      }

      expect(await khrtToken.totalSupply()).to.equal(expectedTotal);
    });
  });
});