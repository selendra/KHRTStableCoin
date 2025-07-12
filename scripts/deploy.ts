import { ethers } from "hardhat";
import { Contract } from "ethers";

async function main() {
  const [deployer] = await ethers.getSigners();
  
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // Deploy KHRT Stablecoin first
  console.log("\n=== Deploying KHRT Stablecoin ===");
  const KHRTStablecoin = await ethers.getContractFactory("KHRTStablecoin");
  const khrtToken = await KHRTStablecoin.deploy();
  await khrtToken.waitForDeployment();
  const khrtAddress = await khrtToken.getAddress();
  
  console.log("KHRT Stablecoin deployed to:", khrtAddress);

  // Deploy Collateral Manager
  console.log("\n=== Deploying Collateral Manager ===");
  const KHRTCollateralManager = await ethers.getContractFactory("KHRTCollateralManager");
  const collateralManager = await KHRTCollateralManager.deploy(khrtAddress);
  await collateralManager.waitForDeployment();
  const collateralManagerAddress = await collateralManager.getAddress();
  
  console.log("Collateral Manager deployed to:", collateralManagerAddress);

  // Setup initial configuration
  console.log("\n=== Setting up initial configuration ===");

  // Authorize collateral manager as a collateral minter
  console.log("Authorizing Collateral Manager as collateral minter...");
  const authorizeTx = await khrtToken.setCollateralMinter(collateralManagerAddress, true);
  await authorizeTx.wait();
  console.log("✓ Collateral Manager authorized");

  // Deploy mock ERC20 tokens for testing/demo (only on testnets)
  const network = await ethers.provider.getNetwork();
  const isTestnet = network.chainId === 11155111n || network.chainId === 31337n; // Sepolia or Hardhat

  if (isTestnet) {
    console.log("\n=== Deploying Mock Tokens for Testing ===");
    
    // Deploy Mock USDC
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6); // 6 decimals like real USDC
    await mockUSDC.waitForDeployment();
    const mockUSDCAddress = await mockUSDC.getAddress();
    console.log("Mock USDC deployed to:", mockUSDCAddress);

    // Deploy Mock USDT
    const mockUSDT = await MockERC20.deploy("Mock USDT", "USDT", 6); // 6 decimals like real USDT
    await mockUSDT.waitForDeployment();
    const mockUSDTAddress = await mockUSDT.getAddress();
    console.log("Mock USDT deployed to:", mockUSDTAddress);

    // Whitelist mock tokens in KHRT
    console.log("\nWhitelisting mock tokens...");
    await (await khrtToken.setTokenWhitelist(mockUSDCAddress, true)).wait();
    await (await khrtToken.setTokenWhitelist(mockUSDTAddress, true)).wait();
    console.log("✓ Mock tokens whitelisted");

    // Set collateral ratios (1:1 for stablecoins, adjusted for decimals)
    console.log("\nSetting collateral ratios...");
    // For 6-decimal tokens to 18-decimal KHRT: ratio = 10^12 (1:1 value ratio)
    const stablecoinRatio = ethers.parseUnits("1", 12); // 1e12
    
    await (await collateralManager.setCollateralRatio(mockUSDCAddress, stablecoinRatio)).wait();
    await (await collateralManager.setCollateralRatio(mockUSDTAddress, stablecoinRatio)).wait();
    console.log("✓ Collateral ratios set (1:1 for stablecoins)");

    // Mint some mock tokens to deployer for testing
    console.log("\nMinting mock tokens for testing...");
    const mintAmount = ethers.parseUnits("1000000", 6); // 1M tokens with 6 decimals
    await (await mockUSDC.mint(deployer.address, mintAmount)).wait();
    await (await mockUSDT.mint(deployer.address, mintAmount)).wait();
    console.log("✓ Minted 1M USDC and 1M USDT to deployer");

    console.log("\n=== Mock Token Addresses ===");
    console.log("Mock USDC:", mockUSDCAddress);
    console.log("Mock USDT:", mockUSDTAddress);
  }

  // Verify deployment
  console.log("\n=== Verifying Deployment ===");
  
  // Check KHRT token details
  const name = await khrtToken.name();
  const symbol = await khrtToken.symbol();
  const decimals = await khrtToken.decimals();
  const maxSupply = await khrtToken.MAX_SUPPLY();
  
  console.log("KHRT Token Details:");
  console.log("- Name:", name);
  console.log("- Symbol:", symbol);
  console.log("- Decimals:", decimals);
  console.log("- Max Supply:", ethers.formatEther(maxSupply));

  // Check collateral manager details
  const isAuthorized = await khrtToken.isCollateralMinter(collateralManagerAddress);
  const minRatio = await collateralManager.getMinimumCollateralRatio();
  
  console.log("\nCollateral Manager Details:");
  console.log("- Is Authorized Minter:", isAuthorized);
  console.log("- Minimum Collateral Ratio:", minRatio.toString(), "basis points");

  console.log("\n=== Deployment Summary ===");
  console.log("KHRT Stablecoin:", khrtAddress);
  console.log("Collateral Manager:", collateralManagerAddress);
  console.log("Deployer:", deployer.address);
  console.log("Network:", network.name, `(Chain ID: ${network.chainId})`);

  // Save deployment addresses to a file
  const deploymentInfo = {
    network: network.name,
    chainId: network.chainId.toString(),
    timestamp: new Date().toISOString(),
    contracts: {
      KHRTStablecoin: khrtAddress,
      KHRTCollateralManager: collateralManagerAddress,
    },
    deployer: deployer.address,
  };

  console.log("\n=== Deployment Info ===");
  console.log(JSON.stringify(deploymentInfo, null, 2));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });