// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {USDSC} from '../../src/coin/mock/USDSC.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';

contract UnitUSDSC is Test {
  USDSC internal usdsc;
  MockM internal mToken;
  MockSwapFacility internal swapFacility;
  ProxyAdmin internal proxyAdmin;

  address bob = makeAddr('bob');
  address charlie = makeAddr('charlie');
  address admin = makeAddr('admin');
  address yieldRecipient = makeAddr('yieldRecipient');
  address user = makeAddr('user');

  function setUp() external {
    mToken = new MockM();
    swapFacility = new MockSwapFacility();

    // Deploy proxy admin
    proxyAdmin = new ProxyAdmin(admin);

    // Deploy implementation
    USDSC implementation = new USDSC(address(mToken), address(swapFacility));

    // Deploy proxy with initialization
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(implementation),
      address(proxyAdmin),
      abi.encodeWithSelector(USDSC.initialize.selector, 'USDSC', 'USDSC', admin, yieldRecipient)
    );

    usdsc = USDSC(address(proxy));

    vm.deal(bob, 10_000 ether);
    // deal some m token to bob
    deal(address(mToken), bob, 10_000 ether);

    // If needed,transfer some m tokens to usdsc contract address
    // vm.startPrank(bob);
    // mToken.transfer(address(usdsc), 10000 ether);
    // vm.stopPrank();
  }

  function test_initialize() public view {
    assertEq(usdsc.name(), 'USDSC');
    assertEq(usdsc.symbol(), 'USDSC');
    assertEq(usdsc.yieldRecipient(), yieldRecipient);
  }

  function test_freezing() public {
    // Test freezing functionality
    vm.prank(admin);
    usdsc.freeze(user);
    assertTrue(usdsc.isFrozen(user));
  }

  function test_yieldRecipientChange() public {
    // Test changing yield recipient
    address newTreasury = makeAddr('newTreasury');
    vm.prank(admin);
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

    // Call claimYield()
    // Note: anyone can call and that would go to set yieldRecipient
    usdsc.claimYield();
    // it sends balance - totalsupply worth of tokens.

    console2.log('usdsc.balanceOf(yieldRecipient)', usdsc.balanceOf(yieldRecipient));

    // check yield recipient M and USDSC balance
    assertEq(usdsc.balanceOf(yieldRecipient), 1 ether);
  }
}
