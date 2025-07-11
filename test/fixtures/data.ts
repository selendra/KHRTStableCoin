import { ethers } from "hardhat";

export const TEST_CONSTANTS = {
  MAX_SUPPLY: ethers.parseEther("1000000"),
  INITIAL_MINT: ethers.parseEther("100000"),
  CANDIDATE_FEE: ethers.parseEther("1000"),
  COUNCIL_TERM: 365 * 24 * 60 * 60, // 1 year
  ELECTION_PERIOD: 7 * 24 * 60 * 60, // 7 days
  VOTING_PERIOD: 3 * 24 * 60 * 60, // 3 days
  EXECUTION_DELAY: 2 * 24 * 60 * 60, // 2 days
};

export const ROLE_NAMES = {
  MINTER: "MINTER_ROLE",
  BURNER: "BURNER_ROLE", 
  BLACKLIST: "BLACKLIST_ROLE",
  GOVERNANCE: "GOVERNANCE_ROLE",
};

export const TEST_ACCOUNTS = {
  DEPLOYER: 0,
  EMERGENCY_ADMIN: 1,
  COUNCIL_MEMBER_1: 2,
  COUNCIL_MEMBER_2: 3,
  COUNCIL_MEMBER_3: 4,
  USER_1: 5,
  USER_2: 6,
  MINTER: 7,
  BURNER: 8,
  ATTACKER: 9,
};