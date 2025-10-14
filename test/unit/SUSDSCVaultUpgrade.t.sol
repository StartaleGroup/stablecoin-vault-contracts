// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from 'forge-std/Test.sol';
import {SUSDSCVault} from '../../src/vaults/4626/SUSDSCVault.sol';
import {MockSUSDSCVaultV2} from '../mocks/MockSUSDSCVaultV2.sol';
import {USDSC} from '../../src/coin/mock/USDSC.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title SUSDSCVaultUpgradeTest
 * @notice Comprehensive tests for SUSDSCVault upgradability
 * @dev Tests upgrade functionality, storage preservation, and access control
 */
contract SUSDSCVaultUpgradeTest is Test {
    SUSDSCVault internal vault;
    USDSC internal usdsc;
    MockM internal mToken;
    MockSwapFacility internal swapFacility;
    ProxyAdmin internal proxyAdmin;
    TransparentUpgradeableProxy internal proxy;

    address internal admin = makeAddr('admin'); // ProxyAdmin owner (for upgrades)
    address internal vaultAdmin = makeAddr('vaultAdmin'); // Vault DEFAULT_ADMIN_ROLE (for role management)
    address internal pauser = makeAddr('pauser');
    address internal yieldRecipient = makeAddr('yieldRecipient');
    address internal user1 = makeAddr('user1');
    address internal user2 = makeAddr('user2');
    address internal attacker = makeAddr('attacker');

    uint256 internal constant INITIAL_BALANCE = 10000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 1000e6;

    event Upgraded(address indexed implementation);

    function setUp() external {
        _deployContracts();
        _setupUsers();
    }

    function _deployContracts() internal {
        vm.startPrank(admin);

        // Deploy dependencies
        mToken = new MockM();
        swapFacility = new MockSwapFacility();

        // Deploy USDSC with proxy
        USDSC usdscImplementation = new USDSC(address(mToken), address(swapFacility));
        TransparentUpgradeableProxy usdscProxy = new TransparentUpgradeableProxy(
            address(usdscImplementation),
            admin, // OpenZeppelin v5 creates ProxyAdmin automatically with this as owner
            abi.encodeWithSelector(USDSC.initialize.selector, 'USDSC', 'USDSC', vaultAdmin, yieldRecipient)
        );
        usdsc = USDSC(address(usdscProxy));

        // Deploy SUSDSCVault with proxy
        SUSDSCVault vaultImplementation = new SUSDSCVault();
        proxy = new TransparentUpgradeableProxy(
            address(vaultImplementation),
            admin, // OpenZeppelin v5 creates ProxyAdmin automatically with this as owner
            abi.encodeWithSelector(
                SUSDSCVault.initialize.selector,
                IERC20(address(usdsc)),
                vaultAdmin, // Vault admin for role management
                pauser
            )
        );
        vault = SUSDSCVault(address(proxy));
        
        // Get the auto-created ProxyAdmin from the proxy using ERC1967 admin slot
        // keccak256("eip1967.proxy.admin") - 1
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        address proxyAdminAddress = address(uint160(uint256(vm.load(address(proxy), adminSlot))));
        proxyAdmin = ProxyAdmin(proxyAdminAddress);
        

        vm.stopPrank();
    }

    function _setupUsers() internal {
        // Mint USDSC to users via M token and swap facility
        deal(address(mToken), user1, INITIAL_BALANCE);
        deal(address(mToken), user2, INITIAL_BALANCE);

        // User1 wraps M tokens to USDSC
        vm.startPrank(user1);
        mToken.transfer(address(swapFacility), INITIAL_BALANCE);
        vm.stopPrank();
        vm.startPrank(address(swapFacility));
        usdsc.wrap(user1, INITIAL_BALANCE);
        vm.stopPrank();

        // User2 wraps M tokens to USDSC
        vm.startPrank(user2);
        mToken.transfer(address(swapFacility), INITIAL_BALANCE);
        vm.stopPrank();
        vm.startPrank(address(swapFacility));
        usdsc.wrap(user2, INITIAL_BALANCE);
        vm.stopPrank();

        // Approve vault
        vm.prank(user1);
        usdsc.approve(address(vault), type(uint256).max);

        vm.prank(user2);
        usdsc.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        vault.initialize(IERC20(address(usdsc)), admin, pauser);
    }

    function test_CannotInitializeImplementationDirectly() public {
        SUSDSCVault implementation = new SUSDSCVault();
        
        vm.expectRevert();
        implementation.initialize(IERC20(address(usdsc)), admin, pauser);
    }

    function test_InitializationSetsCorrectValues() public view {
        assertEq(vault.name(), 'Staked USDSC');
        assertEq(vault.symbol(), 'sUSDSC');
        assertEq(address(vault.asset()), address(usdsc));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), vaultAdmin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
    }

    /*//////////////////////////////////////////////////////////////
                        UPGRADE AUTHORIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnlyAdminCanUpgrade() public {
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();

        // Non-admin cannot upgrade
        vm.prank(attacker);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Admin can upgrade
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");
    }

    function test_UpgradeEmitsEvent() public {
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit Upgraded(address(newImplementation));
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");
    }

    /*//////////////////////////////////////////////////////////////
                    STORAGE PRESERVATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpgradePreservesBasicState() public {
        // Record initial state
        string memory nameBefore = vault.name();
        string memory symbolBefore = vault.symbol();
        address assetBefore = address(vault.asset());
        
        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify state preserved
        assertEq(vault.name(), nameBefore);
        assertEq(vault.symbol(), symbolBefore);
        assertEq(address(vault.asset()), assetBefore);
    }

    function test_UpgradePreservesRoles() public {
        // Record roles before upgrade
        bool vaultAdminRoleBefore = vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), vaultAdmin);
        bool pauserRoleBefore = vault.hasRole(vault.PAUSER_ROLE(), pauser);

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify roles preserved
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), vaultAdmin), vaultAdminRoleBefore);
        assertEq(vault.hasRole(vault.PAUSER_ROLE(), pauser), pauserRoleBefore);
    }

    function test_UpgradePreservesBalances() public {
        // User1 deposits
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        uint256 sharesBefore = vault.balanceOf(user1);
        uint256 assetsBefore = vault.totalAssets();

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify balances preserved
        assertEq(vault.balanceOf(user1), sharesBefore);
        assertEq(vault.totalAssets(), assetsBefore);
    }

    function test_UpgradePreservesPricePerShare() public {
        // User1 deposits
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        // Simulate yield (transfer USDSC from yieldDistributor to vault)
        deal(address(mToken), yieldRecipient, DEPOSIT_AMOUNT);
        vm.prank(yieldRecipient);
        mToken.transfer(address(swapFacility), DEPOSIT_AMOUNT);
        vm.prank(address(swapFacility));
        usdsc.wrap(address(vault), DEPOSIT_AMOUNT);

        uint256 ppsBefore = vault.convertToAssets(1e6);

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify PPS preserved
        assertEq(vault.convertToAssets(1e6), ppsBefore);
    }

    function test_UpgradePreservesPausedState() public {
        // Pause the vault
        vm.prank(pauser);
        vault.pause(true);

        bool pausedBefore = vault.paused();

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify paused state preserved
        assertEq(vault.paused(), pausedBefore);
        assertTrue(vault.paused());
    }

    /*//////////////////////////////////////////////////////////////
                FUNCTIONALITY AFTER UPGRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositWorksAfterUpgrade() public {
        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Test deposit
        vm.prank(user1);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(user1), shares);
    }

    function test_WithdrawWorksAfterUpgrade() public {
        // User deposits before upgrade
        vm.prank(user1);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Test withdraw
        vm.prank(user1);
        uint256 assets = vault.redeem(shares, user1, user1);

        assertEq(assets, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(user1), 0);
    }

    function test_PauseWorksAfterUpgrade() public {
        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Test pause
        vm.prank(pauser);
        vault.pause(true);

        assertTrue(vault.paused());

        // Test unpause
        vm.prank(pauser);
        vault.pause(false);

        assertFalse(vault.paused());
    }

    function test_AccessControlWorksAfterUpgrade() public {
        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Test that non-pauser cannot pause
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause(true);

        // Test that vault admin can grant roles
        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.prank(vaultAdmin);
        vault.grantRole(pauserRole, user2);

        assertTrue(vault.hasRole(pauserRole, user2));
    }

    /*//////////////////////////////////////////////////////////////
                    COMPLEX UPGRADE SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_UpgradeWithMultipleDepositors() public {
        // Multiple users deposit
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        vm.prank(user2);
        vault.deposit(DEPOSIT_AMOUNT * 2, user2);

        uint256 user1SharesBefore = vault.balanceOf(user1);
        uint256 user2SharesBefore = vault.balanceOf(user2);
        uint256 totalAssetsBefore = vault.totalAssets();

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify all balances preserved
        assertEq(vault.balanceOf(user1), user1SharesBefore);
        assertEq(vault.balanceOf(user2), user2SharesBefore);
        assertEq(vault.totalAssets(), totalAssetsBefore);

        // Verify both users can still withdraw
        vm.prank(user1);
        vault.redeem(user1SharesBefore, user1, user1);

        vm.prank(user2);
        vault.redeem(user2SharesBefore, user2, user2);

        assertEq(vault.totalAssets(), 0);
    }

    function test_UpgradeWhilePaused() public {
        // Pause vault
        vm.prank(pauser);
        vault.pause(true);

        // User1 deposits before pause
        vm.prank(pauser);
        vault.pause(false);
        
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        vm.prank(pauser);
        vault.pause(true);

        uint256 sharesBefore = vault.balanceOf(user1);

        // Upgrade while paused
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify still paused
        assertTrue(vault.paused());

        // Verify balances preserved
        assertEq(vault.balanceOf(user1), sharesBefore);

        // Unpause and verify functionality
        vm.prank(pauser);
        vault.pause(false);

        vm.prank(user1);
        vault.redeem(sharesBefore, user1, user1);
    }

    function test_UpgradeWithAccumulatedYield() public {
        // User deposits
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        // Simulate yield accumulation (50% yield)
        uint256 yieldAmount = DEPOSIT_AMOUNT / 2;
        deal(address(mToken), yieldRecipient, yieldAmount);
        vm.prank(yieldRecipient);
        mToken.transfer(address(swapFacility), yieldAmount);
        vm.prank(address(swapFacility));
        usdsc.wrap(address(vault), yieldAmount);

        uint256 assetsBefore = vault.totalAssets();
        uint256 sharesBefore = vault.balanceOf(user1);
        uint256 ppsBefore = vault.convertToAssets(1e6);

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify yield preserved
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.balanceOf(user1), sharesBefore);
        assertEq(vault.convertToAssets(1e6), ppsBefore);

        // Verify user gets yield on withdrawal
        vm.prank(user1);
        uint256 withdrawn = vault.redeem(sharesBefore, user1, user1);
        
        assertGt(withdrawn, DEPOSIT_AMOUNT); // Should get more than deposited due to yield
    }

    function test_MultipleSequentialUpgrades() public {
        // Initial deposit
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        uint256 initialShares = vault.balanceOf(user1);

        // First upgrade
        MockSUSDSCVaultV2 newImplementation1 = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation1), "");

        assertEq(vault.balanceOf(user1), initialShares);

        // Second upgrade
        MockSUSDSCVaultV2 newImplementation2 = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation2), "");

        assertEq(vault.balanceOf(user1), initialShares);

        // Third upgrade
        MockSUSDSCVaultV2 newImplementation3 = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation3), "");

        // Verify state preserved through all upgrades
        assertEq(vault.balanceOf(user1), initialShares);
        
        // Verify functionality still works
        vm.prank(user1);
        vault.redeem(initialShares, user1, user1);
    }

    /*//////////////////////////////////////////////////////////////
                        SECURITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CannotUpgradeToZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(0), "");
    }

    function test_ProxyAdminOwnerCannotBeChanged() public {
        address currentOwner = proxyAdmin.owner();
        
        vm.prank(attacker);
        vm.expectRevert();
        proxyAdmin.transferOwnership(attacker);

        assertEq(proxyAdmin.owner(), currentOwner);
    }

    function test_UpgradeDoesNotResetRoles() public {
        // Debug: print addresses
        
        // Grant additional role
        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.prank(vaultAdmin);
        vault.grantRole(pauserRole, user1);

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Verify role still exists
        assertTrue(vault.hasRole(pauserRole, user1));

        // Verify user1 can still use the role
        vm.prank(user1);
        vault.pause(true);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ViewFunctionsWorkAfterUpgrade() public {
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        // Upgrade
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Test view functions
        assertEq(vault.totalSupply(), vault.balanceOf(user1));
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
        assertGt(vault.convertToShares(DEPOSIT_AMOUNT), 0);
        assertGt(vault.convertToAssets(vault.balanceOf(user1)), 0);
        assertGt(vault.maxDeposit(user2), 0);
        assertGt(vault.maxMint(user2), 0);
        assertGt(vault.maxWithdraw(user1), 0);
        assertGt(vault.maxRedeem(user1), 0);
    }

    function test_V2NewFunctionality() public {
        // Upgrade to V2
        MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), "");

        // Cast to V2 to access new functionality
        MockSUSDSCVaultV2 vaultV2 = MockSUSDSCVaultV2(address(vault));

        // Test new variable starts at 0
        assertEq(vaultV2.getNewVariable(), 0);

        // Test version function
        assertEq(vaultV2.version(), "2.0.0");

        // Test only admin can set new variable
        vm.prank(attacker);
        vm.expectRevert();
        vaultV2.setNewVariable(12345);

        // Test vault admin can set new variable
        vm.prank(vaultAdmin);
        vm.expectEmit(true, false, false, true);
        emit MockSUSDSCVaultV2.NewVariableSet(12345);
        vaultV2.setNewVariable(12345);

        // Verify new variable was set
        assertEq(vaultV2.getNewVariable(), 12345);

        // Verify original functionality still works
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        assertGt(vault.balanceOf(user1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getImplementation() internal view returns (address) {
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        return address(uint160(uint256(vm.load(address(proxy), implementationSlot))));
    }
}
