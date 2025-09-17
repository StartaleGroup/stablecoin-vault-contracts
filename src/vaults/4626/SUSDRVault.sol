// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeTransferLib} from 'solady/utils/SafeTransferLib.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ISUSDRVaultEventsAndErrors} from '../../interfaces/vaults/4626/ISUSDRVaultEventsAndErrors.sol';

// Note: non-upgradeable version
// Note: We could have some admin actions

/// @title sUSDRVault — ERC-4626: deposit USDR → mint sUSDR; external asset inflows lift PPS
contract SUSDRVault is ERC20, ERC4626, AccessControl, Pausable, ReentrancyGuard, ISUSDRVaultEventsAndErrors {
  using SafeTransferLib for IERC20;

  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');

  constructor(IERC20 usdr, address admin, address pauser) ERC20('Staked USDR', 'sUSDR') ERC4626(usdr) {
    if (admin == address(0)) revert AdminCannotBeZeroAddress();
    if (pauser == address(0)) revert PauserCannotBeZeroAddress();
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

  // Recover non-asset ERC20 tokens
  // This is used to recover tokens that are sent to the vault by mistake  
  function recoverNonAssetERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if(token == asset()) revert TokenCannotBeUSDR();
    if (token == address(0)) revert TokenCannotBeZeroAddress();
    if (to == address(0)) revert ToCannotBeZeroAddress();
    if (amount == 0) revert AmountCannotBeZero();
    SafeTransferLib.safeTransfer(token, to, amount);
  }

  // Todo // Review
  // Decide if we want to accept eth, withdraw eth etc or not.
}
