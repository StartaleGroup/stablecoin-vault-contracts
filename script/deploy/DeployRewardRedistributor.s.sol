// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {RewardRedistributor} from '../../src/distributor/RewardRedistributor.sol';
import {IEarnVault} from '../../src/interfaces/vaults/earn/IEarnVault.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {DeployHelpers} from 'common/script/deploy/DeployHelpers.sol';
import {Script, console} from 'forge-std/Script.sol';

/**
 * @title DeployRewardRedistributor
 * @notice Deployment script for RewardRedistributor contract using CREATE3 for deterministic addresses
 */
contract DeployRewardRedistributor is Script, DeployHelpers {
  // Environment variables
  address usdscAddress;
  address treasuryAddress;
  address earnVaultAddress;
  address susdscVaultAddress;
  address adminAddress;
  address keeperAddress;

  // Deployment artifacts
  RewardRedistributor public rewardRedistributor;

  // Salt for CREATE3 deployment
  string public constant CONTRACT_NAME = 'RewardRedistributor_112025';

  function setUp() public {
    // Load environment variables
    usdscAddress = vm.envAddress('USDSC_ADDRESS');
    treasuryAddress = vm.envAddress('TREASURY_ADDRESS');
    earnVaultAddress = vm.envAddress('EARN_VAULT_ADDRESS');
    susdscVaultAddress = vm.envAddress('SUSDSC_VAULT_ADDRESS');
    adminAddress = vm.envAddress('ADMIN_ADDRESS');
    keeperAddress = vm.envAddress('KEEPER_ADDRESS');

    // Validate addresses
    require(usdscAddress != address(0), 'USDSC_ADDRESS not set');
    require(treasuryAddress != address(0), 'TREASURY_ADDRESS not set');
    require(earnVaultAddress != address(0), 'EARN_VAULT_ADDRESS not set');
    require(susdscVaultAddress != address(0), 'SUSDSC_VAULT_ADDRESS not set');
    require(adminAddress != address(0), 'ADMIN_ADDRESS not set');
    require(keeperAddress != address(0), 'KEEPER_ADDRESS not set');

    console.log('=== Deployment Configuration ===');
    console.log('USDSC Address:', usdscAddress);
    console.log('Treasury Address:', treasuryAddress);
    console.log('EarnVault Address:', earnVaultAddress);
    console.log('sUSDSC Vault Address:', susdscVaultAddress);
    console.log('Admin Address:', adminAddress);
    console.log('Keeper Address:', keeperAddress);
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint('DEPLOYER_PRIVATE_KEY');
    address deployer = vm.addr(deployerPrivateKey);

    console.log('\n=== Starting Deployment ===');
    console.log('Deployer address:', deployer);

    // Compute the salt for CREATE3
    bytes32 salt = _computeSalt(deployer, CONTRACT_NAME);
    console.log('Computed salt:');
    console.logBytes32(salt);

    vm.startBroadcast(deployerPrivateKey);

    // Deploy RewardRedistributor using CREATE3
    bytes memory creationCode = abi.encodePacked(
      type(RewardRedistributor).creationCode,
      abi.encode(
        usdscAddress,
        treasuryAddress,
        IEarnVault(earnVaultAddress),
        IERC4626(susdscVaultAddress),
        adminAddress,
        keeperAddress
      )
    );

    address deployedAddress = _deployCreate3(creationCode, salt);
    rewardRedistributor = RewardRedistributor(deployedAddress);

    console.log('\n=== Deployment Successful ===');
    console.log('RewardRedistributor deployed at:', address(rewardRedistributor));

    // Verify constructor parameters
    _verifyDeployment();

    vm.stopBroadcast();

    // Log deployment summary
    _logDeploymentSummary();
  }

  function _verifyDeployment() internal view {
    console.log('\n=== Post-Deployment Verification ===');

    // Verify immutable USDSC address
    require(rewardRedistributor.USDSC_ADDRESS() == usdscAddress, 'USDSC_ADDRESS mismatch');
    console.log('USDSC_ADDRESS: OK');

    // Verify treasury address
    require(rewardRedistributor.treasury() == treasuryAddress, 'Treasury address mismatch');
    console.log('Treasury address: OK');

    // Verify earnVault address
    require(address(rewardRedistributor.earnVault()) == earnVaultAddress, 'EarnVault address mismatch');
    console.log('EarnVault address: OK');

    // Verify susdscVault address
    require(address(rewardRedistributor.susdscVault()) == susdscVaultAddress, 'sUSDSC Vault address mismatch');
    console.log('sUSDSC Vault address: OK');

    // Verify fee is 0 (default)
    require(rewardRedistributor.fee_on_yield_bps() == 0, 'Fee should be 0 by default');
    console.log('Fee on yield (bps): 0 (default)');

    // Verify admin has DEFAULT_ADMIN_ROLE
    bytes32 adminRole = rewardRedistributor.DEFAULT_ADMIN_ROLE();
    require(rewardRedistributor.hasRole(adminRole, adminAddress), 'Admin missing DEFAULT_ADMIN_ROLE');
    console.log('Admin DEFAULT_ADMIN_ROLE: OK');

    // Verify keeper has OPERATOR_ROLE
    bytes32 operatorRole = rewardRedistributor.OPERATOR_ROLE();
    require(rewardRedistributor.hasRole(operatorRole, keeperAddress), 'Keeper missing OPERATOR_ROLE');
    console.log('Keeper OPERATOR_ROLE: OK');

    // Verify contract is not paused
    require(!rewardRedistributor.paused(), 'Contract should not be paused');
    console.log('Contract paused status: false (OK)');

    console.log('\n=== All Verifications Passed ===');
  }

  function _logDeploymentSummary() internal view {
    console.log('\n=== Deployment Summary ===');
    console.log('Contract: RewardRedistributor');
    console.log('Address:', address(rewardRedistributor));
    console.log('USDSC Token:', rewardRedistributor.USDSC_ADDRESS());
    console.log('Treasury:', rewardRedistributor.treasury());
    console.log('EarnVault:', address(rewardRedistributor.earnVault()));
    console.log('sUSDSC Vault:', address(rewardRedistributor.susdscVault()));
    console.log('Admin:', adminAddress);
    console.log('Keeper:', keeperAddress);
    console.log('Fee (bps):', rewardRedistributor.fee_on_yield_bps());
    console.log('Max Fee (bps):', rewardRedistributor.MAX_FEE_BPS());
    console.log('\n=== Next Steps ===');
    console.log('1. Verify contract on block explorer');
    console.log('2. Set RewardRedistributor as yieldRecipient in M0 extension');
    console.log('3. Set RewardRedistributor as yieldRedistributor in EarnVault');
    console.log('4. Keeper already has OPERATOR_ROLE - ready to call distribute()');
    console.log('5. Test distribute() function with small amounts');
  }
}
