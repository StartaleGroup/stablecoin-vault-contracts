// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';

/// @title MockERC20Permit
/// @notice Mock ERC20 token with permit functionality for testing
contract MockERC20Permit is ERC20Permit {
  constructor(string memory name, string memory symbol) ERC20(name, symbol) ERC20Permit(name) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) external {
    _burn(from, amount);
  }
}

