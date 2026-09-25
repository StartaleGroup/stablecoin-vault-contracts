// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {EarnVaultV2UpgradeChecks} from './EarnVaultV2UpgradeChecks.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {console} from 'forge-std/Script.sol';

/**
 * @title UpgradeEarnVaultToV2
 * @notice Upgrades a live EarnVaultUpgradeable (V1) TransparentUpgradeableProxy to EarnVaultV2 in ONE
 *         ProxyAdmin.upgradeAndCall carrying initializeV2(boostKeeper).
 * @dev Env: EARN_VAULT_PROXY, EXPECTED_PROXY_ADMIN, BOOST_KEEPER_ADDRESS,
 *      DEPLOYER_PRIVATE_KEY (must be the ProxyAdmin owner), and optionally
 *      IMPLEMENTATION - a pre-deployed, explorer-verified EarnVaultV2 to upgrade to (recommended, so
 *      the wired bytecode is exactly the audited, verified bytecode). Without it a fresh
 *      implementation is deployed in the same run.
 * @dev Pre-flight refuses to send anything unless the proxy's ERC-1967 admin slot is exactly
 *      EXPECTED_PROXY_ADMIN (a UUPS-style or otherwise unexpected proxy fails here), the broadcaster
 *      owns that ProxyAdmin, and the proxy is still V1 at initialized version 1.
 * @dev IMPORTANT: forge script runs this locally (simulation) before broadcasting, so the
 *      post-flight here validates the SIMULATED state. After the broadcast lands, run
 *      VerifyEarnVaultV2Upgrade against the live chain.
 */
contract UpgradeEarnVaultToV2 is EarnVaultV2UpgradeChecks {
  struct V1Snapshot {
    Roles roles;
    uint256 totalPrincipal;
    uint256 claimReserve;
    uint256 globalIndex;
    bool paused;
  }

  struct Params {
    address proxy;
    address expectedAdmin;
    address keeper;
    address implementation; // address(0) => deploy a fresh EarnVaultV2
  }

  function run() external {
    Params memory p = Params({
      proxy: vm.envAddress('EARN_VAULT_PROXY'),
      expectedAdmin: vm.envAddress('EXPECTED_PROXY_ADMIN'),
      keeper: vm.envAddress('BOOST_KEEPER_ADDRESS'),
      implementation: vm.envOr('IMPLEMENTATION', address(0))
    });
    uint256 key = vm.envUint('DEPLOYER_PRIVATE_KEY');

    vm.startBroadcast(key);
    upgrade(p, vm.addr(key));
    vm.stopBroadcast();
  }

  /// @notice Pre-flight, upgrade, post-flight. `sender` is the account that will call the ProxyAdmin.
  /// @dev Public so tests can drive it directly against a local V1 proxy.
  function upgrade(Params memory p, address sender) public returns (address impl) {
    V1Snapshot memory before = preflight(p, sender);

    impl = p.implementation == address(0) ? address(new EarnVaultV2()) : p.implementation;
    ProxyAdmin(p.expectedAdmin)
      .upgradeAndCall(ITransparentUpgradeableProxy(p.proxy), impl, abi.encodeCall(EarnVaultV2.initializeV2, (p.keeper)));
    console.log('Upgraded to EarnVaultV2 implementation:', impl);

    postflight(p, impl, before);
  }

  function preflight(Params memory p, address sender) public view returns (V1Snapshot memory snap) {
    require(p.proxy != address(0) && p.expectedAdmin != address(0), 'proxy/admin not set');
    require(p.keeper != address(0), 'BOOST_KEEPER_ADDRESS not set');
    require(_admin(p.proxy) == p.expectedAdmin, 'ERC-1967 admin slot != EXPECTED_PROXY_ADMIN');
    require(ProxyAdmin(p.expectedAdmin).owner() == sender, 'sender does not own the ProxyAdmin');
    if (p.implementation != address(0)) _requireV2Implementation(p.implementation);

    EarnVaultV2 v = EarnVaultV2(payable(p.proxy));
    require(keccak256(bytes(v.getVersion())) == keccak256('EarnVaultV1'), 'proxy is not on EarnVaultV1');
    require(_initializedVersion(p.proxy) == 1, 'unexpected initialized version (expected 1)');

    snap = V1Snapshot({
      roles: _readRoles(p.proxy),
      totalPrincipal: v.totalPrincipal(),
      claimReserve: v.claimReserve(),
      globalIndex: v.globalIndex(),
      paused: v.paused()
    });
    console.log('Pre-flight OK. proxy / admin:', p.proxy, p.expectedAdmin);
  }

  function postflight(Params memory p, address impl, V1Snapshot memory before) public view {
    _requireV2Config(p.proxy, p.expectedAdmin, impl, p.keeper);
    _requireRoles(p.proxy, before.roles);

    EarnVaultV2 v = EarnVaultV2(payable(p.proxy));
    require(v.totalPrincipal() == before.totalPrincipal, 'totalPrincipal changed');
    require(v.claimReserve() == before.claimReserve, 'claimReserve changed');
    require(v.globalIndex() == before.globalIndex, 'globalIndex changed');
    require(v.paused() == before.paused, 'paused changed');
    console.log('Post-flight OK (simulated): V2 initialized, V1 state and roles unchanged');
    console.log('Now run VerifyEarnVaultV2Upgrade against the live chain.');
  }
}
