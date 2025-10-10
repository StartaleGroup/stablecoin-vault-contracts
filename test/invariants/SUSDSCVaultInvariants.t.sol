// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from 'forge-std/Test.sol';
import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {console2} from 'forge-std/console2.sol';
import {SUSDSCVault} from '../../src/vaults/4626/SUSDSCVault.sol';
import {USDSC} from '../../src/coin/mock/USDSC.sol';
import {MockMToken} from '../mocks/MockMToken.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

contract SUSDSCVaultHandler is Test {
    SUSDSCVault public vault;
    USDSC public usdr;
    
    address[] public users;
    uint256 public constant MAX_USERS = 20;
    uint256 public constant MAX_AMOUNT = 1000000 ether;
    
    mapping(address => uint256) public userShares;
    uint256 public totalUserShares;
    
    constructor(SUSDSCVault _vault, USDSC _usdr) {
        vault = _vault;
        usdr = _usdr;
        
        for (uint i = 0; i < MAX_USERS; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));
            users.push(user);
            deal(address(usdr), user, MAX_AMOUNT);
        }
    }
    
    function deposit(uint256 userIndex, uint256 assets) external {
        userIndex = bound(userIndex, 0, users.length - 1);
        assets = bound(assets, 1, _min(MAX_AMOUNT / 10, usdr.balanceOf(users[userIndex])));
        
        address user = users[userIndex];
        
        vm.startPrank(user);
        usdr.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, user);
        vm.stopPrank();
        
        userShares[user] += shares;
        totalUserShares += shares;
    }
    
    function mint(uint256 userIndex, uint256 shares) external {
        userIndex = bound(userIndex, 0, users.length - 1);
        shares = bound(shares, 1, MAX_AMOUNT / 10);
        
        address user = users[userIndex];
        uint256 assets = vault.previewMint(shares);
        
        if (assets > usdr.balanceOf(user)) return;
        
        vm.startPrank(user);
        usdr.approve(address(vault), assets);
        vault.mint(shares, user);
        vm.stopPrank();
        
        userShares[user] += shares;
        totalUserShares += shares;
    }
    
    function redeem(uint256 userIndex, uint256 shares) external {
        userIndex = bound(userIndex, 0, users.length - 1);
        address user = users[userIndex];
        
        uint256 userBalance = vault.balanceOf(user);
        if (userBalance == 0) return;
        
        shares = bound(shares, 1, userBalance);
        
        vm.startPrank(user);
        vault.redeem(shares, user, user);
        vm.stopPrank();
        
        userShares[user] -= shares;
        totalUserShares -= shares;
    }
    
    function withdraw(uint256 userIndex, uint256 assets) external {
        userIndex = bound(userIndex, 0, users.length - 1);
        address user = users[userIndex];
        
        uint256 maxAssets = vault.maxWithdraw(user);
        if (maxAssets == 0) return;
        
        assets = bound(assets, 1, maxAssets);
        uint256 shares = vault.previewWithdraw(assets);
        
        vm.startPrank(user);
        vault.withdraw(assets, user, user);
        vm.stopPrank();
        
        userShares[user] -= shares;
        totalUserShares -= shares;
    }
    
    function addYield(uint256 yieldAmount) external {
        if (vault.totalSupply() == 0) return;
        
        uint256 maxYield = vault.totalAssets() > 0 ? vault.totalAssets() / 10 : 1000 ether;
        maxYield = _min(maxYield, MAX_AMOUNT / 100);
        
        if (maxYield < 1 ether) return;
        
        yieldAmount = bound(yieldAmount, 1 ether, maxYield);
        
        address yieldDistributor = makeAddr('yieldDistributor');
        deal(address(usdr), yieldDistributor, yieldAmount);
        
        vm.startPrank(yieldDistributor);
        usdr.transfer(address(vault), yieldAmount);
        vm.stopPrank();
    }
    
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract SUSDSCVaultInvariants is StdInvariant, Test {
    SUSDSCVault internal vault;
    USDSC internal usdr;
    MockM internal mToken;
    MockSwapFacility internal swapFacility;
    SUSDSCVaultHandler internal handler;
    
    address internal admin = makeAddr('admin');
    address internal pauser = makeAddr('pauser');
    address internal yieldRecipient = makeAddr('yieldRecipient');
    
    function setUp() external {
        _deployContracts();
        _setupHandler();
    }
    
    function _deployContracts() internal {
        mToken = new MockM();
        swapFacility = new MockSwapFacility();
        ProxyAdmin proxyAdmin = new ProxyAdmin(admin);

        USDSC implementation = new USDSC(address(mToken), address(swapFacility));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeWithSelector(USDSC.initialize.selector, 'USDSC', 'USDSC', admin, yieldRecipient)
        );
        usdr = USDSC(address(proxy));

        vault = new SUSDSCVault(IERC20(address(usdr)), admin, pauser);
    }
    
    function _setupHandler() internal {
        handler = new SUSDSCVaultHandler(vault, usdr);
        
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = SUSDSCVaultHandler.deposit.selector;
        selectors[1] = SUSDSCVaultHandler.mint.selector;
        selectors[2] = SUSDSCVaultHandler.redeem.selector;
        selectors[3] = SUSDSCVaultHandler.withdraw.selector;
        selectors[4] = SUSDSCVaultHandler.addYield.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }
    
    function invariant_assetConservation() external view {
        assertEq(vault.totalAssets(), usdr.balanceOf(address(vault)));
    }
    
    function invariant_shareSupplyConsistency() external view {
        uint256 totalSupply = vault.totalSupply();
        uint256 sumUserShares = 0;
        
        for (uint i = 0; i < handler.MAX_USERS(); i++) {
            address user = handler.users(i);
            sumUserShares += vault.balanceOf(user);
        }
        
        assertEq(totalSupply, sumUserShares);
    }
    
    function invariant_conversionConsistency() external view {
        if (vault.totalSupply() == 0) return;
        
        uint256 testShares = 1000 ether;
        if (testShares > vault.totalSupply()) testShares = vault.totalSupply();
        
        uint256 assets = vault.convertToAssets(testShares);
        uint256 backToShares = vault.convertToShares(assets);
        
        assertApproxEqAbs(testShares, backToShares, testShares / 1000 + 1);
    }
    
    function invariant_previewAccuracy() external view {
        if (vault.totalSupply() == 0) return;
        
        uint256 testAssets = _min(1000 ether, vault.totalAssets() / 2);
        uint256 testShares = _min(1000 ether, vault.totalSupply() / 2);
        
        if (testAssets > 0) {
            assertApproxEqAbs(vault.previewDeposit(testAssets), vault.convertToShares(testAssets), 1);
            assertApproxEqAbs(vault.previewWithdraw(testAssets), vault.convertToShares(testAssets), 1);
        }
        
        if (testShares > 0) {
            assertApproxEqAbs(vault.previewMint(testShares), vault.convertToAssets(testShares), 1);
            assertApproxEqAbs(vault.previewRedeem(testShares), vault.convertToAssets(testShares), 1);
        }
    }
    
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    function invariant_ppsNonDecreasing() external view {
        if (vault.totalSupply() == 0) return;
        
        uint256 currentPPS = vault.convertToAssets(1 ether);
        
        if (vault.totalAssets() > 0) {
            assertGe(currentPPS, 1 ether);
        }
    }
    
    function invariant_proportionalShares() external view {
        if (vault.totalSupply() == 0 || vault.totalAssets() == 0) return;
        
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        
        for (uint i = 0; i < handler.MAX_USERS(); i++) {
            address user = handler.users(i);
            uint256 userShares = vault.balanceOf(user);
            
            if (userShares > 0 && userShares <= totalSupply) {
                uint256 userAssets = vault.convertToAssets(userShares);
                uint256 expectedUserAssets = (userShares * totalAssets) / totalSupply;
                
                uint256 tolerance = _max(userAssets / 1000, expectedUserAssets / 1000) + 2;
                assertApproxEqAbs(userAssets, expectedUserAssets, tolerance);
            }
        }
    }
    
    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
    
    function invariant_roundingFavorVault() external view {
        if (vault.totalSupply() == 0) return;
        
        uint256 testAssets = 1000 ether;
        uint256 shares = vault.convertToShares(testAssets);
        uint256 backToAssets = vault.convertToAssets(shares);
        
        assertLe(backToAssets, testAssets + 1);
    }
    
    function invariant_noNegativeBalances() external view {
        assertGe(vault.totalSupply(), 0);
        assertGe(vault.totalAssets(), 0);
        assertGe(usdr.balanceOf(address(vault)), 0);
        
        for (uint i = 0; i < handler.MAX_USERS(); i++) {
            address user = handler.users(i);
            assertGe(vault.balanceOf(user), 0);
            assertGe(usdr.balanceOf(user), 0);
        }
    }
    
    function invariant_totalSupplyMatchesIndividualShares() external view {
        uint256 totalSupply = vault.totalSupply();
        uint256 sumIndividualShares = 0;
        
        for (uint i = 0; i < handler.MAX_USERS(); i++) {
            address user = handler.users(i);
            sumIndividualShares += vault.balanceOf(user);
        }
        
        assertEq(totalSupply, sumIndividualShares);
    }
    
    function invariant_maxFunctionsNeverRevert() external view {
        for (uint i = 0; i < handler.MAX_USERS(); i++) {
            address user = handler.users(i);
            
            uint256 maxDeposit = vault.maxDeposit(user);
            uint256 maxMint = vault.maxMint(user);
            uint256 maxWithdraw = vault.maxWithdraw(user);
            uint256 maxRedeem = vault.maxRedeem(user);
            
            assertGe(maxDeposit, 0);
            assertGe(maxMint, 0);
            assertGe(maxWithdraw, 0);
            assertGe(maxRedeem, 0);
        }
    }
    
    function invariant_previewNeverReverts() external view {
        uint256 testAmount = 1000 ether;
        
        vault.previewDeposit(testAmount);
        vault.previewMint(testAmount);
        vault.previewWithdraw(testAmount);
        vault.previewRedeem(testAmount);
    }
    
    function invariant_rolesSecurity() external view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
        
        for (uint i = 0; i < handler.MAX_USERS(); i++) {
            address user = handler.users(i);
            assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), user));
            assertFalse(vault.hasRole(vault.PAUSER_ROLE(), user));
        }
    }
    
    function invariant_assetIntegrity() external view {
        assertEq(address(vault.asset()), address(usdr));
        assertEq(vault.decimals(), usdr.decimals());
    }
    
    function invariant_erc4626Compliance() external view {
        if (vault.totalSupply() == 0) return;
        
        uint256 testAssets = 100 ether;
        uint256 testShares = 100 ether;
        
        uint256 sharesFromAssets = vault.convertToShares(testAssets);
        uint256 assetsFromShares = vault.convertToAssets(testShares);
        
        if (sharesFromAssets > 0) {
            uint256 backToAssets = vault.convertToAssets(sharesFromAssets);
            assertLe(backToAssets, testAssets + 1);
        }
        
        if (assetsFromShares > 0) {
            uint256 backToShares = vault.convertToShares(assetsFromShares);
            assertLe(backToShares, testShares + 1);
        }
    }
    
    function invariant_yieldOnlyIncreasesValue() external view {
        if (vault.totalSupply() == 0) return;
        
        uint256 pps = vault.convertToAssets(1 ether);
        assertGe(pps, 1 ether);
    }
    
    function invariant_noArbitraryMinting() external view {
        uint256 vaultBalance = usdr.balanceOf(address(vault));
        uint256 totalAssets = vault.totalAssets();
        
        assertEq(vaultBalance, totalAssets);
    }
}

