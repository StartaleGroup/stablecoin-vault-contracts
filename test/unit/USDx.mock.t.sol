// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from 'forge-std/Test.sol';
import {USDx} from '../../src/coin/mock/USDx.sol';
import {MockMToken} from '../mocks/MockMToken.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';
import {console2} from 'forge-std/console2.sol';

contract UnitUSDx is Test {
  USDx internal usdx;
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
    USDx implementation = new USDx(address(mToken), address(swapFacility));

    // Deploy proxy with initialization
    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(implementation),
      address(proxyAdmin),
      abi.encodeWithSelector(USDx.initialize.selector, 'USDx', 'USDx', admin, yieldRecipient)
    );

    usdx = USDx(address(proxy));

    vm.deal(bob, 10000 ether);
    // deal some m token to bob
    deal(address(mToken), bob, 10000 ether);

    // If needed,transfer some m tokens to usdx contract address
    // vm.startPrank(bob);
    // mToken.transfer(address(usdx), 10000 ether);
    // vm.stopPrank();
  }

  function test_initialize() public view {
    assertEq(usdx.name(), 'USDx');
    assertEq(usdx.symbol(), 'USDx');
    assertEq(usdx.yieldRecipient(), yieldRecipient);
  }

  function test_freezing() public {
    // Test freezing functionality
    vm.prank(admin);
    usdx.freeze(user);
    assertTrue(usdx.isFrozen(user));
  }

  function test_yieldRecipientChange() public {
    // Test changing yield recipient
    address newTreasury = makeAddr('newTreasury');
    vm.prank(admin);
    usdx.setYieldRecipient(newTreasury);
    assertEq(usdx.yieldRecipient(), newTreasury);
  }

  function test_claimYield() external {

    // Test yield claiming functionality
    uint128 currentIndex = mToken.currentIndex();
    console2.log('currentIndex', currentIndex);

    uint32 currentEarnerRate = mToken.earnerRate();
    console2.log('currentEarnerRate', currentEarnerRate);

    vm.startPrank(bob);
    mToken.transfer(address(swapFacility), 10000 ether);
    vm.stopPrank();

    // Below will take M from swapFacility and transfer to USDX contract and mint USDX
    vm.startPrank(address(swapFacility));
    usdx.wrap(charlie, 5000 ether);
    vm.stopPrank();

    // check balance of usdx contract is 5000 ether m tokens
    assertEq(mToken.balanceOf(address(usdx)), 5000 ether);

    // check charlie has 5000 ether usdx tokens
    // totalsupply of usdx should be 5000 ether now
     assertEq(usdx.balanceOf(charlie), 5000 ether);

    // Mock the yield accrual 
    mToken.setCurrentIndex(1056091682480);
    assertEq(mToken.currentIndex(), 1056091682480);

    mToken.setEarnerRate(425);
    assertEq(mToken.earnerRate(), 425);

    // make our usdx contract earning 
    // (Normally we'd call enableEarning() on USDR which will call startEarning on M if it's approved by TTG )
    mToken.setIsEarning(address(usdx), true);
    assertEq(mToken.isEarning(address(usdx)), true);

    uint128 newCurrentIndex = mToken.currentIndex();
    console2.log('newCurrentIndex', newCurrentIndex);

    // Balance is not reflected because MockM does not have dual accounting balance.
    assertEq(mToken.balanceOf(address(usdx)), 5000 ether);

    // Manually update balance of usdx contract
    // Note: I wouldn't need to do this and just update index and add set earning if MockM was more like real M.
    mToken.setBalanceOf(address(usdx), 5000 ether + 1 ether);
    assertEq(mToken.balanceOf(address(usdx)), 5000 ether + 1 ether);
    
    // check yield recipient M and USDx balance 
    assertEq(usdx.balanceOf(yieldRecipient), 0);

    // Call claimYield()
    // Note: anyone can call and that would go to set yieldRecipient 
    usdx.claimYield();
    // it sends balance - totalsupply worth of tokens.

    console2.log('usdx.balanceOf(yieldRecipient)', usdx.balanceOf(yieldRecipient));

    // check yield recipient M and USDx balance 
    assertEq(usdx.balanceOf(yieldRecipient), 1 ether);
  }
}
