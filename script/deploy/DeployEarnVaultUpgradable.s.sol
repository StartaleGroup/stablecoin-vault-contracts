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

    vm.stopBroadcast();

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

    vm.startBroadcast(deployerPrivateKey);

    address deployedProxyAddress = _deployCreate3(proxyCreationCode, proxySalt);

    vm.stopBroadcast();
    proxy = TransparentUpgradeableProxy(payable(deployedProxyAddress));
    earnVault = EarnVaultUpgradeable(payable(deployedProxyAddress));

    console.log('\n=== Deployment Successful ===');
    console.log('EarnVaultUpgradeable Implementation:', address(implementation));
    console.log('EarnVaultUpgradeable Proxy (EarnVault):', address(earnVault));

    _verifyDeployment();
    _logPostDeploymentState();
  }

  // Helper: Read boostRewardKeeper from ERC-7201 storage
  function _readBoostRewardKeeper() internal view returns (address) {
    // ERC-7201 storage location from EarnVaultStorageBase.sol
    bytes32 EARN_VAULT_STORAGE_LOCATION = 0x4acfb950108afb92cc59b268b946808304d34de46619a1e803aeac06ad89cb00;
    // boostRewardKeeper is at offset 2 in the struct (after RAY at 0, yieldRedistributor at 1)
    bytes32 boostKeeperSlot = bytes32(uint256(EARN_VAULT_STORAGE_LOCATION) + 2);
    return address(uint160(uint256(vm.load(address(earnVault), boostKeeperSlot))));
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

    require(earnVault.asset() == usdscAddress, 'Asset address mismatch');
    console.log('Asset usdscAddress Address: OK');
    require(earnVault.owner() == ownerAddress, 'Owner address mismatch');
    console.log('Owner Address: OK');
    require(earnVault.yieldRedistributor() == yieldRedistributorAddress, 'Yield redistributor mismatch');
    console.log('Yield Redistributor: OK');
    require(earnVault.treasury() == treasuryAddress, 'Treasury address mismatch');
    console.log('Treasury Address: OK');
    require(earnVault.pauser() == pauserAddress, 'Pauser address mismatch');
    console.log('Pauser Address: OK');
    require(!earnVault.paused(), 'Vault should not be paused');
    console.log('Paused State: OK');

    // Verify boostRewardKeeper via storage read (no public getter exists)
    address actualBoostRewardKeeper = _readBoostRewardKeeper();
    require(actualBoostRewardKeeper == boostRewardKeeperAddress, 'Boost reward keeper mismatch');
    console.log('Boost Reward Keeper: OK');

    // Verify ProxyAdmin owner
    (address proxyAdminContract, address actualProxyAdminOwner) = _readProxyAdminOwner();
    require(actualProxyAdminOwner == proxyAdminOwner, 'ProxyAdmin owner mismatch');
    console.log('ProxyAdmin Owner: OK');

    console.log('\n=== All Verifications Passed ===');
  }

  // Post-deployment state logging
  function _logPostDeploymentState() internal view {
    console.log('\n=== Post-Deployment State ===');
    console.log('Asset (USDSC):', earnVault.asset());
    console.log('Owner:', earnVault.owner());
    console.log('Yield Redistributor:', earnVault.yieldRedistributor());
    console.log('Treasury:', earnVault.treasury());
    console.log('Pauser:', earnVault.pauser());
    console.log('Total Principal:', earnVault.totalPrincipal());
    console.log('Global Index:', earnVault.globalIndex());
    console.log('Claim Reserve:', earnVault.claimReserve());
    console.log('Paused:', earnVault.paused());

    // Read ProxyAdmin info
    (address proxyAdminContract, address actualProxyAdminOwner) = _readProxyAdminOwner();
    console.log('ProxyAdmin Contract:', proxyAdminContract);
    console.log('ProxyAdmin Owner:', actualProxyAdminOwner);

    // Read boostRewardKeeper via storage (no public getter exists)
    address actualBoostRewardKeeper = _readBoostRewardKeeper();
    console.log('Boost Reward Keeper:', actualBoostRewardKeeper);
  }
}
