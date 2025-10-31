// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVaultEventsAndErrors} from '../../interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';

/// @title EarnVaultStorageBase - Storage layout for upgradeable EarnVault
/// @notice Uses ERC7201 namespaced storage to prevent collisions
/// @dev All storage variables are defined here to ensure consistent layout across upgrades
abstract contract EarnVaultStorageBase is IEarnVaultEventsAndErrors {
  /// @custom:storage-location erc7201:startale.storage.EarnVault
  struct EarnVaultStorage {
    // -------- Constants --------
    uint256 RAY; // High precision for yield calculations (MakerDAO standard)
    // -------- Access Control --------
    address yieldRedistributor; // Address authorized to call onYield() (RewardRedistributor contract)
    address boostRewardKeeper; // Address authorized to call onBoostReward() (keeper/operator address)
    address pauser; // Address authorized to pause/unpause the contract
    // -------- Immutables (stored as regular variables in upgradeable) --------
    IERC20 USDSC; // USDSC token contract
    // -------- Roles / endpoints --------
    address treasury; // receives yield when no deposits exist, surplus sweeps
    // -------- Optional blacklist --------
    mapping(address => bool) isBlacklisted;
    // -------- Vault accounting --------
    uint256 totalPrincipal; // sum of user principals
    uint256 globalIndex; // global index (scaled 1e27 - RAY precision)
    uint256 claimReserve; // assets available to pay claims/withdraws
    uint256 _carryRay; // remainder in "RAY * principal" space for exact precision
    mapping(address => uint256) principal;
    mapping(address => uint256) userIndex;
    mapping(address => uint256) accrued;
    // -------- Boost rewards accounting (same logic as USDSC yield) --------
    mapping(address => uint256) boostGlobalIndex; // token => global boost index
    mapping(address => uint256) boostClaimReserve; // token => claimable boost reserves
    mapping(address => mapping(address => uint256)) userBoostIndex; // user => token => last boost index
    mapping(address => mapping(address => uint256)) userBoostAccrued; // user => token => accrued boost rewards
    address[] activeBoostTokens; // list of tokens that have been distributed
    mapping(address => uint256) boostTokenIndex; // token => index in activeBoostTokens array
  }

  // keccak256(abi.encode(uint256(keccak256("startale.storage.EarnVault")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant EARN_VAULT_STORAGE_LOCATION =
    0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;

  function _getEarnVaultStorage() internal pure returns (EarnVaultStorage storage $) {
    assembly {
      $.slot := EARN_VAULT_STORAGE_LOCATION
    }
  }

  /// @dev Get storage reference for internal use
  function _getStorage() internal pure returns (EarnVaultStorage storage) {
    return _getEarnVaultStorage();
  }
}
