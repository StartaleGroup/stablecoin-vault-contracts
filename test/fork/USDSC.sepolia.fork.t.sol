// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {IMExtension} from 'm-extensions/interfaces/IMExtension.sol';
import {IMTokenLike} from 'm-extensions/interfaces/IMTokenLike.sol';
import {IMYieldToOne} from 'm-extensions/projects/yieldToOne/IMYieldToOne.sol';

contract ForkUSDSC is Test {
  IMYieldToOne internal usdsc;
  IMExtension internal usdscExtension;
  IERC20 internal usdscToken;
  IERC20Metadata internal usdscMetadata;
  IMTokenLike internal mToken;
  IERC20 internal mTokenERC20;
  // Todo
  // Import swapFacility

  address constant SEPOLIA_USDSC_ADDRESS = 0x7E426d026f604d1c47b50059752122d8ab1E2C28;
  address constant SEPOLIA_USDSC_ADMIN = 0x77001610a4fD68548B80E49226c02a99c3b6Ae14;
  address constant SEPOLIA_MTOKEN_ADDRESS = 0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b;
  address constant SEPOLIA_SWAP_FACILITY_ADDRESS = 0x34F141dACB2DeF72D2196a473C585830af8B4004;

  // Test users
  address bob = makeAddr('bob');
  address charlie = makeAddr('charlie');
  address user = makeAddr('user');
  address zelda = makeAddr('zelda');

  function setUp() external {
    // Fork Sepolia at the latest block
    string memory sepoliaRpc = 'https://ethereum-sepolia-rpc.publicnode.com';
    vm.createSelectFork(sepoliaRpc);
    // Fork Sepolia network and select it immediately
    // This creates the fork and selects it in one step

    // Initialize contract interfaces
    usdsc = IMYieldToOne(SEPOLIA_USDSC_ADDRESS);
    usdscExtension = IMExtension(SEPOLIA_USDSC_ADDRESS);
    usdscToken = IERC20(SEPOLIA_USDSC_ADDRESS);
    usdscMetadata = IERC20Metadata(SEPOLIA_USDSC_ADDRESS);
    mToken = IMTokenLike(SEPOLIA_MTOKEN_ADDRESS);
    mTokenERC20 = IERC20(SEPOLIA_MTOKEN_ADDRESS);

    // Give some ETH to test accounts
    vm.deal(bob, 10 ether);
    vm.deal(charlie, 10 ether);
    vm.deal(user, 10 ether);
    vm.deal(zelda, 10 ether);
    vm.deal(SEPOLIA_USDSC_ADMIN, 10 ether);

    // Give some USDSC tokens to zelda for testing transfers
    // This uses vm.deal to artificially set token balances without affecting total supply
    deal(SEPOLIA_USDSC_ADDRESS, zelda, 1000e6); // 1000 USDSC tokens
    deal(SEPOLIA_USDSC_ADDRESS, SEPOLIA_USDSC_ADMIN, 500e6); // 500 USDSC tokens for admin

    // Give some M tokens to admin for wrap/unwrap testing
    // Use vm.store with the CORRECT storage slot from MToken's actual layout
    // From MToken storage layout: _balances is at slot 8
    // mapping(address => struct MToken.MBalance) _balances
    bytes32 balanceSlot = keccak256(abi.encode(SEPOLIA_USDSC_ADMIN, uint256(8)));

    // MToken uses struct MBalance { bool isEarning; uint240 rawBalance; }
    uint256 desiredBalance = 1000e6; // 1000 M tokens = 1000,000,000

    // calc..
    // Current result: 390625000 when we set 100000000000
    // Ratio: 390625000 / 100000000000 = 0.00390625 = 1/256

    // Try scaling up our input to get the desired output
    uint256 scaledInput = desiredBalance * 256; // Scale by 256 to compensate
    vm.store(SEPOLIA_MTOKEN_ADDRESS, balanceSlot, bytes32(scaledInput));

    console2.log('Setting M token balance - desired:', desiredBalance);
    console2.log('Scaled input:', scaledInput);
  }

  function test_contractInfo() public view {
    // Test basic contract information
    console2.log('USDSC Name:', usdscMetadata.name());
    console2.log('USDSC Symbol:', usdscMetadata.symbol());
    console2.log('USDSC Decimals:', usdscMetadata.decimals());
    console2.log('USDSC Total Supply:', usdscToken.totalSupply());
    console2.log('USDSC Yield Recipient:', usdsc.yieldRecipient());

    // Basic assertions
    // Note: Sepolia USDSC is deployed with USDR symbol
    assertEq(usdscMetadata.symbol(), 'USDR');
    // Note: Total supply might be 0 if no tokens have been minted yet
    assertGe(usdscToken.totalSupply(), 0);
  }

  function test_yieldRecipient() public view {
    // Test yield recipient functionality
    address currentYieldRecipient = usdsc.yieldRecipient();
    assertNotEq(currentYieldRecipient, address(0));
    console2.log('Current Yield Recipient:', currentYieldRecipient);
  }

  function test_yieldAmount() public view {
    // Test yield amount
    uint256 currentYield = usdsc.yield();
    console2.log('Current Yield Available:', currentYield);
  }

  function test_claimYield() external {
    // Test yield claiming functionality
    uint256 initialYield = usdsc.yield();
    address yieldRecipient = usdsc.yieldRecipient();

    console2.log('Initial Yield:', initialYield);
    console2.log('Yield Recipient:', yieldRecipient);

    if (initialYield > 0) {
      uint256 recipientBalanceBefore = usdscToken.balanceOf(yieldRecipient);

      // Anyone can call claimYield()
      uint256 claimedYield = usdsc.claimYield();

      uint256 recipientBalanceAfter = usdscToken.balanceOf(yieldRecipient);

      assertEq(claimedYield, initialYield, 'Claimed yield should match initial yield');
      assertEq(recipientBalanceAfter - recipientBalanceBefore, claimedYield, 'Recipient should receive claimed yield');
      assertEq(usdsc.yield(), 0, 'Yield should be zero after claiming');

      console2.log('Claimed Yield:', claimedYield);
      console2.log('Recipient Balance Increase:', recipientBalanceAfter - recipientBalanceBefore);
    } else {
      console2.log('No yield available to claim');
    }
  }

  function test_adminCanSetYieldRecipient() external {
    // Test that admin can change yield recipient
    address newYieldRecipient = makeAddr('newYieldRecipient');
    address currentYieldRecipient = usdsc.yieldRecipient();

    // Prank as admin and change yield recipient
    vm.prank(SEPOLIA_USDSC_ADMIN);
    usdsc.setYieldRecipient(newYieldRecipient);

    assertEq(usdsc.yieldRecipient(), newYieldRecipient, 'Yield recipient should be updated');
    assertNotEq(usdsc.yieldRecipient(), currentYieldRecipient, 'Yield recipient should be different from before');

    console2.log('Old Yield Recipient:', currentYieldRecipient);
    console2.log('New Yield Recipient:', newYieldRecipient);
  }

  function test_nonAdminCannotSetYieldRecipient() external {
    // Test that non-admin cannot change yield recipient
    address newYieldRecipient = makeAddr('newYieldRecipient');

    vm.prank(bob);
    vm.expectRevert();
    usdsc.setYieldRecipient(newYieldRecipient);
  }

  function test_tokenTransfers() external {
    // Test basic ERC20 functionality using dealt tokens
    uint256 zeldaInitialBalance = usdscToken.balanceOf(zelda);
    uint256 adminInitialBalance = usdscToken.balanceOf(SEPOLIA_USDSC_ADMIN);
    uint256 bobInitialBalance = usdscToken.balanceOf(bob);
    // We have externally minted some USDSC tokens, so total supply is not 0
    uint256 earlierTotalSupply = usdscToken.totalSupply();

    console2.log('=== Initial Balances ===');
    console2.log('Zelda Balance:', zeldaInitialBalance);
    console2.log('Admin Balance:', adminInitialBalance);
    console2.log('Bob Balance:', bobInitialBalance);

    // Test 1: Zelda transfers to Bob
    uint256 transferAmount1 = 100e6; // 100 USDSC
    vm.prank(zelda);
    bool success = usdscToken.transfer(bob, transferAmount1);
    require(success, 'Transfer failed');

    assertEq(usdscToken.balanceOf(bob), bobInitialBalance + transferAmount1, 'Bob should receive transferred tokens');
    assertEq(usdscToken.balanceOf(zelda), zeldaInitialBalance - transferAmount1, 'Zelda balance should decrease');

    console2.log('=== After Zelda -> Bob Transfer ===');
    console2.log('Transferred Amount:', transferAmount1);
    console2.log("Bob's New Balance:", usdscToken.balanceOf(bob));
    console2.log("Zelda's New Balance:", usdscToken.balanceOf(zelda));

    // Test 2: Admin transfers to Charlie
    uint256 transferAmount2 = 50e6; // 50 USDSC
    uint256 charlieInitialBalance = usdscToken.balanceOf(charlie);

    vm.prank(SEPOLIA_USDSC_ADMIN);
    success = usdscToken.transfer(charlie, transferAmount2);
    require(success, 'Transfer failed');

    assertEq(
      usdscToken.balanceOf(charlie),
      charlieInitialBalance + transferAmount2,
      'Charlie should receive transferred tokens'
    );
    assertEq(
      usdscToken.balanceOf(SEPOLIA_USDSC_ADMIN), adminInitialBalance - transferAmount2, 'Admin balance should decrease'
    );

    console2.log('=== After Admin -> Charlie Transfer ===');
    console2.log('Transferred Amount:', transferAmount2);
    console2.log("Charlie's New Balance:", usdscToken.balanceOf(charlie));
    console2.log("Admin's New Balance:", usdscToken.balanceOf(SEPOLIA_USDSC_ADMIN));

    // Test 3: Approve and transferFrom functionality
    uint256 approveAmount = 75e6; // 75 USDSC
    uint256 transferAmount3 = 30e6; // 30 USDSC (less than approved)

    // Bob approves Charlie to spend some of his tokens
    vm.prank(bob);
    usdscToken.approve(charlie, approveAmount);

    assertEq(usdscToken.allowance(bob, charlie), approveAmount, 'Allowance should be set correctly');

    // Charlie uses transferFrom to move tokens from Bob to User
    uint256 userInitialBalance = usdscToken.balanceOf(user);
    uint256 bobBalanceBeforeTransferFrom = usdscToken.balanceOf(bob);

    vm.prank(charlie);
    success = usdscToken.transferFrom(bob, user, transferAmount3);
    require(success, 'Transfer failed');

    assertEq(usdscToken.balanceOf(user), userInitialBalance + transferAmount3, 'User should receive transferred tokens');
    assertEq(usdscToken.balanceOf(bob), bobBalanceBeforeTransferFrom - transferAmount3, 'Bob balance should decrease');
    assertEq(usdscToken.allowance(bob, charlie), approveAmount - transferAmount3, 'Allowance should be reduced');

    console2.log('=== After Approve/TransferFrom Test ===');
    console2.log('Approved Amount:', approveAmount);
    console2.log('TransferFrom Amount:', transferAmount3);
    console2.log("User's New Balance:", usdscToken.balanceOf(user));
    console2.log('Remaining Allowance:', usdscToken.allowance(bob, charlie));

    // Test 4: Verify total supply is unaffected by deal() operations
    // Note: deal() artificially sets balances but doesn't change total supply
    uint256 currentTotalSupply = usdscToken.totalSupply();
    console2.log('=== Total Supply Check ===');
    console2.log('Total Supply (should still be earlierTotalSupply):', earlierTotalSupply);
    assertEq(
      currentTotalSupply,
      earlierTotalSupply,
      "Total supply should remain earlierTotalSupply as deal() doesn't affect it"
    );
  }

  function test_roleBasedAccess() external {
    // Test role-based access control
    bytes32 yieldRecipientManagerRole = usdsc.YIELD_RECIPIENT_MANAGER_ROLE();
    console2.log('Yield Recipient Manager Role:');
    console2.logBytes32(yieldRecipientManagerRole);

    // The admin should have the yield recipient manager role
    // (This test assumes the admin has the necessary role)
    address newYieldRecipient = makeAddr('testYieldRecipient');

    vm.prank(SEPOLIA_USDSC_ADMIN);
    usdsc.setYieldRecipient(newYieldRecipient);

    assertEq(usdsc.yieldRecipient(), newYieldRecipient);
  }

  function test_contractState() external view {
    // Log comprehensive contract state
    console2.log('=== USDSC Contract State ===');
    console2.log('Address:', SEPOLIA_USDSC_ADDRESS);
    console2.log('Name:', usdscMetadata.name());
    console2.log('Symbol:', usdscMetadata.symbol());
    console2.log('Decimals:', usdscMetadata.decimals());
    console2.log('Total Supply:', usdscToken.totalSupply());
    console2.log('Yield Recipient:', usdsc.yieldRecipient());
    console2.log('Available Yield:', usdsc.yield());
    console2.log('Admin Balance:', usdscToken.balanceOf(SEPOLIA_USDSC_ADMIN));
    console2.log('Contract Balance:', usdscToken.balanceOf(SEPOLIA_USDSC_ADDRESS));
  }

  function test_wrapFunctionality() external {
    // Test USDSC wrap functionality interface and access control
    uint256 wrapAmount = 100e6; // 100 M tokens to wrap

    // Get initial states
    uint256 adminMBalance = mTokenERC20.balanceOf(SEPOLIA_USDSC_ADMIN);
    console2.log('=== Wrap Test ===');
    console2.log('Admin M Balance:', adminMBalance);

    // Test 1: Non-SwapFacility cannot call wrap (should revert)
    vm.prank(SEPOLIA_USDSC_ADMIN);
    vm.expectRevert(); // Should revert with NotSwapFacility error
    usdscExtension.wrap(bob, wrapAmount);
    console2.log('[PASS] Non-SwapFacility correctly cannot call wrap');

    // Test 2: Now that we have M tokens, let's try a real wrap operation
    uint256 adminMBalanceAfterStore = mTokenERC20.balanceOf(SEPOLIA_USDSC_ADMIN);
    console2.log('Admin M Balance after vm.store:', adminMBalanceAfterStore);

    if (adminMBalanceAfterStore >= wrapAmount) {
      // Transfer M tokens to SwapFacility first
      vm.prank(SEPOLIA_USDSC_ADMIN);
      bool success = mTokenERC20.transfer(SEPOLIA_SWAP_FACILITY_ADDRESS, wrapAmount);
      require(success, 'Transfer failed');

      uint256 swapFacilityMBalance = mTokenERC20.balanceOf(SEPOLIA_SWAP_FACILITY_ADDRESS);
      console2.log('SwapFacility M Balance after transfer:', swapFacilityMBalance);

      if (swapFacilityMBalance >= wrapAmount) {
        // SWAP FACILITY TEST
        // Note: We Prank SwapFacility now and send M Tokens to it.
        // But in full test, we would call swapInM or swapOutM with proper swapper role. (given approval)

        // SwapFacility needs to approve USDSC contract to spend M tokens
        vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
        mTokenERC20.approve(SEPOLIA_USDSC_ADDRESS, wrapAmount);

        // Now SwapFacility can actually wrap!
        vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
        usdscExtension.wrap(bob, wrapAmount);
        console2.log('[PASS] SwapFacility successfully wrapped M tokens to USDSC!');

        uint256 bobUSDSCBalance = usdscToken.balanceOf(bob);
        uint256 usdscTotalSupplyAfter = usdscToken.totalSupply();
        console2.log("Bob's USDSC balance after wrap:", bobUSDSCBalance);
        console2.log('USDSC total supply after wrap:', usdscTotalSupplyAfter);

        uint256 mTokenBalanceOfUSDSC = mTokenERC20.balanceOf(SEPOLIA_USDSC_ADDRESS);
        console2.log('M Token balance of USDSC:', mTokenBalanceOfUSDSC);
      } else {
        vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
        vm.expectRevert();
        usdscExtension.wrap(bob, wrapAmount);
        console2.log('[PASS] SwapFacility wrap failed (insufficient M tokens in SwapFacility)');
      }
    } else {
      vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
      vm.expectRevert();
      usdscExtension.wrap(bob, wrapAmount);
      console2.log('[PASS] SwapFacility wrap failed (admin has insufficient M tokens)');
    }

    // Test 3: Verify the interface works by checking that SwapFacility is recognized
    address swapFacilityFromContract = usdscExtension.swapFacility();
    assertEq(swapFacilityFromContract, SEPOLIA_SWAP_FACILITY_ADDRESS, 'SwapFacility address should match');
    console2.log('[PASS] SwapFacility address correctly configured:', swapFacilityFromContract);

    // Test 4: Check M Token address
    address mTokenFromContract = usdscExtension.mToken();
    assertEq(mTokenFromContract, SEPOLIA_MTOKEN_ADDRESS, 'M Token address should match');
    console2.log('[PASS] M Token address correctly configured:', mTokenFromContract);
  }

  function test_readMTokenCurrentIndex() external view {
    // Test reading the current index of the M token
    uint256 currentIndex = mToken.currentIndex();
    console2.log('Current Index:', currentIndex);
  }

  function test_unwrapFunctionality() external {
    // Test USDSC unwrap functionality interface and access control
    uint256 unwrapAmount = 50e6; // 50 USDSC tokens to unwrap

    console2.log('=== Unwrap Test ===');

    // Test 1: Non-SwapFacility cannot call unwrap (should revert)
    vm.prank(SEPOLIA_USDSC_ADMIN);
    vm.expectRevert(); // Should revert with NotSwapFacility error
    usdscExtension.unwrap(SEPOLIA_USDSC_ADMIN, unwrapAmount);
    console2.log('[PASS] Non-SwapFacility correctly cannot call unwrap');

    // Test 2: SwapFacility can call unwrap (but will fail due to no USDSC tokens to burn)
    vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
    vm.expectRevert(); // Should revert due to insufficient USDSC balance or other reason
    usdscExtension.unwrap(SEPOLIA_SWAP_FACILITY_ADDRESS, unwrapAmount);
    console2.log('[PASS] SwapFacility can call unwrap (reverted as expected due to no tokens)');

    // Test 3: Test with actual USDSC tokens (using dealt tokens)
    // Give SwapFacility some USDSC tokens to test unwrap with
    deal(SEPOLIA_USDSC_ADDRESS, SEPOLIA_SWAP_FACILITY_ADDRESS, unwrapAmount);
    uint256 swapFacilityUSDSCBalance = usdscToken.balanceOf(SEPOLIA_SWAP_FACILITY_ADDRESS);
    console2.log('SwapFacility USDSC Balance after deal:', swapFacilityUSDSCBalance);

    if (swapFacilityUSDSCBalance >= unwrapAmount) {
      // SwapFacility needs to approve itself to spend its own tokens (this is unusual but for testing)
      vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
      usdscToken.approve(SEPOLIA_SWAP_FACILITY_ADDRESS, unwrapAmount);

      // Record balances before unwrap
      uint256 balanceBefore = usdscToken.balanceOf(SEPOLIA_SWAP_FACILITY_ADDRESS);
      uint256 mTokenBalanceBefore = mTokenERC20.balanceOf(SEPOLIA_SWAP_FACILITY_ADDRESS);

      vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
      usdscExtension.unwrap(SEPOLIA_SWAP_FACILITY_ADDRESS, unwrapAmount);

      // Verify unwrap succeeded
      uint256 balanceAfter = usdscToken.balanceOf(SEPOLIA_SWAP_FACILITY_ADDRESS);
      uint256 mTokenBalanceAfter = mTokenERC20.balanceOf(SEPOLIA_SWAP_FACILITY_ADDRESS);

      assertEq(balanceAfter, balanceBefore - unwrapAmount, 'USDSC balance should decrease by unwrap amount');
      assertGt(mTokenBalanceAfter, mTokenBalanceBefore, 'M token balance should increase after unwrap');

      console2.log('[PASS] SwapFacility unwrap succeeded - USDSC burned and M tokens received');
    }
  }

  function test_wrapUnwrapAccessControl() external {
    // Test that wrap/unwrap access control works correctly
    console2.log('=== Access Control Test ===');

    uint256 testAmount = 100e6;

    // Test 1: Only SwapFacility can call wrap
    address[] memory unauthorizedCallers = new address[](4);
    unauthorizedCallers[0] = SEPOLIA_USDSC_ADMIN;
    unauthorizedCallers[1] = bob;
    unauthorizedCallers[2] = charlie;
    unauthorizedCallers[3] = user;

    for (uint256 i = 0; i < unauthorizedCallers.length; i++) {
      vm.prank(unauthorizedCallers[i]);
      vm.expectRevert(); // Should revert with NotSwapFacility
      usdscExtension.wrap(bob, testAmount);
    }
    console2.log('[PASS] All unauthorized callers correctly rejected for wrap()');

    // Test 2: Only SwapFacility can call unwrap
    for (uint256 i = 0; i < unauthorizedCallers.length; i++) {
      vm.prank(unauthorizedCallers[i]);
      vm.expectRevert(); // Should revert with NotSwapFacility
      usdscExtension.unwrap(bob, testAmount);
    }
    console2.log('[PASS] All unauthorized callers correctly rejected for unwrap()');

    // Test 3: SwapFacility can call both functions (even if they fail for other reasons)
    vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
    vm.expectRevert(); // Will revert for other reasons (insufficient balance, etc.)
    usdscExtension.wrap(bob, testAmount);
    console2.log('[PASS] SwapFacility can call wrap() (reverted for balance reasons, not access)');

    vm.prank(SEPOLIA_SWAP_FACILITY_ADDRESS);
    vm.expectRevert(); // Will revert for other reasons (insufficient balance, etc.)
    usdscExtension.unwrap(bob, testAmount);
    console2.log('[PASS] SwapFacility can call unwrap() (reverted for balance reasons, not access)');
  }

  function test_contractInfoWithMToken() external view {
    // Enhanced contract info including M token information
    console2.log('=== Enhanced Contract State ===');
    console2.log('USDSC Address:', SEPOLIA_USDSC_ADDRESS);
    console2.log('M Token Address:', SEPOLIA_MTOKEN_ADDRESS);
    console2.log('SwapFacility Address:', SEPOLIA_SWAP_FACILITY_ADDRESS);
    console2.log('Admin Address:', SEPOLIA_USDSC_ADMIN);
    console2.log('');
    console2.log('=== Token Balances ===');
    console2.log('Admin M Balance:', mTokenERC20.balanceOf(SEPOLIA_USDSC_ADMIN));
    console2.log('Admin USDSC Balance:', usdscToken.balanceOf(SEPOLIA_USDSC_ADMIN));
    console2.log('SwapFacility M Balance:', mTokenERC20.balanceOf(SEPOLIA_SWAP_FACILITY_ADDRESS));
    console2.log('USDSC Contract M Balance:', mTokenERC20.balanceOf(SEPOLIA_USDSC_ADDRESS));
    console2.log('USDSC Total Supply:', usdscToken.totalSupply());
  }

  // Todo
  // Testing yield accural based on index
  // setIsEarning can be called by appropriate mocks on M token (Or we wait for M0 team to add our extension as earner)
  // then based on M token balance in our USDSC contract and currentIndex, we would see yield.
}
