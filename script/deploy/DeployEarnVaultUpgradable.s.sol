// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {DeployHelpers} from 'common/script/deploy/DeployHelpers.sol';
import {Script, console} from 'forge-std/Script.sol';

/**
 * @title DeployEarnVaultUpgradeable
 * @notice Deployment script for EarnVaultUpgradeable contract using CREATE3 for deterministic addresses
 */
contract DeployEarnVaultUpgradeable is Script, DeployHelpers {
  // Environment variables
  address usdscAddress;
  address ownerAddress;
  address yieldRedistributorAddress;
  address treasuryAddress;
  address pauserAddress;
  address proxyAdminOwner;
  address boostRewardKeeperAddress;

  // Deployment artifacts
  EarnVaultUpgradeable public implementation;
  TransparentUpgradeableProxy public proxy;
  EarnVaultUpgradeable public earnVault;

  // Salt for CREATE3 deployment
  string public constant IMPLEMENTATION_NAME = 'EarnVaultUpgradeable_Implementation_112025';
  string public constant PROXY_NAME = 'EarnVaultUpgradeable_Proxy_112025';

  function setUp() public {
    // Load environment variables
    usdscAddress = vm.envAddress('USDSC_ADDRESS');
    ownerAddress = vm.envAddress('OWNER_ADDRESS');
    yieldRedistributorAddress = vm.envAddress('YIELD_REDISTRIBUTOR_ADDRESS');
    treasuryAddress = vm.envAddress('TREASURY_ADDRESS');
    pauserAddress = vm.envAddress('PAUSER_ADDRESS');
    boostRewardKeeperAddress = vm.envAddress('BOOST_REWARD_KEEPER_ADDRESS');

    // ProxyAdmin owner - defaults to owner if not set
    proxyAdminOwner = vm.envOr('PROXY_ADMIN_OWNER', ownerAddress);

    // Validate addresses
    require(usdscAddress != address(0), 'USDSC_ADDRESS not set');
    require(ownerAddress != address(0), 'OWNER_ADDRESS not set');
    require(yieldRedistributorAddress != address(0), 'YIELD_REDISTRIBUTOR_ADDRESS not set');
    require(treasuryAddress != address(0), 'TREASURY_ADDRESS not set');
    require(pauserAddress != address(0), 'PAUSER_ADDRESS not set');
    require(proxyAdminOwner != address(0), 'PROXY_ADMIN_OWNER not set');
    require(boostRewardKeeperAddress != address(0), 'BOOST_REWARD_KEEPER_ADDRESS not set');

    console.log('=== Deployment Configuration ===');
    console.log('USDSC Address:', usdscAddress);
    console.log('Owner Address:', ownerAddress);
    console.log('Yield Redistributor Address:', yieldRedistributorAddress);
    console.log('Treasury Address:', treasuryAddress);
    console.log('Pauser Address:', pauserAddress);
    console.log('ProxyAdmin Owner:', proxyAdminOwner);
    console.log('Boost Reward Keeper Address:', boostRewardKeeperAddress);
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
    bytes memory implCreationCode = type(EarnVaultUpgradeable).creationCode;
    address deployedImplAddress = _deployCreate3(implCreationCode, implSalt);
    implementation = EarnVaultUpgradeable(payable(deployedImplAddress));

    // Step 2: Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      usdscAddress,
      ownerAddress,
      yieldRedistributorAddress,
      treasuryAddress,
      pauserAddress,
      boostRewardKeeperAddress
    );

    // Step 3: Deploy proxy using CREATE3
    bytes memory proxyCreationCode = abi.encodePacked(
      type(TransparentUpgradeableProxy).creationCode, abi.encode(address(implementation), proxyAdminOwner, initData)
    );

    address deployedProxyAddress = _deployCreate3(proxyCreationCode, proxySalt);
    proxy = TransparentUpgradeableProxy(payable(deployedProxyAddress));
    earnVault = EarnVaultUpgradeable(payable(deployedProxyAddress));

    console.log('\n=== Deployment Successful ===');
    console.log('EarnVaultUpgradeable Implementation:', address(implementation));
    console.log('EarnVaultUpgradeable Proxy (EarnVault):', address(earnVault));

    vm.stopBroadcast();

    _logPostDeploymentState();
  }

  // Post-deployment verification
  function _logPostDeploymentState() internal view {
    console.log('\n=== Post-Deployment State ===');
    console.log('Total Principal:', earnVault.totalPrincipal());
    console.log('Global Index:', earnVault.globalIndex());
    console.log('Claim Reserve:', earnVault.claimReserve());
    console.log('Owner:', earnVault.owner());
  }
}
