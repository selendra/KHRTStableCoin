// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20, Ownable {
    uint8 private _decimals;
    
    // Events for batch operations
    event BatchTransfer(address indexed from, uint256 totalAmount, uint256 recipientCount);
    event BatchTransferFrom(address indexed spender, address indexed from, uint256 totalAmount, uint256 recipientCount);
    
    constructor(
        string memory name, 
        string memory symbol, 
        uint8 decimals_,
        address initialOwner
    ) ERC20(name, symbol) Ownable(initialOwner) {
        _decimals = decimals_;
    }
    
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
    
    /**
     * @dev Batch transfer tokens to multiple recipients
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to transfer to each recipient
     * @return success True if all transfers succeeded
     */
    function batchTransfer(
        address[] calldata recipients, 
        uint256[] calldata amounts
    ) external returns (bool success) {
        require(recipients.length == amounts.length, "Arrays length mismatch");
        require(recipients.length > 0, "Empty arrays");
        require(recipients.length <= 200, "Too many recipients"); // Gas limit protection
        
        uint256 totalAmount = 0;
        
        // Calculate total amount and validate recipients
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Invalid recipient");
            require(amounts[i] > 0, "Invalid amount");
            totalAmount += amounts[i];
        }
        
        // Check sender has sufficient balance
        require(balanceOf(msg.sender) >= totalAmount, "Insufficient balance");
        
        // Perform transfers
        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(msg.sender, recipients[i], amounts[i]);
        }
        
        emit BatchTransfer(msg.sender, totalAmount, recipients.length);
        return true;
    }
    
    /**
     * @dev Batch transfer tokens from another account to multiple recipients
     * @param from Address to transfer from
     * @param recipients Array of recipient addresses  
     * @param amounts Array of amounts to transfer to each recipient
     * @return success True if all transfers succeeded
     */
    function batchTransferFrom(
        address from,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external returns (bool success) {
        require(recipients.length == amounts.length, "Arrays length mismatch");
        require(recipients.length > 0, "Empty arrays");
        require(recipients.length <= 200, "Too many recipients"); // Gas limit protection
        
        uint256 totalAmount = 0;
        
        // Calculate total amount and validate recipients
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Invalid recipient");
            require(amounts[i] > 0, "Invalid amount");
            totalAmount += amounts[i];
        }
        
        // Check allowance and balance
        require(allowance(from, msg.sender) >= totalAmount, "Insufficient allowance");
        require(balanceOf(from) >= totalAmount, "Insufficient balance");
        
        // Update allowance
        _approve(from, msg.sender, allowance(from, msg.sender) - totalAmount);
        
        // Perform transfers
        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(from, recipients[i], amounts[i]);
        }
        
        emit BatchTransferFrom(msg.sender, from, totalAmount, recipients.length);
        return true;
    }
    
}