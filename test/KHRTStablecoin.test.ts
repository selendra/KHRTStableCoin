import { expect } from "chai";
import { ethers } from "hardhat";
import { KHRTStablecoin, MockERC20 } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("KHRTStablecoin", function () {
  let khrtToken: KHRTStablecoin;
  let mockUSDC: MockERC20;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let minter: SignerWithAddress;
  let blacklisted: SignerWithAddress;

  beforeEach(async function () {
    [owner, user1, user2, minter, blacklisted] = await ethers.getSigners();

    // Deploy KHRT token
    const KHRTStablecoin = await ethers.getContractFactory("KHRTStablecoin");
    khrtToken = await KHRTStablecoin.deploy("KHRT Testing","TKHR");
    await khrtToken.waitForDeployment();

    // Deploy mock USDC
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6);
    await mockUSDC.waitForDeployment();

    // Setup initial permissions
    await khrtToken.setNormalMinter(minter.address, true);
    await khrtToken.setCollateralMinter(minter.address, true);
    await khrtToken.setTokenWhitelist(await mockUSDC.getAddress(), true);
  });

  describe("Deployment", function () {
    it("Should set owner as initial minter", async function () {
      expect(await khrtToken.isNormalMinter(owner.address)).to.be.true;
      expect(await khrtToken.isCollateralMinter(owner.address)).to.be.true;
    });

    it("Should start with zero total supply", async function () {
      expect(await khrtToken.totalSupply()).to.equal(0);
    });

    it("Should have 6 decimals", async function () {
      expect(await khrtToken.decimals()).to.equal(6);
    });
  });

  describe("Access Control", function () {
    describe("Token Whitelist", function () {
      it("Should allow owner to whitelist tokens", async function () {
        const tokenAddress = user1.address;
        await expect(khrtToken.setTokenWhitelist(tokenAddress, true))
          .to.emit(khrtToken, "TokenWhitelisted")
          .withArgs(tokenAddress, true);
        
        expect(await khrtToken.isTokenWhitelisted(tokenAddress)).to.be.true;
      });

      it("Should allow owner to remove tokens from whitelist", async function () {
        const tokenAddress = user1.address;
        await khrtToken.setTokenWhitelist(tokenAddress, true);
        
        await expect(khrtToken.setTokenWhitelist(tokenAddress, false))
          .to.emit(khrtToken, "TokenWhitelisted")
          .withArgs(tokenAddress, false);
        
        expect(await khrtToken.isTokenWhitelisted(tokenAddress)).to.be.false;
      });

      it("Should allow batch whitelisting", async function () {
        const tokens = [user1.address, user2.address];
        const statuses = [true, false];

        await expect(khrtToken.batchSetTokenWhitelist(tokens, statuses))
          .to.emit(khrtToken, "TokenWhitelisted")
          .withArgs(user1.address, true);

        expect(await khrtToken.isTokenWhitelisted(user1.address)).to.be.true;
        expect(await khrtToken.isTokenWhitelisted(user2.address)).to.be.false;
      });

      it("Should reject non-owner whitelist attempts", async function () {
        await expect(khrtToken.connect(user1).setTokenWhitelist(user2.address, true))
          .to.be.revertedWithCustomError(khrtToken, "OwnableUnauthorizedAccount");
      });

      it("Should reject invalid addresses", async function () {
        await expect(khrtToken.setTokenWhitelist(ethers.ZeroAddress, true))
          .to.be.revertedWith("KHRT: Invalid address");
      });
    });

    describe("Minter Management", function () {
      it("Should allow owner to set normal minters", async function () {
        await expect(khrtToken.setNormalMinter(user1.address, true))
          .to.emit(khrtToken, "NormalMinterAuthorized")
          .withArgs(user1.address, true);
        
        expect(await khrtToken.isNormalMinter(user1.address)).to.be.true;
      });

      it("Should allow owner to set collateral minters", async function () {
        await expect(khrtToken.setCollateralMinter(user1.address, true))
          .to.emit(khrtToken, "CollateralMinterAuthorized")
          .withArgs(user1.address, true);
        
        expect(await khrtToken.isCollateralMinter(user1.address)).to.be.true;
      });

      it("Should allow owner to revoke minter permissions", async function () {
        await khrtToken.setNormalMinter(user1.address, true);
        await khrtToken.setNormalMinter(user1.address, false);
        
        expect(await khrtToken.isNormalMinter(user1.address)).to.be.false;
      });
    });

    describe("User Blacklist", function () {
      it("Should allow owner to blacklist users", async function () {
        await expect(khrtToken.setUserBlacklist(user1.address, true))
          .to.emit(khrtToken, "UserBlacklisted")
          .withArgs(user1.address, true);
        
        expect(await khrtToken.isUserBlacklisted(user1.address)).to.be.true;
      });

      it("Should allow batch blacklisting", async function () {
        const users = [user1.address, user2.address];
        const statuses = [true, false];

        await khrtToken.batchSetUserBlacklist(users, statuses);

        expect(await khrtToken.isUserBlacklisted(user1.address)).to.be.true;
        expect(await khrtToken.isUserBlacklisted(user2.address)).to.be.false;
      });
    });
  });

  describe("Minting", function () {
    describe("Normal Minting", function () {
      it("Should allow authorized minters to mint tokens", async function () {
        const mintAmount = ethers.parseUnits("1000", 6); // 1000 KHRT with 6 decimals
        
        await expect(khrtToken.connect(minter).mint(user1.address, mintAmount))
          .to.emit(khrtToken, "TokensMinted")
          .withArgs(user1.address, mintAmount);
        
        expect(await khrtToken.balanceOf(user1.address)).to.equal(mintAmount);
        expect(await khrtToken.totalSupply()).to.equal(mintAmount);
      });

      it("Should reject minting from unauthorized addresses", async function () {
        const mintAmount = ethers.parseUnits("1000", 6);
        
        await expect(khrtToken.connect(user1).mint(user2.address, mintAmount))
          .to.be.revertedWith("KHRT: Unauthorized normal minter");
      });

      it("Should reject minting below minimum amount", async function () {
        const belowMinAmount = ethers.parseUnits("0.5", 6); // Below 1 KHRT minimum
        
        await expect(khrtToken.connect(minter).mint(user1.address, belowMinAmount))
          .to.be.revertedWith("KHRT: Below minimum mint amount");
      });

      it("Should reject minting to blacklisted users", async function () {
        await khrtToken.setUserBlacklist(user1.address, true);
        const mintAmount = ethers.parseUnits("1000", 6);
        
        await expect(khrtToken.connect(minter).mint(user1.address, mintAmount))
          .to.be.revertedWith("KHRT: Address is blacklisted");
      });

      it("Should reject minting beyond max supply", async function () {
        const maxSupply = await khrtToken.getMaxSupply();
        const excessAmount = maxSupply + ethers.parseUnits("1", 6);
        
        await expect(khrtToken.connect(minter).mint(user1.address, excessAmount))
          .to.be.revertedWith("KHRT: Exceeds maximum supply");
      });
    });

    describe("Collateral Minting", function () {
      it("Should allow collateral minters to mint with collateral", async function () {
        const mintAmount = ethers.parseUnits("1000", 6);
        const collateralToken = await mockUSDC.getAddress();
        
        await expect(khrtToken.connect(minter).mintWithCollateral(user1.address, mintAmount, collateralToken))
          .to.emit(khrtToken, "TokensMintedWithCollateral")
          .withArgs(user1.address, mintAmount, collateralToken);
        
        expect(await khrtToken.balanceOf(user1.address)).to.equal(mintAmount);
      });

      it("Should reject collateral minting with non-whitelisted token", async function () {
        const mintAmount = ethers.parseUnits("1000", 6);
        const nonWhitelistedToken = user2.address;
        
        await expect(khrtToken.connect(minter).mintWithCollateral(user1.address, mintAmount, nonWhitelistedToken))
          .to.be.revertedWith("KHRT: Token not whitelisted");
      });

      it("Should reject unauthorized collateral minting", async function () {
        const mintAmount = ethers.parseUnits("1000", 6);
        const collateralToken = await mockUSDC.getAddress();
        
        await expect(khrtToken.connect(user1).mintWithCollateral(user2.address, mintAmount, collateralToken))
          .to.be.revertedWith("KHRT: Unauthorized collateral minter");
      });
    });
  });

  describe("Burning", function () {
    beforeEach(async function () {
      // Mint some tokens for testing
      const mintAmount = ethers.parseUnits("10000", 6);
      await khrtToken.connect(minter).mint(user1.address, mintAmount);
      await khrtToken.connect(minter).mint(user2.address, mintAmount);
    });

    it("Should allow users to burn their own tokens", async function () {
      const burnAmount = ethers.parseUnits("1000", 6);
      const initialBalance = await khrtToken.balanceOf(user1.address);
      
      await expect(khrtToken.connect(user1).burn(burnAmount))
        .to.emit(khrtToken, "TokensBurned")
        .withArgs(user1.address, burnAmount);
      
      expect(await khrtToken.balanceOf(user1.address)).to.equal(initialBalance - burnAmount);
    });

    it("Should allow burning from another address with allowance", async function () {
      const burnAmount = ethers.parseUnits("1000", 6);
      
      // Approve user2 to burn user1's tokens
      await khrtToken.connect(user1).approve(user2.address, burnAmount);
      
      await expect(khrtToken.connect(user2).burnFrom(user1.address, burnAmount))
        .to.emit(khrtToken, "TokensBurnedFrom")
        .withArgs(user1.address, user2.address, burnAmount);
    });

    it("Should reject burning below minimum amount", async function () {
      const belowMinAmount = ethers.parseUnits("0.5", 6);
      
      await expect(khrtToken.connect(user1).burn(belowMinAmount))
        .to.be.revertedWith("KHRT: Below minimum burn amount");
    });

    it("Should reject burning more than balance", async function () {
      const balance = await khrtToken.balanceOf(user1.address);
      const excessAmount = balance + ethers.parseUnits("1", 6);
      
      await expect(khrtToken.connect(user1).burn(excessAmount))
        .to.be.revertedWith("KHRT: Insufficient balance to burn");
    });

    it("Should reject burnFrom without sufficient allowance", async function () {
      const burnAmount = ethers.parseUnits("1000", 6);
      
      await expect(khrtToken.connect(user2).burnFrom(user1.address, burnAmount))
        .to.be.revertedWith("KHRT: Insufficient allowance");
    });

    it("Should reject burning from blacklisted users", async function () {
      await khrtToken.setUserBlacklist(user1.address, true);
      const burnAmount = ethers.parseUnits("1000", 6);
      
      await expect(khrtToken.connect(user1).burn(burnAmount))
        .to.be.revertedWith("KHRT: Address is blacklisted");
    });
  });

  describe("Transfers", function () {
    beforeEach(async function () {
      // Mint some tokens for testing
      const mintAmount = ethers.parseUnits("10000", 6);
      await khrtToken.connect(minter).mint(user1.address, mintAmount);
    });

    it("Should allow normal transfers", async function () {
      const transferAmount = ethers.parseUnits("1000", 6);
      
      await expect(khrtToken.connect(user1).transfer(user2.address, transferAmount))
        .to.emit(khrtToken, "Transfer")
        .withArgs(user1.address, user2.address, transferAmount);
      
      expect(await khrtToken.balanceOf(user2.address)).to.equal(transferAmount);
    });

    it("Should reject transfers to blacklisted users", async function () {
      await khrtToken.setUserBlacklist(user2.address, true);
      const transferAmount = ethers.parseUnits("1000", 6);
      
      await expect(khrtToken.connect(user1).transfer(user2.address, transferAmount))
        .to.be.revertedWith("KHRT: Address is blacklisted");
    });

    it("Should reject transfers from blacklisted users", async function () {
      await khrtToken.setUserBlacklist(user1.address, true);
      const transferAmount = ethers.parseUnits("1000", 6);
      
      await expect(khrtToken.connect(user1).transfer(user2.address, transferAmount))
        .to.be.revertedWith("KHRT: Address is blacklisted");
    });

    it("Should allow batch transfers", async function () {
      const recipients = [user2.address, minter.address];
      const amounts = [ethers.parseUnits("1000", 6), ethers.parseUnits("2000", 6)];
      
      await khrtToken.connect(user1).batchTransfer(recipients, amounts);
      
      expect(await khrtToken.balanceOf(user2.address)).to.equal(amounts[0]);
      expect(await khrtToken.balanceOf(minter.address)).to.equal(amounts[1]);
    });

    it("Should reject batch transfers with mismatched arrays", async function () {
      const recipients = [user2.address];
      const amounts = [ethers.parseUnits("1000", 6), ethers.parseUnits("2000", 6)];
      
      await expect(khrtToken.connect(user1).batchTransfer(recipients, amounts))
        .to.be.revertedWith("KHRT: Arrays length mismatch");
    });
  });

  describe("Pause Functionality", function () {
    beforeEach(async function () {
      // Mint some tokens for testing
      const mintAmount = ethers.parseUnits("10000", 6);
      await khrtToken.connect(minter).mint(user1.address, mintAmount);
    });

    it("Should allow owner to pause contract", async function () {
      await khrtToken.pause();
      expect(await khrtToken.paused()).to.be.true;
    });

    it("Should reject minting when paused", async function () {
      await khrtToken.pause();
      const mintAmount = ethers.parseUnits("1000", 6);
      
      await expect(khrtToken.connect(minter).mint(user2.address, mintAmount))
        .to.be.revertedWithCustomError(khrtToken, "EnforcedPause");
    });

    it("Should reject transfers when paused", async function () {
      await khrtToken.pause();
      const transferAmount = ethers.parseUnits("1000", 6);
      
      await expect(khrtToken.connect(user1).transfer(user2.address, transferAmount))
        .to.be.revertedWithCustomError(khrtToken, "EnforcedPause");
    });

    it("Should allow unpausing", async function () {
      await khrtToken.pause();
      await khrtToken.unpause();
      
      expect(await khrtToken.paused()).to.be.false;
      
      // Should work after unpausing
      const transferAmount = ethers.parseUnits("1000", 6);
      await khrtToken.connect(user1).transfer(user2.address, transferAmount);
    });
  });

  describe("View Functions", function () {
    it("Should check if amount can be minted", async function () {
      const maxSupply = await khrtToken.getMaxSupply();
      
      expect(await khrtToken.canMint(ethers.parseUnits("1000", 6))).to.be.true;
      expect(await khrtToken.canMint(maxSupply + ethers.parseUnits("1", 6))).to.be.false;
    });
  });

  describe("Edge Cases", function () {
    it("Should handle zero amount transfers", async function () {
      await expect(khrtToken.connect(user1).transfer(user2.address, 0))
        .to.be.revertedWith("KHRT: Transfer amount must be greater than 0");
    });

    it("Should handle invalid address operations", async function () {
      await expect(khrtToken.connect(user1).transfer(ethers.ZeroAddress, ethers.parseUnits("1000", 6)))
        .to.be.revertedWith("KHRT: Invalid address");
    });

    it("Should handle approvals to zero address", async function () {
      await expect(khrtToken.connect(user1).approve(ethers.ZeroAddress, ethers.parseUnits("1000", 6)))
        .to.be.revertedWith("KHRT: Invalid address");
    });
  });
});