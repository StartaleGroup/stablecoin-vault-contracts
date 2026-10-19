// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {UsdscToken} from '../../src/coin/UsdscToken.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';

/// @notice UsdscToken - the live USDSC implementation - with each role on its own address, as live
contract UnitUsdscToken is Test {
  UsdscToken internal usdsc;
  UsdscToken internal implementation;
  MockM internal mToken;
  MockSwapFacility internal swapFacility;
  ProxyAdmin internal proxyAdmin;

  address bob = makeAddr('bob');
  address charlie = makeAddr('charlie');
  address admin = makeAddr('admin');
  address freezeManager = makeAddr('freezeManager');
  address yieldRecipientManager = makeAddr('yieldRecipientManager');
  address yieldClaimer = makeAddr('yieldClaimer');
  address yieldRecipient = makeAddr('yieldRecipient');
  address user = makeAddr('user');

  function setUp() external {
    mToken = new MockM();
    swapFacility = new MockSwapFacility();
    proxyAdmin = new ProxyAdmin(admin);
    implementation = new UsdscToken(address(mToken), address(swapFacility));
    usdsc = UsdscToken(address(_deploy(yieldClaimer)));

    vm.deal(bob, 10_000 ether);
    deal(address(mToken), bob, 10_000 ether);
  }

  function _deploy(address claimer) internal returns (TransparentUpgradeableProxy) {
    return new TransparentUpgradeableProxy(
      address(implementation),
      address(proxyAdmin),
      abi.encodeCall(
        UsdscToken.initialize, ('USDSC', 'USDSC', yieldRecipient, admin, freezeManager, yieldRecipientManager, claimer)
      )
    );
  }

  function test_initialize_RolesOnTheirOwnAddresses() public view {
    assertTrue(usdsc.hasRole(usdsc.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(usdsc.hasRole(usdsc.FREEZE_MANAGER_ROLE(), freezeManager));
    assertTrue(usdsc.hasRole(usdsc.YIELD_RECIPIENT_MANAGER_ROLE(), yieldRecipientManager));
    assertTrue(usdsc.hasRole(usdsc.YIELD_CLAIMER_ROLE(), yieldClaimer));
    assertFalse(usdsc.hasRole(usdsc.YIELD_CLAIMER_ROLE(), admin));
    assertFalse(usdsc.hasRole(usdsc.FREEZE_MANAGER_ROLE(), admin));
  }

  function test_initialize_ZeroYieldClaimerReverts() public {
    vm.expectRevert(UsdscToken.YieldClaimerCannotBeZeroAddress.selector);
    _deploy(address(0));
  }

  function test_freezing_OnlyFreezeManager() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, admin, usdsc.FREEZE_MANAGER_ROLE()
      )
    );
    vm.prank(admin);
    usdsc.freeze(user);

    vm.prank(freezeManager);
    usdsc.freeze(user);
    assertTrue(usdsc.isFrozen(user));
  }

  /// @dev setYieldRecipient() claims the outgoing recipient's yield first, and claimYield() is gated
  ///      to YIELD_CLAIMER_ROLE by msg.sender: the caller needs YIELD_RECIPIENT_MANAGER_ROLE and
  ///      YIELD_CLAIMER_ROLE together, or the change reverts
  function test_yieldRecipientChange_NeedsManagerAndClaimerRoles() public {
    address newTreasury = makeAddr('newTreasury');
    bytes32 managerRole = usdsc.YIELD_RECIPIENT_MANAGER_ROLE();
    bytes32 claimerRole = usdsc.YIELD_CLAIMER_ROLE();

    // neither role
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, managerRole)
    );
    vm.prank(admin);
    usdsc.setYieldRecipient(newTreasury);

    // manager role alone: the internal claimYield() reverts
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, yieldRecipientManager, claimerRole
      )
    );
    vm.prank(yieldRecipientManager);
    usdsc.setYieldRecipient(newTreasury);

    // claimer role alone
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, yieldClaimer, managerRole)
    );
    vm.prank(yieldClaimer);
    usdsc.setYieldRecipient(newTreasury);

    // both roles: the pending yield goes to the outgoing recipient, then the recipient changes
    _accrueYield();
    vm.prank(admin);
    usdsc.grantRole(claimerRole, yieldRecipientManager);
    vm.prank(yieldRecipientManager);
    usdsc.setYieldRecipient(newTreasury);
    assertEq(usdsc.yieldRecipient(), newTreasury);
    assertEq(usdsc.balanceOf(yieldRecipient), 1 ether, 'outgoing recipient got the pending yield');
  }

  function test_claimYield_OnlyYieldClaimer() public {
    _accrueYield();
    bytes32 role = usdsc.YIELD_CLAIMER_ROLE();
    address[3] memory others = [admin, yieldRecipient, bob];
    for (uint256 i = 0; i < others.length; i++) {
      vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, others[i], role));
      vm.prank(others[i]);
      usdsc.claimYield();
    }
    assertEq(usdsc.balanceOf(yieldRecipient), 0, 'nothing claimed');
  }

  function test_claimYield_AdminCanGrantClaimerRole() public {
    _accrueYield();
    address newClaimer = makeAddr('newClaimer');
    bytes32 role = usdsc.YIELD_CLAIMER_ROLE();
    vm.prank(admin);
    usdsc.grantRole(role, newClaimer);
    vm.prank(newClaimer);
    usdsc.claimYield();
    assertEq(usdsc.balanceOf(yieldRecipient), 1 ether);
  }

  /// @dev Wraps 5000 M into USDSC and gives the token 1 M of yield (MockM has no index accounting)
  function _accrueYield() internal {
    vm.prank(bob);
    require(mToken.transfer(address(swapFacility), 10_000 ether), 'Transfer failed');
    vm.prank(address(swapFacility));
    usdsc.wrap(charlie, 5000 ether);
    mToken.setIsEarning(address(usdsc), true);
    mToken.setBalanceOf(address(usdsc), 5000 ether + 1 ether);
  }

  function test_initialize() public view {
    assertEq(usdsc.name(), 'USDSC');
    assertEq(usdsc.symbol(), 'USDSC');
    assertEq(usdsc.yieldRecipient(), yieldRecipient);
  }

  function test_freezing() public {
    // Test freezing functionality
    vm.prank(freezeManager);
    usdsc.freeze(user);
    assertTrue(usdsc.isFrozen(user));
  }

  function test_yieldRecipientChange() public {
    // Test changing yield recipient
    address newTreasury = makeAddr('newTreasury');
    bytes32 claimerRole = usdsc.YIELD_CLAIMER_ROLE();
    vm.prank(admin);
    usdsc.grantRole(claimerRole, yieldRecipientManager); // setYieldRecipient() also claims yield
    vm.prank(yieldRecipientManager);
    usdsc.setYieldRecipient(newTreasury);
    assertEq(usdsc.yieldRecipient(), newTreasury);
  }

  function test_claimYield() external {
    // Test yield claiming functionality
    uint128 currentIndex = mToken.currentIndex();
    console2.log('currentIndex', currentIndex);

    uint32 currentEarnerRate = mToken.earnerRate();
    console2.log('currentEarnerRate', currentEarnerRate);

    vm.startPrank(bob);
    bool success = mToken.transfer(address(swapFacility), 10_000 ether);
    require(success, 'Transfer failed');
    vm.stopPrank();

    // Below will take M from swapFacility and transfer to USDSC contract and mint USDSC
    vm.startPrank(address(swapFacility));
    usdsc.wrap(charlie, 5000 ether);
    vm.stopPrank();

    // check balance of usdsc contract is 5000 ether m tokens
    assertEq(mToken.balanceOf(address(usdsc)), 5000 ether);

    // check charlie has 5000 ether usdsc tokens
    // totalsupply of usdsc should be 5000 ether now
    assertEq(usdsc.balanceOf(charlie), 5000 ether);

    // Mock the yield accrual
    mToken.setCurrentIndex(1_056_091_682_480);
    assertEq(mToken.currentIndex(), 1_056_091_682_480);

    mToken.setEarnerRate(425);
    assertEq(mToken.earnerRate(), 425);

    // make our usdsc contract earning
    // (Normally we'd call enableEarning() on USDSC which will call startEarning on M if it's approved by TTG )
    mToken.setIsEarning(address(usdsc), true);
    assertEq(mToken.isEarning(address(usdsc)), true);

    uint128 newCurrentIndex = mToken.currentIndex();
    console2.log('newCurrentIndex', newCurrentIndex);

    // Balance is not reflected because MockM does not have dual accounting balance.
    assertEq(mToken.balanceOf(address(usdsc)), 5000 ether);

    // Manually update balance of usdsc contract
    // Note: I wouldn't need to do this and just update index and add set earning if MockM was more like real M.
    mToken.setBalanceOf(address(usdsc), 5000 ether + 1 ether);
    assertEq(mToken.balanceOf(address(usdsc)), 5000 ether + 1 ether);

    // check yield recipient M and USDSC balance
    assertEq(usdsc.balanceOf(yieldRecipient), 0);

    // Call claimYield() - gated to YIELD_CLAIMER_ROLE; the yield goes to the set yieldRecipient
    vm.prank(yieldClaimer);
    usdsc.claimYield();
    // it sends balance - totalsupply worth of tokens.

    console2.log('usdsc.balanceOf(yieldRecipient)', usdsc.balanceOf(yieldRecipient));

    // check yield recipient M and USDSC balance
    assertEq(usdsc.balanceOf(yieldRecipient), 1 ether);
  }
}
