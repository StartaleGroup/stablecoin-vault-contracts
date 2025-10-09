// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockUSDR} from "./MockUSDR.sol";

contract MockEarnVault {
    MockUSDR public immutable usdr;
    uint256 public totalPrincipal_;
    uint256 public claimReserve;

    constructor(MockUSDR _usdr) { usdr = _usdr; }

    function asset() external view returns (address) { return address(usdr); }
    function totalPrincipal() external view returns (uint256) { return totalPrincipal_; }

    function setPrincipal(uint256 p) external { totalPrincipal_ = p; }
    function setClaimReserve(uint256 r) external { claimReserve = r; }

    function onYield(uint256 amount) external {
        require(usdr.balanceOf(address(this)) >= claimReserve + amount, "funding invariant");
        claimReserve += amount;
    }

    // user funcs not required by redistributor tests omitted
}
