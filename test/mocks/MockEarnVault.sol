// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockUSDSC} from "./MockUSDSC.sol";

contract MockEarnVault {
    MockUSDSC public immutable usdsc;
    uint256 public totalPrincipal_;
    uint256 public claimReserve;

    constructor(MockUSDSC _usdsc) { usdsc = _usdsc; }

    function asset() external view returns (address) { return address(usdsc); }
    function totalPrincipal() external view returns (uint256) { return totalPrincipal_; }

    function setPrincipal(uint256 p) external { totalPrincipal_ = p; }
    function setClaimReserve(uint256 r) external { claimReserve = r; }

    function onYield(uint256 amount) external {
        require(usdsc.balanceOf(address(this)) >= claimReserve + amount, "funding invariant");
        claimReserve += amount;
    }

    // user funcs not required by redistributor tests omitted
}
