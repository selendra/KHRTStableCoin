const { ethers } = require("hardhat");

async function main() {
    console.log("Clearing stuck nonce...\n");

    // Get the deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Account:", deployer.address);
    
    // Get current nonce
    const currentNonce = await ethers.provider.getTransactionCount(deployer.address, "pending");
    console.log("Current nonce:", currentNonce);
    
    // Send a transaction to self with high gas price to clear the stuck nonce
    const tx = await deployer.sendTransaction({
        to: deployer.address,
        value: 0,
        nonce: currentNonce,
        gasLimit: 21000,
        gasPrice: ethers.parseUnits("100", "gwei") // Very high gas price
    });
    
    console.log("Clearing transaction sent:", tx.hash);
    console.log("Waiting for confirmation...");
    
    await tx.wait();
    console.log("✅ Nonce cleared successfully");
    
    // Check new nonce
    const newNonce = await ethers.provider.getTransactionCount(deployer.address, "pending");
    console.log("New nonce:", newNonce);
}

main()
    .then(() => process.exit(0))
    .catch((error: any) => {
        console.error(error);
        process.exit(1);
    });