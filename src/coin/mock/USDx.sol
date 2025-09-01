// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {MYieldToOne} from 'm-extensions/projects/yieldToOne/MYieldToOne.sol';

// simple placeholder
// upgradeable from start because MYieldToOne base is upgradeable
// can add PausableUpgradeable later if needed
// can add ForcedTransferManager features later if needed (check mUSD)

// Note: MYieldToOne is IMYieldToOne, MYieldToOneStorageLayout, MExtension, Freezable
contract USDx is MYieldToOne {
  constructor(address mToken, address swapFacility) MYieldToOne(mToken, swapFacility) {
    _disableInitializers();
  }

  // Note: init args after name and symbol are in order: yieldRecipient, admin, freezeManager, yieldRecipientManager

  function initialize(
    string memory name,
    string memory symbol,
    address admin,
    address yieldRecipient
  ) public initializer {
    __MYieldToOne_init(name, symbol, yieldRecipient, admin, admin, admin);
  }
}
