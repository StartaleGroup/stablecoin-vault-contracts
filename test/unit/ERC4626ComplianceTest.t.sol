// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";
import {SUSDxVault} from '../../src/vaults/4626/SUSDxVault.sol';
import {USDx} from '../../src/coin/mock/USDx.sol';
import {MockMToken} from '../mocks/MockMToken.sol';
import {MockSwapFacility} from 'm-extensions-test/utils/Mocks.sol';
import {MockM} from 'm-extensions-test/utils/Mocks.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {ERC4626OffsetMock} from "@openzeppelin/contracts/mocks/token/ERC4626OffsetMock.sol";

// Used ERC4626 properties test from a16z. https://github.com/a16z/erc4626-tests
// More examples can be found in: https://github.com/search?q=path%3A*.sol+%22erc4626-tests%2FERC4626.test.sol%22+&type=code
contract ERC4626VaultOffsetMock is ERC4626OffsetMock {
    constructor(
        ERC20 underlying_,
        uint8 offset_
    ) ERC20("My USDx Vault", "MUSDXV") ERC4626(underlying_) ERC4626OffsetMock(offset_) {}
}

contract ERC4626ComplianceTest is ERC4626Test {

    SUSDxVault internal vault;

    address internal admin = makeAddr('admin');
    address internal pauser = makeAddr('pauser');

    ERC20 private _underlyingMock = new ERC20Mock();

    function setUp() public override {
        _deployContracts();
        _underlying_ = address(_underlyingMock);
        _vault_ = address(vault);
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = true;
    }

    function _deployContracts() internal {
        vault = new SUSDxVault(IERC20(address(_underlyingMock)), admin, pauser);
    }

    /**
     * @dev Check the case where calculated `decimals` value overflows the `uint8` type.
     */
    function testFuzzDecimalsOverflow(uint8 offset) public {
        /// @dev Remember that the `_underlying` exhibits a `decimals` value of 18.
        offset = uint8(bound(uint256(offset), 238, uint256(type(uint8).max)));
        ERC4626VaultOffsetMock erc4626VaultOffsetMock = new ERC4626VaultOffsetMock(_underlyingMock, offset);
        vm.expectRevert();
        erc4626VaultOffsetMock.decimals();
    }
}