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
  },
  mocha: {
    timeout: 60000, // 60 seconds for complex tests
  },
};

export default config;