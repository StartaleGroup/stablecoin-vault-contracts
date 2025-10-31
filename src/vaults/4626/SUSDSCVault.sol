// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISUSDSCVaultEventsAndErrors} from '../../interfaces/vaults/4626/ISUSDSCVaultEventsAndErrors.sol';
import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {SafeTransferLib} from 'solady/utils/SafeTransferLib.sol';

/// @title sUSDSCVault — ERC-4626: deposit USDSC → mint sUSDSC; external asset inflows lift PPS
contract SUSDSCVault is ERC20, ERC4626, AccessControl, Pausable, ReentrancyGuardTransient, ISUSDSCVaultEventsAndErrors {
  using SafeTransferLib for IERC20;

  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');

  constructor(IERC20 usdsc, address admin, address pauser) ERC20('Staked USDSC', 'sUSDSC') ERC4626(usdsc) {
    if (admin == address(0)) revert ISUSDSCVaultEventsAndErrors.AdminCannotBeZeroAddress();
    if (pauser == address(0)) revert ISUSDSCVaultEventsAndErrors.PauserCannotBeZeroAddress();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PAUSER_ROLE, pauser);
  }

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

  function recoverNonAssetERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (token == asset()) revert ISUSDSCVaultEventsAndErrors.TokenCannotBeUSDSC();
    if (token == address(0)) revert ISUSDSCVaultEventsAndErrors.TokenCannotBeZeroAddress();
    if (to == address(0)) revert ISUSDSCVaultEventsAndErrors.ToCannotBeZeroAddress();
    if (amount == 0) revert ISUSDSCVaultEventsAndErrors.AmountCannotBeZero();
    SafeTransferLib.safeTransfer(token, to, amount);
  }

  function decimals() public view override(ERC20, ERC4626) returns (uint8) {
    return super.decimals();
  }

  function _decimalsOffset() internal pure override returns (uint8) {
    return 0;
  }
}
