import { ethers } from "hardhat";

// Token configuration interface
interface TokenConfig {
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  khrtPerToken: number;
  description: string;
  whitelist: boolean;
}

// Your token configurations
const TOKEN_CONFIGS: TokenConfig[] = [
  {
    address: "0xc15c87cB326c22a801680DcC78Cb0032808B62a2",
    symbol: "STAR",
    name: "STAR TOKEN",
    decimals: 18,
    khrtPerToken: 40, // 1 STAR = 40 KHRT
    description: "STAR token of tcl",
    whitelist: true
  },
  // Add more tokens here as needed
  // {
  //   address: "0x...",
  //   symbol: "USDT",
  //   name: "Tether USD",
  //   decimals: 6,
  //   khrtPerToken: 4000,
  //   description: "USDT stablecoin",
  //   whitelist: true
  // },
];

// Contract addresses
const KHRT_TOKEN_ADDRESS = "0x67A686c4BEF1f817157eA9e184E7aEf2380427db";
const COLLATERAL_MANAGER_ADDRESS = "0xf35e383Ba3A351E3eE212B9D011e3BA269e03AC4";

class WhitelistManager {
  private khrtToken: any;
  private collateralManager: any;
  private deployer: any;

  constructor(khrtToken: any, collateralManager: any, deployer: any) {
    this.khrtToken = khrtToken;
    this.collateralManager = collateralManager;
    this.deployer = deployer;
  }

  /**
   * Validate system configuration
   */
  async validateSystem(): Promise<void> {
    console.log("\n=== System Validation ===");
    
    try {
      // Check if deployer is owner of KHRT token
      const khrtOwner = await this.khrtToken.owner();
      const isKhrtOwner = khrtOwner.toLowerCase() === this.deployer.address.toLowerCase();
      console.log(`KHRT Owner: ${khrtOwner}`);
      console.log(`Deployer is KHRT owner: ${isKhrtOwner ? '✓' : '✗'}`);

      // Check if deployer is owner of collateral manager
      const managerOwner = await this.collateralManager.owner();
      const isManagerOwner = managerOwner.toLowerCase() === this.deployer.address.toLowerCase();
      console.log(`Manager Owner: ${managerOwner}`);
      console.log(`Deployer is Manager owner: ${isManagerOwner ? '✓' : '✗'}`);

      // Check if collateral manager is authorized as minter
      const collateralManagerAddress = await this.collateralManager.getAddress();
      const isAuthorizedMinter = await this.khrtToken.isCollateralMinter(collateralManagerAddress);
      console.log(`Collateral Manager authorized as minter: ${isAuthorizedMinter ? '✓' : '✗'}`);

      if (!isAuthorizedMinter) {
        console.log("\n⚠️  WARNING: Collateral Manager is not authorized as a minter!");
        console.log("Run: OPERATION=authorize-manager to fix this");
      }

      // Validate token configs
      const validConfigs = this.getValidConfigs();
      console.log(`Valid token configurations: ${validConfigs.length}`);

    } catch (error) {
      console.error("System validation failed:", error);
      throw error;
    }
  }

  /**
   * Authorize collateral manager as minter
   */
  async authorizeCollateralManager(): Promise<void> {
    console.log("\n=== Authorizing Collateral Manager ===");
    
    try {
      const collateralManagerAddress = await this.collateralManager.getAddress();
      
      // Check current status
      const isAuthorized = await this.khrtToken.isCollateralMinter(collateralManagerAddress);
      if (isAuthorized) {
        console.log("✓ Collateral Manager is already authorized");
        return;
      }

      // Authorize as collateral minter
      const tx = await this.khrtToken.setCollateralMinter(collateralManagerAddress, true);
      await tx.wait();
      
      console.log("✓ Collateral Manager authorized as minter");
      console.log(`Transaction hash: ${tx.hash}`);
    } catch (error) {
      console.error("✗ Failed to authorize collateral manager:", error);
      throw error;
    }
  }

  /**
   * Get valid token configurations
   */
  private getValidConfigs(): TokenConfig[] {
    return TOKEN_CONFIGS.filter(config => 
      config.address !== "0x..." && 
      ethers.isAddress(config.address) &&
      config.address.toLowerCase() !== KHRT_TOKEN_ADDRESS.toLowerCase()
    );
  }

  /**
   * Add a single token to whitelist
   */
  async addToWhitelist(tokenAddress: string, tokenSymbol?: string): Promise<void> {
    try {
      console.log(`\n=== Adding ${tokenSymbol || tokenAddress} to whitelist ===`);
      
      // Validate address
      if (!ethers.isAddress(tokenAddress)) {
        throw new Error("Invalid token address");
      }

      // Check if it's the KHRT token itself
      if (tokenAddress.toLowerCase() === KHRT_TOKEN_ADDRESS.toLowerCase()) {
        throw new Error("Cannot whitelist the KHRT token itself");
      }
      
      // Check if already whitelisted
      const isWhitelisted = await this.khrtToken.isTokenWhitelisted(tokenAddress);
      if (isWhitelisted) {
        console.log(`✓ ${tokenSymbol || tokenAddress} is already whitelisted`);
        return;
      }

      // Add to whitelist
      const tx = await this.khrtToken.setTokenWhitelist(tokenAddress, true);
      await tx.wait();
      
      console.log(`✓ ${tokenSymbol || tokenAddress} added to whitelist`);
      console.log(`Transaction hash: ${tx.hash}`);
    } catch (error) {
      console.error(`✗ Failed to add ${tokenSymbol || tokenAddress} to whitelist:`, error);
      throw error;
    }
  }

  /**
   * Remove a single token from whitelist
   */
  async removeFromWhitelist(tokenAddress: string, tokenSymbol?: string): Promise<void> {
    try {
      console.log(`\n=== Removing ${tokenSymbol || tokenAddress} from whitelist ===`);
      
      // Check if currently whitelisted
      const isWhitelisted = await this.khrtToken.isTokenWhitelisted(tokenAddress);
      if (!isWhitelisted) {
        console.log(`✓ ${tokenSymbol || tokenAddress} is already not whitelisted`);
        return;
      }

      // Remove from whitelist
      const tx = await this.khrtToken.setTokenWhitelist(tokenAddress, false);
      await tx.wait();
      
      console.log(`✓ ${tokenSymbol || tokenAddress} removed from whitelist`);
      console.log(`Transaction hash: ${tx.hash}`);
    } catch (error) {
      console.error(`✗ Failed to remove ${tokenSymbol || tokenAddress} from whitelist:`, error);
      throw error;
    }
  }

  /**
   * Batch add/remove tokens from whitelist
   */
  async batchUpdateWhitelist(
    tokenAddresses: string[], 
    statuses: boolean[], 
    tokenSymbols?: string[]
  ): Promise<void> {
    try {
      console.log(`\n=== Batch updating whitelist for ${tokenAddresses.length} tokens ===`);
      
      if (tokenAddresses.length !== statuses.length) {
        throw new Error("Token addresses and statuses arrays must have same length");
      }

      if (tokenAddresses.length > 50) {
        throw new Error("Too many tokens for batch operation (max 50)");
      }

      // Display what will be updated
      for (let i = 0; i < tokenAddresses.length; i++) {
        const symbol = tokenSymbols?.[i] || tokenAddresses[i];
        const action = statuses[i] ? "ADD" : "REMOVE";
        console.log(`- ${action}: ${symbol}`);
      }

      // Execute batch update
      const tx = await this.khrtToken.batchSetTokenWhitelist(tokenAddresses, statuses);
      await tx.wait();
      
      console.log(`✓ Batch whitelist update completed`);
      console.log(`Transaction hash: ${tx.hash}`);
    } catch (error) {
      console.error("✗ Failed to batch update whitelist:", error);
      throw error;
    }
  }

  /**
   * Update whitelist based on TOKEN_CONFIGS
   */
  async updateFromConfigs(): Promise<void> {
    console.log(`\n=== Updating whitelist from TOKEN_CONFIGS ===`);
    
    const validConfigs = this.getValidConfigs();

    if (validConfigs.length === 0) {
      console.log("No valid token addresses found in TOKEN_CONFIGS");
      return;
    }

    const addresses = validConfigs.map(config => config.address);
    const statuses = validConfigs.map(config => config.whitelist);
    const symbols = validConfigs.map(config => config.symbol);

    await this.batchUpdateWhitelist(addresses, statuses, symbols);
  }

  /**
   * Set collateral ratios for whitelisted tokens
   */
  async setCollateralRatios(): Promise<void> {
    console.log(`\n=== Setting collateral ratios ===`);
    
    const validConfigs = this.getValidConfigs().filter(config => config.whitelist);

    for (const config of validConfigs) {
      try {
        // Check if token is whitelisted
        const isWhitelisted = await this.khrtToken.isTokenWhitelisted(config.address);
        if (!isWhitelisted) {
          console.log(`⚠ Skipping ${config.symbol} - not whitelisted`);
          continue;
        }

        // Get current ratio
        const currentRatio = await this.collateralManager.getCollateralRatio(config.address);
        if (currentRatio.toString() === config.khrtPerToken.toString()) {
          console.log(`✓ ${config.symbol} ratio already set: 1 ${config.symbol} = ${config.khrtPerToken} KHRT`);
          continue;
        }

        // Set collateral ratio
        const tx = await this.collateralManager.setCollateralRatio(
          config.address, 
          config.khrtPerToken
        );
        await tx.wait();
        
        console.log(`✓ ${config.symbol} ratio set: 1 ${config.symbol} = ${config.khrtPerToken} KHRT`);
        console.log(`Transaction hash: ${tx.hash}`);
        
        // Add delay between transactions
        await new Promise(resolve => setTimeout(resolve, 1000));
      } catch (error) {
        console.error(`✗ Failed to set ratio for ${config.symbol}:`, error);
      }
    }
  }

  /**
   * Get current whitelist status for multiple tokens
   */
  async checkWhitelistStatus(tokenAddresses: string[], tokenSymbols?: string[]): Promise<void> {
    console.log(`\n=== Checking whitelist status ===`);
    
    for (let i = 0; i < tokenAddresses.length; i++) {
      try {
        const isWhitelisted = await this.khrtToken.isTokenWhitelisted(tokenAddresses[i]);
        const symbol = tokenSymbols?.[i] || tokenAddresses[i];
        const status = isWhitelisted ? "✓ WHITELISTED" : "✗ NOT WHITELISTED";
        console.log(`${symbol}: ${status}`);
      } catch (error) {
        const symbol = tokenSymbols?.[i] || tokenAddresses[i];
        console.log(`${symbol}: ERROR - ${error}`);
      }
    }
  }

  /**
   * Get comprehensive token information
   */
  async getTokenInfo(tokenAddress: string): Promise<any> {
    try {
      const [isWhitelisted, tokenInfo] = await Promise.all([
        this.khrtToken.isTokenWhitelisted(tokenAddress),
        this.collateralManager.getTokenInfo(tokenAddress)
      ]);

      // Try to get token metadata
      let tokenMetadata = {
        name: "Unknown",
        symbol: "Unknown",
        decimals: tokenInfo.decimals
      };

      try {
        const token = await ethers.getContractAt("IERC20Metadata", tokenAddress);
        const [name, symbol] = await Promise.all([
          token.name(),
          token.symbol()
        ]);
        tokenMetadata = { name, symbol, decimals: tokenInfo.decimals };
      } catch (error) {
        console.log(`Could not fetch metadata for ${tokenAddress}`);
      }

      return {
        address: tokenAddress,
        ...tokenMetadata,
        isWhitelisted,
        collateralRatio: tokenInfo.ratio.toString(),
        totalDeposited: ethers.formatUnits(tokenInfo.totalDeposited, tokenInfo.decimals),
        rawTotalDeposited: tokenInfo.totalDeposited.toString()
      };
    } catch (error) {
      throw new Error(`Failed to get token info for ${tokenAddress}: ${error}`);
    }
  }

  /**
   * Complete setup process
   */
  async completeSetup(): Promise<void> {
    console.log("\n🚀 === Starting Complete Setup Process ===");
    
    try {
      // Step 1: Validate system
      await this.validateSystem();
      
      // Step 2: Authorize collateral manager if needed
      await this.authorizeCollateralManager();
      
      // Step 3: Update whitelist from configs
      await this.updateFromConfigs();
      
      // Step 4: Set collateral ratios
      await this.setCollateralRatios();
      
      // Step 5: Final verification
      console.log("\n=== Final Verification ===");
      const validConfigs = this.getValidConfigs();
      const addresses = validConfigs.map(config => config.address);
      const symbols = validConfigs.map(config => config.symbol);
      await this.checkWhitelistStatus(addresses, symbols);
      
      console.log("\n🎉 Setup completed successfully!");
      console.log("Your KHRT collateral system is now ready to accept deposits.");
      
    } catch (error) {
      console.error("\n❌ Setup failed:", error);
      throw error;
    }
  }

  /**
   * Audit all whitelisted tokens using events
   */
  async auditWhitelistedTokens(): Promise<void> {
    console.log("\n=== Whitelisted Tokens Audit ===");
    
    try {
      // Get all TokenWhitelisted events
      const filter = this.khrtToken.filters.TokenWhitelisted();
      const events = await this.khrtToken.queryFilter(filter, 0, "latest");
      
      // Track current status of each token
      const tokenStatus = new Map<string, boolean>();
      
      for (const event of events) {
        if ('args' in event && event.args && event.args.length >= 2) {
          const tokenAddress = event.args[0] as string;
          const isWhitelisted = event.args[1] as boolean;
          tokenStatus.set(tokenAddress.toLowerCase(), isWhitelisted);
        }
      }
      
      // Get only currently whitelisted tokens
      const whitelistedAddresses = Array.from(tokenStatus.entries())
        .filter(([_, isWhitelisted]) => isWhitelisted)
        .map(([address, _]) => address);
      
      if (whitelistedAddresses.length === 0) {
        console.log("No whitelisted tokens found");
        return;
      }

      console.log(`Found ${whitelistedAddresses.length} whitelisted tokens:\n`);
      
      for (const address of whitelistedAddresses) {
        try {
          const info = await this.getTokenInfo(address);
          console.log(`Token: ${info.symbol} (${info.name})`);
          console.log(`  Address: ${info.address}`);
          console.log(`  Decimals: ${info.decimals}`);
          console.log(`  Collateral Ratio: ${info.collateralRatio} KHRT per token`);
          console.log(`  Total Deposited: ${info.totalDeposited} ${info.symbol}`);
          console.log(`  Whitelisted: ${info.isWhitelisted ? '✓' : '✗'}`);
          console.log();
        } catch (error) {
          console.log(`  Error getting info for ${address}: ${error}`);
          console.log();
        }
      }
    } catch (error) {
      console.error("Error during audit:", error);
    }
  }
}

/**
 * Main execution function
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  
  console.log("🔧 Managing whitelist with account:", deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");

  // Get contract instances
  const khrtToken = await ethers.getContractAt("KHRTStablecoin", KHRT_TOKEN_ADDRESS);
  const collateralManager = await ethers.getContractAt("KHRTCollateralManager", COLLATERAL_MANAGER_ADDRESS);

  // Create whitelist manager
  const whitelistManager = new WhitelistManager(khrtToken, collateralManager, deployer);

  // Parse command line arguments for operation type
  const operation = process.env.OPERATION || "setup";
  const tokenAddress = process.env.TOKEN_ADDRESS;
  const tokenSymbol = process.env.TOKEN_SYMBOL;

  try {
    switch (operation.toLowerCase()) {
      case "setup":
        await whitelistManager.completeSetup();
        break;

      case "validate":
        await whitelistManager.validateSystem();
        break;

      case "authorize-manager":
        await whitelistManager.authorizeCollateralManager();
        break;

      case "add":
        if (!tokenAddress) {
          throw new Error("TOKEN_ADDRESS environment variable required for add operation");
        }
        await whitelistManager.addToWhitelist(tokenAddress, tokenSymbol);
        break;

      case "remove":
        if (!tokenAddress) {
          throw new Error("TOKEN_ADDRESS environment variable required for remove operation");
        }
        await whitelistManager.removeFromWhitelist(tokenAddress, tokenSymbol);
        break;

      case "batch-update":
        await whitelistManager.updateFromConfigs();
        break;

      case "set-ratios":
        await whitelistManager.setCollateralRatios();
        break;

      case "audit":
        await whitelistManager.auditWhitelistedTokens();
        break;

      case "info":
        if (!tokenAddress) {
          throw new Error("TOKEN_ADDRESS required for info operation");
        }
        const info = await whitelistManager.getTokenInfo(tokenAddress);
        console.log("\n=== Token Information ===");
        console.log(JSON.stringify(info, null, 2));
        break;

      case "check":
        const validConfigs = TOKEN_CONFIGS.filter(config => 
          config.address !== "0x..." && ethers.isAddress(config.address)
        );
        
        if (validConfigs.length === 0) {
          console.log("No valid token addresses in TOKEN_CONFIGS to check");
          console.log("Please update the addresses in TOKEN_CONFIGS array");
        } else {
          const addresses = validConfigs.map(config => config.address);
          const symbols = validConfigs.map(config => config.symbol);
          await whitelistManager.checkWhitelistStatus(addresses, symbols);
        }
        break;

      default:
        console.log("Available operations:");
        console.log("- setup: Complete setup process (recommended)");
        console.log("- validate: Check system configuration");
        console.log("- authorize-manager: Authorize collateral manager");
        console.log("- add: Add single token to whitelist");
        console.log("- remove: Remove single token from whitelist");
        console.log("- batch-update: Update whitelist from configs");
        console.log("- set-ratios: Set collateral ratios");
        console.log("- check: Check whitelist status");
        console.log("- audit: Audit all whitelisted tokens");
        console.log("- info: Get token information");
        break;
    }

    console.log("\n✅ Operation completed successfully");
  } catch (error) {
    console.error("\n❌ Operation failed:", error);
    process.exit(1);
  }
}

// Export for use in other scripts
export { WhitelistManager, TOKEN_CONFIGS };

// Run if called directly
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}