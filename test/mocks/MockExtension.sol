// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./MockUSDSC.sol";
import {IMYieldToOne} from "m-extensions/projects/yieldToOne/IMYieldToOne.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockExtension is IMYieldToOne, IERC20 {
    MockUSDSC public immutable usdsc;
    address  public yieldRecipient;
    uint256  public pending; // pending yield

    constructor(MockUSDSC _usdsc, address _recipient) {
        usdsc = _usdsc;
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
            usdsc.mint(msg.sender, m);
        }
        return m;
    }

    // IERC20 methods - delegate to underlying USDSC
    function totalSupply() external view returns (uint256) {
        return usdsc.totalSupply();
    }

    function balanceOf(address account) external view returns (uint256) {
        return usdsc.balanceOf(account);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return usdsc.allowance(owner, spender);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        return usdsc.approve(spender, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        // MockExtension acts as a proxy - transfer from caller's MockUSDSC balance
        // We need to use transferFrom since we're acting on behalf of the caller
        require(usdsc.balanceOf(msg.sender) >= amount, "bal");
        
        // Since we can't directly modify MockUSDSC's internal state,
        // we'll use a different approach: mint to recipient and burn from sender
        usdsc.mint(to, amount);
        usdsc.burn(msg.sender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return usdsc.transferFrom(from, to, amount);
    }
}
