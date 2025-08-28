// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { MYieldToOne } from "m-extensions/projects/yieldToOne/MYieldToOne.sol";

// placeholder

// is IMYieldToOne, MYieldToOneStorageLayout, MExtension, Freezable
contract USDx is MYieldToOne {
    constructor(address mToken, address swapFacility) MYieldToOne(mToken, swapFacility) {}

    // Remaining args
    /* address yieldRecipient_,
        address admin,
        address freezeManager,
        address yieldRecipientManager
        */

    function initialize(string memory name, string memory symbol) external {
        __MYieldToOne_init(name, symbol, msg.sender, msg.sender, msg.sender, msg.sender);
    }
}
