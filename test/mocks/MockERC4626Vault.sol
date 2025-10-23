// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import './MockUSDSC.sol';
import 'lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol';

contract MockERC4626Vault is IERC4626 {
  MockUSDSC public immutable USDSC;

  constructor(MockUSDSC _usdsc) {
    USDSC = _usdsc;
  }

  // We implement only what's needed by the redistributor: totalAssets()
  function totalAssets() public view returns (uint256) {
    return USDSC.balanceOf(address(this));
  }

  // ---- ERC20 Metadata functions ----
  function name() external pure returns (string memory) {
    return 'Mock ERC4626 Vault';
  }

  function symbol() external pure returns (string memory) {
    return 'MOCK4626';
  }

  function decimals() external pure returns (uint8) {
    return 6;
  }

  // ---- Unused IERC4626 funcs (stubs to satisfy interface) ----
  function asset() external view returns (address) {
    return address(USDSC);
  }

  function totalSupply() external pure returns (uint256) {
    return 0;
  }

  function balanceOf(address) external pure returns (uint256) {
    return 0;
  }

  function convertToShares(uint256) external pure returns (uint256) {
    return 0;
  }

  function convertToAssets(uint256) external pure returns (uint256) {
    return 0;
  }

  function maxDeposit(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function previewDeposit(uint256) external pure returns (uint256) {
    return 0;
  }

  function deposit(uint256, address) external pure returns (uint256) {
    return 0;
  }

  function maxMint(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function previewMint(uint256) external pure returns (uint256) {
    return 0;
  }

  function mint(uint256, address) external pure returns (uint256) {
    return 0;
  }

  function maxWithdraw(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function previewWithdraw(uint256) external pure returns (uint256) {
    return 0;
  }

  function withdraw(uint256, address, address) external pure returns (uint256) {
    return 0;
  }

  function maxRedeem(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function previewRedeem(uint256) external pure returns (uint256) {
    return 0;
  }

  function redeem(uint256, address, address) external pure returns (uint256) {
    return 0;
  }

  function allowance(address, address) external pure returns (uint256) {
    return 0;
  }

  function approve(address, uint256) external pure returns (bool) {
    return true;
  }

  function transfer(address, uint256) external pure returns (bool) {
    return true;
  }

  function transferFrom(address, address, uint256) external pure returns (bool) {
    return true;
  }
}
