import { ethers } from "hardhat";
import fs from "fs";
import path from "path";

// Configuration for whitelisting
interface WhitelistConfig {
  token: string;
  action: "add" | "remove";
  ratio?: number; // KHRT per 1 token (only for add action)
}

// Example configurations - modify as needed
const WHITELIST_CONFIGS: WhitelistConfig[] = [
  // Add these tokens to whitelist with their ratios
  { token: "0xBd8a86E2F16f5251d17348eA0F66d1400301A3bD", action: "add", ratio: 40 }, // STAR TOKEN - 1 STAR = 40 KHRT
  // { token: "0x...", action: "add", ratio: 8000000 }, // Example: 1 ETH = 8,000,000 KHRT
  // { token: "0x...", action: "remove" }, // Remove from whitelist
];

async function main() {
  console.log("Starting whitelist management...");
  
  // Get the deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Managing whitelist with account:", deployer.address);

  // Load deployment info
  const chainId = (await ethers.provider.getNetwork()).chainId;
  const deploymentFile = path.join(__dirname, "../deployments", `deployment-${chainId}.json`);
  
  if (!fs.existsSync(deploymentFile)) {
    throw new Error(`Deployment file not found: ${deploymentFile}. Please run deploy script first.`);
  }

  const deploymentInfo = JSON.parse(fs.readFileSync(deploymentFile, "utf8"));
  const collateralMinterAddress = "0x0764b6C1D56A9A8eD82d737797Fd6910469ff5A0";

  // Get CollateralMinter contract
  const CollateralMinter = await ethers.getContractFactory("CollateralMinter");
  const collateralMinter = CollateralMinter.attach(collateralMinterAddress);

  console.log("CollateralMinter address:", collateralMinterAddress);

  // Process command line arguments
  const args = process.argv.slice(2);
  
  if (args.length === 0) {
    // Use predefined configs
    if (WHITELIST_CONFIGS.length === 0) {
      console.log("\nNo whitelist configurations provided.");
      console.log("Usage examples:");
      console.log("  npm run add:whitelist -- add 0x... 4000");
      console.log("  npm run add:whitelist -- remove 0x...");
      console.log("  npm run add:whitelist -- list");
      return;
    }

    console.log("\nProcessing predefined whitelist configurations...");
    for (const config of WHITELIST_CONFIGS) {
      await processWhitelistAction(collateralMinter, config);
    }
  } else {
    // Process command line arguments
    const command = args[0].toLowerCase();

    if (command === "list") {
      await listWhitelistedTokens(collateralMinter);
    } else if (command === "add" || command === "remove") {
      if (args.length < 2) {
        console.error("Error: Token address required");
        console.log("Usage: npm run add:whitelist -- add <token_address> <ratio>");
        console.log("       npm run add:whitelist -- remove <token_address>");
        return;
      }

      const tokenAddress = args[1];
      
      if (command === "add") {
        if (args.length < 3) {
          console.error("Error: Ratio required for add action");
          console.log("Usage: npm run add:whitelist -- add <token_address> <ratio>");
          return;
        }
        
        const ratio = parseInt(args[2]);
        if (isNaN(ratio) || ratio <= 0) {
          console.error("Error: Invalid ratio. Must be a positive number.");
          return;
        }

        await processWhitelistAction(collateralMinter, {
          token: tokenAddress,
          action: "add",
          ratio: ratio
        });
      } else {
        await processWhitelistAction(collateralMinter, {
          token: tokenAddress,
          action: "remove"
        });
      }
    } else {
      console.error(`Unknown command: ${command}`);
      console.log("Available commands: add, remove, list");
    }
  }
}

async function processWhitelistAction(
  collateralMinter: any,
  config: WhitelistConfig
) {
  const { token, action, ratio } = config;

  // Validate token address
  if (!ethers.isAddress(token)) {
    console.error(`Invalid token address: ${token}`);
    return;
  }

  console.log(`\nProcessing ${action} for token: ${token}`);

  try {
    // Check current whitelist status
    const isWhitelisted = await collateralMinter.isTokenWhitelisted(token);
    console.log(`Current whitelist status: ${isWhitelisted}`);

    if (action === "add") {
      if (!ratio) {
        console.error("Ratio required for add action");
        return;
      }

      // Add to whitelist
      if (!isWhitelisted) {
        console.log("Adding token to whitelist...");
        const whitelistTx = await collateralMinter.setTokenWhitelist(token, true);
        await whitelistTx.wait();
        console.log("Token whitelisted successfully");
      }

      // Set collateral ratio
      console.log(`Setting collateral ratio: 1 token = ${ratio} KHRT...`);
      const ratioTx = await collateralMinter.setCollateralRatio(token, ratio);
      await ratioTx.wait();
      console.log("Collateral ratio set successfully");

      // Verify the ratio
      const savedRatio = await collateralMinter.getCollateralRatio(token);
      console.log(`Verified ratio: ${savedRatio} KHRT per token`);

      // Get token info if possible
      try {
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const tokenContract = MockERC20.attach(token);
        const name = await tokenContract.name();
        const symbol = await tokenContract.symbol();
        const decimals = await tokenContract.decimals();
        console.log(`Token info: ${name} (${symbol}), Decimals: ${decimals}`);
      } catch (e) {
        console.log("Could not fetch token info");
      }

    } else if (action === "remove") {
      if (isWhitelisted) {
        console.log("Removing token from whitelist...");
        const tx = await collateralMinter.setTokenWhitelist(token, false);
        await tx.wait();
        console.log("Token removed from whitelist successfully");
      } else {
        console.log("Token is not whitelisted");
      }
    }
  } catch (error) {
    console.error(`Error processing ${action} for token ${token}:`, error);
  }
}

async function listWhitelistedTokens(collateralMinter: any) {
  console.log("\n========== WHITELISTED TOKENS ==========");
  
  // Note: Since the contract doesn't have a function to list all whitelisted tokens,
  // we need to check specific token addresses or track them separately
  console.log("To check if a token is whitelisted, use:");
  console.log("  npm run add:whitelist -- list <token_address>");
  
  // If you have a list of known tokens, you can check them here
  const knownTokens = [
    // Add your known token addresses here
    // "0x...",
  ];

  if (knownTokens.length > 0) {
    for (const token of knownTokens) {
      const isWhitelisted = await collateralMinter.isTokenWhitelisted(token);
      if (isWhitelisted) {
        const ratio = await collateralMinter.getCollateralRatio(token);
        console.log(`Token: ${token}`);
        console.log(`  Whitelisted: Yes`);
        console.log(`  Ratio: ${ratio} KHRT per token`);
      }
    }
  }
  
  console.log("========================================");
}

// Handle specific token check
if (process.argv[2] === "list" && process.argv[3]) {
  const checkSpecificToken = async () => {
    const [deployer] = await ethers.getSigners();
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const deploymentFile = path.join(__dirname, "../deployments", `deployment-${chainId}.json`);
    const deploymentInfo = JSON.parse(fs.readFileSync(deploymentFile, "utf8"));
    const CollateralMinter = await ethers.getContractFactory("CollateralMinter");
    const collateralMinter = CollateralMinter.attach(deploymentInfo.contracts.CollateralMinter.address);
    
    const token = process.argv[3];
    const isWhitelisted = await collateralMinter.isTokenWhitelisted(token);
    console.log(`\nToken: ${token}`);
    console.log(`Whitelisted: ${isWhitelisted}`);
    
    if (isWhitelisted) {
      const ratio = await collateralMinter.getCollateralRatio(token);
      const totalDeposited = await collateralMinter.getTotalCollateralDeposited(token);
      console.log(`Ratio: ${ratio} KHRT per token`);
      console.log(`Total Deposited: ${totalDeposited}`);
    }
  };
  
  checkSpecificToken()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
} else {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}