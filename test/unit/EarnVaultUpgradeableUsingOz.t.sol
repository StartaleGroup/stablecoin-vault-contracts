// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IEarnVaultEventsAndErrors} from '../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../mocks/EarnVaultV2.sol';
import {EarnVaultV3} from '../mocks/EarnVaultV3.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {SelfDestructor} from '../mocks/SelfDestructor.sol';
import {Test} from 'forge-std/Test.sol';
import {UnsafeUpgrades} from 'lib/openzeppelin-foundry-upgrades/src/Upgrades.sol';

/// @title EarnVaultUpgradeableUsingOzTest
/// @notice Test suite using OpenZeppelin Foundry Upgrades for cleaner proxy management
/// @dev Demonstrates proper usage of OZ Foundry Upgrades library
contract EarnVaultUpgradeableUsingOzTest is Test {
  EarnVaultUpgradeable public vault;
  MockERC20 public usdsc;
  EarnVaultV2 public v2Implementation;
  EarnVaultV3 public v3Implementation;

  address public admin = makeAddr('admin'); // ProxyAdmin owner
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

  function setUp() public {
    // Deploy mock USDSC token
    usdsc = new MockERC20('USDSC Token', 'USDSC', 6);

    // Mint USDSC to test users
    usdsc.mint(alice, INITIAL_SUPPLY);
    usdsc.mint(bob, INITIAL_SUPPLY);
    usdsc.mint(charlie, INITIAL_SUPPLY);
    usdsc.mint(yieldRedistributor, INITIAL_SUPPLY);

    // Deploy implementation contracts
    EarnVaultUpgradeable v1Implementation = new EarnVaultUpgradeable();
    v2Implementation = new EarnVaultV2();
    v3Implementation = new EarnVaultV3();

    // Deploy proxy using OpenZeppelin Foundry Upgrades (UnsafeUpgrades for tests)
    vault = EarnVaultUpgradeable(
      payable(UnsafeUpgrades.deployTransparentProxy(
          address(v1Implementation),
          admin, // ProxyAdmin owner
          abi.encodeWithSelector(
            EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, yieldRedistributor, treasury, pauser
          )
        ))
    );

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
  // Basic Functionality Tests
  // =========================

  function test_Initialize() public view {
    assertEq(vault.asset(), address(usdsc));
    assertEq(vault.owner(), owner);
    assertEq(vault.yieldRedistributor(), yieldRedistributor);
    assertEq(vault.treasury(), treasury);
    assertEq(vault.pauser(), pauser);
    assertEq(vault.globalIndex(), RAY);
    assertEq(vault.totalPrincipal(), 0);
    assertEq(vault.claimReserve(), 0);
  }

  function test_InitializeZeroUSDSC() public {
    EarnVaultUpgradeable implementation = new EarnVaultUpgradeable();

    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector));
    UnsafeUpgrades.deployTransparentProxy(
      address(implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(0), // Zero USDSC address
        owner,
        yieldRedistributor,
        treasury,
        pauser
      )
    );
  }

  function test_InitializeZeroOwner() public {
    EarnVaultUpgradeable implementation = new EarnVaultUpgradeable();

    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector));
    UnsafeUpgrades.deployTransparentProxy(
      address(implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        address(0), // Zero owner address
        yieldRedistributor,
        treasury,
        pauser
      )
    );
  }

  function test_InitializeZeroYieldRedistributor() public {
    EarnVaultUpgradeable implementation = new EarnVaultUpgradeable();

    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector));
    UnsafeUpgrades.deployTransparentProxy(
      address(implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        address(0), // Zero yield redistributor address
        treasury,
        pauser
      )
    );
  }

  function test_InitializeZeroTreasury() public {
    EarnVaultUpgradeable implementation = new EarnVaultUpgradeable();

    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector));
    UnsafeUpgrades.deployTransparentProxy(
      address(implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        yieldRedistributor,
        address(0), // Zero treasury address
        pauser
      )
    );
  }

  function test_InitializeZeroPauser() public {
    EarnVaultUpgradeable implementation = new EarnVaultUpgradeable();

    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.CanNotBeZeroAddress.selector));
    UnsafeUpgrades.deployTransparentProxy(
      address(implementation),
      admin,
      abi.encodeWithSelector(
        EarnVaultUpgradeable.initialize.selector,
        address(usdsc),
        owner,
        yieldRedistributor,
        treasury,
        address(0) // Zero pauser address
      )
    );
  }

  function test_BasicDepositAndWithdraw() public {
    // Alice deposits
    vm.prank(alice);
    vault.deposit(1000e6);

    assertEq(vault.principal(alice), 1000e6);
    assertEq(vault.totalPrincipal(), 1000e6);
    assertEq(vault.claimReserve(), 1000e6);

    // Bob deposits
    vm.prank(bob);
    vault.deposit(2000e6);

    assertEq(vault.principal(bob), 2000e6);
    assertEq(vault.totalPrincipal(), 3000e6);
    assertEq(vault.claimReserve(), 3000e6);

    // Alice withdraws
    vm.prank(alice);
    vault.withdraw(500e6);

    assertEq(vault.principal(alice), 500e6);
    assertEq(vault.totalPrincipal(), 2500e6);
    assertEq(vault.claimReserve(), 2500e6);
  }

  function test_YieldDistribution() public {
    // Set up deposits
    vm.prank(alice);
    vault.deposit(1000e6);

    vm.prank(bob);
    vault.deposit(2000e6);

    // Distribute yield
    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vault), 300e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vault.onYield(300e6);

    // Verify yield distribution
    assertTrue(vault.claimable(alice) > 0);
    assertTrue(vault.claimable(bob) > 0);
    assertTrue(vault.globalIndex() > RAY);
    assertEq(vault.claimReserve(), 3300e6); // 3000e6 principal + 300e6 yield

    // Alice claims
    uint256 aliceBalanceBefore = usdsc.balanceOf(alice);
    uint256 aliceClaimable = vault.claimable(alice);

    vm.prank(alice);
    vault.claim();

    assertEq(usdsc.balanceOf(alice), aliceBalanceBefore + aliceClaimable);
    assertEq(vault.accrued(alice), 0);
  }

  // =========================
  // Upgrade Tests using OZ Foundry Upgrades
  // =========================

  function test_V1ToV2Upgrade() public {
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

    // Upgrade to V2 using OZ Foundry Upgrades
    // Note: admin is the ProxyAdmin owner, not the vault owner
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v2Implementation), abi.encodeWithSelector(EarnVaultV2.initializeV2.selector), admin
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(vault)));

    // Verify implementation updated
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

  function test_V2ToV3Upgrade() public {
    // First upgrade to V2
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v2Implementation), abi.encodeWithSelector(EarnVaultV2.initializeV2.selector), admin
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(vault)));

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

    // Upgrade to V3 using OZ Foundry Upgrades
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v3Implementation), abi.encodeWithSelector(EarnVaultV3.initializeV3.selector), admin
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(vault)));

    // Verify implementation updated
    assertEq(vaultV3.getVersion(), 'EarnVaultV3');

    // Verify V2 state preserved
    assertEq(vaultV3.totalPrincipal(), totalPrincipalBefore);
    assertEq(vaultV3.globalIndex(), globalIndexBefore);
    assertEq(vaultV3.principal(alice), alicePrincipalBefore);
    assertEq(vaultV3.claimable(alice), aliceClaimableBefore);

    // Verify V3 initialization
    assertEq(vaultV3.getPerformanceFeeRate(), 200); // 2%
    assertEq(vaultV3.getManagementFeeRate(), 50); // 0.5%
    assertEq(vaultV3.getTotalFeesCollected(), 0);
    assertFalse(vaultV3.isAutoCompoundEnabled());
    assertEq(vaultV3.getCompoundThreshold(), 100e6);
    assertEq(vaultV3.getTotalCompounds(), 0);
  }

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
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v2Implementation), abi.encodeWithSelector(EarnVaultV2.initializeV2.selector), admin
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(vault)));

    // Set V2 features
    vm.prank(owner);
    vaultV2.setEmergencyYieldMultiplier(12_000);

    // V2 -> V3 Upgrade
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v3Implementation), abi.encodeWithSelector(EarnVaultV3.initializeV3.selector), admin
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(vault)));

    // Verify final state
    assertEq(vaultV3.getVersion(), 'EarnVaultV3');

    // Verify V1 state preserved through chain
    assertEq(vaultV3.totalPrincipal(), v1TotalPrincipal);
    assertEq(vaultV3.globalIndex(), v1GlobalIndex);
    assertEq(vaultV3.claimable(alice), v1AliceClaimable);

    // Verify V3 features initialized
    assertEq(vaultV3.getPerformanceFeeRate(), 200);
    assertEq(vaultV3.getManagementFeeRate(), 50);
    assertFalse(vaultV3.isAutoCompoundEnabled());
  }

  // =========================
  // V3 Specific Functionality Tests
  // =========================

  function test_V3FeeCollection() public {
    // Upgrade to V3
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v3Implementation), abi.encodeWithSelector(EarnVaultV3.initializeV3.selector), admin
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(vault)));

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
    // Upgrade to V3
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v3Implementation), abi.encodeWithSelector(EarnVaultV3.initializeV3.selector), admin
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(vault)));

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

  // =========================
  // ETH Safety Tests
  // =========================

  function test_CannotSendETHToVault() public {
    // Try to send ETH to vault - should fail
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.EthNotAccepted.selector));
    (bool success,) = address(vault).call{value: 1 ether}('');
    success;
  }

  function test_SweepNativeWorks() public {
    // Send ETH via selfdestruct (simulate accidental ETH)
    SelfDestructor destructor = new SelfDestructor{value: 1 ether}();

    // Selfdestruct to the vault - this bypasses receive/fallback
    destructor.selfDestruct(payable(address(vault)));

    // Verify ETH is in the vault
    assertEq(address(vault).balance, 1 ether);

    // Owner can sweep the ETH
    address payable recipient = payable(makeAddr('recipient'));
    uint256 recipientBalanceBefore = recipient.balance;

    vm.prank(owner);
    vault.sweepNative(recipient, 1 ether);

    // Verify ETH was swept
    assertEq(address(vault).balance, 0);
    assertEq(recipient.balance, recipientBalanceBefore + 1 ether);
  }

  function test_SweepNativeOnlyOwner() public {
    // Send ETH via selfdestruct
    SelfDestructor destructor = new SelfDestructor{value: 1 ether}();
    destructor.selfDestruct(payable(address(vault)));

    // Non-owner cannot sweep
    address payable recipient = payable(makeAddr('recipient'));

    vm.prank(alice);
    vm.expectRevert();
    vault.sweepNative(recipient, 1 ether);

    // Owner can sweep
    vm.prank(owner);
    vault.sweepNative(recipient, 1 ether);

    assertEq(address(vault).balance, 0);
  }

  // =========================
  // Blacklist Tests
  // =========================

  function test_BlacklistFunctionality() public {
    // Set up deposits
    vm.prank(alice);
    vault.deposit(1000e6);

    vm.prank(bob);
    vault.deposit(2000e6);

    // Blacklist Alice
    vm.prank(owner);
    vault.setBlacklisted(alice, true);

    // Verify blacklist status
    assertTrue(vault.isBlacklisted(alice));
    assertFalse(vault.isBlacklisted(bob));

    // Verify blacklisted user cannot deposit
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.AddressBlacklisted.selector));
    vault.deposit(100e6);

    // Verify non-blacklisted user can deposit
    vm.prank(bob);
    vault.deposit(500e6);
    assertEq(vault.principal(bob), 2500e6);

    // Verify blacklisted user cannot claim
    vm.prank(yieldRedistributor);
    bool success = usdsc.transfer(address(vault), 100e6);
    require(success, 'Transfer failed');
    vm.prank(yieldRedistributor);
    vault.onYield(100e6);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.AddressBlacklisted.selector));
    vault.claim();

    // Verify non-blacklisted user can claim
    uint256 bobBalanceBefore = usdsc.balanceOf(bob);
    vm.prank(bob);
    vault.claim();
    assertTrue(usdsc.balanceOf(bob) > bobBalanceBefore);
  }

  function test_BlacklistPreservedAcrossUpgrades() public {
    // Set up deposits and blacklist
    vm.prank(alice);
    vault.deposit(1000e6);

    vm.prank(bob);
    vault.deposit(2000e6);

    vm.prank(owner);
    vault.setBlacklisted(alice, true);

    // Verify blacklist status in V1
    assertTrue(vault.isBlacklisted(alice));
    assertFalse(vault.isBlacklisted(bob));

    // Upgrade to V2
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v2Implementation), abi.encodeWithSelector(EarnVaultV2.initializeV2.selector), admin
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(vault)));

    // Verify blacklist status preserved in V2
    assertTrue(vaultV2.isBlacklisted(alice));
    assertFalse(vaultV2.isBlacklisted(bob));

    // Upgrade to V3
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v3Implementation), abi.encodeWithSelector(EarnVaultV3.initializeV3.selector), admin
    );

    EarnVaultV3 vaultV3 = EarnVaultV3(payable(address(vault)));

    // Verify blacklist status preserved in V3
    assertTrue(vaultV3.isBlacklisted(alice));
    assertFalse(vaultV3.isBlacklisted(bob));

    // Verify blacklist enforcement still works
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IEarnVaultEventsAndErrors.AddressBlacklisted.selector));
    vaultV3.deposit(100e6);

    vm.prank(bob);
    vaultV3.deposit(500e6);
    assertEq(vaultV3.principal(bob), 2500e6);
  }

  // =========================
  // Pause Functionality Tests
  // =========================

  function test_PauseFunctionality() public {
    // Set up deposits
    vm.prank(alice);
    vault.deposit(1000e6);

    // Pause the contract
    vm.prank(pauser);
    vault.pause();
    assertTrue(vault.paused());

    // Verify deposits are blocked when paused
    vm.prank(bob);
    vm.expectRevert();
    vault.deposit(500e6);

    // Verify withdrawals are blocked when paused
    vm.prank(alice);
    vm.expectRevert();
    vault.withdraw(100e6);

    // Unpause and verify functionality resumes
    vm.prank(pauser);
    vault.unpause();
    assertFalse(vault.paused());

    vm.prank(bob);
    vault.deposit(500e6);
    assertEq(vault.principal(bob), 500e6);
  }

  function test_PausePreservedAcrossUpgrades() public {
    // Set up deposits and pause
    vm.prank(alice);
    vault.deposit(1000e6);

    vm.prank(pauser);
    vault.pause();
    assertTrue(vault.paused());

    // Upgrade to V2
    UnsafeUpgrades.upgradeProxy(
      address(vault), address(v2Implementation), abi.encodeWithSelector(EarnVaultV2.initializeV2.selector), admin
    );

    EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(vault)));

    // Verify still paused after upgrade
    assertTrue(vaultV2.paused());

    // Unpause and verify functionality works
    vm.prank(pauser);
    vaultV2.unpause();
    assertFalse(vaultV2.paused());

    vm.prank(alice);
    vaultV2.withdraw(100e6);
    assertEq(vaultV2.principal(alice), 900e6);
  }
}
