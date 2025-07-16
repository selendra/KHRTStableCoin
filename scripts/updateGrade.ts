// Deployment script for Hardhat
// deploy/01_deploy_khrt.js

const { ethers, upgrades } = require("hardhat");

async function main() {
    console.log("Deploying KHRT Stablecoin...");

    // Get the contract factory
    const KHRTStablecoinV1 = await ethers.getContractFactory("KHRTStablecoinV1");
    
    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with account:", deployer.address);

    // Deploy the upgradeable contract
    const khrt = await upgrades.deployProxy(
        KHRTStablecoinV1,
        ["Khmer Riel Token", "KHRT", deployer.address],
        { 
            initializer: "initialize",
            kind: "uups" // Using UUPS proxy pattern
        }
    );

    await khrt.waitForDeployment();
    
    const proxyAddress = await khrt.getAddress();
    console.log("KHRT Proxy deployed to:", proxyAddress);

    // Get implementation address
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("KHRT Implementation deployed to:", implementationAddress);

    // Verify the deployment
    console.log("\nVerifying deployment...");
    console.log("Token name:", await khrt.name());
    console.log("Token symbol:", await khrt.symbol());
    console.log("Token decimals:", await khrt.decimals());
    console.log("Max supply:", await khrt.getMaxSupply());
    console.log("Owner:", await khrt.owner());
    console.log("Is deployer authorized minter?", await khrt.isAuthorizedMinter(deployer.address));

    // Optional: Verify on Etherscan (if on a public network)
    if (network.name !== "hardhat" && network.name !== "localhost") {
        console.log("\nWaiting for block confirmations...");
        await khrt.deploymentTransaction().wait(5);
        
        console.log("Verifying contract on Etherscan...");
        await run("verify:verify", {
            address: implementationAddress,
            constructorArguments: [],
        });
    }

    console.log("\nDeployment complete!");
    
    return {
        proxy: proxyAddress,
        implementation: implementationAddress
    };
}

// Upgrade script example
async function upgradeContract(proxyAddress) {
    console.log("Upgrading KHRT Stablecoin...");
    
    // Get the new contract factory (e.g., KHRTStablecoinV2)
    const KHRTStablecoinV2 = await ethers.getContractFactory("KHRTStablecoinV2");
    
    // Upgrade the proxy to point to the new implementation
    const upgraded = await upgrades.upgradeProxy(proxyAddress, KHRTStablecoinV2);
    
    console.log("KHRT upgraded successfully!");
    console.log("New implementation:", await upgrades.erc1967.getImplementationAddress(proxyAddress));
    
    return upgraded;
}

// Execute deployment
if (require.main === module) {
    main()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}

module.exports = { main, upgradeContract };