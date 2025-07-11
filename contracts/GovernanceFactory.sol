// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./RoleController.sol";
import "./CouncilGovernance.sol";
import "./KHRTStableCoin.sol";

/**
 * @title GovernanceFactory
 * @dev Factory contract to deploy the entire governance system in correct order
 * Solves the circular dependency problem between contracts
 */
contract GovernanceFactory {
    
    struct DeploymentConfig {
        // Stablecoin config
        uint256 maxSupply;
        string tokenName;
        string tokenSymbol;
        
        // Council config  
        address[] initialCouncilMembers;
        uint256[] councilVotingPowers;
        
        // Emergency admin
        address emergencyAdmin;
        
        // Governance parameters
        uint256 votingPeriod;
        uint256 timeLock;
        uint256 quorumPercent;
    }
    
    struct DeployedContracts {
        address roleController;
        address councilGovernance;
        address stablecoin;
        bool isInitialized;
    }
    
    event SystemDeployed(
        address indexed deployer,
        address roleController,
        address councilGovernance, 
        address stablecoin,
        uint256 timestamp
    );
    
    event SystemInitialized(
        address indexed system,
        uint256 timestamp
    );
    
    /**
     * @dev Deploy the complete governance system
     * @param config Deployment configuration
     * @return deployed Addresses of all deployed contracts
     * FIXED: Changed from external to public and calldata to memory for internal calls
     */
    function deployGovernanceSystem(DeploymentConfig memory config) 
        public 
        returns (DeployedContracts memory deployed) 
    {
        require(config.initialCouncilMembers.length >= 3, "Need at least 3 council members");
        require(config.initialCouncilMembers.length == config.councilVotingPowers.length, "Member/power length mismatch");
        require(config.emergencyAdmin != address(0), "Invalid emergency admin");
        require(config.maxSupply > 0, "Invalid max supply");
        
        // Step 1: Deploy RoleController with placeholder governance (will be updated)
        address[] memory initialAuthorized = new address[](0); // Empty initially
        deployed.roleController = address(new RoleController(
            address(this), // Temporary governance - factory will set up properly
            config.emergencyAdmin,
            initialAuthorized
        ));
        
        // Step 2: Deploy CouncilGovernance
        deployed.councilGovernance = address(new CouncilGovernance(
            deployed.roleController,
            config.initialCouncilMembers,
            config.councilVotingPowers
        ));
        
        // Step 3: Deploy KHRTStableCoin
        deployed.stablecoin = address(new KHRTStableCoin(
            config.maxSupply,
            config.emergencyAdmin,
            deployed.roleController,
            config.tokenName,
            config.tokenSymbol
        ));
        
        // Step 4: Initialize the system properly
        _initializeSystem(deployed, config);
        
        deployed.isInitialized = true;
        
        emit SystemDeployed(
            msg.sender,
            deployed.roleController,
            deployed.councilGovernance,
            deployed.stablecoin,
            block.timestamp
        );
        
        return deployed;
    }
    
    /**
     * @dev Initialize the deployed system with proper connections
     */
    function _initializeSystem(
        DeployedContracts memory deployed, 
        DeploymentConfig memory config
    ) internal {
        RoleController roleController = RoleController(deployed.roleController);
        CouncilGovernance governance = CouncilGovernance(deployed.councilGovernance);
        
        // Step 1: Update governance contract in RoleController
        roleController.updateGovernanceContract(deployed.councilGovernance);
        
        // Step 2: Authorize stablecoin to call RoleController
        roleController.authorizeContract(deployed.stablecoin, true);
        
        // Step 3: Authorize governance to call RoleController  
        roleController.authorizeContract(deployed.councilGovernance, true);
        
        // Step 4: Set governance configuration if provided
        if (config.votingPeriod > 0 || config.timeLock > 0 || config.quorumPercent > 0) {
            governance.updateConfig(
                config.votingPeriod > 0 ? config.votingPeriod : 3 days,
                config.timeLock > 0 ? config.timeLock : 1 days,
                config.quorumPercent > 0 ? config.quorumPercent : 60
            );
        }
        
        // Step 5: Renounce factory's temporary governance role
        roleController.renounceRole(roleController.GOVERNANCE_ROLE(), address(this));
        
        emit SystemInitialized(deployed.councilGovernance, block.timestamp);
    }
    
    /**
     * @dev Deploy system with default configuration
     * @param councilMembers Initial council members
     * @param councilPowers Voting powers for council members
     * @param emergencyAdmin Emergency admin address
     * @param maxSupply Maximum token supply
     */
    function deployWithDefaults(
        address[] calldata councilMembers,
        uint256[] calldata councilPowers, 
        address emergencyAdmin,
        uint256 maxSupply
    ) external returns (DeployedContracts memory) {
        
        DeploymentConfig memory config = DeploymentConfig({
            maxSupply: maxSupply,
            tokenName: "KHR Token (Official)",
            tokenSymbol: "KHRT",
            initialCouncilMembers: councilMembers,
            councilVotingPowers: councilPowers,
            emergencyAdmin: emergencyAdmin,
            votingPeriod: 3 days,
            timeLock: 1 days,
            quorumPercent: 60
        });
        
        return deployGovernanceSystem(config);
    }
}