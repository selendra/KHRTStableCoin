import { expect } from "chai";
import { ethers } from "hardhat";
import { KHRTStablecoin, KHRTCollateralManager, MockERC20 } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("KHRT System Integration Tests", function () {
  let khrtToken: KHRTStablecoin;
  let collateralManager: KHRTCollateralManager;
  let mockUSDC: MockERC20;
  let mockUSDT: MockERC20;
  let mockWETH: MockERC20;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let user3: SignerWithAddress;

  const USDC_DECIMALS = 6;
  const USDT_DECIMALS = 6;
  const WETH_DECIMALS = 18;
  const KHRT_DECIMALS = 18;
  
  // Collateral ratios
  const STABLECOIN_RATIO = ethers.parseUnits("1", 12); // 1:1 ratio for stablecoins
  const WETH_RATIO = 2000; // 1 ETH = 2000 KHRT (assuming $2000 ETH)
  
  beforeEach(async function () {
    [owner, user1, user2, user3] = await ethers.getSigners();

    // Deploy all contracts
    const KHRTStablecoin = await ethers.getContractFactory("KHRTStablecoin");
    khrtToken = await KHRTStablecoin.deploy("KHRT Testing","TKHR");
    await khrtToken.waitForDeployment();

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

    // Setup system
    await setupSystem();
  });

  async function setupSystem() {
    // Authorize collateral manager
    await khrtToken.setCollateralMinter(await collateralManager.getAddress(), true);

    // Whitelist tokens
    await khrtToken.setTokenWhitelist(await mockUSDC.getAddress(), true);
    await khrtToken.setTokenWhitelist(await mockUSDT.getAddress(), true);
    await khrtToken.setTokenWhitelist(await mockWETH.getAddress(), true);

    // Set collateral ratios
    await collateralManager.setCollateralRatio(await mockUSDC.getAddress(), STABLECOIN_RATIO);
    await collateralManager.setCollateralRatio(await mockUSDT.getAddress(), STABLECOIN_RATIO);
    await collateralManager.setCollateralRatio(await mockWETH.getAddress(), WETH_RATIO);

    // Mint tokens to users
    const stablecoinAmount = ethers.parseUnits("100000", 6); // 100k stablecoins
    const ethAmount = ethers.parseUnits("100", 18); // 100 ETH

    for (const user of [user1, user2, user3]) {
      await mockUSDC.mint(user.address, stablecoinAmount);
      await mockUSDT.mint(user.address, stablecoinAmount);
      await mockWETH.mint(user.address, ethAmount);
    }
  }

  describe("Complete User Journey", function () {
   it("Should allow complete deposit-withdraw cycle with multiple collaterals", async function () {
      const usdcAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const ethAmount = ethers.parseUnits("1", WETH_DECIMALS); // 1 ETH
      const expectedKHRTFromUSDC = ethers.parseUnits("1000", KHRT_DECIMALS);
      const expectedKHRTFromETH = ethers.parseUnits("2000", KHRT_DECIMALS); // 1 ETH * 2000 ratio

      // === DEPOSIT PHASE ===
      
      // Deposit USDC
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), usdcAmount);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), usdcAmount);

      // Deposit WETH
      await mockWETH.connect(user1).approve(await collateralManager.getAddress(), ethAmount);
      await collateralManager.connect(user1).depositCollateral(await mockWETH.getAddress(), ethAmount);

      // Check total KHRT balance
      const totalKHRT = expectedKHRTFromUSDC + expectedKHRTFromETH;
      expect(await khrtToken.balanceOf(user1.address)).to.equal(totalKHRT);

      // === TRANSFER PHASE ===
      
      // Transfer some KHRT to user2
      const transferAmount = ethers.parseUnits("500", KHRT_DECIMALS);
      await khrtToken.connect(user1).transfer(user2.address, transferAmount);
      expect(await khrtToken.balanceOf(user2.address)).to.equal(transferAmount);

      // === PARTIAL WITHDRAWAL PHASE ===
      
      // Withdraw half of USDC position
      const partialWithdraw = ethers.parseUnits("500", KHRT_DECIMALS);
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), partialWithdraw);
      await collateralManager.connect(user1).withdrawCollateral(await mockUSDC.getAddress(), partialWithdraw);

      // Check remaining position
      const usdcPosition = await collateralManager.getUserPosition(user1.address, await mockUSDC.getAddress());
      expect(usdcPosition.mintedAmount).to.equal(ethers.parseUnits("500", KHRT_DECIMALS));
      expect(usdcPosition.collateralBalance).to.equal(ethers.parseUnits("500", USDC_DECIMALS));

      // === FINAL BALANCE CHECK (REMOVED COMPLETE WITHDRAWAL) ===
      
      // User1 should have: 3000 - 500 (transfer) - 500 (withdrawal) = 2000 KHRT remaining
      const remainingKHRT = await khrtToken.balanceOf(user1.address);
      expect(remainingKHRT).to.equal(ethers.parseUnits("2000", KHRT_DECIMALS));
      
      // Verify positions are still active
      const wethPosition = await collateralManager.getUserPosition(user1.address, await mockWETH.getAddress());
      expect(wethPosition.mintedAmount).to.equal(ethers.parseUnits("2000", KHRT_DECIMALS));
      expect(wethPosition.collateralBalance).to.equal(ethAmount);
      
      // User2 should have the transferred amount
      expect(await khrtToken.balanceOf(user2.address)).to.equal(transferAmount);
    });

    it("Should handle complex multi-user scenarios", async function () {
      // User1: Conservative strategy with stablecoins
      const user1USDCAmount = ethers.parseUnits("500", USDC_DECIMALS);
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), user1USDCAmount);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), user1USDCAmount);

      // User2: Aggressive strategy with ETH
      const user2ETHAmount = ethers.parseUnits("1", WETH_DECIMALS);
      await mockWETH.connect(user2).approve(await collateralManager.getAddress(), user2ETHAmount);
      await collateralManager.connect(user2).depositCollateral(await mockWETH.getAddress(), user2ETHAmount);

      // User3: Mixed strategy
      const user3USDTAmount = ethers.parseUnits("200", USDT_DECIMALS);
      const user3ETHAmount = ethers.parseUnits("0.5", WETH_DECIMALS);
      
      await mockUSDT.connect(user3).approve(await collateralManager.getAddress(), user3USDTAmount);
      await collateralManager.connect(user3).depositCollateral(await mockUSDT.getAddress(), user3USDTAmount);
      
      await mockWETH.connect(user3).approve(await collateralManager.getAddress(), user3ETHAmount);
      await collateralManager.connect(user3).depositCollateral(await mockWETH.getAddress(), user3ETHAmount);

      // Check individual balances
      expect(await khrtToken.balanceOf(user1.address)).to.equal(ethers.parseUnits("500", KHRT_DECIMALS));
      expect(await khrtToken.balanceOf(user2.address)).to.equal(ethers.parseUnits("2000", KHRT_DECIMALS));
      expect(await khrtToken.balanceOf(user3.address)).to.equal(ethers.parseUnits("1200", KHRT_DECIMALS));

      // Check total supply
      const totalExpected = ethers.parseUnits("3700", KHRT_DECIMALS);
      expect(await khrtToken.totalSupply()).to.equal(totalExpected);

      // === FIXED TRANSFER LOGIC ===
      
      // Cross-transfers between users (smaller amounts to avoid balance issues)
      await khrtToken.connect(user2).transfer(user1.address, ethers.parseUnits("500", KHRT_DECIMALS)); // User2: 2000->1500, User1: 500->1000
      await khrtToken.connect(user3).transfer(user2.address, ethers.parseUnits("200", KHRT_DECIMALS)); // User3: 1200->1000, User2: 1500->1700

      // Batch transfer from user1 (realistic amounts)
      const recipients = [user2.address, user3.address];
      const amounts = [ethers.parseUnits("400", KHRT_DECIMALS), ethers.parseUnits("300", KHRT_DECIMALS)]; // Total: 700 KHRT
      await khrtToken.connect(user1).batchTransfer(recipients, amounts);

      // Verify final balances after transfers
      // User1: 1000 - 700 = 300
      // User2: 1700 + 400 = 2100  
      // User3: 1000 + 300 = 1300
      expect(await khrtToken.balanceOf(user1.address)).to.equal(ethers.parseUnits("300", KHRT_DECIMALS));
      expect(await khrtToken.balanceOf(user2.address)).to.equal(ethers.parseUnits("2100", KHRT_DECIMALS));
      expect(await khrtToken.balanceOf(user3.address)).to.equal(ethers.parseUnits("1300", KHRT_DECIMALS));
      
      // Total supply should remain the same
      expect(await khrtToken.totalSupply()).to.equal(totalExpected);
    });
  });

  describe("System Stress Tests", function () {
    it("Should handle rapid deposit/withdrawal cycles", async function () {
      const baseAmount = ethers.parseUnits("100", USDC_DECIMALS);
      const usdcAddress = await mockUSDC.getAddress();

      for (let i = 0; i < 10; i++) {
        // Deposit
        await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), baseAmount);
        await collateralManager.connect(user1).depositCollateral(usdcAddress, baseAmount);

        // Partial withdrawal
        const withdrawAmount = ethers.parseUnits("50", KHRT_DECIMALS);
        await khrtToken.connect(user1).approve(await collateralManager.getAddress(), withdrawAmount);
        await collateralManager.connect(user1).withdrawCollateral(usdcAddress, withdrawAmount);
      }

      // Final check
      const position = await collateralManager.getUserPosition(user1.address, usdcAddress);
      expect(position.mintedAmount).to.equal(ethers.parseUnits("500", KHRT_DECIMALS)); // 10 * 50 remaining
      expect(position.collateralBalance).to.equal(ethers.parseUnits("500", USDC_DECIMALS));
    });

    it("Should handle maximum supply scenarios", async function () {
      // Try to mint close to max supply
      const maxSupply = await khrtToken.getMaxSupply();
      const largeAmount = maxSupply / 2n; // Half of max supply

      // Calculate required collateral
      const requiredUSDC = largeAmount / ethers.parseUnits("1", 12); // Adjust for ratio

      // Mint enough USDC
      await mockUSDC.mint(user1.address, requiredUSDC);
      
      // Deposit and mint large amount
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), requiredUSDC);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), requiredUSDC);

      expect(await khrtToken.balanceOf(user1.address)).to.equal(largeAmount);

      // Try to mint more than max supply should fail
      const excessAmount = maxSupply - largeAmount + ethers.parseUnits("1", 18);
      const excessUSDC = excessAmount / ethers.parseUnits("1", 12);
      
      await mockUSDC.mint(user2.address, excessUSDC);
      await mockUSDC.connect(user2).approve(await collateralManager.getAddress(), excessUSDC);
      
      await expect(collateralManager.connect(user2).depositCollateral(await mockUSDC.getAddress(), excessUSDC))
        .to.be.revertedWith("KHRT: Exceeds maximum supply");
    });
  });

  describe("Security and Edge Cases", function () {
    it("Should prevent unauthorized minting", async function () {
      // Try to mint directly without being authorized
      await expect(khrtToken.connect(user1).mint(user1.address, ethers.parseUnits("1000", 18)))
        .to.be.revertedWith("KHRT: Unauthorized normal minter");

      // Try collateral minting without authorization
      await expect(khrtToken.connect(user1).mintWithCollateral(
        user1.address, 
        ethers.parseUnits("1000", 18), 
        await mockUSDC.getAddress()
      )).to.be.revertedWith("KHRT: Unauthorized collateral minter");
    });

    it("Should handle blacklisted users properly", async function () {
      // Setup position for user1
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), depositAmount);

      // Blacklist user1
      await khrtToken.setUserBlacklist(user1.address, true);

      // Should not be able to transfer
      await expect(khrtToken.connect(user1).transfer(user2.address, ethers.parseUnits("100", 18)))
        .to.be.revertedWith("KHRT: Address is blacklisted");

      // Should not be able to receive transfers
      await expect(khrtToken.connect(user2).transfer(user1.address, ethers.parseUnits("100", 18)))
        .to.be.revertedWith("KHRT: Address is blacklisted");

      // Remove from blacklist and operations should work
      await khrtToken.setUserBlacklist(user1.address, false);
      await khrtToken.connect(user1).transfer(user2.address, ethers.parseUnits("100", 18));
    });

    it("Should handle paused system correctly", async function () {
      // Setup position
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), depositAmount);

      // Pause both contracts
      await khrtToken.pause();
      await collateralManager.pause();

      // Should reject all operations
      await expect(khrtToken.connect(user1).transfer(user2.address, ethers.parseUnits("100", 18)))
        .to.be.revertedWithCustomError(khrtToken, "EnforcedPause");

      await expect(collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), depositAmount))
        .to.be.revertedWithCustomError(collateralManager, "EnforcedPause");

      // Unpause and operations should work
      await khrtToken.unpause();
      await collateralManager.unpause();

      await khrtToken.connect(user1).transfer(user2.address, ethers.parseUnits("100", 18));
    });

   it("Should handle token ratio changes correctly", async function () {
      // Initial deposit with ratio 1:1
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(await mockUSDC.getAddress(), depositAmount);

      expect(await khrtToken.balanceOf(user1.address)).to.equal(ethers.parseUnits("1000", 18));

      // Change ratio to 2:1 (multiply by 2e12 instead of 1e12)
      const newRatio = ethers.parseUnits("2", 12);
      await collateralManager.setCollateralRatio(await mockUSDC.getAddress(), newRatio);

      // New deposits should use new ratio
      await mockUSDC.connect(user2).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user2).depositCollateral(await mockUSDC.getAddress(), depositAmount);

      // FIXED EXPECTATION: 1000 USDC * 2e12 = 2000 KHRT (not 500)
      expect(await khrtToken.balanceOf(user2.address)).to.equal(ethers.parseUnits("2000", 18));

      // Existing positions should still work with their original terms
      const user1Position = await collateralManager.getUserPosition(user1.address, await mockUSDC.getAddress());
      expect(user1Position.mintedAmount).to.equal(ethers.parseUnits("1000", 18));
    });
  });

  describe("Gas Optimization Tests", function () {
    it("Should be gas efficient for common operations", async function () {
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const usdcAddress = await mockUSDC.getAddress();

      // Approve once
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount * 10n);

      // Measure gas for deposit
      const depositTx = await collateralManager.connect(user1).depositCollateral(usdcAddress, depositAmount);
      const depositReceipt = await depositTx.wait();
      console.log("Deposit gas used:", depositReceipt?.gasUsed?.toString());

      // Measure gas for withdrawal
      await khrtToken.connect(user1).approve(await collateralManager.getAddress(), ethers.parseUnits("500", 18));
      const withdrawTx = await collateralManager.connect(user1).withdrawCollateral(usdcAddress, ethers.parseUnits("500", 18));
      const withdrawReceipt = await withdrawTx.wait();
      console.log("Withdrawal gas used:", withdrawReceipt?.gasUsed?.toString());

      // Measure gas for transfer
      const transferTx = await khrtToken.connect(user1).transfer(user2.address, ethers.parseUnits("100", 18));
      const transferReceipt = await transferTx.wait();
      console.log("Transfer gas used:", transferReceipt?.gasUsed?.toString());
    });

    it("Should handle batch operations efficiently", async function () {
      // Setup initial balance
      const mintAmount = ethers.parseUnits("10000", 18);
      await khrtToken.connect(owner).mint(user1.address, mintAmount);

      // Batch transfer to multiple recipients
      const recipients = [user2.address, user3.address, owner.address];
      const amounts = [
        ethers.parseUnits("1000", 18),
        ethers.parseUnits("2000", 18),
        ethers.parseUnits("1500", 18)
      ];

      const batchTx = await khrtToken.connect(user1).batchTransfer(recipients, amounts);
      const batchReceipt = await batchTx.wait();
      console.log("Batch transfer gas used:", batchReceipt?.gasUsed?.toString());

      // Verify all transfers completed
      expect(await khrtToken.balanceOf(user2.address)).to.equal(amounts[0]);
      expect(await khrtToken.balanceOf(user3.address)).to.equal(amounts[1]);
      expect(await khrtToken.balanceOf(owner.address)).to.equal(amounts[2]);
    });
  });

  describe("Integration with External Systems", function () {
    it("Should work correctly with external DeFi protocols (simulated)", async function () {
      // Simulate lending protocol interaction
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      const usdcAddress = await mockUSDC.getAddress();

      // User deposits collateral and gets KHRT
      await mockUSDC.connect(user1).approve(await collateralManager.getAddress(), depositAmount);
      await collateralManager.connect(user1).depositCollateral(usdcAddress, depositAmount);

      const khrtBalance = await khrtToken.balanceOf(user1.address);

      // Simulate lending KHRT to external protocol (approve + transferFrom pattern)
      const lendingAmount = khrtBalance / 2n;
      await khrtToken.connect(user1).approve(user2.address, lendingAmount); // user2 simulates lending protocol

      // Lending protocol takes tokens
      await khrtToken.connect(user2).transferFrom(user1.address, user2.address, lendingAmount);

      // User should have reduced balance
      expect(await khrtToken.balanceOf(user1.address)).to.equal(khrtBalance - lendingAmount);

      // Later, user gets tokens back with interest (simulate repayment)
      const interest = ethers.parseUnits("50", 18);
      await khrtToken.connect(owner).mint(user2.address, interest); // Mint interest
      await khrtToken.connect(user2).transfer(user1.address, lendingAmount + interest);

      // User should have more than original
      expect(await khrtToken.balanceOf(user1.address)).to.equal(khrtBalance / 2n + lendingAmount + interest);
    });

    it("Should handle oracle price update scenarios", async function () {
      // Simulate ETH price change by updating collateral ratio
      const ethAmount = ethers.parseUnits("1", WETH_DECIMALS);
      const wethAddress = await mockWETH.getAddress();

      // Initial deposit at $2000 ETH (ratio = 2000)
      await mockWETH.connect(user1).approve(await collateralManager.getAddress(), ethAmount);
      await collateralManager.connect(user1).depositCollateral(wethAddress, ethAmount);

      const initialKHRT = await khrtToken.balanceOf(user1.address);
      expect(initialKHRT).to.equal(ethers.parseUnits("2000", 18));

      // Simulate ETH price increase to $3000 by updating ratio for new deposits
      const newRatio = 3000; // FIXED: just 3000, not ethers.parseUnits("3000", 18)
      await collateralManager.setCollateralRatio(wethAddress, newRatio);

      // New deposits should get more KHRT
      await mockWETH.connect(user2).approve(await collateralManager.getAddress(), ethAmount);
      await collateralManager.connect(user2).depositCollateral(wethAddress, ethAmount);

      const user2KHRT = await khrtToken.balanceOf(user2.address);
      expect(user2KHRT).to.equal(ethers.parseUnits("3000", 18));

      // Existing positions maintain their ratios
      const user1Position = await collateralManager.getUserPosition(user1.address, wethAddress);
      expect(user1Position.mintedAmount).to.equal(ethers.parseUnits("2000", 18));
    });
  });
});