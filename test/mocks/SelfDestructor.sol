// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SelfDestructor
/// @notice Helper contract to simulate selfdestruct sending ETH to vault
contract SelfDestructor {
    constructor() payable {}

    function selfDestruct(address payable target) external {

        assembly {
            // solhint-disable-next-line no-inline-assembly
            selfdestruct(target)
        }
    }
}
