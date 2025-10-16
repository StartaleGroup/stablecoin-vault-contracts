// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {EarnVaultUpgradeable} from "../../src/vaults/earn/EarnVaultUpgradeable.sol";
import {EarnVaultUpgradeableHarness} from "../harness/EarnVaultUpgradeableHarness.sol";
import {EarnVaultV2} from "../mocks/EarnVaultV2.sol";
import {IEarnVaultEventsAndErrors} from "../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';

contract EarnVaultUpgradeableSimpleTest is Test {
    EarnVaultUpgradeable public vault;
    MockERC20 public usdsc;
    ProxyAdmin internal proxyAdmin;
    TransparentUpgradeableProxy internal proxy;
    EarnVaultUpgradeableHarness internal implementation;
    EarnVaultV2 internal v2Implementation;
    
    address public admin = makeAddr('admin'); // ProxyAdmin owner (for upgrades)
    address public owner = makeAddr("owner"); // vault owner
    address public yieldRedistributor = makeAddr("yieldRedistributor");
    address public treasury = makeAddr("treasury");
    address public pauser = makeAddr("pauser");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

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
        usdsc = new MockERC20("USDSC Token", "USDSC", 6);

        // Mint USDSC to test users
        usdsc.mint(alice, INITIAL_SUPPLY);
        usdsc.mint(bob, INITIAL_SUPPLY);
        usdsc.mint(charlie, INITIAL_SUPPLY);
        usdsc.mint(yieldRedistributor, INITIAL_SUPPLY);

        // Deploy EarnVault implementation contracts
        implementation = new EarnVaultUpgradeableHarness();
        v2Implementation = new EarnVaultV2();

        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin, // OpenZeppelin v5 creates ProxyAdmin automatically with this as admin
            abi.encodeWithSelector(
                EarnVaultUpgradeable.initialize.selector,
                address(usdsc),
                owner,
                yieldRedistributor,
                treasury,
                pauser
            )
        );
        vault = EarnVaultUpgradeable(payable(address(proxy)));

        // Get the auto-created ProxyAdmin from the proxy using ERC1967 admin slot
        // keccak256("eip1967.proxy.admin") - 1
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
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

    function test_initialize() public view {
        assertEq(vault.asset(), address(usdsc));
        assertEq(vault.owner(), owner);
        assertEq(vault.yieldRedistributor(), yieldRedistributor);
        assertEq(vault.treasury(), treasury);
        assertEq(vault.pauser(), pauser);
    }

    function test_getImplementation() public view {
        EarnVaultUpgradeableHarness harness = EarnVaultUpgradeableHarness(payable(address(proxy)));
        assertEq(harness.getImplementation(), address(implementation));
    }

    // =========================
    // Initialization Tests
    // =========================

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        vault.initialize(
            address(usdsc),
            owner,
            yieldRedistributor,
            treasury,
            pauser
        );
    }

    function test_CannotInitializeImplementationDirectly() public {
        EarnVaultUpgradeableHarness impl = new EarnVaultUpgradeableHarness();
        vm.expectRevert();
        impl.initialize(
            address(usdsc),
            owner,
            yieldRedistributor,
            treasury,
            pauser
        );
    }

    function test_InitializationSetsCorrectValues() public view {
        assertEq(vault.asset(), address(usdsc));
        assertEq(vault.owner(), owner);
        assertEq(vault.yieldRedistributor(), yieldRedistributor);
        assertEq(vault.treasury(), treasury);
        assertEq(vault.pauser(), pauser);
        assertEq(vault.globalIndex(), RAY);
        assertEq(vault.totalPrincipal(), 0);
        assertEq(vault.claimReserve(), 0);
    }

    // =========================
    // Upgrade Tests
    // =========================

    function test_OnlyAdminCanUpgrade() public {
        EarnVaultV2 newImpl = new EarnVaultV2();
        
        // Non-admin cannot upgrade
        vm.prank(alice);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        // Owner cannot upgrade (only admin can)
        vm.prank(owner);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        // Admin can upgrade
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
    }

    function test_UpgradeEmitsEvent() public {
        EarnVaultV2 newImpl = new EarnVaultV2();
        
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Upgraded(address(newImpl));
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
    }

    function test_UpgradePreservesBasicState() public {
        // Set up some state
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Capture state before upgrade
        uint256 totalPrincipalBefore = vault.totalPrincipal();
        uint256 globalIndexBefore = vault.globalIndex();
        uint256 claimReserveBefore = vault.claimReserve();
        uint256 alicePrincipalBefore = vault.principal(alice);
        uint256 aliceClaimableBefore = vault.claimable(alice);
        
        // Upgrade and initialize V2
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)), 
            address(newImpl), 
            abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
        );
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        
        // Verify state is preserved
        assertEq(vaultV2.totalPrincipal(), totalPrincipalBefore);
        assertEq(vaultV2.globalIndex(), globalIndexBefore);
        assertEq(vaultV2.claimReserve(), claimReserveBefore);
        assertEq(vaultV2.principal(alice), alicePrincipalBefore);
        assertEq(vaultV2.claimable(alice), aliceClaimableBefore);
        
        // Verify basic functionality still works
        assertEq(vaultV2.asset(), address(usdsc));
        assertEq(vaultV2.owner(), owner);
        assertEq(vaultV2.yieldRedistributor(), yieldRedistributor);
    }

    function test_UpgradePreservesBalances() public {
        // Set up deposits and yield
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(bob);
        vault.deposit(2000e6);
        
        // Distribute yield
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 300e6);
        vm.prank(yieldRedistributor);
        vault.onYield(300e6);
        
        // Capture balances before upgrade
        uint256 alicePrincipal = vault.principal(alice);
        uint256 aliceClaimable = vault.claimable(alice);
        uint256 bobPrincipal = vault.principal(bob);
        uint256 bobClaimable = vault.claimable(bob);
        uint256 vaultBalance = usdsc.balanceOf(address(vault));
        
        // Upgrade and initialize V2
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)), 
            address(newImpl), 
            abi.encodeWithSelector(EarnVaultV2.initializeV2.selector)
        );
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        
        // Verify balances are preserved
        assertEq(vaultV2.principal(alice), alicePrincipal);
        assertEq(vaultV2.claimable(alice), aliceClaimable);
        assertEq(vaultV2.principal(bob), bobPrincipal);
        assertEq(vaultV2.claimable(bob), bobClaimable);
        assertEq(usdsc.balanceOf(address(vaultV2)), vaultBalance);
    }

    // =========================
    // Functionality Tests (Before & After Upgrade)
    // =========================

    function test_DepositWorksBeforeAndAfterUpgrade() public {
        // Test deposit before upgrade
        vm.prank(alice);
        vault.deposit(1000e6);
        assertEq(vault.principal(alice), 1000e6);
        assertEq(vault.totalPrincipal(), 1000e6);
        
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Test deposit after upgrade
        vm.prank(bob);
        vaultV2.deposit(2000e6);
        assertEq(vaultV2.principal(bob), 2000e6);
        assertEq(vaultV2.totalPrincipal(), 3000e6);
    }

    function test_WithdrawWorksBeforeAndAfterUpgrade() public {
        // Set up deposit
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Distribute yield
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Test withdraw after upgrade
        uint256 aliceBalanceBefore = usdsc.balanceOf(alice);
        uint256 aliceClaimableBefore = vaultV2.claimable(alice);
        vm.prank(alice);
        vaultV2.withdraw(500e6);
        
        assertEq(vaultV2.principal(alice), 500e6);
        assertEq(usdsc.balanceOf(alice), aliceBalanceBefore + 500e6 + aliceClaimableBefore);
    }

    function test_ClaimWorksBeforeAndAfterUpgrade() public {
        // Set up deposit and yield
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Test claim after upgrade
        uint256 claimableAmount = vaultV2.claimable(alice);
        uint256 aliceBalanceBefore = usdsc.balanceOf(alice);
        
        vm.prank(alice);
        vaultV2.claim();
        
        assertEq(usdsc.balanceOf(alice), aliceBalanceBefore + claimableAmount);
        assertEq(vaultV2.accrued(alice), 0);
    }

    function test_YieldDistributionWorksBeforeAndAfterUpgrade() public {
        // Set up deposits
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(bob);
        vault.deposit(2000e6);
        
        // Test yield distribution before upgrade
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 300e6);
        vm.prank(yieldRedistributor);
        vault.onYield(300e6);
        
        uint256 aliceClaimableBefore = vault.claimable(alice);
        uint256 bobClaimableBefore = vault.claimable(bob);
        
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Test yield distribution after upgrade
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vaultV2), 200e6);
        vm.prank(yieldRedistributor);
        vaultV2.onYield(200e6);
        
        // Verify new yield is distributed correctly
        assertTrue(vaultV2.claimable(alice) > aliceClaimableBefore);
        assertTrue(vaultV2.claimable(bob) > bobClaimableBefore);
    }

    function test_AdminFunctionsWorkAfterUpgrade() public {
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Test admin functions still work
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        vaultV2.setTreasury(newTreasury);
        assertEq(vaultV2.treasury(), newTreasury);
        
        address newPauser = makeAddr("newPauser");
        vm.prank(owner);
        vaultV2.setPauser(newPauser);
        assertEq(vaultV2.pauser(), newPauser);
    }

    function test_V2NewFeaturesWork() public {
        // Upgrade to V2
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Test V2 specific features
        assertEq(vaultV2.getEmergencyYieldMultiplier(), 10000); // Default 100%
        assertFalse(vaultV2.isEmergencyModeActive());
        
        // Test setting emergency multiplier
        vm.prank(owner);
        vaultV2.setEmergencyYieldMultiplier(15000); // 150%
        assertEq(vaultV2.getEmergencyYieldMultiplier(), 15000);
        
        // Test toggling emergency mode
        vm.prank(owner);
        vaultV2.setEmergencyMode(true);
        assertTrue(vaultV2.isEmergencyModeActive());
    }

    function test_PauseWorksAfterUpgrade() public {
        // Set up some deposits
        vm.prank(alice);
        vault.deposit(1000e6);
        
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Test pause functionality after upgrade
        vm.prank(pauser);
        vaultV2.pause();
        assertTrue(vaultV2.paused());
        
        // Verify deposits are blocked when paused
        vm.prank(bob);
        vm.expectRevert();
        vaultV2.deposit(500e6);
        
        // Verify withdrawals are blocked when paused
        vm.prank(alice);
        vm.expectRevert();
        vaultV2.withdraw(100e6);
        
        // Unpause and verify functionality resumes
        vm.prank(pauser);
        vaultV2.unpause();
        assertFalse(vaultV2.paused());
        
        vm.prank(bob);
        vaultV2.deposit(500e6);
        assertEq(vaultV2.principal(bob), 500e6);
    }

    function test_UpgradeWhilePaused() public {
        // Set up deposits and pause
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());
        
        // Capture state while paused
        uint256 totalPrincipalBefore = vault.totalPrincipal();
        uint256 alicePrincipalBefore = vault.principal(alice);
        
        // Upgrade while paused
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Verify state is preserved and still paused
        assertEq(vaultV2.totalPrincipal(), totalPrincipalBefore);
        assertEq(vaultV2.principal(alice), alicePrincipalBefore);
        assertTrue(vaultV2.paused());
        
        // Unpause and verify functionality works
        vm.prank(pauser);
        vaultV2.unpause();
        assertFalse(vaultV2.paused());
        
        vm.prank(alice);
        vaultV2.withdraw(100e6);
        assertEq(vaultV2.principal(alice), 900e6);
    }

    function test_UpgradeWithAccumulatedYield() public {
        // Set up deposits and multiple yield distributions
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(bob);
        vault.deposit(2000e6);
        
        // First yield distribution
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 100e6);
        vm.prank(yieldRedistributor);
        vault.onYield(100e6);
        
        // Second yield distribution
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 200e6);
        vm.prank(yieldRedistributor);
        vault.onYield(200e6);
        
        // Capture accumulated yield before upgrade
        uint256 aliceClaimableBefore = vault.claimable(alice);
        uint256 bobClaimableBefore = vault.claimable(bob);
        uint256 globalIndexBefore = vault.globalIndex();
        uint256 claimReserveBefore = vault.claimReserve();
        
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Verify accumulated yield is preserved
        assertEq(vaultV2.claimable(alice), aliceClaimableBefore);
        assertEq(vaultV2.claimable(bob), bobClaimableBefore);
        assertEq(vaultV2.globalIndex(), globalIndexBefore);
        assertEq(vaultV2.claimReserve(), claimReserveBefore);
        
        // Test claiming accumulated yield after upgrade
        uint256 aliceBalanceBefore = usdsc.balanceOf(alice);
        vm.prank(alice);
        vaultV2.claim();
        assertEq(usdsc.balanceOf(alice), aliceBalanceBefore + aliceClaimableBefore);
        assertEq(vaultV2.accrued(alice), 0);
    }

    function test_UpgradeDoesNotResetRolesOrStates() public {
        // Set up some state and roles
        vm.prank(alice);
        vault.deposit(1000e6);
        
        address newTreasury = makeAddr("newTreasury");
        address newPauser = makeAddr("newPauser");
        address newRedistributor = makeAddr("newRedistributor");
        
        vm.prank(owner);
        vault.setTreasury(newTreasury);
        vm.prank(owner);
        vault.setPauser(newPauser);
        vm.prank(owner);
        vault.setYieldRedistributor(newRedistributor);
        
        // Capture all state before upgrade
        uint256 totalPrincipalBefore = vault.totalPrincipal();
        uint256 globalIndexBefore = vault.globalIndex();
        uint256 alicePrincipalBefore = vault.principal(alice);
        
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Verify roles are preserved
        assertEq(vaultV2.owner(), owner);
        assertEq(vaultV2.treasury(), newTreasury);
        assertEq(vaultV2.pauser(), newPauser);
        assertEq(vaultV2.yieldRedistributor(), newRedistributor);
        
        // Verify state is preserved
        assertEq(vaultV2.totalPrincipal(), totalPrincipalBefore);
        assertEq(vaultV2.globalIndex(), globalIndexBefore);
        assertEq(vaultV2.principal(alice), alicePrincipalBefore);
        
        // Verify roles still work
        address newerTreasury = makeAddr("newerTreasury");
        vm.prank(owner);
        vaultV2.setTreasury(newerTreasury);
        assertEq(vaultV2.treasury(), newerTreasury);
    }

    function test_ViewFunctionsWorkAfterUpgrade() public {
        // Set up deposits and yield
        vm.prank(alice);
        vault.deposit(1000e6);
        
        vm.prank(bob);
        vault.deposit(2000e6);
        
        vm.prank(yieldRedistributor);
        usdsc.transfer(address(vault), 300e6);
        vm.prank(yieldRedistributor);
        vault.onYield(300e6);
        
        // Upgrade
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Test all view functions work after upgrade
        assertEq(vaultV2.asset(), address(usdsc));
        assertEq(vaultV2.totalPrincipal(), 3000e6);
        assertEq(vaultV2.globalIndex(), vault.globalIndex());
        assertEq(vaultV2.claimReserve(), vault.claimReserve());
        
        // Test user-specific view functions
        assertEq(vaultV2.principal(alice), 1000e6);
        assertEq(vaultV2.principal(bob), 2000e6);
        assertEq(vaultV2.claimable(alice), vault.claimable(alice));
        assertEq(vaultV2.claimable(bob), vault.claimable(bob));
        assertEq(vaultV2.totalValue(alice), vault.totalValue(alice));
        assertEq(vaultV2.totalValue(bob), vault.totalValue(bob));
        
        // Test getUserInfo function
        (uint256 alicePrincipal, uint256 aliceClaimable, uint256 aliceTotal, uint256 aliceIndex) = vaultV2.getUserInfo(alice);
        assertEq(alicePrincipal, 1000e6);
        assertEq(aliceClaimable, vault.claimable(alice));
        assertEq(aliceTotal, vault.totalValue(alice));
        assertEq(aliceIndex, vault.userIndex(alice));
        
        // Test getVaultStats function
        (uint256 vaultTotalPrincipal, uint256 vaultClaimReserve, uint256 vaultGlobalIndex, uint256 vaultBalance, uint256 vaultCarryRay) = vaultV2.getVaultStats();
        assertEq(vaultTotalPrincipal, 3000e6);
        assertEq(vaultClaimReserve, vault.claimReserve());
        assertEq(vaultGlobalIndex, vault.globalIndex());
        assertEq(vaultBalance, usdsc.balanceOf(address(vaultV2)));
        // vaultCarryRay is internal implementation detail, just verify it's returned
        assertTrue(vaultCarryRay >= 0);
    }

    function test_V2NewFunctionality() public {
        // Upgrade to V2
        EarnVaultV2 newImpl = new EarnVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
        
        EarnVaultV2 vaultV2 = EarnVaultV2(payable(address(proxy)));
        vaultV2.initializeV2();
        
        // Verify implementation address is correct
        assertEq(_getImplementation(), address(newImpl));
        
        // Test V2 version info
        assertEq(vaultV2.getVersion(), "EarnVaultV2");
        
        // Test V2 specific storage and functionality
        assertEq(vaultV2.getEmergencyYieldMultiplier(), 10000); // Default 100%
        assertFalse(vaultV2.isEmergencyModeActive());
        
        // Test emergency mode functionality
        vm.prank(owner);
        vaultV2.setEmergencyMode(true);
        assertTrue(vaultV2.isEmergencyModeActive());
        
        // Test emergency yield multiplier
        vm.prank(owner);
        vaultV2.setEmergencyYieldMultiplier(15000); // 150%
        assertEq(vaultV2.getEmergencyYieldMultiplier(), 15000);
        
        // Test that V2 functions are accessible
        vm.prank(owner);
        vaultV2.setEmergencyMode(false);
        assertFalse(vaultV2.isEmergencyModeActive());
        
        // Verify V2 storage doesn't interfere with V1 storage
        assertEq(vaultV2.totalPrincipal(), 0); // Should still be 0 from initialization
        assertEq(vaultV2.globalIndex(), RAY); // Should still be RAY from initialization
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getImplementation() internal view returns (address) {
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        return address(uint160(uint256(vm.load(address(proxy), implementationSlot))));
    }
}
    