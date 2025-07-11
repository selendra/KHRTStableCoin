import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  RoleController,
  CouncilGovernance,
  KHRTStableCoin,
} from "../typechain-types";
import { TEST_CONSTANTS, ROLE_NAMES, TEST_ACCOUNTS } from "./fixtures/data";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("KHRT Integration Tests", function () {
  let accounts: SignerWithAddress[];
  let deployer: SignerWithAddress;
  let emergencyAdmin: SignerWithAddress;
  let councilMembers: SignerWithAddress[];
  let users: SignerWithAddress[];
  let minter: SignerWithAddress;

  let roleController: RoleController;
  let governance: CouncilGovernance;
  let stablecoin: KHRTStableCoin;

  // Test data
  const maxSupply = TEST_CONSTANTS.MAX_SUPPLY;
  const councilPowers = [100, 75, 50]; // Total: 225
  const totalVotingPower = 225;
  const quorumRequired = Math.floor((225 * 60) / 100); // 60% of 225 = 135

  beforeEach(async function () {
    accounts = await ethers.getSigners();
    deployer = accounts[TEST_ACCOUNTS.DEPLOYER];
    emergencyAdmin = accounts[TEST_ACCOUNTS.EMERGENCY_ADMIN];
    councilMembers = [
      accounts[TEST_ACCOUNTS.COUNCIL_MEMBER_1],
      accounts[TEST_ACCOUNTS.COUNCIL_MEMBER_2],
      accounts[TEST_ACCOUNTS.COUNCIL_MEMBER_3],
    ];
    users = [accounts[TEST_ACCOUNTS.USER_1], accounts[TEST_ACCOUNTS.USER_2]];
    minter = accounts[TEST_ACCOUNTS.MINTER];

    // Deploy full system
    const RoleController = await ethers.getContractFactory("RoleController");
    const CouncilGovernance = await ethers.getContractFactory(
      "CouncilGovernance"
    );
    const KHRTStableCoin = await ethers.getContractFactory("KHRTStableCoin");

    roleController = await RoleController.deploy(
      ethers.ZeroAddress,
      emergencyAdmin.address,
      []
    );

    governance = await CouncilGovernance.deploy(
      await roleController.getAddress(),
      councilMembers.map((m) => m.address),
      councilPowers
    );

    stablecoin = await KHRTStableCoin.deploy(
      maxSupply,
      emergencyAdmin.address,
      await roleController.getAddress(),
      "KHRT Stablecoin",
      "KHRT"
    );

    // Complete integration setup
    await roleController.updateGovernanceContract(
      await governance.getAddress()
    );
    await roleController.authorizeContract(await stablecoin.getAddress(), true);
    await roleController.authorizeContract(await governance.getAddress(), true);
    await roleController.endSetupPhase();
  });

  describe("Governance Voting Process", function () {
    it("Should complete full role grant proposal lifecycle", async function () {
      const minterRole = await roleController.MINTER_ROLE();

      // 1. Create proposal
      await expect(
        governance
          .connect(councilMembers[0])
          .proposeRoleChange(
            minterRole,
            minter.address,
            true,
            "Grant minter role for initial token distribution"
          )
      )
        .to.emit(governance, "ProposalCreated")
        .withArgs(0, councilMembers[0].address, 0);

      // 2. Check proposal state
      const [
        proposer,
        proposalType,
        state,
        deadline,
        executeTime,
        forVotes,
        againstVotes,
      ] = await governance.getProposalState(0);

      expect(proposer).to.equal(councilMembers[0].address);
      expect(proposalType).to.equal(0); // ROLE_CHANGE
      expect(state).to.equal(1); // ACTIVE
      expect(forVotes).to.equal(0);
      expect(againstVotes).to.equal(0);

      // 3. Vote - Council member 0 (power 100) votes for
      await expect(governance.connect(councilMembers[0]).vote(0, true))
        .to.emit(governance, "VoteCast")
        .withArgs(0, councilMembers[0].address, true, 100);

      // 4. Vote - Council member 1 (power 75) votes for
      await expect(governance.connect(councilMembers[1]).vote(0, true))
        .to.emit(governance, "VoteCast")
        .withArgs(0, councilMembers[1].address, true, 75);

      // 5. Check if proposal succeeded (100 + 75 = 175 > 135 quorum)
      const [, , newState, , , newForVotes] = await governance.getProposalState(
        0
      );
      expect(newState).to.equal(3); // SUCCEEDED
      expect(newForVotes).to.equal(175);

      // 6. Try to execute before timelock
      await expect(governance.execute(0)).to.be.revertedWithCustomError(
        governance,
        "NotReady"
      );

      // 7. Fast forward past timelock
      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );

      // 8. Execute proposal
      await expect(governance.execute(0))
        .to.emit(governance, "ProposalExecuted")
        .withArgs(0, true);

      // 9. Verify role was granted

      expect(await stablecoin.hasRoleView(minterRole, minter.address)).to.be
        .true;

      // 10. Verify stablecoin can check the role
      expect(await stablecoin.hasRoleView(minterRole, minter.address)).to.be
        .true;
    });

    it("Should handle proposal defeat correctly", async function () {
      const blacklistRole = await roleController.BLACKLIST_ROLE();

      // Create proposal
      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          blacklistRole,
          users[0].address,
          true,
          "Grant blacklist role"
        );

      // Vote against with majority
      await governance.connect(councilMembers[0]).vote(0, false); // 100 against
      await governance.connect(councilMembers[1]).vote(0, false); // 75 against
      // Total against: 175 > quorum, and against > for

      const [, , state, , , forVotes, againstVotes] =
        await governance.getProposalState(0);
      expect(state).to.equal(2); // DEFEATED
      expect(forVotes).to.equal(0);
      expect(againstVotes).to.equal(175);

      // Should not be able to execute defeated proposal
      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await expect(governance.execute(0)).to.be.revertedWithCustomError(
        governance,
        "NotReady"
      );
    });

    it("Should handle council member addition through governance", async function () {
      const newMember = users[0].address;
      const newPower = 60;

      // Create add member proposal
      await governance
        .connect(councilMembers[0])
        .proposeAddMember(
          newMember,
          newPower,
          "Add new qualified council member"
        );

      // Vote for the proposal (need majority)
      await governance.connect(councilMembers[0]).vote(0, true); // 100
      await governance.connect(councilMembers[1]).vote(0, true); // 75
      // Total: 175 > 135 quorum

      // Fast forward and execute
      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );

      await expect(governance.execute(0))
        .to.emit(governance, "CouncilAdded")
        .withArgs(newMember, newPower);

      // Verify member was added
      const [isActive, power, joinedAt] = await governance.getCouncilInfo(
        newMember
      );
      expect(isActive).to.be.true;
      expect(power).to.equal(newPower);
      expect(joinedAt).to.be.gt(0);

      // Verify council stats updated
      expect(await governance.activeMembers()).to.equal(4);
      expect(await governance.totalVotingPower()).to.equal(285); // 225 + 60

      // Verify new member can vote on proposals
      const minterRole = await roleController.MINTER_ROLE();
      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          minterRole,
          users[1].address,
          true,
          "Test new member voting"
        );

      await expect(governance.connect(users[0]).vote(1, true))
        .to.emit(governance, "VoteCast")
        .withArgs(1, newMember, true, newPower);
    });

    it("Should handle council member removal through governance", async function () {
      // First add a new member so we can remove one without going below minimum
      const newMember = users[0].address;
      const newPower = 60;

      await governance
        .connect(councilMembers[0])
        .proposeAddMember(newMember, newPower, "Add new member first");

      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(0);

      // Now remove the original member
      const memberToRemove = councilMembers[2].address;

      await governance
        .connect(councilMembers[0])
        .proposeRemoveMember(memberToRemove, "Remove inactive council member");

      await governance.connect(councilMembers[0]).vote(1, true);
      await governance.connect(councilMembers[1]).vote(1, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );

      await expect(governance.execute(1))
        .to.emit(governance, "CouncilRemoved")
        .withArgs(memberToRemove);

      const [isActive, ,] = await governance.getCouncilInfo(memberToRemove);

      expect(isActive).to.be.false;

      // Verify council stats updated
      expect(await governance.activeMembers()).to.equal(3);
      expect(await governance.totalVotingPower()).to.equal(235); // 225 + 60 - 50

      // Verify removed member cannot vote
      const minterRole = await roleController.MINTER_ROLE();
      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          minterRole,
          users[1].address,
          true,
          "Test removed member cannot vote"
        );

      await expect(
        governance.connect(councilMembers[2]).vote(2, true)
      ).to.be.revertedWithCustomError(governance, "NotCouncil");
    });
  });

  describe("End-to-End Token Operations", function () {
    beforeEach(async function () {
      // Grant minter role through governance
      const minterRole = await roleController.MINTER_ROLE();

      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          minterRole,
          minter.address,
          true,
          "Grant minter role"
        );

      // Vote and execute
      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(0);
    });

    it("Should allow complete mint and transfer flow", async function () {
      const mintAmount = ethers.parseEther("1000");

      // Mint tokens
      await expect(
        stablecoin.connect(minter).mint(users[0].address, mintAmount)
      )
        .to.emit(stablecoin, "Mint")
        .withArgs(users[0].address, mintAmount, minter.address);

      expect(await stablecoin.balanceOf(users[0].address)).to.equal(mintAmount);
      expect(await stablecoin.totalSupply()).to.equal(mintAmount);

      // Transfer tokens
      const transferAmount = ethers.parseEther("200");
      await expect(
        stablecoin.connect(users[0]).transfer(users[1].address, transferAmount)
      )
        .to.emit(stablecoin, "Transfer")
        .withArgs(users[0].address, users[1].address, transferAmount);

      expect(await stablecoin.balanceOf(users[0].address)).to.equal(
        mintAmount - transferAmount
      );
      expect(await stablecoin.balanceOf(users[1].address)).to.equal(
        transferAmount
      );

      // Burn tokens
      const burnAmount = ethers.parseEther("50");
      await expect(stablecoin.connect(users[1]).burn(burnAmount))
        .to.emit(stablecoin, "Burn")
        .withArgs(users[1].address, burnAmount, users[1].address);

      expect(await stablecoin.balanceOf(users[1].address)).to.equal(
        transferAmount - burnAmount
      );
      expect(await stablecoin.totalSupply()).to.equal(mintAmount - burnAmount);
    });

    it("Should respect max supply limits", async function () {
      const mintAmount = maxSupply + ethers.parseEther("1");

      await expect(
        stablecoin.connect(minter).mint(users[0].address, mintAmount)
      ).to.be.revertedWithCustomError(stablecoin, "ExceedsMaxSupply");
    });

    it("Should handle blacklisting through governance", async function () {
      const blacklistRole = await roleController.BLACKLIST_ROLE();

      // Grant blacklist role through governance
      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          blacklistRole,
          emergencyAdmin.address,
          true,
          "Grant blacklist role to emergency admin"
        );

      await governance.connect(councilMembers[0]).vote(1, true);
      await governance.connect(councilMembers[1]).vote(1, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(1);

      // Mint some tokens first
      const mintAmount = ethers.parseEther("1000");
      await stablecoin.connect(minter).mint(users[0].address, mintAmount);

      // Blacklist user
      await expect(
        stablecoin
          .connect(emergencyAdmin)
          .updateBlacklist(users[0].address, true)
      )
        .to.emit(stablecoin, "BlacklistUpdated")
        .withArgs(users[0].address, true);

      // Blacklisted user cannot transfer
      await expect(
        stablecoin
          .connect(users[0])
          .transfer(users[1].address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(stablecoin, "AccountBlacklisted");

      // Cannot mint to blacklisted user
      await expect(
        stablecoin
          .connect(minter)
          .mint(users[0].address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(stablecoin, "AccountBlacklisted");

      // Remove from blacklist
      await stablecoin
        .connect(emergencyAdmin)
        .updateBlacklist(users[0].address, false);

      // Should work again
      await expect(
        stablecoin
          .connect(users[0])
          .transfer(users[1].address, ethers.parseEther("100"))
      ).to.emit(stablecoin, "Transfer");
    });
  });

  describe("Emergency Coordination", function () {
    it("Should coordinate emergency modes across system", async function () {
      // First grant blacklist role to emergency admin
      const blacklistRole = await roleController.BLACKLIST_ROLE();

      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          blacklistRole,
          emergencyAdmin.address,
          true,
          "Grant blacklist role"
        );

      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(0);

      // Now test emergency coordination
      expect(await roleController.isEmergencyMode()).to.be.false;
      expect(await stablecoin.isEmergencyMode()).to.be.false;

      // Activate role controller emergency
      await roleController.connect(emergencyAdmin).toggleEmergencyMode(true);

      expect(await roleController.isEmergencyMode()).to.be.true;
      expect(await stablecoin.isEmergencyMode()).to.be.true;

      // Stablecoin operations should be blocked
      await expect(
        stablecoin
          .connect(emergencyAdmin)
          .updateBlacklist(users[0].address, true)
      ).to.be.revertedWithCustomError(stablecoin, "EmergencyModeActive");

      // Clear emergency
      await roleController.connect(emergencyAdmin).toggleEmergencyMode(false);
      expect(await roleController.isEmergencyMode()).to.be.false;
      expect(await stablecoin.isEmergencyMode()).to.be.false;
    });

    it("Should handle local stablecoin emergency independently", async function () {
      // First grant blacklist role to emergency admin
      const blacklistRole = await roleController.BLACKLIST_ROLE();

      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          blacklistRole,
          emergencyAdmin.address,
          true,
          "Grant blacklist role"
        );

      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(0);

      // Activate only local stablecoin emergency
      await stablecoin.connect(emergencyAdmin).toggleLocalEmergency(true);

      expect(await roleController.isEmergencyMode()).to.be.false;
      expect(await stablecoin.isEmergencyMode()).to.be.true;

      // Stablecoin operations blocked
      await expect(
        stablecoin
          .connect(emergencyAdmin)
          .updateBlacklist(users[0].address, true)
      ).to.be.revertedWithCustomError(stablecoin, "EmergencyModeActive");

      // But governance still works
      const minterRole = await roleController.MINTER_ROLE();
      await expect(
        governance
          .connect(councilMembers[0])
          .proposeRoleChange(
            minterRole,
            users[0].address,
            true,
            "Test during local emergency"
          )
      ).to.emit(governance, "ProposalCreated");
    });

    it("Should handle pause/unpause correctly", async function () {
      // Pause stablecoin
      await stablecoin.connect(emergencyAdmin).pause();
      expect(await stablecoin.paused()).to.be.true;
      expect(await stablecoin.isEmergencyMode()).to.be.true;

      // Cannot transfer when paused
      await expect(stablecoin.connect(users[0]).transfer(users[1].address, 100))
        .to.be.reverted;

      // Unpause
      await stablecoin.connect(emergencyAdmin).unpause();
      expect(await stablecoin.paused()).to.be.false;
    });
  });

  describe("Complex Governance Scenarios", function () {
    it("Should handle role revocation through governance", async function () {
      const minterRole = await roleController.MINTER_ROLE();

      // First grant the role
      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          minterRole,
          minter.address,
          true,
          "Grant minter role"
        );

      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(0);

      expect(await stablecoin.hasRoleView(minterRole, minter.address)).to.be
        .true;

      // Now revoke the role
      await governance.connect(councilMembers[0]).proposeRoleChange(
        minterRole,
        minter.address,
        false, // isGrant = false
        "Revoke minter role due to security concerns"
      );

      await governance.connect(councilMembers[0]).vote(1, true);
      await governance.connect(councilMembers[1]).vote(1, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(1);

      expect(await stablecoin.hasRoleView(minterRole, minter.address)).to.be
        .false;

      // Should not be able to mint anymore
      await expect(
        stablecoin
          .connect(minter)
          .mint(users[0].address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(stablecoin, "UnauthorizedAccess");
    });

    it("Should handle failed governance execution gracefully", async function () {
      // First mint some tokens to create supply
      const minterRole = await roleController.MINTER_ROLE();

      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          minterRole,
          emergencyAdmin.address,
          true,
          "Grant minter role"
        );

      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(0);

      // Mint some tokens first
      await stablecoin
        .connect(emergencyAdmin)
        .mint(users[0].address, ethers.parseEther("1000"));

      // Create execution proposal that will fail - set max supply below current supply
      const newMaxSupply = ethers.parseEther("100"); // Lower than current supply
      const invalidCalldata = stablecoin.interface.encodeFunctionData(
        "updateMaxSupply",
        [newMaxSupply]
      );

      await governance
        .connect(councilMembers[0])
        .proposeExecution(
          await stablecoin.getAddress(),
          invalidCalldata,
          "Update max supply below current supply (will fail)"
        );

      await governance.connect(councilMembers[0]).vote(1, true);
      await governance.connect(councilMembers[1]).vote(1, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );

      // Execution should fail
      await expect(governance.execute(1)).to.be.revertedWithCustomError(
        governance,
        "ExecutionFailed"
      );
    });
  });

  describe("System Health and Diagnostics", function () {
    it("Should provide accurate integration status", async function () {
      const [rcAddr, isSet, isInit, hasRole] =
        await governance.getIntegrationStatus();

      expect(rcAddr).to.equal(await roleController.getAddress());
      expect(isSet).to.be.true;
      expect(isInit).to.be.true;
      expect(hasRole).to.be.true;
    });

    it("Should track role change IDs correctly", async function () {
      const minterRole = await roleController.MINTER_ROLE();

      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          minterRole,
          users[0].address,
          true,
          "Test role change tracking"
        );

      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );

      await expect(governance.execute(0)).to.emit(
        governance,
        "RoleChangeProposed"
      );

      // Should have a role change ID recorded
      const roleChangeId = await governance.getRoleChangeId(0);
      expect(roleChangeId).to.be.gt(0);
    });

    it("Should allow role change retry on failure", async function () {
      // This test would need to simulate a role change failure
      // For now, we'll test the function exists and has proper permissions
      const minterRole = await roleController.MINTER_ROLE();

      await governance
        .connect(councilMembers[0])
        .proposeRoleChange(
          minterRole,
          users[0].address,
          true,
          "Test role change retry"
        );

      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      await time.increase(
        TEST_CONSTANTS.VOTING_PERIOD + TEST_CONSTANTS.EXECUTION_DELAY
      );
      await governance.execute(0);

      // Should be able to call retry (even if it's not needed in this case)
      const canRetry = await governance
        .connect(councilMembers[0])
        .retryRoleChange(0);
      // Function should execute without reverting
    });
  });
});
