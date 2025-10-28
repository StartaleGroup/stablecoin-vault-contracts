// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {MockERC20} from './MockERC20.sol';

contract MockWrappedMToken is MockERC20 {
  address public mToken;

  constructor(address mToken_) MockERC20('Mock Wrapped M', 'Wrapped M', 6) {
    mToken = mToken_;
  }

  function wrap(address recipient_, uint256 amount_) external returns (uint240 wrapped_) {
    uint256 startingBalance_ = IERC20(mToken).balanceOf(address(this));
    bool success = IERC20(mToken).transferFrom(msg.sender, address(this), amount_);
    require(success, 'Transfer failed');

    uint256 balanceDiff = IERC20(mToken).balanceOf(address(this)) - startingBalance_;
    require(balanceDiff <= type(uint240).max, 'Amount exceeds uint240 max');
    // casting to 'uint240' is safe because we check balanceDiff <= type(uint240).max above
    // forge-lint: disable-next-line(unsafe-typecast)
    wrapped_ = uint240(balanceDiff);

    _mint(recipient_, wrapped_);
  }

  function unwrap(address recipient_, uint256 amount_) external returns (uint240 unwrapped_) {
    _burn(msg.sender, amount_);
    uint256 startingBalance_ = IERC20(mToken).balanceOf(address(this));
    bool success = IERC20(mToken).transfer(recipient_, amount_);
    require(success, 'Transfer failed');

    uint256 balanceDiff = startingBalance_ - IERC20(mToken).balanceOf(address(this));
    require(balanceDiff <= type(uint240).max, 'Amount exceeds uint240 max');
    // casting to 'uint240' is safe because we check balanceDiff <= type(uint240).max above
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint240(balanceDiff);
  }
}
