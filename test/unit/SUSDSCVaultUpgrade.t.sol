// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {USDSC} from '../../src/coin/mock/USDSC.sol';
import {ISUSDSCVaultEventsAndErrors} from '../../src/interfaces/vaults/4626/ISUSDSCVaultEventsAndErrors.sol';
import {SUSDSCVaultUpgradable} from '../../src/vaults/4626/SUSDSCVaultUpgradable.sol';
import {MockSUSDSCVaultV2} from '../mocks/MockSUSDSCVaultV2.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ITransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';

/**
 * @title SUSDSCVaultUpgradeTest
 * @notice Comprehensive tests for SUSDSCVaultUpgradable upgradability
 * @dev Tests upgrade functionality, storage preservation, and access control
 */
contract SUSDSCVaultUpgradeTest is Test {
  SUSDSCVaultUpgradable internal vault;
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

  uint256 internal constant INITIAL_BALANCE = 10_000e6;
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
      // See: https://docs.openzeppelin.com/contracts/5.x/api/proxy#TransparentUpgradeableProxy
      abi.encodeWithSelector(USDSC.initialize.selector, 'USDSC', 'USDSC', vaultAdmin, yieldRecipient)
    );
    usdsc = USDSC(address(usdscProxy));

    // Deploy SUSDSCVaultUpgradable with proxy
    SUSDSCVaultUpgradable vaultImplementation = new SUSDSCVaultUpgradable();
    proxy = new TransparentUpgradeableProxy(
      address(vaultImplementation),
      admin, // OpenZeppelin v5 creates ProxyAdmin automatically with this as owner
      // See: https://docs.openzeppelin.com/contracts/5.x/api/proxy#TransparentUpgradeableProxy
      abi.encodeWithSelector(
        SUSDSCVaultUpgradable.initialize.selector,
        IERC20(address(usdsc)),
        vaultAdmin, // Vault admin for role management
        pauser
      )
    );
    vault = SUSDSCVaultUpgradable(address(proxy));

    // Get the auto-created ProxyAdmin from the proxy using ERC1967 admin slot
    // keccak256("eip1967.proxy.admin") - 1
    bytes32 adminSlot = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
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
    bool success = mToken.transfer(address(swapFacility), INITIAL_BALANCE);
    require(success, 'Transfer failed');
    vm.stopPrank();
    vm.startPrank(address(swapFacility));
    usdsc.wrap(user1, INITIAL_BALANCE);
    vm.stopPrank();

    // User2 wraps M tokens to USDSC
    vm.startPrank(user2);
    bool success2 = mToken.transfer(address(swapFacility), INITIAL_BALANCE);
    require(success2, 'Transfer failed');
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
    SUSDSCVaultUpgradable implementation = new SUSDSCVaultUpgradable();

    vm.expectRevert();
    implementation.initialize(IERC20(address(usdsc)), admin, pauser);
  }

  function test_InitializationSetsCorrectValues() public view {
    assertEq(vault.name(), 'Staked Startale USD');
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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

    // Admin can upgrade
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');
  }

  function test_UpgradeEmitsEvent() public {
    MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();

    vm.prank(admin);
    vm.expectEmit(true, false, false, false);
    emit Upgraded(address(newImplementation));
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');
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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    bool success = mToken.transfer(address(swapFacility), DEPOSIT_AMOUNT);
    require(success, 'Transfer failed');
    vm.prank(address(swapFacility));
    usdsc.wrap(address(vault), DEPOSIT_AMOUNT);

    uint256 ppsBefore = vault.convertToAssets(1e6);

    // Upgrade
    MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    bool success = mToken.transfer(address(swapFacility), yieldAmount);
    require(success, 'Transfer failed');
    vm.prank(address(swapFacility));
    usdsc.wrap(address(vault), yieldAmount);

    uint256 assetsBefore = vault.totalAssets();
    uint256 sharesBefore = vault.balanceOf(user1);
    uint256 ppsBefore = vault.convertToAssets(1e6);

    // Upgrade
    MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation1), '');

    assertEq(vault.balanceOf(user1), initialShares);

    // Second upgrade
    MockSUSDSCVaultV2 newImplementation2 = new MockSUSDSCVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation2), '');

    assertEq(vault.balanceOf(user1), initialShares);

    // Third upgrade
    MockSUSDSCVaultV2 newImplementation3 = new MockSUSDSCVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation3), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(0), '');
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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

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
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

    // Cast to V2 to access new functionality
    MockSUSDSCVaultV2 vaultV2 = MockSUSDSCVaultV2(address(vault));

    // Test new variable starts at 0
    assertEq(vaultV2.getNewVariable(), 0);

    // Test version function
    assertEq(vaultV2.version(), '2.0.0');

    // Test only admin can set new variable
    vm.prank(attacker);
    vm.expectRevert();
    vaultV2.setNewVariable(12_345);

    // Test vault admin can set new variable
    vm.prank(vaultAdmin);
    vm.expectEmit(true, false, false, true);
    emit MockSUSDSCVaultV2.NewVariableSet(12_345);
    vaultV2.setNewVariable(12_345);

    // Verify new variable was set
    assertEq(vaultV2.getNewVariable(), 12_345);

    // Verify original functionality still works
    vm.prank(user1);
    vault.deposit(DEPOSIT_AMOUNT, user1);
    assertGt(vault.balanceOf(user1), 0);
  }

  /*//////////////////////////////////////////////////////////////
                      HELPER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function _getImplementation() internal view returns (address) {
    bytes32 implementationSlot = bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1);
    return address(uint160(uint256(vm.load(address(proxy), implementationSlot))));
  }

  /*//////////////////////////////////////////////////////////////
              RECOVER NON-ASSET ERC20 TESTS
  //////////////////////////////////////////////////////////////*/

  function test_RecoverNonAssetERC20_Success() public {
    // Deploy a different ERC20 token (not USDSC)
    MockM otherToken = new MockM();
    uint256 amount = 1000e18;

    // Send tokens to vault by mistake
    deal(address(otherToken), address(vault), amount);

    uint256 recipientBalanceBefore = otherToken.balanceOf(user1);

    // Recover tokens
    vm.prank(vaultAdmin);
    vault.recoverNonAssetERC20(address(otherToken), user1, amount);

    // Verify tokens were recovered
    assertEq(otherToken.balanceOf(user1), recipientBalanceBefore + amount);
    assertEq(otherToken.balanceOf(address(vault)), 0);
  }

  function test_Revert_RecoverNonAssetERC20_AssetToken() public {
    // Try to recover USDSC (the asset)
    vm.prank(vaultAdmin);
    vm.expectRevert(ISUSDSCVaultEventsAndErrors.TokenCannotBeUSDSC.selector);
    vault.recoverNonAssetERC20(address(usdsc), user1, 1000e6);
  }

  function test_Revert_RecoverNonAssetERC20_ZeroTokenAddress() public {
    vm.prank(vaultAdmin);
    vm.expectRevert(ISUSDSCVaultEventsAndErrors.TokenCannotBeZeroAddress.selector);
    vault.recoverNonAssetERC20(address(0), user1, 1000e6);
  }

  function test_Revert_RecoverNonAssetERC20_ZeroRecipient() public {
    MockM otherToken = new MockM();

    vm.prank(vaultAdmin);
    vm.expectRevert(ISUSDSCVaultEventsAndErrors.ToCannotBeZeroAddress.selector);
    vault.recoverNonAssetERC20(address(otherToken), address(0), 1000e18);
  }

  function test_Revert_RecoverNonAssetERC20_ZeroAmount() public {
    MockM otherToken = new MockM();

    vm.prank(vaultAdmin);
    vm.expectRevert(ISUSDSCVaultEventsAndErrors.AmountCannotBeZero.selector);
    vault.recoverNonAssetERC20(address(otherToken), user1, 0);
  }

  function test_Revert_RecoverNonAssetERC20_NotAdmin() public {
    MockM otherToken = new MockM();
    deal(address(otherToken), address(vault), 1000e18);

    // Non-admin tries to recover
    vm.prank(attacker);
    vm.expectRevert();
    vault.recoverNonAssetERC20(address(otherToken), user1, 1000e18);
  }

  /*//////////////////////////////////////////////////////////////
                      DECIMALS TESTS
  //////////////////////////////////////////////////////////////*/

  function test_Decimals_MatchesAsset() public view {
    // USDSC has 6 decimals, vault should also have 6 decimals (with 0 offset)
    assertEq(vault.decimals(), 6);
    assertEq(vault.decimals(), usdsc.decimals());
  }

  function test_Decimals_ConsistentAfterUpgrade() public {
    uint8 decimalsBefore = vault.decimals();

    // Upgrade
    MockSUSDSCVaultV2 newImplementation = new MockSUSDSCVaultV2();
    vm.prank(admin);
    proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImplementation), '');

    // Verify decimals unchanged
    assertEq(vault.decimals(), decimalsBefore);
  }

  /*//////////////////////////////////////////////////////////////
                      WITHDRAW TESTS
  //////////////////////////////////////////////////////////////*/

  function test_Withdraw_Success() public {
    // User deposits first
    vm.prank(user1);
    vault.deposit(DEPOSIT_AMOUNT, user1);

    uint256 shares = vault.balanceOf(user1);
    uint256 user1BalanceBefore = usdsc.balanceOf(user1);

    // Withdraw half
    uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;
    vm.prank(user1);
    uint256 sharesRedeemed = vault.withdraw(withdrawAmount, user1, user1);

    // Verify withdrawal
    assertEq(usdsc.balanceOf(user1), user1BalanceBefore + withdrawAmount);
    assertEq(vault.balanceOf(user1), shares - sharesRedeemed);
  }

  function test_Withdraw_WithYield() public {
    // User deposits
    vm.prank(user1);
    vault.deposit(DEPOSIT_AMOUNT, user1);

    // Add yield (50%)
    uint256 yieldAmount = DEPOSIT_AMOUNT / 2;
    deal(address(mToken), yieldRecipient, yieldAmount);
    vm.prank(yieldRecipient);
    bool success = mToken.transfer(address(swapFacility), yieldAmount);
    require(success, 'Transfer failed');
    vm.prank(address(swapFacility));
    usdsc.wrap(address(vault), yieldAmount);

    uint256 user1BalanceBefore = usdsc.balanceOf(user1);
    uint256 sharesBefore = vault.balanceOf(user1);

    // Withdraw original deposit amount
    vm.prank(user1);
    uint256 sharesRedeemed = vault.withdraw(DEPOSIT_AMOUNT, user1, user1);

    // Should burn fewer shares due to increased PPS (approximately 2/3 of shares)
    assertLe(sharesRedeemed, sharesBefore); // Should burn less than all shares
    assertEq(usdsc.balanceOf(user1), user1BalanceBefore + DEPOSIT_AMOUNT);

    // User should still have shares left
    assertGt(vault.balanceOf(user1), 0);
  }

  function test_Withdraw_ToReceiver() public {
    // User1 deposits
    vm.prank(user1);
    vault.deposit(DEPOSIT_AMOUNT, user1);

    uint256 user2BalanceBefore = usdsc.balanceOf(user2);

    // Withdraw to user2
    vm.prank(user1);
    vault.withdraw(DEPOSIT_AMOUNT, user2, user1);

    // Verify user2 received the assets
    assertEq(usdsc.balanceOf(user2), user2BalanceBefore + DEPOSIT_AMOUNT);
    assertEq(vault.balanceOf(user1), 0);
  }

  function test_Withdraw_WithApproval() public {
    // User1 deposits
    vm.prank(user1);
    vault.deposit(DEPOSIT_AMOUNT, user1);

    // User1 approves user2 to withdraw
    vm.prank(user1);
    vault.approve(user2, type(uint256).max);

    uint256 user2BalanceBefore = usdsc.balanceOf(user2);

    // User2 withdraws on behalf of user1
    vm.prank(user2);
    vault.withdraw(DEPOSIT_AMOUNT, user2, user1);

    assertEq(usdsc.balanceOf(user2), user2BalanceBefore + DEPOSIT_AMOUNT);
    assertEq(vault.balanceOf(user1), 0);
  }

  function test_Revert_Withdraw_WhenPaused() public {
    // User deposits
    vm.prank(user1);
    vault.deposit(DEPOSIT_AMOUNT, user1);

    // Pause vault
    vm.prank(pauser);
    vault.pause(true);

    // Try to withdraw
    vm.prank(user1);
    vm.expectRevert();
    vault.withdraw(DEPOSIT_AMOUNT, user1, user1);
  }

  function test_Revert_Withdraw_InsufficientShares() public {
    // User1 deposits
    vm.prank(user1);
    vault.deposit(DEPOSIT_AMOUNT, user1);

    // Try to withdraw more than deposited
    vm.prank(user1);
    vm.expectRevert();
    vault.withdraw(DEPOSIT_AMOUNT * 2, user1, user1);
  }

  /*//////////////////////////////////////////////////////////////
                      MINT TESTS
  //////////////////////////////////////////////////////////////*/

  function test_Mint_Success() public {
    uint256 sharesToMint = 1000e6;
    uint256 user1BalanceBefore = usdsc.balanceOf(user1);

    // Calculate assets needed
    uint256 assetsNeeded = vault.previewMint(sharesToMint);

    // Mint shares
    vm.prank(user1);
    uint256 assetsUsed = vault.mint(sharesToMint, user1);

    // Verify mint
    assertEq(vault.balanceOf(user1), sharesToMint);
    assertEq(assetsUsed, assetsNeeded);
    assertEq(usdsc.balanceOf(user1), user1BalanceBefore - assetsUsed);
  }

  function test_Mint_WithYield() public {
    // First deposit to establish vault state
    vm.prank(user2);
    vault.deposit(DEPOSIT_AMOUNT, user2);

    // Add yield (100%)
    deal(address(mToken), yieldRecipient, DEPOSIT_AMOUNT);
    vm.prank(yieldRecipient);
    bool success = mToken.transfer(address(swapFacility), DEPOSIT_AMOUNT);
    require(success, 'Transfer failed');
    vm.prank(address(swapFacility));
    usdsc.wrap(address(vault), DEPOSIT_AMOUNT);

    uint256 sharesToMint = 1000e6;
    uint256 user1BalanceBefore = usdsc.balanceOf(user1);

    // Calculate assets needed (should be more due to higher PPS)
    vault.previewMint(sharesToMint);

    // Mint shares
    vm.prank(user1);
    uint256 assetsUsed = vault.mint(sharesToMint, user1);

    // Verify - should use more assets than shares due to PPS > 1
    assertGt(assetsUsed, sharesToMint);
    assertEq(vault.balanceOf(user1), sharesToMint);
    assertEq(usdsc.balanceOf(user1), user1BalanceBefore - assetsUsed);
  }

  function test_Mint_ToReceiver() public {
    uint256 sharesToMint = 1000e6;
    uint256 user1BalanceBefore = usdsc.balanceOf(user1);

    // User1 mints to user2
    vm.prank(user1);
    uint256 assetsUsed = vault.mint(sharesToMint, user2);

    // Verify user2 received shares, user1 paid assets
    assertEq(vault.balanceOf(user2), sharesToMint);
    assertEq(vault.balanceOf(user1), 0);
    assertEq(usdsc.balanceOf(user1), user1BalanceBefore - assetsUsed);
  }

  function test_Mint_MultipleUsers() public {
    uint256 sharesToMint = 1000e6;

    // User1 mints
    vm.prank(user1);
    vault.mint(sharesToMint, user1);

    // User2 mints same amount
    vm.prank(user2);
    vault.mint(sharesToMint, user2);

    // Both should have same shares
    assertEq(vault.balanceOf(user1), sharesToMint);
    assertEq(vault.balanceOf(user2), sharesToMint);
    assertEq(vault.totalSupply(), sharesToMint * 2);
  }

  function test_Revert_Mint_WhenPaused() public {
    // Pause vault
    vm.prank(pauser);
    vault.pause(true);

    // Try to mint
    vm.prank(user1);
    vm.expectRevert();
    vault.mint(1000e6, user1);
  }

  function test_Revert_Mint_InsufficientAssets() public {
    // User with no USDSC tries to mint
    address poorUser = makeAddr('poorUser');

    vm.prank(poorUser);
    vm.expectRevert();
    vault.mint(1000e6, poorUser);
  }

  function test_Mint_MaxMint() public {
    // maxMint returns a very large number, so we'll just test a reasonable amount
    uint256 sharesToMint = 1000e6; // Reasonable amount of shares

    // Verify user has enough assets
    uint256 assetsNeeded = vault.previewMint(sharesToMint);
    assertLe(assetsNeeded, usdsc.balanceOf(user1), "User doesn't have enough assets");

    // Mint shares
    vm.prank(user1);
    vault.mint(sharesToMint, user1);

    assertEq(vault.balanceOf(user1), sharesToMint);
  }
}
