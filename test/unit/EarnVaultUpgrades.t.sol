// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultUpgradeableHarness} from '../harness/EarnVaultUpgradeableHarness.sol';
import {EarnVaultV2} from '../mocks/EarnVaultV2.sol';
import {EarnVaultV3} from '../mocks/EarnVaultV3.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';

/// @title EarnVaultUpgradesTest
/// @notice Comprehensive upgrade tests for EarnVault with V1 -> V2 -> V3 upgrades
/// @dev Tests storage consistency, implementation updates, and new functionality across versions
contract EarnVaultUpgradesTest is Test {
  EarnVaultUpgradeable public vault;
  MockERC20 public usdsc;
  ProxyAdmin internal proxyAdmin;
  TransparentUpgradeableProxy internal proxy;
  EarnVaultUpgradeableHarness internal v1Implementation;
  EarnVaultV2 internal v2Implementation;
  EarnVaultV3 internal v3Implementation;

  address public admin = makeAddr('admin'); // ProxyAdmin owner (for upgrades)
  address public owner = makeAddr('owner'); // vault owner
  address public yieldRedistributor = makeAddr('yieldRedistributor');
  address public treasury = makeAddr('treasury');
  address public pauser = makeAddr('pauser');
  address public alice = makeAddr('alice');
  address public bob = makeAddr('bob');
  address public charlie = makeAddr('charlie');

  uint256 public constant RAY = 1e27;
  uint256 public constant INITIAL_SUPPLY = 1_000_000e6;

  // =========================
  // Events
  // =========================
  event Upgraded(address indexed implementation);
  event Deposit(address indexed user, uint256 amount);
  event Withdraw(address indexed user, uint256 amount);
  event InterestClaimed(address indexed user, uint256 amount);
  event YieldIndexed(uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
  event EmergencyModeToggled(bool enabled);
  event EmergencyYieldMultiplierSet(uint256 multiplier);
  event PerformanceFeeSet(uint256 oldRate, uint256 newRate);
  event ManagementFeeSet(uint256 oldRate, uint256 newRate);
  event FeeCollected(uint256 amount, uint256 totalFees);
  event AutoCompoundToggled(bool enabled);
  event CompoundThresholdSet(uint256 threshold);
  event AutoCompoundExecuted(address indexed user, uint256 amount);

  function setUp() public {
    // Deploy mock USDSC token
    usdsc = new MockERC20('USDSC Token', 'USDSC', 6);

    // Mint USDSC to test users
    usdsc.mint(alice, INITIAL_SUPPLY);
    usdsc.mint(bob, INITIAL_SUPPLY);
    usdsc.mint(charlie, INITIAL_SUPPLY);
    usdsc.mint(yieldRedistributor, INITIAL_SUPPLY);

    // Deploy all implementation contracts
    v1Implementation = new EarnVaultUpgradeableHarness();
    v2Implementation = new EarnVaultV2();
    v3Implementation = new EarnVaultV3();

    proxy = new TransparentUpgradeableProxy(
      address(v1Implementation),
      admin, // OpenZeppelin v5 creates ProxyAdmin automatically with this as admin
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, yieldRedistributor, treasury, pauser
      )
    );
    vault = EarnVaultUpgradeable(payable(address(proxy)));

    // Get the auto-created ProxyAdmin from the proxy using ERC1967 admin slot
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
    address proxyAdminAddress = address(uint160(uint256(vm.load(address(proxy), adminSlot))));
    proxyAdmin = ProxyAdmin(proxyAdminAddress);

    // Pre-approve vault for all users
    vm.prank(alice);
    usdsc.approve(address(vault), type(uint256).max);
    vm.prank(bob);
    usdsc.approve(address(vault), type(uint256).max);
    vm.prank(charlie);
    usdsc.approve(address(vault), type(uint256).max);
    vm.prank(yieldRedistributor);
    usdsc.approve(address(vault), type(uint256).max);
  }

  // =========================
  // V1 -> V2 Upgrade Tests
  // =========================

  function test_V1ToV2UpgradeWithInitialization() public {
    // Set up V1 state
    vm.prank(alice);
    vault.deposit(1000e6);

    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vault), 100e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vault.onYield(100e6);

    // Capture V1 state
    uint256 totalPrincipalBefore = vault.totalPrincipal();
    uint256 globalIndexBefore = vault.globalIndex();
    uint256 alicePrincipalBefore = vault.principal(alice);
    uint256 aliceClaimableBefore = vault.claimable(alice);

    // Upgrade to V2 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));

    // Verify implementation updated
    assertEq(_getImplementation(), address(v2Implementation));
    assertEq(vaultV2.getVersion(), 'EarnVaultV2');

    // Verify V1 state preserved
    assertEq(vaultV2.totalPrincipal(), totalPrincipalBefore);
    assertEq(vaultV2.globalIndex(), globalIndexBefore);
    assertEq(vaultV2.principal(alice), alicePrincipalBefore);
    assertEq(vaultV2.claimable(alice), aliceClaimableBefore);

    // Verify V2 initialization
    assertEq(vaultV2.getEmergencyYieldMultiplier(), 10_000);
    assertFalse(vaultV2.isEmergencyModeActive());

    // Test V2 functionality
    vm.prank(owner);
    vaultV2.setEmergencyYieldMultiplier(15_000);
    assertEq(vaultV2.getEmergencyYieldMultiplier(), 15_000);
  }

  function test_V1ToV2UpgradePreservesComplexState() public {
    // Set up complex V1 state
    vm.prank(alice);
    vault.deposit(1000e6);

    vm.prank(bob);
    vault.deposit(2000e6);

    // Multiple yield distributions
    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vault), 100e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vault.onYield(100e6);

    vm.prank(yieldRedistributor);
    success = usdsc.transfer(address(vault), 200e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vault.onYield(200e6);

    // Capture all state
    uint256 totalPrincipalBefore = vault.totalPrincipal();
    uint256 globalIndexBefore = vault.globalIndex();
    uint256 claimReserveBefore = vault.claimReserve();
    uint256 alicePrincipalBefore = vault.principal(alice);
    uint256 aliceClaimableBefore = vault.claimable(alice);
    uint256 bobPrincipalBefore = vault.principal(bob);
    uint256 bobClaimableBefore = vault.claimable(bob);

    // Upgrade to V2 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));

    // Verify all state preserved
    assertEq(vaultV2.totalPrincipal(), totalPrincipalBefore);
    assertEq(vaultV2.globalIndex(), globalIndexBefore);
    assertEq(vaultV2.claimReserve(), claimReserveBefore);
    assertEq(vaultV2.principal(alice), alicePrincipalBefore);
    assertEq(vaultV2.claimable(alice), aliceClaimableBefore);
    assertEq(vaultV2.principal(bob), bobPrincipalBefore);
    assertEq(vaultV2.claimable(bob), bobClaimableBefore);

    // Test functionality still works
    vm.prank(alice);
    vaultV2.withdraw(500e6);
    assertEq(vaultV2.principal(alice), 500e6);
  }

  // =========================
  // V2 -> V3 Upgrade Tests
  // =========================

  function test_V2ToV3UpgradeWithInitialization() public {
    // Upgrade to V2 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));

    // Set up V2 state
    vm.prank(alice);
    vaultV2.deposit(1000e6);

    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vaultV2), 100e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vaultV2.onYield(100e6);

    // Set V2 features
    vm.prank(owner);
    vaultV2.setEmergencyYieldMultiplier(12_000);
    vm.prank(owner);
    vaultV2.setEmergencyMode(true);

    // Capture V2 state
    uint256 totalPrincipalBefore = vaultV2.totalPrincipal();
    uint256 globalIndexBefore = vaultV2.globalIndex();
    uint256 alicePrincipalBefore = vaultV2.principal(alice);
    uint256 aliceClaimableBefore = vaultV2.claimable(alice);

    // Upgrade to V3 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    // Verify implementation updated
    assertEq(_getImplementation(), address(v3Implementation));
    assertEq(vaultV3.getVersion(), 'EarnVaultV3');

    // Verify V2 state preserved
    assertEq(vaultV3.totalPrincipal(), totalPrincipalBefore);
    assertEq(vaultV3.globalIndex(), globalIndexBefore);
    assertEq(vaultV3.principal(alice), alicePrincipalBefore);
    assertEq(vaultV3.claimable(alice), aliceClaimableBefore);

    // Note: V3 doesn't inherit V2 emergency features, so we skip those assertions

    // Verify V3 initialization
    assertEq(vaultV3.getPerformanceFeeRate(), 200); // 2%
    assertEq(vaultV3.getManagementFeeRate(), 50); // 0.5%
    assertEq(vaultV3.getTotalFeesCollected(), 0);
    assertFalse(vaultV3.isAutoCompoundEnabled());
    assertEq(vaultV3.getCompoundThreshold(), 100e6);
    assertEq(vaultV3.getTotalCompounds(), 0);
  }

  function test_V2ToV3UpgradeWithComplexState() public {
    // Upgrade to V2 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));

    // Set up complex V2 state
    vm.prank(alice);
    vaultV2.deposit(1000e6);

    vm.prank(bob);
    vaultV2.deposit(2000e6);

    vm.prank(charlie);
    vaultV2.deposit(1500e6);

    // Multiple yield distributions
    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vaultV2), 200e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vaultV2.onYield(200e6);

    vm.prank(yieldRedistributor);
    success = usdsc.transfer(address(vaultV2), 300e6);
    vm.prank(yieldRedistributor);
    vaultV2.onYield(300e6);

    // Set V2 features
    vm.prank(owner);
    vaultV2.setEmergencyYieldMultiplier(15_000);
    vm.prank(owner);
    vaultV2.setEmergencyMode(false);

    // Capture all state
    uint256 totalPrincipalBefore = vaultV2.totalPrincipal();
    uint256 globalIndexBefore = vaultV2.globalIndex();
    uint256 claimReserveBefore = vaultV2.claimReserve();
    uint256 alicePrincipalBefore = vaultV2.principal(alice);
    uint256 aliceClaimableBefore = vaultV2.claimable(alice);
    uint256 bobPrincipalBefore = vaultV2.principal(bob);
    uint256 bobClaimableBefore = vaultV2.claimable(bob);
    uint256 charliePrincipalBefore = vaultV2.principal(charlie);
    uint256 charlieClaimableBefore = vaultV2.claimable(charlie);

    // Upgrade to V3 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    // Verify all state preserved
    assertEq(vaultV3.totalPrincipal(), totalPrincipalBefore);
    assertEq(vaultV3.globalIndex(), globalIndexBefore);
    assertEq(vaultV3.claimReserve(), claimReserveBefore);
    assertEq(vaultV3.principal(alice), alicePrincipalBefore);
    assertEq(vaultV3.claimable(alice), aliceClaimableBefore);
    assertEq(vaultV3.principal(bob), bobPrincipalBefore);
    assertEq(vaultV3.claimable(bob), bobClaimableBefore);
    assertEq(vaultV3.principal(charlie), charliePrincipalBefore);
    assertEq(vaultV3.claimable(charlie), charlieClaimableBefore);

    // Test V3 functionality
    vm.prank(owner);
    vaultV3.setPerformanceFeeRate(300); // 3%
    assertEq(vaultV3.getPerformanceFeeRate(), 300);

    vm.prank(owner);
    vaultV3.setAutoCompoundEnabled(true);
    assertTrue(vaultV3.isAutoCompoundEnabled());
  }

  // =========================
  // V1 -> V2 -> V3 Chain Upgrade Tests
  // =========================

  function test_V1ToV2ToV3ChainUpgrade() public {
    // Set up V1 state
    vm.prank(alice);
    vault.deposit(1000e6);

    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vault), 100e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vault.onYield(100e6);

    uint256 v1TotalPrincipal = vault.totalPrincipal();
    uint256 v1GlobalIndex = vault.globalIndex();
    uint256 v1AliceClaimable = vault.claimable(alice);

    // V1 -> V2 Upgrade
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2Implementation), '');

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
    vaultV2.initializeV2();

    // Set V2 features
    vm.prank(owner);
    vaultV2.setEmergencyYieldMultiplier(12_000);

    // V2 -> V3 Upgrade
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v3Implementation), '');

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));
    vaultV3.initializeV3();

    // Verify final state
    assertEq(_getImplementation(), address(v3Implementation));
    assertEq(vaultV3.getVersion(), 'EarnVaultV3');

    // Verify V1 state preserved through chain
    assertEq(vaultV3.totalPrincipal(), v1TotalPrincipal);
    assertEq(vaultV3.globalIndex(), v1GlobalIndex);
    assertEq(vaultV3.claimable(alice), v1AliceClaimable);

    // Note: V3 doesn't inherit V2 emergency features

    // Verify V3 features initialized
    assertEq(vaultV3.getPerformanceFeeRate(), 200);
    assertEq(vaultV3.getManagementFeeRate(), 50);
    assertFalse(vaultV3.isAutoCompoundEnabled());
  }

  // =========================
  // V3 New Functionality Tests
  // =========================

  function test_V3FeeCollection() public {
    // Upgrade to V3 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    // Set up deposits
    vm.prank(alice);
    vaultV3.deposit(1000e6);

    vm.prank(bob);
    vaultV3.deposit(2000e6);

    // Distribute yield (should collect fees)
    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vaultV3), 1000e6);
    require(success, 'Transfer failed');

    uint256 treasuryBalanceBefore = usdsc.balanceOf(treasury);

    vm.prank(yieldRedistributor);
    vaultV3.onYield(1000e6);

    // Verify fees collected
    uint256 expectedFee = (1000e6 * 200) / 10_000; // 2% of 1000e6 = 20e6
    assertEq(vaultV3.getTotalFeesCollected(), expectedFee);

    // Verify treasury received fees
    assertEq(usdsc.balanceOf(treasury), treasuryBalanceBefore + expectedFee);
  }

  function test_V3AutoCompound() public {
    // Upgrade to V3 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    // Enable auto-compound
    vm.prank(owner);
    vaultV3.setAutoCompoundEnabled(true);
    vm.prank(owner);
    vaultV3.setCompoundThreshold(50e6);

    // Set up deposit and yield
    vm.prank(alice);
    vaultV3.deposit(1000e6);

    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vaultV3), 100e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vaultV3.onYield(100e6);

    uint256 alicePrincipalBefore = vaultV3.principal(alice);
    uint256 aliceClaimableBefore = vaultV3.claimable(alice);

    // Execute auto-compound
    vm.prank(alice);
    vaultV3.executeAutoCompound(alice);

    // Verify auto-compound worked
    assertEq(vaultV3.principal(alice), alicePrincipalBefore + aliceClaimableBefore);
    assertEq(vaultV3.accrued(alice), 0);
    assertEq(vaultV3.getTotalCompounds(), 1);
    assertTrue(vaultV3.getUserLastCompoundTime(alice) > 0);
  }

  function test_V3OverriddenDepositWithAutoCompound() public {
    // Upgrade to V3 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    // Enable auto-compound
    vm.prank(owner);
    vaultV3.setAutoCompoundEnabled(true);
    vm.prank(owner);
    vaultV3.setCompoundThreshold(50e6);

    // Set up deposit and yield
    vm.prank(alice);
    vaultV3.deposit(1000e6);

    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vaultV3), 100e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vaultV3.onYield(100e6);

    uint256 alicePrincipalBefore = vaultV3.principal(alice);
    uint256 aliceClaimableBefore = vaultV3.claimable(alice);

    // Deposit more (should trigger auto-compound)
    vm.prank(alice);
    vaultV3.deposit(100e6);

    // Verify auto-compound was triggered
    assertEq(vaultV3.principal(alice), alicePrincipalBefore + aliceClaimableBefore + 100e6);
    assertEq(vaultV3.accrued(alice), 0);
    assertEq(vaultV3.getTotalCompounds(), 1);
  }

  // =========================
  // Storage Consistency Tests
  // =========================

  function test_StorageConsistencyAcrossUpgrades() public {
    // Set up initial state
    vm.prank(alice);
    vault.deposit(1000e6);

    vm.prank(bob);
    vault.deposit(2000e6);

    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vault), 300e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vault.onYield(300e6);

    // Capture V1 state
    uint256 v1TotalPrincipal = vault.totalPrincipal();
    uint256 v1GlobalIndex = vault.globalIndex();
    uint256 v1ClaimReserve = vault.claimReserve();
    uint256 v1AlicePrincipal = vault.principal(alice);
    uint256 v1AliceClaimable = vault.claimable(alice);
    uint256 v1BobPrincipal = vault.principal(bob);
    uint256 v1BobClaimable = vault.claimable(bob);

    // V1 -> V2
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2Implementation), '');

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
    vaultV2.initializeV2();

    // Verify V1 state preserved in V2
    assertEq(vaultV2.totalPrincipal(), v1TotalPrincipal);
    assertEq(vaultV2.globalIndex(), v1GlobalIndex);
    assertEq(vaultV2.claimReserve(), v1ClaimReserve);
    assertEq(vaultV2.principal(alice), v1AlicePrincipal);
    assertEq(vaultV2.claimable(alice), v1AliceClaimable);
    assertEq(vaultV2.principal(bob), v1BobPrincipal);
    assertEq(vaultV2.claimable(bob), v1BobClaimable);

    // V2 -> V3
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v3Implementation), '');

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));
    vaultV3.initializeV3();

    // Verify V1 state still preserved in V3
    assertEq(vaultV3.totalPrincipal(), v1TotalPrincipal);
    assertEq(vaultV3.globalIndex(), v1GlobalIndex);
    assertEq(vaultV3.claimReserve(), v1ClaimReserve);
    assertEq(vaultV3.principal(alice), v1AlicePrincipal);
    assertEq(vaultV3.claimable(alice), v1AliceClaimable);
    assertEq(vaultV3.principal(bob), v1BobPrincipal);
    assertEq(vaultV3.claimable(bob), v1BobClaimable);
  }

  // =========================
  // Implementation Update Tests
  // =========================

  function test_ImplementationUpdatesCorrectly() public {
    // Verify V1 implementation
    assertEq(_getImplementation(), address(v1Implementation));

    // V1 -> V2
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));

    assertEq(_getImplementation(), address(v2Implementation));
    assertEq(vaultV2.getVersion(), 'EarnVaultV2');

    // V2 -> V3
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    assertEq(_getImplementation(), address(v3Implementation));
    assertEq(vaultV3.getVersion(), 'EarnVaultV3');
  }

  function test_CannotReinitializeV2() public {
    // Upgrade to V2 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));

    // Try to re-initialize V2 - should fail with OpenZeppelin's InvalidInitialization
    vm.expectRevert();
    vaultV2.initializeV2();
  }

  function test_CannotReinitializeV3() public {
    // Upgrade to V3 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    // Try to re-initialize V3 - should fail with OpenZeppelin's InvalidInitialization
    vm.expectRevert();
    vaultV3.initializeV3();
  }

  // =========================
  // ETH Safety Tests
  // =========================

  function test_CannotSendETHToVaultV1() public {
    // Try to send ETH to V1 vault - should fail
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success,) = address(vault).call{value: 1 ether}('');
    success;
  }

  function test_CannotSendETHToVaultV2() public {
    // Upgrade to V2 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));

    // Try to send ETH to V2 vault - should fail
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success,) = address(vaultV2).call{value: 1 ether}('');
    success;
  }

  function test_CannotSendETHToVaultV3() public {
    // Upgrade to V3 and initialize
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    // Try to send ETH to V3 vault - should fail
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success,) = address(vaultV3).call{value: 1 ether}('');
    success;
  }

  function test_EthRejectionWorksThroughUpgradeChain() public {
    // Set up some state in V1
    vm.prank(alice);
    vault.deposit(1000e6);

    // Test ETH rejection in V1
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success,) = address(vault).call{value: 1 ether}('');
    success;

    // Upgrade to V2
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v2Implementation),
      abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));

    // Test ETH rejection in V2
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success2,) = address(vaultV2).call{value: 1 ether}('');
    success2;

    // Upgrade to V3
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(
      ITransparentUpgradeableProxy(address(proxy)),
      address(v3Implementation),
      abi.encodeWithSelector(EarnVaultV3.initializeV3.selector)
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(proxy)));

    // Test ETH rejection in V3
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success3,) = address(vaultV3).call{value: 1 ether}('');
    success3;

    // Verify vault functionality still works through all upgrades
    assertEq(vaultV3.principal(alice), 1000e6);
    assertEq(vaultV3.totalPrincipal(), 1000e6);
  }

  function test_EthRejectionViaReceiveAndFallback() public {
    // Test receive() function
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success1,) = address(vault).call{value: 1 ether}('');
    success1;

    // Test fallback() function with invalid data
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success2,) = address(vault).call{value: 1 ether}('invalidFunction()');
    success2;
  }

  /*//////////////////////////////////////////////////////////////
                      HELPER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function _getImplementation() internal view returns (address) {
    bytes32 implementationSlot = bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1);
    return address(uint160(uint256(vm.load(address(proxy), implementationSlot))));
  }
}
