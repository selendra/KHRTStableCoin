const { ethers } = require("hardhat");

async function main() {
    console.log("Starting ERC20 deployment...\n");

    // Get the deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deploying with account:", deployer.address);
    console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // Configuration for different  tokens
    const Tokens = [
        {
            name: "STAR TOKEN",
            symbol: "STAR", 
            decimals: 18,
            initialSupply: ethers.parseUnits("0", 18)
        },
    ];

    // Get the contract factory
    const ERC20 = await ethers.getContractFactory("MockERC20");

    const deployedTokens = [];

    // Deploy each  token
    for (const tokenConfig of Tokens) {
        console.log(`Deploying ${tokenConfig.name} (${tokenConfig.symbol})...`);
        
        try {
            // Deploy the contract
            const Token = await ERC20.deploy(
                tokenConfig.name,
                tokenConfig.symbol,
                tokenConfig.decimals,
                deployer.address // initialOwner
            );

            // Wait for deployment confirmation
            await Token.waitForDeployment();
            const tokenAddress = await Token.getAddress();
            
            console.log(`✅ ${tokenConfig.symbol} deployed to:`, tokenAddress);

            // Mint initial supply to deployer
            if (tokenConfig.initialSupply > 0) {
                console.log(`Minting initial supply of ${ethers.formatUnits(tokenConfig.initialSupply, tokenConfig.decimals)} ${tokenConfig.symbol}...`);
                const mintTx = await Token.mint(deployer.address, tokenConfig.initialSupply);
                await mintTx.wait();
                console.log(`✅ Initial supply minted`);
            }

            // Verify contract deployment
            const deployedName = await Token.name();
            const deployedSymbol = await Token.symbol();
            const deployedDecimals = await Token.decimals();
            const deployedOwner = await Token.owner();
            const totalSupply = await Token.totalSupply();

            console.log(`Contract verification:`);
            console.log(`  Name: ${deployedName}`);
            console.log(`  Symbol: ${deployedSymbol}`);
            console.log(`  Decimals: ${deployedDecimals}`);
            console.log(`  Owner: ${deployedOwner}`);
            console.log(`  Total Supply: ${ethers.formatUnits(totalSupply, deployedDecimals)}`);

            deployedTokens.push({
                name: tokenConfig.name,
                symbol: tokenConfig.symbol,
                address: tokenAddress,
                decimals: deployedDecimals,
                totalSupply: ethers.formatUnits(totalSupply, deployedDecimals)
            });

            console.log("─".repeat(60));

        } catch (error: any) {
            console.error(`❌ Failed to deploy ${tokenConfig.symbol}:`, error.message);
            console.log("─".repeat(60));
        }
    }

    // Summary
    console.log("\n🎉 DEPLOYMENT SUMMARY");
    console.log("=".repeat(60));
    
    if (deployedTokens.length > 0) {
        deployedTokens.forEach((token, index) => {
            console.log(`${index + 1}. ${token.name} (${token.symbol})`);
            console.log(`   Address: ${token.address}`);
            console.log(`   Decimals: ${token.decimals}`);
            console.log(`   Total Supply: ${token.totalSupply} ${token.symbol}`);
            console.log("");
        });

        // Generate environment variables for easy integration
        console.log("Environment Variables for .env file:");
        console.log("─".repeat(40));
        deployedTokens.forEach(token => {
            const envVar = `${token.symbol.toUpperCase()}_ADDRESS`;
            console.log(`${envVar}=${token.address}`);
        });

        // Generate contract addresses object for scripts
        console.log("\nContract addresses object:");
        console.log("─".repeat(40));
        console.log("const _TOKENS = {");
        deployedTokens.forEach((token, index) => {
            const comma = index < deployedTokens.length - 1 ? "," : "";
            console.log(`  ${token.symbol}: "${token.address}"${comma}`);
        });
        console.log("};");

    } else {
        console.log("❌ No tokens were successfully deployed");
    }
}

// Error handling
main()
    .then(() => {
        console.log("\n✅ Deployment script completed successfully");
        process.exit(0);
    })
    .catch((error) => {
        console.error("\n❌ Deployment script failed:");
        console.error(error);
        process.exit(1);
    });