const { ethers } = require("hardhat");

async function main() {
    console.log("Starting ERC20 deployment...\n");

    // Get the deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deploying with account:", deployer.address);
    console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // We'll get fresh nonce for each deployment attempt

    // Configuration for different tokens
    const Tokens = [
        {
            name: "Cambodian Premier League Token",
            symbol: "CPLSTAR", 
            decimals: 18,
            initialSupply: ethers.parseUnits("0", 18)
        },
    ];

    // Get the contract factory
    const ERC20 = await ethers.getContractFactory("MockERC20");

    const deployedTokens = [];

    // Deploy each token
    for (let i = 0; i < Tokens.length; i++) {
        const tokenConfig = Tokens[i];
        console.log(`Deploying ${tokenConfig.name} (${tokenConfig.symbol})...`);
        
        try {
            // Add retry logic with exponential backoff
            let deploymentSuccessful = false;
            let retryCount = 0;
            const maxRetries = 3;

            while (!deploymentSuccessful && retryCount < maxRetries) {
                try {
                    // Get fresh nonce for each attempt
                    const currentNonce = await ethers.provider.getTransactionCount(deployer.address, "pending");
                    console.log(`Using nonce: ${currentNonce}`);
                    
                    // Use much higher gas price to ensure transaction goes through
                    const gasPrice = retryCount === 0 
                        ? ethers.parseUnits("100", "gwei")
                        : ethers.parseUnits((100 + retryCount * 50).toString(), "gwei"); // Increase gas price on retries
                    
                    console.log(`Using gas price: ${ethers.formatUnits(gasPrice, "gwei")} gwei`);
                    
                    // Deploy the contract with fresh nonce and gas settings
                    const Token = await ERC20.deploy(
                        tokenConfig.name,
                        tokenConfig.symbol,
                        tokenConfig.decimals,
                        deployer.address, // initialOwner
                        {
                            nonce: currentNonce,
                            gasLimit: 3000000, // Explicit gas limit
                            gasPrice: gasPrice
                        }
                    );

                    // Wait for deployment confirmation with timeout
                    console.log("Waiting for deployment confirmation...");
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

                    deploymentSuccessful = true;
                    console.log("─".repeat(60));

                } catch (retryError: any) {
                    retryCount++;
                    console.log(`❌ Attempt ${retryCount} failed:`, retryError.message);
                    
                    if (retryCount < maxRetries) {
                        const waitTime = Math.pow(2, retryCount) * 1000; // Exponential backoff
                        console.log(`Retrying in ${waitTime/1000} seconds...`);
                        await new Promise(resolve => setTimeout(resolve, waitTime));
                    }
                }
            }

            if (!deploymentSuccessful) {
                throw new Error(`Failed to deploy after ${maxRetries} attempts`);
            }

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
    .catch((error: any) => {
        console.error("\n❌ Deployment script failed:");
        console.error(error);
        process.exit(1);
    });