// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {DeployHelpers} from './DeployHelpers.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script, console} from 'forge-std/Script.sol';

/**
 * @title DeployEarnVaultUpgradeable
 * @notice Deployment script for EarnVaultUpgradeable contract using CREATE3 for deterministic addresses
 * @dev Usage:
 *      forge script script/deploy/DeployEarnVaultUpgradable.s.sol:DeployEarnVaultUpgradeable \
 *          --rpc-url $SEP_RPC \
 *          --broadcast \
 *          --verify \
 *          -vvvv
 */
contract DeployEarnVaultUpgradeable is Script, DeployHelpers {
  // Environment variables
  address usdscAddress;
  address ownerAddress;
  address yieldRedistributorAddress;
  address treasuryAddress;
  address pauserAddress;
  address proxyAdminOwner;

  // Deployment artifacts
  EarnVaultUpgradeable public implementation;
  TransparentUpgradeableProxy public proxy;
  EarnVaultUpgradeable public earnVault;

  // Salt for CREATE3 deployment
  string public constant IMPLEMENTATION_NAME = 'EarnVaultUpgradeable_Implementation_03112025';
  string public constant PROXY_NAME = 'EarnVaultUpgradeable_Proxy_03112025';

  function setUp() public {
    // Load environment variables
    usdscAddress = vm.envAddress('USDSC_ADDRESS');
    ownerAddress = vm.envAddress('OWNER_ADDRESS');
    yieldRedistributorAddress = vm.envAddress('YIELD_REDISTRIBUTOR_ADDRESS');
    treasuryAddress = vm.envAddress('TREASURY_ADDRESS');
    pauserAddress = vm.envAddress('PAUSER_ADDRESS');

    // ProxyAdmin owner - defaults to owner if not set
    proxyAdminOwner = vm.envOr('PROXY_ADMIN_OWNER', ownerAddress);

    // Validate addresses
    require(usdscAddress != address(0), 'USDSC_ADDRESS not set');
    require(ownerAddress != address(0), 'OWNER_ADDRESS not set');
    require(yieldRedistributorAddress != address(0), 'YIELD_REDISTRIBUTOR_ADDRESS not set');
    require(treasuryAddress != address(0), 'TREASURY_ADDRESS not set');
    require(pauserAddress != address(0), 'PAUSER_ADDRESS not set');
    require(proxyAdminOwner != address(0), 'PROXY_ADMIN_OWNER not set');

    console.log('=== Deployment Configuration ===');
    console.log('USDSC Address:', usdscAddress);
    console.log('Owner Address:', ownerAddress);
    console.log('Yield Redistributor Address:', yieldRedistributorAddress);
    console.log('Treasury Address:', treasuryAddress);
    console.log('Pauser Address:', pauserAddress);
    console.log('ProxyAdmin Owner:', proxyAdminOwner);
    console.log('Deployer:', msg.sender);
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

    // Predict deployment addresses
    address predictedImplAddress = _getCreate3Address(deployer, implSalt);
    address predictedProxyAddress = _getCreate3Address(deployer, proxySalt);

    console.log('Predicted implementation address:', predictedImplAddress);
    console.log('Predicted proxy address:', predictedProxyAddress);

    vm.startBroadcast(deployerPrivateKey);

    // Step 1: Deploy implementation using CREATE3
    console.log('\n=== Deploying Implementation ===');
    bytes memory implCreationCode = type(EarnVaultUpgradeable).creationCode;
    address deployedImplAddress = _deployCreate3(implCreationCode, implSalt);
    implementation = EarnVaultUpgradeable(payable(deployedImplAddress));

    console.log('Implementation deployed at:', address(implementation));
    require(deployedImplAddress == predictedImplAddress, 'Implementation address mismatch');

    // Step 2: Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      usdscAddress,
      ownerAddress,
      yieldRedistributorAddress,
      treasuryAddress,
      pauserAddress
    );

    // Step 3: Deploy proxy using CREATE3
    console.log('\n=== Deploying Proxy ===');
    bytes memory proxyCreationCode = abi.encodePacked(
      type(TransparentUpgradeableProxy).creationCode, abi.encode(address(implementation), proxyAdminOwner, initData)
    );

    address deployedProxyAddress = _deployCreate3(proxyCreationCode, proxySalt);
    proxy = TransparentUpgradeableProxy(payable(deployedProxyAddress));
    earnVault = EarnVaultUpgradeable(payable(deployedProxyAddress));

    console.log('Proxy deployed at:', address(proxy));
    require(deployedProxyAddress == predictedProxyAddress, 'Proxy address mismatch');

    console.log('\n=== Deployment Successful ===');
    console.log('Implementation:', address(implementation));
    console.log('Proxy (EarnVault):', address(earnVault));
    console.log('Address verification: PASSED');

    vm.stopBroadcast();

    // Post-deployment verification
    console.log('\n=== Post-Deployment Verification ===');
    console.log('Total Principal:', earnVault.totalPrincipal());
    console.log('Global Index:', earnVault.globalIndex());
    console.log('Claim Reserve:', earnVault.claimReserve());
    console.log('Owner:', earnVault.owner());
  }

  /**
   * @notice Simulates a deployment without broadcasting
   * @dev Useful for testing and gas estimation
   */
  function simulateDeploy() public {
    setUp();

    address deployer = msg.sender;
    bytes32 implSalt = _computeSalt(deployer, IMPLEMENTATION_NAME);
    bytes32 proxySalt = _computeSalt(deployer, PROXY_NAME);

    address predictedImplAddress = _getCreate3Address(deployer, implSalt);
    address predictedProxyAddress = _getCreate3Address(deployer, proxySalt);

    console.log('\n=== Deployment Simulation ===');
    console.log('Predicted implementation address:', predictedImplAddress);
    console.log('Predicted proxy address:', predictedProxyAddress);
    console.log('Implementation salt:');
    console.logBytes32(implSalt);
    console.log('Proxy salt:');
    console.logBytes32(proxySalt);

    // Simulate implementation deployment
    EarnVaultUpgradeable simulatedImpl = new EarnVaultUpgradeable();
    console.log('\nSimulated implementation deployed at:', address(simulatedImpl));

    // Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector,
      usdscAddress,
      ownerAddress,
      yieldRedistributorAddress,
      treasuryAddress,
      pauserAddress
    );

    // Simulate proxy deployment
    TransparentUpgradeableProxy simulatedProxy =
      new TransparentUpgradeableProxy(address(simulatedImpl), proxyAdminOwner, initData);

    EarnVaultUpgradeable simulatedVault = EarnVaultUpgradeable(payable(address(simulatedProxy)));

    console.log('Simulated proxy deployed at:', address(simulatedProxy));
    console.log('Simulation successful!');

    // Display initial state
    console.log('\n=== Simulated Initial State ===');
    console.log('Total Principal:', simulatedVault.totalPrincipal());
    console.log('Global Index:', simulatedVault.globalIndex());
    console.log('Claim Reserve:', simulatedVault.claimReserve());
    console.log('Owner:', simulatedVault.owner());
  }
}
