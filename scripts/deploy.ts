import { ethers } from "hardhat";
import { upgrades } from "hardhat";
import fs from "fs";
import path from "path";

async function main() {
  console.log("Starting deployment process...");
  
  // Get the deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  try {
    // Deploy KHRT Stablecoin (Upgradeable)
    console.log("\n1. Deploying KHRT Stablecoin...");
    const KHRTStablecoin = await ethers.getContractFactory("KHRTStablecoinV1");
    
    const khrtProxy = await upgrades.deployProxy(
      KHRTStablecoin,
      ["KHRT Stable (official)", "KHRT", deployer.address],
      { 
        initializer: "initialize",
        kind: "uups",
        timeout: 0 // No timeout for deployment
      }
    );
    
    await khrtProxy.waitForDeployment();
    const khrtAddress = await khrtProxy.getAddress();
    console.log("KHRT Stablecoin deployed to:", khrtAddress);
    
    // Get implementation address
    const khrtImplementationAddress = await upgrades.erc1967.getImplementationAddress(khrtAddress);
    console.log("KHRT Implementation address:", khrtImplementationAddress);

    // Verify the proxy is initialized correctly
    console.log("\nVerifying proxy initialization...");
    const name = await khrtProxy.name();
    const symbol = await khrtProxy.symbol();
    const owner = await khrtProxy.owner();
    console.log("Token name:", name);
    console.log("Token symbol:", symbol);
    console.log("Owner:", owner);

    // Deploy CollateralMinter
    console.log("\n2. Deploying CollateralMinter...");
    const CollateralMinter = await ethers.getContractFactory("CollateralMinter");
    const collateralMinter = await CollateralMinter.deploy(khrtAddress);
    await collateralMinter.waitForDeployment();
    const collateralMinterAddress = await collateralMinter.getAddress();
    console.log("CollateralMinter deployed to:", collateralMinterAddress);

    // Authorize CollateralMinter as a minter
    console.log("\n3. Authorizing CollateralMinter as KHRT minter...");
    
    // First check if the function exists and we have the right permissions
    try {
      // Check if we're the owner
      const currentOwner = await khrtProxy.owner();
      console.log("Current owner:", currentOwner);
      console.log("Deployer address:", deployer.address);
      
      if (currentOwner.toLowerCase() !== deployer.address.toLowerCase()) {
        console.error("ERROR: Deployer is not the owner of the KHRT contract!");
        console.error("Cannot authorize minter without owner permissions.");
        process.exit(1);
      }

      // Try to authorize the minter with proper gas settings
      const authorizeTx = await khrtProxy.setAuthorizedMinter(
        collateralMinterAddress, 
        true,
        {
          gasLimit: 300000 // Set explicit gas limit
        }
      );
      
      console.log("Authorization transaction sent:", authorizeTx.hash);
      const receipt = await authorizeTx.wait();
      console.log("Authorization transaction confirmed in block:", receipt.blockNumber);
      
      // Verify authorization
      const isAuthorized = await khrtProxy.isAuthorizedMinter(collateralMinterAddress);
      console.log("Authorization verified:", isAuthorized);
      
      if (!isAuthorized) {
        console.error("ERROR: CollateralMinter was not properly authorized!");
        process.exit(1);
      }

      // Save deployment info
      const deploymentInfo = {
        network: (await ethers.provider.getNetwork()).name,
        chainId: (await ethers.provider.getNetwork()).chainId.toString(),
        deployer: deployer.address,
        timestamp: new Date().toISOString(),
        contracts: {
          KHRT: {
            proxy: khrtAddress,
            implementation: khrtImplementationAddress,
            name: "KHRT Stablecoin",
            symbol: "KHRT",
            decimals: 6,
            owner: owner,
            maxSupply: "40000000000000000" // 40B with 6 decimals
          },
          CollateralMinter: {
            address: collateralMinterAddress,
            khrtToken: khrtAddress,
            minCollateralRatio: "10000", // 100%
            authorized: isAuthorized
          }
        }
      };

      // Create deployments directory if it doesn't exist
      const deploymentsDir = path.join(__dirname, "../deployments");
      if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
      }

      // Save deployment info to file
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const deploymentFile = path.join(deploymentsDir, `deployment-${chainId}.json`);
      fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
      console.log("\nDeployment info saved to:", deploymentFile);

      // Display summary
      console.log("\n========== DEPLOYMENT SUMMARY ==========");
      console.log("KHRT Proxy Address:", khrtAddress);
      console.log("KHRT Implementation:", khrtImplementationAddress);
      console.log("KHRT Owner:", owner);
      console.log("CollateralMinter Address:", collateralMinterAddress);
      console.log("CollateralMinter Authorized:", isAuthorized);
      console.log("========================================\n");

      // Display next steps
      console.log("Next steps:");
      console.log("1. Whitelist collateral tokens using the whitelist script");
      console.log("2. Set collateral ratios for each whitelisted token");
      console.log("3. Verify contracts on block explorer (if applicable)");
      
    } catch (authError: any) {
      console.error("\nERROR during minter authorization:");
      console.error("Error message:", authError.message);
      
      // Try to decode the error
      if (authError.data) {
        try {
          const decodedError = khrtProxy.interface.parseError(authError.data);
          console.error("Decoded error:", decodedError);
        } catch (e) {
          console.error("Could not decode error data");
        }
      }
      
      // Still save deployment info even if authorization failed
      const deploymentInfo = {
        network: (await ethers.provider.getNetwork()).name,
        chainId: (await ethers.provider.getNetwork()).chainId.toString(),
        deployer: deployer.address,
        timestamp: new Date().toISOString(),
        error: "Minter authorization failed",
        contracts: {
          KHRT: {
            proxy: khrtAddress,
            implementation: khrtImplementationAddress,
            name: "KHRT Stablecoin",
            symbol: "KHRT",
            decimals: 6
          },
          CollateralMinter: {
            address: collateralMinterAddress,
            khrtToken: khrtAddress,
            authorized: false,
            error: "Authorization failed"
          }
        }
      };

      const deploymentsDir = path.join(__dirname, "../deployments");
      if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
      }

      const chainId = (await ethers.provider.getNetwork()).chainId;
      const deploymentFile = path.join(deploymentsDir, `deployment-${chainId}-failed.json`);
      fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
      
      console.log("\nPartial deployment info saved to:", deploymentFile);
      console.log("\nIMPORTANT: Contracts were deployed but minter authorization failed!");
      console.log("You may need to manually authorize the minter using the owner account.");
      
      process.exit(1);
    }
    
  } catch (error: any) {
    console.error("\nDeployment failed with error:");
    console.error(error);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });