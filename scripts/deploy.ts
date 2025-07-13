import { ethers } from "hardhat";
import { Contract } from "ethers";

async function main() {
  const [deployer] = await ethers.getSigners();
  
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // Get current gas price and add buffer
  const baseGasPrice = await ethers.provider.getFeeData();
  const gasPrice = baseGasPrice.gasPrice ? baseGasPrice.gasPrice * 120n / 100n : undefined; // 20% buffer
  
  console.log("Using gas price:", gasPrice ? ethers.formatUnits(gasPrice, "gwei") + " gwei" : "auto");

  // Deploy KHRT Stablecoin first
  console.log("\n=== Deploying KHRT Stablecoin (6 decimals) ===");
  const KHRTStablecoin = await ethers.getContractFactory("KHRTStablecoin");
  const khrtToken = await KHRTStablecoin.deploy("KHRT Testing","TKHR", {
    gasPrice: gasPrice
  });
  await khrtToken.waitForDeployment();
  const khrtAddress = await khrtToken.getAddress();
  
  console.log("KHRT Stablecoin deployed to:", khrtAddress);

  // Deploy Collateral Manager
  console.log("\n=== Deploying Collateral Manager ===");
  const KHRTCollateralManager = await ethers.getContractFactory("KHRTCollateralManager");
  const collateralManager = await KHRTCollateralManager.deploy(khrtAddress, {
    gasPrice: gasPrice
  });
  await collateralManager.waitForDeployment();
  const collateralManagerAddress = await collateralManager.getAddress();
  
  console.log("Collateral Manager deployed to:", collateralManagerAddress);

  // Setup initial configuration with proper gas management
  console.log("\n=== Setting up initial configuration ===");

  // Authorize collateral manager as a collateral minter
  console.log("Authorizing Collateral Manager as collateral minter...");
  const authorizeTx = await khrtToken.setCollateralMinter(collateralManagerAddress, true, {
    gasPrice: gasPrice
  });
  await authorizeTx.wait();
  console.log("✓ Collateral Manager authorized");

  // Add delay between transactions to prevent nonce conflicts
  await new Promise(resolve => setTimeout(resolve, 2000));

  // Deploy mock ERC20 tokens for testing/demo (only on testnets)
  const network = await ethers.provider.getNetwork();
  const isTestnet = network.chainId === 11155111n || network.chainId === 31337n; // Sepolia or Hardhat

  if (isTestnet) {
    console.log("\n=== Deploying Mock Tokens for Testing ===");
    
    // Deploy Mock USDC
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, {
      gasPrice: gasPrice
    });
    await mockUSDC.waitForDeployment();
    const mockUSDCAddress = await mockUSDC.getAddress();
    console.log("Mock USDC deployed to:", mockUSDCAddress);

    await new Promise(resolve => setTimeout(resolve, 2000));

    // Deploy Mock STAR with 18 decimals
    const mockSTAR = await MockERC20.deploy("Mock STAR", "STAR", 18, {
      gasPrice: gasPrice
    });
    await mockSTAR.waitForDeployment();
    const mockSTARAddress = await mockSTAR.getAddress();
    console.log("Mock STAR deployed to:", mockSTARAddress);

    await new Promise(resolve => setTimeout(resolve, 2000));

    // Whitelist mock tokens in KHRT
    console.log("\nWhitelisting mock tokens...");
    await (await khrtToken.setTokenWhitelist(mockUSDCAddress, true, {
      gasPrice: gasPrice
    })).wait();
    
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    await (await khrtToken.setTokenWhitelist(mockSTARAddress, true, {
      gasPrice: gasPrice
    })).wait();
    console.log("✓ Mock tokens whitelisted");

    await new Promise(resolve => setTimeout(resolve, 2000));

    // Set collateral ratios
    console.log("\nSetting collateral ratios...");
    
    // For USDC (6 decimals) to KHRT (6 decimals): 1 USDC = 1 KHRT
    // Both have same decimals, so ratio is simply 1
    const usdcRatio = 1n;
    
    // For STAR (18 decimals) to KHRT (6 decimals): 1 STAR = 40 KHRT
    // STAR has 12 more decimals than KHRT (18-6=12)
    // To get 1 STAR (1e18) = 40 KHRT (40e6), we need: 40e6 / 1e18 = 40 / 1e12
    // Since we can't use decimals in Solidity, we express this as: amount * ratio / 1e12 = khrt_amount
    // So: 1e18 * ratio / 1e12 = 40e6 => ratio = 40e6 * 1e12 / 1e18 = 40
    const starRatio = 40n;
    
    await (await collateralManager.setCollateralRatio(mockUSDCAddress, usdcRatio, {
      gasPrice: gasPrice
    })).wait();
    console.log("✓ USDC ratio set (1:1)");
    
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    await (await collateralManager.setCollateralRatio(mockSTARAddress, starRatio, {
      gasPrice: gasPrice
    })).wait();
    console.log("✓ STAR ratio set (1:40 - 100 STAR = 4000 KHRT)");

    await new Promise(resolve => setTimeout(resolve, 2000));

    // Mint some mock tokens to deployer for testing
    console.log("\nMinting mock tokens for testing...");
    
    // Mint USDC (6 decimals)
    const usdcMintAmount = ethers.parseUnits("1000000", 6); // 1M USDC
    await (await mockUSDC.mint(deployer.address, usdcMintAmount, {
      gasPrice: gasPrice
    })).wait();
    
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    // Mint STAR (18 decimals)
    const starMintAmount = ethers.parseUnits("1000000", 18); // 1M STAR
    await (await mockSTAR.mint(deployer.address, starMintAmount, {
      gasPrice: gasPrice
    })).wait();
    console.log("✓ Minted 1M USDC and 1M STAR to deployer");

    // Verify the ratios are set correctly
    console.log("\n=== Verifying Collateral Ratios ===");
    const usdcRatioSet = await collateralManager.getCollateralRatio(mockUSDCAddress);
    const starRatioSet = await collateralManager.getCollateralRatio(mockSTARAddress);
    
    console.log("USDC ratio:", usdcRatioSet.toString());
    console.log("STAR ratio:", starRatioSet.toString());
    
    // Calculate expected minting amounts for demonstration
    const oneUSDC = ethers.parseUnits("1", 6);
    const oneSTAR = ethers.parseUnits("1", 18);
    const hundredSTAR = ethers.parseUnits("100", 18);
    
    const khrtFromOneUSDC = await collateralManager.calculateMintAmount(mockUSDCAddress, oneUSDC);
    const khrtFromOneSTAR = await collateralManager.calculateMintAmount(mockSTARAddress, oneSTAR);
    const khrtFromHundredSTAR = await collateralManager.calculateMintAmount(mockSTARAddress, hundredSTAR);
    
    console.log("\n=== Minting Calculations ===");
    console.log("1 USDC would mint:", ethers.formatUnits(khrtFromOneUSDC, 6), "KHRT");
    console.log("1 STAR would mint:", ethers.formatUnits(khrtFromOneSTAR, 6), "KHRT");
    console.log("100 STAR would mint:", ethers.formatUnits(khrtFromHundredSTAR, 6), "KHRT");

    console.log("\n=== Mock Token Addresses ===");
    console.log("Mock USDC:", mockUSDCAddress);
    console.log("Mock STAR:", mockSTARAddress);
  }

  // Verify deployment
  console.log("\n=== Verifying Deployment ===");
  
  // Check KHRT token details
  const name = await khrtToken.name();
  const symbol = await khrtToken.symbol();
  const decimals = await khrtToken.decimals();
  const maxSupply = await khrtToken.getMaxSupply();
  
  console.log("KHRT Token Details:");
  console.log("- Name:", name);
  console.log("- Symbol:", symbol);
  console.log("- Decimals:", decimals);
  console.log("- Max Supply:", ethers.formatUnits(maxSupply, 6));

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
    khrtDecimals: 6,
    collateralRatios: {
      USDC: "1:1 (1 USDC = 1 KHRT)",
      STAR: "1:40 (1 STAR = 40 KHRT, 100 STAR = 4000 KHRT)"
    }
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