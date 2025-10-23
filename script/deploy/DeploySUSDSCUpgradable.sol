// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {SUSDSCVaultUpgradable} from '../../src/vaults/4626/SUSDSCVaultUpgradable.sol';
import {DeployHelpers} from './DeployHelpers.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Script, console} from 'forge-std/Script.sol';

/**
 * @title DeploySUSDSCVaultUpgradeable
 * @notice Deployment script for SUSDSCVaultUpgradable contract using CREATE3 for deterministic addresses
 * @dev Usage:
 *      forge script script/deploy/DeploySUSDSCUpgradable.sol:DeploySUSDSCVaultUpgradeable \
 *          --rpc-url $SEP_RPC \
 *          --broadcast \
 *          --verify \
 *          -vvvv
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
  string public constant IMPLEMENTATION_NAME = 'SUSDSCVaultUpgradeable_Implementation2';
  string public constant PROXY_NAME = 'SUSDSCVaultUpgradeable_Proxy2';

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
    bytes memory implCreationCode = type(SUSDSCVaultUpgradable).creationCode;
    address deployedImplAddress = _deployCreate3(implCreationCode, implSalt);
    implementation = SUSDSCVaultUpgradable(payable(deployedImplAddress));

    console.log('Implementation deployed at:', address(implementation));
    require(deployedImplAddress == predictedImplAddress, 'Implementation address mismatch');

    // Step 2: Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(
      SUSDSCVaultUpgradable.initialize.selector, IERC20(usdscAddress), adminAddress, pauserAddress
    );

    // Step 3: Deploy proxy using CREATE3
    console.log('\n=== Deploying Proxy ===');
    bytes memory proxyCreationCode = abi.encodePacked(
      type(TransparentUpgradeableProxy).creationCode, abi.encode(address(implementation), proxyAdminOwner, initData)
    );

    address deployedProxyAddress = _deployCreate3(proxyCreationCode, proxySalt);
    proxy = TransparentUpgradeableProxy(payable(deployedProxyAddress));
    susdscVault = SUSDSCVaultUpgradable(payable(deployedProxyAddress));

    console.log('Proxy deployed at:', address(proxy));
    require(deployedProxyAddress == predictedProxyAddress, 'Proxy address mismatch');

    console.log('\n=== Deployment Successful ===');
    console.log('Implementation:', address(implementation));
    console.log('Proxy (SUSDSCVault):', address(susdscVault));
    console.log('Address verification: PASSED');

    // Step 4: Make initial deposit
    _makeInitialDeposit(deployer);

    vm.stopBroadcast();

    // Post-deployment verification
    console.log('\n=== Post-Deployment Verification ===');
    console.log('Vault Name:', susdscVault.name());
    console.log('Vault Symbol:', susdscVault.symbol());
    console.log('Total Assets:', susdscVault.totalAssets());
    console.log('Total Supply:', susdscVault.totalSupply());
    console.log('Deployer shares:', susdscVault.balanceOf(deployer));
  }

  /**
   * @notice Makes an initial deposit to the vault
   * @dev Deposits 1 USDSC (1e6 units) from the deployer
   * @param deployer The address making the deposit
   */
  function _makeInitialDeposit(address deployer) internal {
    console.log('\n=== Making Initial Deposit ===');
    uint256 depositAmount = 1e6; // 1 USDSC (6 decimals)

    IERC20 usdsc = IERC20(usdscAddress);
    uint256 deployerBalance = usdsc.balanceOf(deployer);
    console.log('Deployer USDSC balance:', deployerBalance);

    if (deployerBalance >= depositAmount) {
      // Approve vault to spend USDSC
      usdsc.approve(address(susdscVault), depositAmount);
      console.log('Approved vault to spend', depositAmount, 'USDSC');

      // Deposit to vault
      uint256 shares = susdscVault.deposit(depositAmount, deployer);
      console.log('Deposited', depositAmount, 'USDSC');
      console.log('Received', shares, 'shares');
    } else {
      console.log('WARNING: Insufficient USDSC balance for initial deposit');
      console.log('Skipping initial deposit...');
    }
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
    SUSDSCVaultUpgradable simulatedImpl = new SUSDSCVaultUpgradable();
    console.log('\nSimulated implementation deployed at:', address(simulatedImpl));

    // Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(
      SUSDSCVaultUpgradable.initialize.selector, IERC20(usdscAddress), adminAddress, pauserAddress
    );

    // Simulate proxy deployment
    TransparentUpgradeableProxy simulatedProxy =
      new TransparentUpgradeableProxy(address(simulatedImpl), proxyAdminOwner, initData);

    SUSDSCVaultUpgradable simulatedVault = SUSDSCVaultUpgradable(payable(address(simulatedProxy)));

    console.log('Simulated proxy deployed at:', address(simulatedProxy));
    console.log('Simulation successful!');

    // Display initial state
    console.log('\n=== Simulated Initial State ===');
    console.log('Vault Name:', simulatedVault.name());
    console.log('Vault Symbol:', simulatedVault.symbol());
    console.log('Total Assets:', simulatedVault.totalAssets());
    console.log('Total Supply:', simulatedVault.totalSupply());
  }
}
