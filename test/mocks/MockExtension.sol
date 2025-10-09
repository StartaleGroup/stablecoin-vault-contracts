// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./MockUSDR.sol";
import {IMYieldToOne} from "m-extensions/projects/yieldToOne/IMYieldToOne.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockExtension is IMYieldToOne, IERC20 {
    MockUSDR public immutable usdr;
    address  public yieldRecipient;
    uint256  public pending; // pending yield

    constructor(MockUSDR _usdr, address _recipient) {
        usdr = _usdr;
        yieldRecipient = _recipient;
    }

    function setYieldRecipient(address y) external { yieldRecipient = y; }
    function addPending(uint256 amt) external { pending += amt; }

    function yield() external view returns (uint256) { return pending; }

    function YIELD_RECIPIENT_MANAGER_ROLE() external pure returns (bytes32) {
        return keccak256("YIELD_RECIPIENT_MANAGER_ROLE");
    }

    function claimYield() external returns (uint256) {
        require(msg.sender == yieldRecipient, "not recipient");
        uint256 m = pending;
        if (m > 0) {
            pending = 0;
            usdr.mint(msg.sender, m);
        }
        return m;
    }

    // IERC20 methods - delegate to underlying USDR
    function totalSupply() external view returns (uint256) {
        return usdr.totalSupply();
    }

    function balanceOf(address account) external view returns (uint256) {
        return usdr.balanceOf(account);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return usdr.allowance(owner, spender);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        return usdr.approve(spender, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        // MockExtension acts as a proxy - transfer from caller's MockUSDR balance
        // We need to use transferFrom since we're acting on behalf of the caller
        require(usdr.balanceOf(msg.sender) >= amount, "bal");
        
        // Since we can't directly modify MockUSDR's internal state,
        // we'll use a different approach: mint to recipient and burn from sender
        usdr.mint(to, amount);
        usdr.burn(msg.sender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return usdr.transferFrom(from, to, amount);
    }
}
