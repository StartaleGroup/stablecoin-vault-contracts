// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {ERC1967Utils} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol';

/// @title EarnVaultV3FromV2 - rehearsal of the next upgrade on top of the current EarnVaultV2
/// @notice Test-only. Inherits EarnVaultV2 as it stands, so the upgrade-path tests keep exercising
///         whatever V2 becomes. It follows the pattern a real V3 should use:
///         - new state only in its own ERC-7201 namespace (EarnVaultV2's and the base layout untouched);
///         - one reinitializer(3), accepted only from the ProxyAdmin inside upgradeAndCall, like
///           initializeV2;
///         - optionally retiring onBoostReward by clearing boostRewardKeeper. onBoostCredit, its
///           keeper and the boost rewards users are already owed are unaffected.
contract EarnVaultV3FromV2 is EarnVaultV2 {
  /// @custom:storage-location erc7201:startale.storage.EarnVaultV3
  struct EarnVaultV3Storage {
    uint256 newSetting;
  }

  /// @dev keccak256(abi.encode(uint256(keccak256("startale.storage.EarnVaultV3")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 public constant EARN_VAULT_V3_STORAGE_LOCATION =
    0xf0fd3710f09ba476745928f43ccace66ed2146a91f7d5681f9a8ff07e0a5da00;

  function _getV3Storage() private pure returns (EarnVaultV3Storage storage $$$) {
    assembly {
      $$$.slot := EARN_VAULT_V3_STORAGE_LOCATION
    }
  }

  /// @param initialNewSetting Stand-in for whatever new state V3 introduces
  /// @param retireBoostReward Clear boostRewardKeeper, so onBoostReward can no longer be called. The
  ///        owner can still re-enable it with setBoostRewardKeeper.
  function initializeV3(uint256 initialNewSetting, bool retireBoostReward) public reinitializer(3) {
    if (msg.sender != ERC1967Utils.getAdmin()) revert NotProxyAdmin();
    _getV3Storage().newSetting = initialNewSetting;
    if (retireBoostReward) {
      EarnVaultStorage storage $ = _getStorage();
      emit BoostRewardKeeperChanged(msg.sender, $.boostRewardKeeper, address(0));
      $.boostRewardKeeper = address(0);
    }
  }

  function newSetting() external view returns (uint256) {
    return _getV3Storage().newSetting;
  }

  function getVersion() external pure virtual override returns (string memory) {
    return 'EarnVaultV3';
  }
}
