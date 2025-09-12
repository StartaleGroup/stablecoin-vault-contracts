// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./MockUSDR.sol";
import {IMYieldToOne} from "m-extensions/projects/yieldToOne/IMYieldToOne.sol";

contract MockExtension is IMYieldToOne {
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
}
