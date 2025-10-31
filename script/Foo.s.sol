// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {Foo} from '../src/mock/Foo.sol';
import {Script} from 'forge-std/Script.sol';

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract FooScript is Script {
  Foo internal foo;

  function run() public {
    vm.startBroadcast();
    foo = new Foo();
    vm.stopBroadcast();
  }
}
