import { ethers } from "hardhat";

// Replace these with your actual deployed contract addresses
const DEPLOYED_ADDRESSES = {
  roleController: "0x59643E9a45000227747b8D7cCC0f23Eef2801AC7",
  governance: "0xbe7e8b2a486dFfA489A1e9740d5bF273C3F9F671",
  stablecoin: "0x3a7E7fDA5cB9967eA57f4D30A8b087a1Be3943c3"
};

async function main() {
  console.log("🔍 KHRT Deployment Verification\n");

  try {
    // Get contract instances
    console.log("🔗 Connecting to contracts...");
    const roleController = await ethers.getContractAt("RoleController", DEPLOYED_ADDRESSES.roleController);
    const governance = await ethers.getContractAt("CouncilGovernance", DEPLOYED_ADDRESSES.governance);
    const stablecoin = await ethers.getContractAt("KHRTStableCoin", DEPLOYED_ADDRESSES.stablecoin);
    console.log("✅ Connected to all contracts\n");

    // Basic contract info
    console.log("📋 CONTRACT INFORMATION:");
    console.log("Role Controller:", DEPLOYED_ADDRESSES.roleController);
    console.log("Council Governance:", DEPLOYED_ADDRESSES.governance);
    console.log("Stablecoin:", DEPLOYED_ADDRESSES.stablecoin);
    console.log("");

    // Role Controller Status
    console.log("🏛️  ROLE CONTROLLER STATUS:");
    const governanceStatus = await roleController.getGovernanceStatus();
    const setupInfo = await roleController.getSetupInfo();
    const emergencyMode = await roleController.isEmergencyMode();
    const emergencyAdmin = await roleController.getEmergencyAdmin();
    
    console.log("  Governance Active:", governanceStatus[0]);
    console.log("  Governance Contract:", governanceStatus[1]);
    console.log("  Setup Phase Active:", setupInfo[0]);
    console.log("  Setup Deadline:", new Date(Number(setupInfo[1]) * 1000).toLocaleString());
    console.log("  Emergency Mode:", emergencyMode);
    console.log("  Emergency Admin:", emergencyAdmin);
    
    // Check authorizations
    const isStablecoinAuth = await roleController.isAuthorizedContract(DEPLOYED_ADDRESSES.stablecoin);
    const isGovernanceAuth = await roleController.isAuthorizedContract(DEPLOYED_ADDRESSES.governance);
    console.log("  Stablecoin Authorized:", isStablecoinAuth);
    console.log("  Governance Authorized:", isGovernanceAuth);
    console.log("");

    // Council Governance Status  
    console.log("🗳️  GOVERNANCE STATUS:");
    const councilList = await governance.getCouncilList();
    const totalVotingPower = await governance.totalVotingPower();
    const activeMembers = await governance.activeMembers();
    const nextProposalId = await governance.nextProposalId();
    const votingPeriod = await governance.votingPeriod();
    const timeLock = await governance.timeLock();
    const quorumPercent = await governance.quorumPercent();
    const isPaused = await governance.paused();
    
    console.log("  Council Members:", councilList.length);
    console.log("  Active Members:", activeMembers.toString());
    console.log("  Total Voting Power:", totalVotingPower.toString());
    console.log("  Next Proposal ID:", nextProposalId.toString());
    console.log("  Voting Period:", Number(votingPeriod) / (24 * 60 * 60), "days");
    console.log("  Time Lock:", Number(timeLock) / (24 * 60 * 60), "days");
    console.log("  Quorum Required:", quorumPercent.toString() + "%");
    console.log("  Governance Paused:", isPaused);
    
    // List council members
    console.log("  Council Members:");
    for (let i = 0; i < councilList.length; i++) {
      const memberInfo = await governance.getCouncilInfo(councilList[i]);
      console.log(`    ${i + 1}. ${councilList[i]}`);
      console.log(`       Power: ${memberInfo[1]}, Joined: ${new Date(Number(memberInfo[2]) * 1000).toLocaleDateString()}`);
    }
    
    // Integration status
    const integrationStatus = await governance.getIntegrationStatus();
    console.log("  Integration Status:");
    console.log("    Role Controller Set:", integrationStatus[1]);
    console.log("    Governance Initialized:", integrationStatus[2]);
    console.log("    Has Governance Role:", integrationStatus[3]);
    console.log("");

    // Stablecoin Status
    console.log("💰 STABLECOIN STATUS:");
    const tokenName = await stablecoin.name();
    const tokenSymbol = await stablecoin.symbol();
    const totalSupply = await stablecoin.totalSupply();
    const maxSupply = await stablecoin.maxSupply();
    const tokenDecimals = await stablecoin.decimals();
    const stablecoinPaused = await stablecoin.paused();
    const localEmergency = await stablecoin.isEmergencyMode();
    const stablecoinEmergencyAdmin = await stablecoin.getEmergencyAdmin();
    
    console.log("  Name:", tokenName);
    console.log("  Symbol:", tokenSymbol);
    console.log("  Decimals:", tokenDecimals);
    console.log("  Total Supply:", ethers.formatEther(totalSupply));
    console.log("  Max Supply:", ethers.formatEther(maxSupply));
    console.log("  Utilization:", ((Number(totalSupply) / Number(maxSupply)) * 100).toFixed(2) + "%");
    console.log("  Contract Paused:", stablecoinPaused);
    console.log("  Emergency Mode:", localEmergency);
    console.log("  Emergency Admin:", stablecoinEmergencyAdmin);
    
    // Check emergency status in detail
    const emergencyStatus = await stablecoin.getEmergencyStatus();
    console.log("  Emergency Details:");
    console.log("    Local Emergency:", emergencyStatus[0]);
    console.log("    Contract Paused:", emergencyStatus[1]);
    console.log("    Role Controller Emergency:", emergencyStatus[2]);
    console.log("    Any Emergency Active:", emergencyStatus[3]);
    console.log("");

    // Role Status
    console.log("👤 ROLE ASSIGNMENTS:");
    const roles = [
      { name: "MINTER_ROLE", value: await roleController.MINTER_ROLE() },
      { name: "BURNER_ROLE", value: await roleController.BURNER_ROLE() },
      { name: "BLACKLIST_ROLE", value: await roleController.BLACKLIST_ROLE() },
      { name: "GOVERNANCE_ROLE", value: await roleController.GOVERNANCE_ROLE() }
    ];
    
    for (const role of roles) {
      console.log(`  ${role.name}:`);
      
      // Check common addresses for this role
      const testAddresses = [
        ...councilList,
        DEPLOYED_ADDRESSES.governance,
        emergencyAdmin,
        stablecoinEmergencyAdmin
      ];
      
      let hasRole = false;
      for (const addr of testAddresses) {
        try {
          if (await roleController.hasRole(role.value, addr)) {
            console.log(`    ✅ ${addr}`);
            hasRole = true;
          }
        } catch (error) {
          // Ignore authorization errors for this check
        }
      }
      
      if (!hasRole) {
        console.log(`    ❌ No accounts found with this role`);
      }
    }
    console.log("");

    // Active Proposals
    console.log("📝 ACTIVE PROPOSALS:");
    if (Number(nextProposalId) === 0) {
      console.log("  No proposals created yet");
    } else {
      let activeCount = 0;
      for (let i = 0; i < Number(nextProposalId); i++) {
        try {
          const proposalState = await governance.getProposalState(i);
          const state = Number(proposalState[2]);
          
          if (state === 1) { // ACTIVE
            activeCount++;
            const proposalAction = await governance.getProposalAction(i);
            console.log(`  Proposal ${i}: ${proposalAction[3]}`);
            console.log(`    Deadline: ${new Date(Number(proposalState[3]) * 1000).toLocaleString()}`);
            console.log(`    Votes: ${proposalState[5]} for, ${proposalState[6]} against`);
          }
        } catch (error) {
          // Skip if can't read proposal
        }
      }
      
      if (activeCount === 0) {
        console.log("  No active proposals");
      }
    }
    console.log("");

    // Overall Health Check
    console.log("🏥 SYSTEM HEALTH CHECK:");
    
    const healthChecks = [
      { name: "Role Controller has governance", check: governanceStatus[0] },
      { name: "Governance points to correct contract", check: governanceStatus[1].toLowerCase() === DEPLOYED_ADDRESSES.governance.toLowerCase() },
      { name: "Setup phase completed", check: !setupInfo[0] },
      { name: "Governance has governance role", check: integrationStatus[3] },
      { name: "Stablecoin authorized", check: isStablecoinAuth },
      { name: "Governance authorized", check: isGovernanceAuth },
      { name: "Council properly configured", check: councilList.length >= 3 && totalVotingPower > 0 },
      { name: "No emergency mode active", check: !emergencyMode && !localEmergency }
    ];
    
    let healthyCount = 0;
    for (const check of healthChecks) {
      const status = check.check ? "✅" : "❌";
      console.log(`  ${status} ${check.name}`);
      if (check.check) healthyCount++;
    }
    
    const healthPercentage = Math.round((healthyCount / healthChecks.length) * 100);
    console.log("");
    console.log(`🎯 OVERALL HEALTH: ${healthPercentage}% (${healthyCount}/${healthChecks.length} checks passed)`);
    
    if (healthPercentage === 100) {
      console.log("🎉 System is fully operational!");
    } else if (healthPercentage >= 75) {
      console.log("⚠️  System mostly operational, minor issues detected");
    } else {
      console.log("🚨 System has significant issues, manual intervention needed");
    }
    console.log("");

    // Recommendations
    if (healthPercentage < 100) {
      console.log("🛠️  RECOMMENDATIONS:");
      
      if (!governanceStatus[0] || governanceStatus[1].toLowerCase() !== DEPLOYED_ADDRESSES.governance.toLowerCase()) {
        console.log("- Run the recovery script to fix governance setup");
      }
      
      if (!isStablecoinAuth || !isGovernanceAuth) {
        console.log("- Complete contract authorization setup");
      }
      
      if (setupInfo[0]) {
        console.log("- End the setup phase to secure the system");
      }
      
      if (emergencyMode || localEmergency) {
        console.log("- Investigate and resolve emergency mode activation");
      }
      
      console.log("- Verify all steps completed correctly");
      console.log("- Consider running recovery script if needed");
    } else {
      console.log("💡 SUGGESTIONS:");
      console.log("- Create proposals to grant operational roles (MINTER_ROLE, etc.)");
      console.log("- Test governance voting process");
      console.log("- Set up monitoring for important events");
      console.log("- Document emergency procedures");
    }

  } catch (error) {
    console.error("❌ Verification failed:", error);
    throw error;
  }
}

// Execute verification
if (require.main === module) {
  main()
    .then(() => {
      console.log("\n✅ Verification completed!");
      process.exit(0);
    })
    .catch((error) => {
      console.error("\n❌ Verification failed:", error);
      process.exit(1);
    });
}

export default main;