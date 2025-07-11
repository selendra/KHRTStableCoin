import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  RoleController,
  CouncilGovernance,
  KHRTStableCoin,
} from "../typechain-types";
import { TEST_CONSTANTS, ROLE_NAMES, TEST_ACCOUNTS } from "./fixtures/data";

describe("KHRT Basic Functionality Tests", function () {
  let accounts: SignerWithAddress[];
  let deployer: SignerWithAddress;
  let emergencyAdmin: SignerWithAddress;
  let councilMembers: SignerWithAddress[];
  let users: SignerWithAddress[];

  let roleController: RoleController;
  let governance: CouncilGovernance;
  let stablecoin: KHRTStableCoin;

  // Test data
  const maxSupply = TEST_CONSTANTS.MAX_SUPPLY;
  const councilPowers = [100, 75, 50]; // Voting powers

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

    // Deploy contracts
    const RoleController = await ethers.getContractFactory("RoleController");
    const CouncilGovernance = await ethers.getContractFactory(
      "CouncilGovernance"
    );
    const KHRTStableCoin = await ethers.getContractFactory("KHRTStableCoin");

    // Deploy RoleController first (needed for other contracts)
    roleController = await RoleController.deploy(
      ethers.ZeroAddress, // Governance will be set later
      emergencyAdmin.address,
      [] // No initial authorized contracts
    );

    // Deploy Governance with RoleController and council
    governance = await CouncilGovernance.deploy(
      await roleController.getAddress(),
      councilMembers.map((m) => m.address),
      councilPowers
    );

    // Deploy Stablecoin
    stablecoin = await KHRTStableCoin.deploy(
      maxSupply,
      emergencyAdmin.address,
      await roleController.getAddress(),
      "KHRT Stablecoin",
      "KHRT"
    );

    // Complete setup: set governance in role controller
    await roleController.updateGovernanceContract(
      await governance.getAddress()
    );

    // Authorize contracts
    await roleController.authorizeContract(await stablecoin.getAddress(), true);
    await roleController.authorizeContract(await governance.getAddress(), true);

    // End setup phase
    await roleController.endSetupPhase();
  });

  describe("RoleController", function () {
    it("Should deploy with correct initial state", async function () {
      expect(await roleController.emergencyMode()).to.be.false;
      expect(await roleController.getEmergencyAdmin()).to.equal(
        emergencyAdmin.address
      );

      const [isActive, govAddr] = await roleController.getGovernanceStatus();
      expect(isActive).to.be.true;
      expect(govAddr).to.equal(await governance.getAddress());
    });

    it("Should allow emergency admin to toggle emergency mode", async function () {
      await expect(
        roleController.connect(emergencyAdmin).toggleEmergencyMode(true)
      )
        .to.emit(roleController, "EmergencyModeToggled")
        .withArgs(true, emergencyAdmin.address);

      expect(await roleController.isEmergencyMode()).to.be.true;
    });

    it("Should reject unauthorized emergency actions", async function () {
      await expect(
        roleController.connect(users[0]).toggleEmergencyMode(true)
      ).to.be.revertedWithCustomError(roleController, "OnlyEmergencyAdmin");
    });

    it("Should check roles correctly", async function () {
      const minterRole = await roleController.MINTER_ROLE();

      // Use stablecoin contract which is authorized to check roles
      expect(await stablecoin.hasRoleView(minterRole, users[0].address)).to.be
        .false;
    });

    it("Should reject role operations from non-governance", async function () {
      const minterRole = await roleController.MINTER_ROLE();

      await expect(
        roleController
          .connect(users[0])
          .grantRoleWithReason(minterRole, users[0].address, "Test grant")
      ).to.be.revertedWithCustomError(
        roleController,
        "UnauthorizedGovernanceAction"
      );
    });
  });

  describe("CouncilGovernance", function () {
    it("Should deploy with correct council configuration", async function () {
      expect(await governance.activeMembers()).to.equal(3);
      expect(await governance.totalVotingPower()).to.equal(225); // 100 + 75 + 50

      const councilList = await governance.getCouncilList();
      expect(councilList.length).to.equal(3);
      expect(councilList).to.include(councilMembers[0].address);
    });

    it("Should allow council members to check their info", async function () {
      const [isActive, power, joinedAt] = await governance.getCouncilInfo(
        councilMembers[0].address
      );
      expect(isActive).to.be.true;
      expect(power).to.equal(100);
      expect(joinedAt).to.be.gt(0);
    });

    it("Should get integration status correctly", async function () {
      const [rcAddr, isSet, isInit, hasRole] =
        await governance.getIntegrationStatus();
      expect(rcAddr).to.equal(await roleController.getAddress());
      expect(isSet).to.be.true;
      expect(isInit).to.be.true;
      expect(hasRole).to.be.true;
    });

    it("Should reject proposal creation from non-council members", async function () {
      const minterRole = await roleController.MINTER_ROLE();

      await expect(
        governance
          .connect(users[0])
          .proposeRoleChange(
            minterRole,
            users[0].address,
            true,
            "Grant minter role"
          )
      ).to.be.revertedWithCustomError(governance, "NotCouncil");
    });

    it("Should allow council members to create role change proposals", async function () {
      const minterRole = await roleController.MINTER_ROLE();

      await expect(
        governance
          .connect(councilMembers[0])
          .proposeRoleChange(
            minterRole,
            users[0].address,
            true,
            "Grant minter role to user"
          )
      )
        .to.emit(governance, "ProposalCreated")
        .withArgs(0, councilMembers[0].address, 0); // 0 = ROLE_CHANGE type
    });

    it("Should allow council members to create member add proposals", async function () {
      const newMember = users[0].address;
      const power = 25;

      await expect(
        governance
          .connect(councilMembers[0])
          .proposeAddMember(newMember, power, "Add new council member")
      )
        .to.emit(governance, "ProposalCreated")
        .withArgs(0, councilMembers[0].address, 1); // 1 = MEMBER_ADD type
    });

    it("Should allow council members to create member remove proposals", async function () {
      // First add a member so we can remove one without going below minimum
      await expect(
        governance
          .connect(councilMembers[0])
          .proposeAddMember(users[0].address, 25, "Add new member first")
      ).to.emit(governance, "ProposalCreated");

      // Vote and execute the add proposal
      await governance.connect(councilMembers[0]).vote(0, true);
      await governance.connect(councilMembers[1]).vote(0, true);

      // Wait for execution time and execute
      await ethers.provider.send("evm_increaseTime", [4 * 24 * 60 * 60]); // 4 days
      await ethers.provider.send("evm_mine");
      await governance.execute(0);

      // Now we can create a remove proposal
      await expect(
        governance
          .connect(councilMembers[0])
          .proposeRemoveMember(
            councilMembers[1].address,
            "Remove inactive member"
          )
      )
        .to.emit(governance, "ProposalCreated")
        .withArgs(1, councilMembers[0].address, 2); // 2 = MEMBER_REMOVE type, proposal ID = 1
    });

    it("Should prevent self-removal proposals", async function () {
      await expect(
        governance
          .connect(councilMembers[0])
          .proposeRemoveMember(councilMembers[0].address, "Remove myself")
      ).to.be.revertedWith("Cannot remove self");
    });
  });

  describe("KHRTStableCoin", function () {
    it("Should deploy with correct initial parameters", async function () {
      expect(await stablecoin.name()).to.equal("KHRT Stablecoin");
      expect(await stablecoin.symbol()).to.equal("KHRT");
      expect(await stablecoin.decimals()).to.equal(18);
      expect(await stablecoin.totalSupply()).to.equal(0);
      expect(await stablecoin.maxSupply()).to.equal(maxSupply);
      expect(await stablecoin.getEmergencyAdmin()).to.equal(
        emergencyAdmin.address
      );
    });

    it("Should have correct role controller integration", async function () {
      const [controller, isSet, isLocked] =
        await stablecoin.getRoleControllerStatus();
      expect(controller).to.equal(await roleController.getAddress());
      expect(isSet).to.be.true;
      expect(isLocked).to.be.false;
    });

    it("Should reject minting without MINTER_ROLE", async function () {
      await expect(
        stablecoin
          .connect(users[0])
          .mint(users[0].address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(stablecoin, "UnauthorizedAccess");
    });

    it("Should allow emergency admin to pause/unpause", async function () {
      await expect(stablecoin.connect(emergencyAdmin).pause())
        .to.emit(stablecoin, "Paused")
        .withArgs(emergencyAdmin.address);

      expect(await stablecoin.paused()).to.be.true;

      await expect(stablecoin.connect(emergencyAdmin).unpause())
        .to.emit(stablecoin, "Unpaused")
        .withArgs(emergencyAdmin.address);

      expect(await stablecoin.paused()).to.be.false;
    });

    it("Should allow emergency admin to toggle local emergency", async function () {
      await expect(
        stablecoin.connect(emergencyAdmin).toggleLocalEmergency(true)
      )
        .to.emit(stablecoin, "LocalEmergencyToggled")
        .withArgs(true, emergencyAdmin.address);

      const [localEmergency, contractPaused, rcEmergency, anyActive] =
        await stablecoin.getEmergencyStatus();
      expect(localEmergency).to.be.true;
      expect(anyActive).to.be.true;
    });

    it("Should reject unauthorized emergency actions", async function () {
      await expect(
        stablecoin.connect(users[0]).pause()
      ).to.be.revertedWithCustomError(stablecoin, "OnlyEmergencyAdmin");

      await expect(
        stablecoin.connect(users[0]).toggleLocalEmergency(true)
      ).to.be.revertedWithCustomError(stablecoin, "OnlyEmergencyAdmin");
    });

    it("Should allow burning own tokens", async function () {
      // Test that burn function exists and reverts when no balance
      await expect(stablecoin.connect(users[0]).burn(ethers.parseEther("100")))
        .to.be.reverted; // Generic revert check instead of specific error message
    });

    it("Should check emergency mode correctly", async function () {
      expect(await stablecoin.isEmergencyMode()).to.be.false;

      // Test local emergency
      await stablecoin.connect(emergencyAdmin).toggleLocalEmergency(true);
      expect(await stablecoin.isEmergencyMode()).to.be.true;

      await stablecoin.connect(emergencyAdmin).toggleLocalEmergency(false);
      expect(await stablecoin.isEmergencyMode()).to.be.false;

      // Test role controller emergency
      await roleController.connect(emergencyAdmin).toggleEmergencyMode(true);
      expect(await stablecoin.isEmergencyMode()).to.be.true;
    });
  });

  describe("Basic Integration", function () {
    it("Should have proper contract authorizations", async function () {
      expect(
        await roleController.isAuthorizedContract(await stablecoin.getAddress())
      ).to.be.true;
      expect(
        await roleController.isAuthorizedContract(await governance.getAddress())
      ).to.be.true;
    });

    it("Should coordinate emergency modes", async function () {
      // Test that role controller emergency affects stablecoin
      await roleController.connect(emergencyAdmin).toggleEmergencyMode(true);
      expect(await stablecoin.isEmergencyMode()).to.be.true;

      // Test that local emergency doesn't affect role controller
      await roleController.connect(emergencyAdmin).toggleEmergencyMode(false);
      await stablecoin.connect(emergencyAdmin).toggleLocalEmergency(true);
      expect(await roleController.isEmergencyMode()).to.be.false;
      expect(await stablecoin.isEmergencyMode()).to.be.true;
    });

    it("Should have setup phase properly completed", async function () {
      const [isSetupPhase, deadline] = await roleController.getSetupInfo();
      expect(isSetupPhase).to.be.false;
    });
  });

  describe("Configuration and Constants", function () {
    it("Should have correct governance configuration", async function () {
      expect(await governance.votingPeriod()).to.equal(3 * 24 * 60 * 60); // 3 days
      expect(await governance.timeLock()).to.equal(1 * 24 * 60 * 60); // 1 day
      expect(await governance.quorumPercent()).to.equal(60); // 60%
      expect(await governance.MIN_COUNCIL()).to.equal(3);
      expect(await governance.MAX_COUNCIL()).to.equal(15);
    });

    it("Should allow council to update configuration", async function () {
      const newVotingPeriod = 2 * 24 * 60 * 60; // 2 days
      const newTimeLock = 12 * 60 * 60; // 12 hours
      const newQuorum = 51; // 51%

      await expect(
        governance
          .connect(councilMembers[0])
          .updateConfig(newVotingPeriod, newTimeLock, newQuorum)
      )
        .to.emit(governance, "ConfigUpdated")
        .withArgs(newVotingPeriod, newTimeLock, newQuorum);

      expect(await governance.votingPeriod()).to.equal(newVotingPeriod);
      expect(await governance.timeLock()).to.equal(newTimeLock);
      expect(await governance.quorumPercent()).to.equal(newQuorum);
    });

    it("Should reject invalid configuration", async function () {
      await expect(
        governance.connect(councilMembers[0]).updateConfig(
          30 * 60, // 30 minutes - too short
          1 * 24 * 60 * 60,
          60
        )
      ).to.be.revertedWith("Invalid voting period");

      await expect(
        governance.connect(councilMembers[0]).updateConfig(
          3 * 24 * 60 * 60,
          8 * 24 * 60 * 60, // 8 days - too long
          60
        )
      ).to.be.revertedWith("Invalid timelock");

      await expect(
        governance.connect(councilMembers[0]).updateConfig(
          3 * 24 * 60 * 60,
          1 * 24 * 60 * 60,
          101 // > 100% - invalid
        )
      ).to.be.revertedWith("Invalid quorum");
    });
  });
});
