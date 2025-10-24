// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.30;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

contract MockSpokePortal {
  address public immutable M_TOKEN;
  address public immutable REGISTRAR;

  constructor(address mToken_, address registrar_) {
    M_TOKEN = mToken_;
    REGISTRAR = registrar_;
  }

  function transfer(
    uint256 amount,
    uint16,
    /*recipientChain*/
    bytes32,
    /*recipient*/
    bytes32,
    /*refundAddress*/
    bool,
    /*shouldQueue*/
    bytes memory /*transceiverInstructions*/
  ) external payable returns (uint64) {
    bool success = IERC20(M_TOKEN).transferFrom(msg.sender, address(this), amount);
    require(success, 'Transfer failed');

    // Simulate ETH refund
    if (msg.value > 1) {
      (bool success2,) = msg.sender.call{value: msg.value - 1}('');
      require(success2, 'ETH refund failed');
    }

    return uint64(1);
  }
}
