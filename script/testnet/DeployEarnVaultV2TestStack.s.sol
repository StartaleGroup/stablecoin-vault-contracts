// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IEarnVault} from '../../src/interfaces/vaults/earn/IEarnVault.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {TestSnapshotRedistributor} from './TestSnapshotRedistributor.sol';
import {TestUSDSC} from './TestUSDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {
  ITransparentUpgradeableProxy,
  TransparentUpgradeableProxy
} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {DeployHelpers} from 'common/script/deploy/DeployHelpers.sol';
import {Script, console} from 'forge-std/Script.sol';

/**
 * @title DeployEarnVaultV2TestStack
 * @notice TEST DEPLOYMENTS ONLY. Deploys a complete, self-contained EarnVaultV2 stack for backend,
 *         keeper and indexer integration - the same V1-proxy -> upgradeAndCall(initializeV2) path
 *         production uses, so integrators test against the real upgrade result:
 *           TestUSDSC (open faucet; skipped if USDSC_ADDRESS is set) -> TestSnapshotRedistributor ->
 *           EarnVaultUpgradeable impl + TransparentUpgradeableProxy -> EarnVaultV2 impl ->
 *           ProxyAdmin.upgradeAndCall(initializeV2(boostKeeper, maxBoostPerBatch)).
 * @dev "Fake salts": every CREATE3 salt name is prefixed `TEST_` and suffixed with TEST_SALT_TAG.
 *      DeployHelpers salts are keccak(name) + deployer with cross-chain redeploy protection OFF, so the
 *      production names would yield the PRODUCTION addresses on any chain for the same deployer key.
 *      A distinct tag guarantees test addresses can never collide with, or be mistaken for, them.
 * @dev Every env var is TEST_-prefixed ON PURPOSE: forge auto-loads `.env`, which holds the
 *      PRODUCTION values (owner = the production Safe, USDSC address, deployer key). Unprefixed names
 *      would silently pull those into a test deployment.
 *      Env (required): TEST_DEPLOYER_PRIVATE_KEY, TEST_SALT_TAG (e.g. "20261005").
 *      Env (optional, default = test deployer): TEST_OWNER_ADDRESS, TEST_TREASURY_ADDRESS,
 *      TEST_PAUSER_ADDRESS, TEST_BOOST_REWARD_KEEPER_ADDRESS, TEST_BOOST_KEEPER_ADDRESS,
 *      TEST_REDISTRIBUTOR_OPERATOR.
 *      Env (optional): TEST_USDSC_ADDRESS (reuse a token instead of deploying TestUSDSC; must have
 *      code), TEST_MAX_BOOST_PER_BATCH (default 50,000e6), TEST_SNAPSHOT_MAX_AGE (default 60 s),
 *      ALLOW_SONEIUM_MAINNET_TEST=true to allow chain 1868.
 *      The ProxyAdmin stays owned by the deployer (test stack). The vault owner is OWNER_ADDRESS.
 */
contract DeployEarnVaultV2TestStack is Script, DeployHelpers {
  struct Config {
    address deployer;
    string tag;
    address owner;
    address treasury;
    address pauser;
    address boostRewardKeeper;
    address boostKeeper;
    address operator;
    address usdsc; // address(0) => deploy TestUSDSC
    uint256 maxBoostPerBatch;
    uint256 snapshotMaxAge;
  }

  struct Deployed {
    address usdsc;
    address redistributor;
    address v1Implementation;
    address proxy;
    address proxyAdmin;
    address v2Implementation;
  }

  bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

  function run() external {
    uint256 key = vm.envUint('TEST_DEPLOYER_PRIVATE_KEY');
    address deployer = vm.addr(key);
    Config memory c = Config({
      deployer: deployer,
      tag: vm.envString('TEST_SALT_TAG'),
      owner: vm.envOr('TEST_OWNER_ADDRESS', deployer),
      treasury: vm.envOr('TEST_TREASURY_ADDRESS', deployer),
      pauser: vm.envOr('TEST_PAUSER_ADDRESS', deployer),
      boostRewardKeeper: vm.envOr('TEST_BOOST_REWARD_KEEPER_ADDRESS', deployer),
      boostKeeper: vm.envOr('TEST_BOOST_KEEPER_ADDRESS', deployer),
      operator: vm.envOr('TEST_REDISTRIBUTOR_OPERATOR', deployer),
      usdsc: vm.envOr('TEST_USDSC_ADDRESS', address(0)),
      maxBoostPerBatch: vm.envOr('TEST_MAX_BOOST_PER_BATCH', uint256(50_000e6)),
      snapshotMaxAge: vm.envOr('TEST_SNAPSHOT_MAX_AGE', uint256(60))
    });
    if (block.chainid == 1868) {
      require(vm.envOr('ALLOW_SONEIUM_MAINNET_TEST', false), 'chain 1868: set ALLOW_SONEIUM_MAINNET_TEST=true');
    }

    vm.startBroadcast(key);
    Deployed memory d = deploy(c);
    vm.stopBroadcast();

    _log(c, d);
  }

  /// @notice Deploys and wires the whole stack. Must be called with `c.deployer` as the sender of
  ///         every call (it owns the ProxyAdmin it creates, then calls upgradeAndCall on it).
  /// @dev Public so tests can drive it directly.
  function deploy(Config memory c) public returns (Deployed memory d) {
    require(bytes(c.tag).length > 0, 'TEST_SALT_TAG not set');
    require(c.maxBoostPerBatch > 0, 'MAX_BOOST_PER_BATCH must be non-zero');

    if (c.usdsc != address(0)) require(c.usdsc.code.length > 0, 'TEST_USDSC_ADDRESS has no code on this chain');
    d.usdsc = c.usdsc == address(0) ? _deployCreate3(type(TestUSDSC).creationCode, _salt(c, 'TestUSDSC')) : c.usdsc;

    // The redistributor needs the vault address and the vault needs the redistributor address at
    // initialize(): CREATE3 makes the proxy address known before it exists.
    bytes32 proxySalt = _salt(c, 'EarnVault_Proxy');
    address predictedProxy = _getCreate3Address(c.deployer, proxySalt);

    d.redistributor = _deployCreate3(
      abi.encodePacked(
        type(TestSnapshotRedistributor).creationCode,
        abi.encode(IERC20(d.usdsc), IEarnVault(predictedProxy), c.operator, c.snapshotMaxAge)
      ),
      _salt(c, 'TestSnapshotRedistributor')
    );

    d.v1Implementation = _deployCreate3(type(EarnVaultUpgradeable).creationCode, _salt(c, 'EarnVaultV1_Impl'));
    bytes memory initData = abi.encodeCall(
      EarnVaultUpgradeable.initialize, (d.usdsc, c.owner, d.redistributor, c.treasury, c.pauser, c.boostRewardKeeper)
    );
    d.proxy = _deployCreate3(
      abi.encodePacked(
        type(TransparentUpgradeableProxy).creationCode, abi.encode(d.v1Implementation, c.deployer, initData)
      ),
      proxySalt
    );
    require(d.proxy == predictedProxy, 'proxy address != CREATE3 prediction');
    d.proxyAdmin = address(uint160(uint256(vm.load(d.proxy, ADMIN_SLOT))));

    d.v2Implementation = _deployCreate3(type(EarnVaultV2).creationCode, _salt(c, 'EarnVaultV2_Impl'));
    ProxyAdmin(d.proxyAdmin)
      .upgradeAndCall(
        ITransparentUpgradeableProxy(d.proxy),
        d.v2Implementation,
        abi.encodeCall(EarnVaultV2.initializeV2, (c.boostKeeper, c.maxBoostPerBatch))
      );

    _check(c, d);
  }

  /// @dev `TEST_<name>_<tag>` - never equal to a production salt name.
  function _salt(Config memory c, string memory name) internal pure returns (bytes32) {
    return _computeSalt(c.deployer, string.concat('TEST_', name, '_', c.tag));
  }

  function _check(Config memory c, Deployed memory d) internal view {
    EarnVaultV2 v = EarnVaultV2(payable(d.proxy));
    require(keccak256(bytes(v.getVersion())) == keccak256('EarnVaultV2'), 'not EarnVaultV2');
    require(v.boostKeeper() == c.boostKeeper, 'boostKeeper mismatch');
    require(v.maxBoostPerBatch() == c.maxBoostPerBatch, 'maxBoostPerBatch mismatch');
    require(v.yieldRedistributor() == d.redistributor, 'yieldRedistributor mismatch');
    require(v.owner() == c.owner, 'owner mismatch');
    require(v.asset() == d.usdsc, 'asset mismatch');
    require(address(TestSnapshotRedistributor(d.redistributor).earnVault()) == d.proxy, 'redistributor vault mismatch');
    require(d.v2Implementation.code.length <= 24_576, 'EarnVaultV2 exceeds EIP-170');
  }

  function _log(Config memory c, Deployed memory d) internal view {
    console.log('=== EarnVaultV2 TEST stack (chain id, salt tag) ===');
    console.log(block.chainid, c.tag);
    console.log('USDSC (test token)        :', d.usdsc);
    console.log('EarnVault proxy (V2)      :', d.proxy);
    console.log('ProxyAdmin (owner=deployer):', d.proxyAdmin);
    console.log('EarnVaultV1 implementation:', d.v1Implementation);
    console.log('EarnVaultV2 implementation:', d.v2Implementation);
    console.log('TestSnapshotRedistributor :', d.redistributor);
    console.log('vault owner / boostKeeper :', c.owner, c.boostKeeper);
    console.log('redistributor operator    :', c.operator);
    console.log('maxBoostPerBatch / snapshotMaxAge:', c.maxBoostPerBatch, c.snapshotMaxAge);
  }
}
