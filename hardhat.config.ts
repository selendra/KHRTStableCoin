import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "hardhat-contract-sizer";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 20000,
      },
      viaIR: true,
    },
  },
  networks: {
    hardhat: {
      accounts: {
        count: 20, // More accounts for testing
        accountsBalance: "10000000000000000000000", // 10k ETH each
      },
      gas: 30000000,
      blockGasLimit: 30000000,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
    },
     sepolia: {
      url: process.env.ETHEREUM_SEPOLIA_URL || "https://sepolia.infura.io/v3/24a3e0a1e6474ff183c2e832a7e1a6a0",
      accounts: 
        process.env.TESTNET_PRIVATE_KEY ? 
        [process.env.TESTNET_PRIVATE_KEY] : 
          ["155ff6bd829e2258c941d3f72aa45d79c90e68afafe53b7da4d8eaa2d6aced3f", 
          "7423e7629724b84c5bd6aba950070516d93ec0a3f625434d58018a77ac64a6a8",
          "a0a31f581433408481286a43a67d9dbb5c19a1ce4b98e0c10bff7d1b3947399e",
          "40c306866bfa21e0d5f56bd7036bc72db2f27e0a3596053e103e5274879bbcea",
          "dd5759e7d274c67969da1cb23df8abd3b2e7dcbea8d3e6805e8688bba77c765e"
        ],
      chainId: 11155111,
      gasPrice: "auto",
      gas: "auto"
    },
     selendra: {
      url: process.env.SELENDRA_RPC || "https://rpcx.selendra.org",
      accounts: 
        process.env.SELENDRA_PRIVATE_KEY ? [process.env.SELENDRA_PRIVATE_KEY] : [],
      chainId: 1961,
      gasPrice: "auto",
      gas: "auto"
    },
  },
  mocha: {
    timeout: 60000, // 60 seconds for complex tests
  },
};

export default config;