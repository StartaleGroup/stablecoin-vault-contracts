// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';

/// @title EarnVaultUpgradeableHarness
/// @notice Harness contract for testing EarnVaultUpgradeable proxy functionality
/// @dev Adds utility functions to access proxy storage slots for testing
contract EarnVaultUpgradeableHarness is EarnVaultUpgradeable {
  // ERC1967 storage slots
  bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
  bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

  /// @notice Get the implementation address from proxy storage
  /// @return impl The implementation address
  function getImplementation() external view returns (address impl) {
    bytes32 slot = _IMPLEMENTATION_SLOT;
    assembly {
      impl := sload(slot)
    }
  }

  /// @notice Get the admin address from proxy storage
  /// @return adm The admin address
  function getAdmin() external view returns (address adm) {
    bytes32 slot = _ADMIN_SLOT;
    assembly {
      adm := sload(slot)
    }
  }
}
