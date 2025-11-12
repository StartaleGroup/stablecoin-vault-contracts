// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {SUSDSCVaultUpgradable} from '../../src/vaults/4626/SUSDSCVaultUpgradable.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {DeployHelpers} from 'common/script/deploy/DeployHelpers.sol';
import {Script, console} from 'forge-std/Script.sol';

/**
 * @title DeploySUSDSCVaultUpgradeable
 * @notice Deployment script for SUSDSCVaultUpgradable contract using CREATE3 for deterministic addresses
 */
contract DeploySUSDSCVaultUpgradeable is Script, DeployHelpers {
  // Environment variables
  address usdscAddress;
  address adminAddress;
  address pauserAddress;
  address proxyAdminOwner;

  // Deployment artifacts
  SUSDSCVaultUpgradable public implementation;
  TransparentUpgradeableProxy public proxy;
  SUSDSCVaultUpgradable public susdscVault;

  // Salt for CREATE3 deployment
  string public constant IMPLEMENTATION_NAME = 'SUSDSCVaultUpgradeable_Implementation_112025';
  string public constant PROXY_NAME = 'SUSDSCVaultUpgradeable_Proxy_112025';

  function setUp() public {
    // Load environment variables
    usdscAddress = vm.envAddress('USDSC_ADDRESS');
    adminAddress = vm.envAddress('ADMIN_ADDRESS');
    pauserAddress = vm.envAddress('PAUSER_ADDRESS');

    // ProxyAdmin owner - defaults to admin if not set
    proxyAdminOwner = vm.envOr('PROXY_ADMIN_OWNER', adminAddress);

    // Validate addresses
    require(usdscAddress != address(0), 'USDSC_ADDRESS not set');
    require(adminAddress != address(0), 'ADMIN_ADDRESS not set');
    require(pauserAddress != address(0), 'PAUSER_ADDRESS not set');
    require(proxyAdminOwner != address(0), 'PROXY_ADMIN_OWNER not set');

    console.log('=== Deployment Configuration ===');
    console.log('USDSC Address:', usdscAddress);
    console.log('Admin Address:', adminAddress);
    console.log('Pauser Address:', pauserAddress);
    console.log('ProxyAdmin Owner:', proxyAdminOwner);
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint('DEPLOYER_PRIVATE_KEY');
    address deployer = vm.addr(deployerPrivateKey);

    console.log('\n=== Starting Deployment ===');
    console.log('Deployer address:', deployer);

    // Compute salts for CREATE3
    bytes32 implSalt = _computeSalt(deployer, IMPLEMENTATION_NAME);
    bytes32 proxySalt = _computeSalt(deployer, PROXY_NAME);

    console.log('Implementation salt:');
    console.logBytes32(implSalt);
    console.log('Proxy salt:');
    console.logBytes32(proxySalt);

    vm.startBroadcast(deployerPrivateKey);

    // Step 1: Deploy implementation using CREATE3
    bytes memory implCreationCode = type(SUSDSCVaultUpgradable).creationCode;
    address deployedImplAddress = _deployCreate3(implCreationCode, implSalt);
    implementation = SUSDSCVaultUpgradable(payable(deployedImplAddress));

    // Step 2: Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(
      SUSDSCVaultUpgradable.initialize.selector, IERC20(usdscAddress), adminAddress, pauserAddress
    );

    // Step 3: Deploy proxy using CREATE3
    bytes memory proxyCreationCode = abi.encodePacked(
      type(TransparentUpgradeableProxy).creationCode, abi.encode(address(implementation), proxyAdminOwner, initData)
    );

    address deployedProxyAddress = _deployCreate3(proxyCreationCode, proxySalt);
    proxy = TransparentUpgradeableProxy(payable(deployedProxyAddress));
    susdscVault = SUSDSCVaultUpgradable(payable(deployedProxyAddress));

    console.log('\n=== Deployment Successful ===');
    console.log('SUSDSCVaultUpgradeable Implementation:', address(implementation));
    console.log('SUSDSCVaultUpgradeable Proxy (SUSDSCVault):', address(susdscVault));

    vm.stopBroadcast();
    _logPostDeploymentState();
  }

  // Post-deployment verification
  function _logPostDeploymentState() internal view {
    console.log('\n=== Post-Deployment Verification ===');
    console.log('Vault Name:', susdscVault.name());
    console.log('Vault Symbol:', susdscVault.symbol());
    // console.log('Total Assets:', susdscVault.totalAssets());
    // console.log('Total Supply:', susdscVault.totalSupply());
  }
}
