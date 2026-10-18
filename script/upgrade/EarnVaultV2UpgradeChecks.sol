// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {Script} from 'forge-std/Script.sol';

/**
 * @title EarnVaultV2UpgradeChecks
 * @notice Shared read-only checks for the EarnVault V1 -> V2 upgrade, used by both
 *         UpgradeEarnVaultToV2 (simulated post-flight) and VerifyEarnVaultV2Upgrade (live chain).
 */
abstract contract EarnVaultV2UpgradeChecks is Script {
  bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
  bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
  // OZ v5 Initializable ERC-7201 slot; `_initialized` (uint64) is its low 8 bytes
  bytes32 internal constant OZ_INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
  // EarnVault V1 ERC-7201 base (same constant DeployEarnVaultUpgradable.s.sol uses); boostRewardKeeper
  // is at offset 2 and has no public getter
  bytes32 internal constant EARN_VAULT_STORAGE_LOCATION =
    0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;

  /// @dev Role/config addresses whose silent change across an upgrade would matter most.
  struct Roles {
    address owner;
    address treasury;
    address yieldRedistributor;
    address pauser;
    address boostRewardKeeper;
  }

  function _admin(address proxy) internal view returns (address) {
    return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
  }

  function _implementation(address proxy) internal view returns (address) {
    return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
  }

  function _initializedVersion(address proxy) internal view returns (uint64) {
    return uint64(uint256(vm.load(proxy, OZ_INITIALIZABLE_SLOT)));
  }

  function _boostRewardKeeper(address proxy) internal view returns (address) {
    return address(uint160(uint256(vm.load(proxy, bytes32(uint256(EARN_VAULT_STORAGE_LOCATION) + 2)))));
  }

  function _readRoles(address proxy) internal view returns (Roles memory r) {
    EarnVaultV2 v = EarnVaultV2(payable(proxy));
    r = Roles({
      owner: v.owner(),
      treasury: v.treasury(),
      yieldRedistributor: v.yieldRedistributor(),
      pauser: v.pauser(),
      boostRewardKeeper: _boostRewardKeeper(proxy)
    });
  }

  function _requireRoles(address proxy, Roles memory expected) internal view {
    Roles memory actual = _readRoles(proxy);
    require(actual.owner == expected.owner, 'owner mismatch');
    require(actual.treasury == expected.treasury, 'treasury mismatch');
    require(actual.yieldRedistributor == expected.yieldRedistributor, 'yieldRedistributor mismatch');
    require(actual.pauser == expected.pauser, 'pauser mismatch');
    require(actual.boostRewardKeeper == expected.boostRewardKeeper, 'boostRewardKeeper mismatch');
  }

  /// @dev A candidate implementation must have code and report itself as EarnVaultV2.
  function _requireV2Implementation(address impl) internal view {
    require(impl.code.length > 0, 'IMPLEMENTATION has no code');
    require(
      keccak256(bytes(EarnVaultV2(payable(impl)).getVersion())) == keccak256('EarnVaultV2'),
      'IMPLEMENTATION is not EarnVaultV2'
    );
  }

  /// @dev Confirms the proxy's `yieldRedistributor()` is a CONTRACT that answers both snapshot
  ///      getters EarnVaultV2's JIT deposit lock depends on (see
  ///      IRewardRedistributorSnapshot.sol / EarnVaultV2._depositLockState()). An EOA
  ///      redistributor makes the lock permanently fail-open (no snapshot to respect ever
  ///      blocks a deposit); a contract redistributor that doesn't implement the getters makes
  ///      EVERY deposit revert post-upgrade (fail-closed). Both are upgrade-time misconfigurations
  ///      worth refusing to send, so this uses raw staticcall (not a Solidity interface call)
  ///      purely to produce the specific require message below instead of an opaque low-level
  ///      revert.
  function _requireRedistributorSnapshotGetters(address proxy) internal view {
    address rr = EarnVaultV2(payable(proxy)).yieldRedistributor();
    require(rr.code.length > 0, 'yieldRedistributor has no code');

    (bool ok1, bytes memory data1) = rr.staticcall(abi.encodeWithSignature('lastSnapshotTimestamp()'));
    (bool ok2, bytes memory data2) = rr.staticcall(abi.encodeWithSignature('snapshotMaxAge()'));
    require(ok1 && ok2 && data1.length == 32 && data2.length == 32, 'yieldRedistributor missing snapshot getters');
  }

  /// @dev EarnVault accepts only USDSC as a boost reward token, and boost tokens can no longer be
  ///      removed. Refuse to upgrade a vault that has any other boost token registered: its holders
  ///      could otherwise never be paid. Reads activeBoostTokens (struct field 18, no V1 getter).
  function _requireUsdscOnlyBoostTokens(address proxy) internal view {
    bytes32 arraySlot = bytes32(uint256(EARN_VAULT_STORAGE_LOCATION) + 18);
    uint256 length = uint256(vm.load(proxy, arraySlot));
    require(length <= 1, 'more than one boost token registered');
    if (length == 1) {
      address token = address(uint160(uint256(vm.load(proxy, keccak256(abi.encode(arraySlot))))));
      require(token == EarnVaultV2(payable(proxy)).asset(), 'a boost token other than USDSC is registered');
    }
  }

  /// @dev The upgraded proxy: expected implementation and admin, V2, initialized (version 2), config.
  function _requireV2Config(
    address proxy,
    address expectedAdmin,
    address expectedImpl,
    address keeper,
    uint256 cap
  ) internal view {
    EarnVaultV2 v = EarnVaultV2(payable(proxy));
    require(_implementation(proxy) == expectedImpl, 'implementation slot mismatch');
    require(_admin(proxy) == expectedAdmin, 'admin slot mismatch');
    require(keccak256(bytes(v.getVersion())) == keccak256('EarnVaultV2'), 'version is not EarnVaultV2');
    require(_initializedVersion(proxy) == 2, 'initializeV2 did not run (version != 2)');
    require(v.boostKeeper() == keeper, 'boostKeeper mismatch');
    require(v.maxBoostPerBatch() == cap, 'maxBoostPerBatch mismatch');
  }
}
