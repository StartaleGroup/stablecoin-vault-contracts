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
    _verifyDeployment();
    _logPostDeploymentState();
  }

  // Helper: Read ProxyAdmin owner
  function _readProxyAdminOwner() internal view returns (address proxyAdminContract, address actualOwner) {
    // ERC1967 admin slot: keccak256("eip1967.proxy.admin") - 1
    bytes32 ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    proxyAdminContract = address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));
    // ProxyAdmin's owner() is stored in the first slot (inherited from Ownable)
    actualOwner = address(uint160(uint256(vm.load(proxyAdminContract, bytes32(0)))));
  }

  // Verify deployment
  function _verifyDeployment() internal view {
    console.log('\n=== Post-Deployment Verification ===');

    require(keccak256(bytes(susdscVault.name())) == keccak256(bytes('Staked USDSC')), 'Vault name mismatch');
    console.log('sUSDSC name Staked USDSC: OK');
    require(keccak256(bytes(susdscVault.symbol())) == keccak256(bytes('sUSDSC')), 'Vault symbol mismatch');
    console.log('sUSDSC symbol: OK');
    require(susdscVault.decimals() == 6, 'Vault decimals mismatch');
    console.log('sUSDSC decimals: OK');
    require(susdscVault.totalAssets() == 0, 'Vault total assets mismatch');
    console.log('Total USDSC in vault = 0: OK');
    require(susdscVault.totalSupply() == 0, 'Vault total supply mismatch');
    console.log('sUSDSC total supply: OK');
    require(susdscVault.paused() == false, 'Vault paused mismatch');
    console.log('sUSDSC paused: OK');

    // Verify roles
    bytes32 adminRole = susdscVault.DEFAULT_ADMIN_ROLE();
    require(susdscVault.hasRole(adminRole, adminAddress), 'Admin role not granted');
    console.log('Admin DEFAULT_ADMIN_ROLE: OK');

    bytes32 pauserRole = susdscVault.PAUSER_ROLE();
    require(susdscVault.hasRole(pauserRole, pauserAddress), 'Pauser role not granted');
    console.log('Pauser PAUSER_ROLE: OK');

    require(address(susdscVault.asset()) == usdscAddress, 'Asset address mismatch');
    console.log('Asset Address: OK');

    // Verify ProxyAdmin owner
    (, address actualProxyAdminOwner) = _readProxyAdminOwner();
    require(actualProxyAdminOwner == proxyAdminOwner, 'ProxyAdmin owner mismatch');
    console.log('ProxyAdmin Owner: OK');

    console.log('\n=== All Verifications Passed ===');
  }

  // Post-deployment state logging
  function _logPostDeploymentState() internal view {
    console.log('\n=== Deployment Summary ===');
    console.log('Contract: SUSDSCVaultUpgradable');
    console.log('Implementation:', address(implementation));
    console.log('Proxy:', address(susdscVault));

    console.log('\n--- Initialize Parameters ---');
    console.log('Asset (USDSC):', address(susdscVault.asset()));

    console.log('\n--- ERC20/ERC4626 State ---');
    console.log('Name:', susdscVault.name());
    console.log('Symbol:', susdscVault.symbol());
    console.log('sUSDSC Decimals:', susdscVault.decimals());
    console.log('Total USDSC in vault:', susdscVault.totalAssets());
    console.log('Total sUSDSC Supply:', susdscVault.totalSupply());

    console.log('\n--- Roles ---');
    bytes32 adminRole = susdscVault.DEFAULT_ADMIN_ROLE();
    bytes32 pauserRole = susdscVault.PAUSER_ROLE();

    console.log('DEFAULT_ADMIN_ROLE:');
    console.logBytes32(adminRole);
    console.log('  Admin address:', adminAddress);
    console.log('  Admin has role:', susdscVault.hasRole(adminRole, adminAddress));

    console.log('PAUSER_ROLE:');
    console.logBytes32(pauserRole);
    console.log('  Pauser address:', pauserAddress);
    console.log('  Pauser has role:', susdscVault.hasRole(pauserRole, pauserAddress));

    console.log('\n--- Proxy Configuration ---');
    (address proxyAdminContract, address actualProxyAdminOwner) = _readProxyAdminOwner();
    console.log('ProxyAdmin Contract:', proxyAdminContract);
    console.log('ProxyAdmin Owner:', actualProxyAdminOwner);

    console.log('\n--- Contract State ---');
    console.log('Paused:', susdscVault.paused());
  }
}
