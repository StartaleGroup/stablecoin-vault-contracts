// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {EarnVaultV2UpgradeChecks} from './EarnVaultV2UpgradeChecks.sol';
import {console} from 'forge-std/Script.sol';

/**
 * @title VerifyEarnVaultV2Upgrade
 * @notice READ-ONLY post-upgrade verification against the LIVE chain. Run after
 *         UpgradeEarnVaultToV2 has broadcast (whose own post-flight only checked the simulation).
 *         Never broadcasts anything. Also re-checks (as UpgradeEarnVaultToV2.preflight did
 *         pre-upgrade) that yieldRedistributor is a contract answering EarnVaultV2's JIT deposit
 *         lock getters - catches a setYieldRedistributor() call landing between broadcast and
 *         this verification.
 * @dev Env: EARN_VAULT_PROXY, EXPECTED_PROXY_ADMIN, EXPECTED_PROXY_ADMIN_OWNER, EXPECTED_IMPLEMENTATION,
 *      EXPECTED_IMPLEMENTATION_CODEHASH (keccak256 of the implementation's runtime code; required on
 *      Soneium mainnet, where the implementation must also embed the live BoostRewardsLib address),
 *      BOOST_KEEPER_ADDRESS, MAX_BOOST_PER_BATCH, and the expected roles EXPECTED_OWNER,
 *      EXPECTED_TREASURY, EXPECTED_YIELD_REDISTRIBUTOR, EXPECTED_PAUSER, EXPECTED_BOOST_REWARD_KEEPER.
 *      Usage: forge script script/upgrade/VerifyEarnVaultV2Upgrade.s.sol --rpc-url <rpc>  (no --broadcast)
 */
contract VerifyEarnVaultV2Upgrade is EarnVaultV2UpgradeChecks {
  function run() external view {
    address proxy = vm.envAddress('EARN_VAULT_PROXY');
    bytes32 expectedCodehash = vm.envOr('EXPECTED_IMPLEMENTATION_CODEHASH', bytes32(0));
    if (_isProductionScriptRun()) {
      require(expectedCodehash != bytes32(0), 'EXPECTED_IMPLEMENTATION_CODEHASH is required on Soneium');
    }
    verify(
      proxy,
      vm.envAddress('EXPECTED_PROXY_ADMIN'),
      vm.envAddress('EXPECTED_IMPLEMENTATION'),
      vm.envAddress('BOOST_KEEPER_ADDRESS'),
      vm.envUint('MAX_BOOST_PER_BATCH'),
      Roles({
        owner: vm.envAddress('EXPECTED_OWNER'),
        treasury: vm.envAddress('EXPECTED_TREASURY'),
        yieldRedistributor: vm.envAddress('EXPECTED_YIELD_REDISTRIBUTOR'),
        pauser: vm.envAddress('EXPECTED_PAUSER'),
        boostRewardKeeper: vm.envAddress('EXPECTED_BOOST_REWARD_KEEPER')
      }),
      expectedCodehash,
      vm.envAddress('EXPECTED_PROXY_ADMIN_OWNER')
    );
  }

  /// @dev Public so tests can drive it directly. `expectedCodehash` bytes32(0) and
  ///      `expectedAdminOwner` address(0) skip those two checks (tests only; run() always sets them).
  function verify(
    address proxy,
    address expectedAdmin,
    address expectedImpl,
    address keeper,
    uint256 cap,
    Roles memory expectedRoles,
    bytes32 expectedCodehash,
    address expectedAdminOwner
  ) public view {
    _requireV2Config(proxy, expectedAdmin, expectedImpl, keeper, cap);
    _requireV2Implementation(expectedImpl, expectedCodehash);
    if (expectedAdminOwner != address(0)) _requireProxyAdminOwner(expectedAdmin, expectedAdminOwner);
    _requireRoles(proxy, expectedRoles);
    _requireRedistributorSnapshotGetters(proxy);
    _requireUsdscOnlyBoostTokens(proxy);
    console.log('Live verification OK: EarnVaultV2 initialized with expected config and roles');
  }

  /// @dev Convenience overload without the codehash and ProxyAdmin-owner checks (tests only).
  function verify(
    address proxy,
    address expectedAdmin,
    address expectedImpl,
    address keeper,
    uint256 cap,
    Roles memory expectedRoles
  ) public view {
    verify(proxy, expectedAdmin, expectedImpl, keeper, cap, expectedRoles, bytes32(0), address(0));
  }
}
