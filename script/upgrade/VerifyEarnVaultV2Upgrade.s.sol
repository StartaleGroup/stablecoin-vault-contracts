// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {EarnVaultV2UpgradeChecks} from './EarnVaultV2UpgradeChecks.sol';
import {console} from 'forge-std/Script.sol';

/**
 * @title VerifyEarnVaultV2Upgrade
 * @notice READ-ONLY post-upgrade verification against the LIVE chain. Run after
 *         UpgradeEarnVaultToV2 has broadcast (whose own post-flight only checked the simulation).
 *         Never broadcasts anything.
 * @dev Env: EARN_VAULT_PROXY, EXPECTED_PROXY_ADMIN, EXPECTED_IMPLEMENTATION, BOOST_KEEPER_ADDRESS,
 *      and the expected roles EXPECTED_OWNER,
 *      EXPECTED_TREASURY, EXPECTED_YIELD_REDISTRIBUTOR, EXPECTED_PAUSER, EXPECTED_BOOST_REWARD_KEEPER.
 *      Usage: forge script script/upgrade/VerifyEarnVaultV2Upgrade.s.sol --rpc-url <rpc>  (no --broadcast)
 */
contract VerifyEarnVaultV2Upgrade is EarnVaultV2UpgradeChecks {
  function run() external view {
    address proxy = vm.envAddress('EARN_VAULT_PROXY');
    verify(
      proxy,
      vm.envAddress('EXPECTED_PROXY_ADMIN'),
      vm.envAddress('EXPECTED_IMPLEMENTATION'),
      vm.envAddress('BOOST_KEEPER_ADDRESS'),
      Roles({
        owner: vm.envAddress('EXPECTED_OWNER'),
        treasury: vm.envAddress('EXPECTED_TREASURY'),
        yieldRedistributor: vm.envAddress('EXPECTED_YIELD_REDISTRIBUTOR'),
        pauser: vm.envAddress('EXPECTED_PAUSER'),
        boostRewardKeeper: vm.envAddress('EXPECTED_BOOST_REWARD_KEEPER')
      })
    );
  }

  /// @dev Public so tests can drive it directly.
  function verify(
    address proxy,
    address expectedAdmin,
    address expectedImpl,
    address keeper,
    Roles memory expectedRoles
  ) public view {
    _requireV2Config(proxy, expectedAdmin, expectedImpl, keeper);
    _requireRoles(proxy, expectedRoles);
    console.log('Live verification OK: EarnVaultV2 initialized with expected config and roles');
  }
}
