// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SUSDSCVault} from '../../src/vaults/4626/SUSDSCVault.sol';

/**
 * @title MockSUSDSCVaultV2
 * @notice Mock upgraded version of SUSDSCVault for testing upgrades
 * @dev Adds new functionality to test upgrade storage compatibility
 */
contract MockSUSDSCVaultV2 is SUSDSCVault {
    /// @notice New state variable added in V2
    uint256 public newVariable;

    /// @notice Event emitted when new variable is set
    event NewVariableSet(uint256 value);

    /**
     * @notice New function added in V2
     * @param _value The value to set
     */
    function setNewVariable(uint256 _value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        newVariable = _value;
        emit NewVariableSet(_value);
    }

    /**
     * @notice New view function added in V2
     * @return The current value of newVariable
     */
    function getNewVariable() external view returns (uint256) {
        return newVariable;
    }

    /**
     * @notice Returns the version of the contract
     * @return The version number
     */
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}
