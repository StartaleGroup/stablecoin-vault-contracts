// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

// Note: Placeholder init
// Note: non-upgradeable version
// Note: We could have some admin actions

/// @title sUSDxVault — ERC-4626: deposit USDx → mint sUSDx; external asset inflows lift PPS
contract SUSDxVault is ERC20, ERC4626, AccessControl, Pausable, ReentrancyGuard {
  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');

  constructor(IERC20 usdx, address admin, address pauser) ERC20('Staked USDx', 'sUSDx') ERC4626(usdx) {
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PAUSER_ROLE, pauser);
  }

  // OZ’s totalAssets() = asset.balanceOf(this), so simple transfers raise PPS — perfect for yield “donations”.

  function deposit(
    uint256 assets,
    address receiver
  ) public override whenNotPaused nonReentrant returns (uint256 shares) {
    return super.deposit(assets, receiver);
  }

  function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256 assets) {
    return super.mint(shares, receiver);
  }

  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public override whenNotPaused nonReentrant returns (uint256 shares) {
    return super.withdraw(assets, receiver, owner);
  }

  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public override whenNotPaused nonReentrant returns (uint256 assets) {
    return super.redeem(shares, receiver, owner);
  }

  function pause(bool p) external onlyRole(PAUSER_ROLE) {
    p ? _pause() : _unpause();
  }

  // Override function that exists in multiple base contracts
  function decimals() public view override(ERC20, ERC4626) returns (uint8) {
    return super.decimals();
  }
}
