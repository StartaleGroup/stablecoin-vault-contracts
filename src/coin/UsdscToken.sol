// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// Copy of the USDSC implementation verified on Soneium at 0x38E4713a896EfCF253430efD6292515Dc13489A1
// (behind the USDSC proxy 0x3f99231dD03a9F0E7e3421c92B7b90fbe012985a), used by tests in place of a
// simplified token. Two edits only, both for this repo's build: the pragma is ^0.8.26 instead of
// 0.8.26, and MYieldToOne is imported through this repo's m-extensions/ remapping. The m-extensions
// sources under lib/evm-m-extensions match the verified ones apart from the same pragma pin.
// Excluded from forge fmt so it stays diffable against the verified source.

import {MYieldToOne} from "m-extensions/projects/yieldToOne/MYieldToOne.sol";

/**
 *
 * ██╗   ██╗███████╗██████╗ ███████╗ ██████╗
 * ██║   ██║██╔════╝██╔══██╗██╔════╝██╔════╝
 * ██║   ██║███████╗██║  ██║███████╗██║
 * ██║   ██║╚════██║██║  ██║╚════██║██║
 * ╚██████╔╝███████║██████╔╝███████║╚██████╗
 *  ╚═════╝ ╚══════╝╚═════╝ ╚══════╝ ╚═════╝
 *
 */

/**
 * @title UsdscToken
 * @notice M extension for the USDSC token.
 * @author M0 labs, Startale
 */
contract UsdscToken is MYieldToOne {
    /* ============ Custom Errors ============ */
    error YieldClaimerCannotBeZeroAddress();

    /* ============ Variables ============ */
    bytes32 public constant YIELD_CLAIMER_ROLE = keccak256("YIELD_CLAIMER_ROLE");

    /* ============ Constructor ============ */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address mToken_, address swapFacility_) MYieldToOne(mToken_, swapFacility_) {
        _disableInitializers();
    }

    /* ============ Initializer ============ */
    /**
     * @notice Initializes the USDSC token.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     * @param yieldRecipient The address to send the yield to.
     * @param admin The address of the admin.
     * @param freezeManager The address of the freeze manager.
     * @param yieldRecipientManager The address of the yield recipient manager.
     * @param yieldClaimer The address of the yield claimer. Must be granted the YIELD_CLAIMER_ROLE.
     */
    function initialize(
        string memory name,
        string memory symbol,
        address yieldRecipient,
        address admin,
        address freezeManager,
        address yieldRecipientManager,
        address yieldClaimer
    ) external initializer {
        if (yieldClaimer == address(0)) revert YieldClaimerCannotBeZeroAddress();
        __MYieldToOne_init(
            name, // "Startale USD"
            symbol, // "USDSC"
            yieldRecipient, // Where all the yield is sent to
            admin, // Default admin address
            freezeManager, // Freeze manager address
            yieldRecipientManager // Yield recipient manager address
        );
        _grantRole(YIELD_CLAIMER_ROLE, yieldClaimer);
    }

    /**
     * @dev Hook called before claiming yield.
     * @dev MUST only be callable by the `YIELD_CLAIMER_ROLE`.
     */
    function _beforeClaimYield() internal view override onlyRole(YIELD_CLAIMER_ROLE) {}
}
