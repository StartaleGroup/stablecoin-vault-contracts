// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeTransferLib} from 'solady/utils/SafeTransferLib.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ISUSDSCVaultEventsAndErrors} from '../../interfaces/vaults/4626/ISUSDSCVaultEventsAndErrors.sol';

// Note: non-upgradeable version
// Note: We could have some admin actions

/// @title sUSDSCVault — ERC-4626: deposit USDSC → mint sUSDSC; external asset inflows lift PPS
contract SUSDSCVault is ERC20, ERC4626, AccessControl, Pausable, ReentrancyGuard, ISUSDSCVaultEventsAndErrors {
  using SafeTransferLib for IERC20;

  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');

  constructor(IERC20 usdsc, address admin, address pauser) ERC20('Staked USDSC', 'sUSDSC') ERC4626(usdsc) {
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
    if(token == asset()) revert TokenCannotBeUSDSC();
    if (token == address(0)) revert TokenCannotBeZeroAddress();
    if (to == address(0)) revert ToCannotBeZeroAddress();
    if (amount == 0) revert AmountCannotBeZero();
    SafeTransferLib.safeTransfer(token, to, amount);
  }

  /**
   * @dev Override to provide enhanced protection against inflation attacks.
   * 
   * With USDSC having 6 decimals, setting _decimalsOffset to 6 creates 10^6 = 1,000,000 virtual shares.
   * This makes inflation attacks prohibitively expensive as an attacker would need to donate
   * approximately 1 million USDSC to manipulate a 1 USDSC deposit, making the attack economically infeasible.
   * 
   * The offset increases the vault decimals to 12 (6 + 6) but doesn't affect user experience
   * as all conversions are handled internally by the ERC4626 implementation.
   * 
   * OR
   * we could keep this to zero and put Initial seed deposit upon deployment (say 1000 USDSC)
   */
  function _decimalsOffset() internal pure override returns (uint8) {
    return 0;
  }
}
