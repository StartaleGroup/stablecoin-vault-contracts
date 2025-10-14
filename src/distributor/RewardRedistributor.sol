// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IEarnVault} from "../interfaces/vaults/earn/IEarnVault.sol";
import {IMYieldToOne} from "m-extensions/projects/yieldToOne/IMYieldToOne.sol";

/// @title RewardRedistributor
/// @notice Pulls freshly-minted USDSC yield from the M0 extension, applies an optional fee to Startale,
///         then allocates the **net** yield to eligible cohorts by their share of the
///         **base supply** S (supply before this mint):
///         - EarnVault (checkbox OFF) receives `toEarn = Y_net * T_earn / S_base`
///         - sUSDSC (ERC-4626) vault (checkbox ON) receives `toOn = Y_net * T_yield / S_base`
///         - Remainder (wallets/LP/points + rounding) → Startale (`toStartaleExtra`)
/// @dev    Uses per-cohort integer carry to remove long-run rounding bias.
///         Delivers to EarnVault with transfer→onYield ordering to satisfy its funding invariant.
///         Delivers to sUSDSC via raw transfer, which raises PPS in ERC-4626.
///         
///         Architecture:
///         - USDSC_ADDRESS: Single USDSC token address that implements both IERC20 and IMYieldToOne interfaces
///         - Cast to IERC20 for transfers and supply queries (totalSupply, safeTransfer)
///         - Cast to IMYieldToOne for yield operations (claimYield, yield)
contract RewardRedistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Keeper allowed to call distribute()
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice USDSC token address - used for both transfers/supply queries (IERC20) and yield operations (IMYieldToOne).
    /// @dev    The same address implements both IERC20 and IMYieldToOne interfaces.
    address          public immutable USDSC_ADDRESS;


    /// @notice Treasury recipient for fees and ineligible cohort yield.
    address          public treasury;          // Treasury

    /// @notice Earn vault (checkbox OFF) that indexes yield via {IEarnVault.onYield}.
    IEarnVault       public earnVault;                 // checkbox OFF vault

    /// @notice sUSDSC ERC-4626 vault (checkbox ON) that receives donations via raw transfer (PPS rises).
    IERC4626         public susdscVault;                // checkbox ON (ERC-4626)

    // Note: fee_on_yield_bps is most likely to be 0 always. as this portion we plan to take on Ethereum. 
    // Review
    // Making configurable with some boundaries.

    /// @notice Fee on newly minted yield expressed in basis points (e.g., 1000 = 10%).
    uint16 public fee_on_yield_bps = 0;             // 0 = 0% , 1000 = 10%

    /// @notice Maximum fee allowed (basis points).
    uint16 public constant MAX_FEE_BPS = 2000;

    /// @dev Carry accumulator for EarnVault share calculations across epochs.
    uint256 private carryEarn;  // rounding carry for EarnVault share

    /// @dev Carry accumulator for sUSDSC (ON) share calculations across epochs.
    uint256 private carryOn;    // rounding carry for sUSDSCVault share

    /// @notice Emitted after each distribution.
    /// @param minted            Total USDSC freshly minted by the extension in this call.
    /// @param feeToStartale     Fee portion (bps of minted) sent to Startale.
    /// @param toEarnVault            Net yield sent to EarnVault (checkbox OFF).
    /// @param toSUSDSCVault      Net yield sent to sUSDSC ERC-4626 vault (checkbox ON).
    /// @param toStartaleExtra   Remainder of net yield: ineligible cohorts (wallets/LP/points) + rounding dust.
    /// @param S_base            Total USDSC supply **before** this mint (denominator for allocation).
    /// @param T_earn            EarnVault TVL used for allocation (i.e., `earnVault.totalPrincipal()`).
    /// @param T_yield              sUSDSCVault TVL used for allocation (i.e., `susdscVault.totalAssets()`).
    event Distributed(
        uint256 minted,
        uint256 feeToStartale,
        uint256 toEarnVault,
        uint256 toSUSDSCVault,
        uint256 toStartaleExtra,
        uint256 S_base,
        uint256 T_earn,
        uint256 T_yield
    );

    /// @notice Emitted when Startale/earn/sUSDSC addresses or fee are updated.
    /// @param treasury          New Treasury address.
    /// @param earnVault         New EarnVault address.
    /// @param susdscVault        New sUSDSC (ERC-4626) vault address.
    /// @param fee_on_yield_bps  New fee on yield (bps).
    event ParamsUpdated(
        address treasury,
        address earnVault,
        address susdscVault,
        uint16  fee_on_yield_bps
    );

    /// @notice Initializes the redistributor.
    /// @param usdscAddress    USDSC token address (implements both IERC20 and IMYieldToOne interfaces).
    /// @param treasuryAddr   Treasury recipient.
    /// @param earnV          EarnVault (checkbox OFF) recipient.
    /// @param sVault         sUSDSC ERC-4626 vault (checkbox ON) recipient.
    /// @param admin          Admin address; receives DEFAULT_ADMIN_ROLE and OPERATOR_ROLE initially.
    /// @dev Note: could take keeper address and give it OPERATOR_ROLE
    constructor(
        address usdscAddress,
        address treasuryAddr,
        IEarnVault earnV,
        IERC4626 sVault,
        address admin
    ) {
        require(usdscAddress!=address(0) && treasuryAddr!=address(0) 
            && address(earnV)!=address(0) && address(sVault)!=address(0) 
            && admin!=address(0), "zero");

        USDSC_ADDRESS = usdscAddress;
        treasury = treasuryAddr;
        earnVault = earnV;
        susdscVault = sVault;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
    }

    /// @notice Updates Startale/EarnVault/sUSDSC addresses and the fee on yield.
    /// @dev    Fee is capped by {MAX_FEE_BPS}. Callable by DEFAULT_ADMIN_ROLE.
    /// @param treasuryAddr   New Treasury address.
    /// @param earnV          New EarnVault (OFF) address.
    /// @param sVault         New sUSDSC ERC-4626 vault (ON) address.
    /// @param newFeeBps      New fee on yield in bps (≤ MAX_FEE_BPS).
    /// @dev Note: could make this as separeate functions for each parameter.
    function setParams(
        address treasuryAddr,
        IEarnVault earnV,
        IERC4626 sVault,
        uint16 newFeeBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(treasuryAddr!=address(0) && address(earnV)!=address(0) && address(sVault)!=address(0), "zero");
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        treasury   = treasuryAddr;
        earnVault          = earnV;
        susdscVault         = sVault;
        fee_on_yield_bps   = newFeeBps;
        emit ParamsUpdated(treasuryAddr, address(earnV), address(sVault), newFeeBps);
    }

    function pause(bool p) external onlyRole(DEFAULT_ADMIN_ROLE) { p ? _pause() : _unpause(); }

    // ---------- previews ----------

    /// @notice Preview a split for a hypothetical minted amount.
    /// @dev    Pure math helper (no state/carry usage). Does **not** call the extension.
    /// @param minted  Hypothetical fresh yield to allocate (pre-fee).
    /// @return feeToStartale     Fee portion (bps of `minted`) to Startale.
    /// @return toEarn            Portion of net allocated to EarnVault (OFF) **without carry**.
    /// @return toOn              Portion of net allocated to sUSDSC (ON) **without carry**.
    /// @return toStartaleExtra   Remainder of net: ineligible cohorts + rounding.
    /// @return S_base            Total USDSC supply **before** this mint (= totalSupply - minted if ≥0).
    /// @return T_earn            EarnVault TVL used for allocation (`earnVault.totalPrincipal()`).
    /// @return T_yield              sUSDSCVault TVL used for allocation (`susdscVault.totalAssets()`).
    function previewSplit(uint256 minted)
        external view
        returns (
            uint256 feeToStartale,
            uint256 toEarn,
            uint256 toOn,
            uint256 toStartaleExtra,
            uint256 S_base,
            uint256 T_earn,
            uint256 T_yield
        )
    {
        return _calculateSplit(minted, false, true);
    }

    /// @notice Preview a split using the extension’s **current pending** yield (no carries).
    /// @dev    Reads {IUSDSCMExtension.yield}. Pure preview; does not mutate.
    /// @return minted            Pending fresh yield on the extension at this moment.
    /// @return feeToStartale     Fee portion (bps of `minted`) to Startale.
    /// @return toEarn            Portion of net to EarnVault (OFF) **without carry**.
    /// @return toOn              Portion of net to sUSDSC (ON) **without carry**.
    /// @return toStartaleExtra   Remainder of net: ineligible cohorts + rounding.
    /// @return S_base            Total USDSC supply **before** this mint.
    /// @return T_earn            EarnVault TVL used for allocation.
    /// @return T_yield              sUSDSCVault TVL used for allocation.
    function previewSplitCurrent()
        external view
        returns (
            uint256 minted,
            uint256 feeToStartale,
            uint256 toEarn,
            uint256 toOn,
            uint256 toStartaleExtra,
            uint256 S_base,
            uint256 T_earn,
            uint256 T_yield
        )
    {
        minted = IMYieldToOne(USDSC_ADDRESS).yield();
        (feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield) = _calculateSplit(minted, false, true);
    }

    /// @notice Exact dry-run of {distribute} against current chain state (includes carries).
    /// @dev    Reads extension’s pending yield and current carries; does not mutate state.
    /// @return minted            Pending fresh yield on the extension at this moment.
    /// @return feeToStartale     Fee portion (bps of `minted`) to Startale.
    /// @return toEarn            Portion of net to EarnVault (OFF) **with carry** (exact if called now).
    /// @return toOn              Portion of net to sUSDSC (ON) **with carry** (exact if called now).
    /// @return toStartaleExtra   Remainder of net: ineligible cohorts + rounding.
    /// @return S_base            Total USDSC supply **before** this mint.
    /// @return T_earn            EarnVault TVL used for allocation.
    /// @return T_yield              sUSDSCVault TVL used for allocation.
    function previewDistribute()
        external view
        returns (
            uint256 minted,
            uint256 feeToStartale,
            uint256 toEarn,
            uint256 toOn,
            uint256 toStartaleExtra,
            uint256 S_base,
            uint256 T_earn,
            uint256 T_yield
        )
    {
        minted = IMYieldToOne(USDSC_ADDRESS).yield();
        (feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield) = _calculateSplit(minted, true, true);
    }

    // ---------- core ----------

    /// @notice Claims pending USDSC yield from the extension and distributes it per policy.
    /// @dev    Sequence:
    ///         1) Record `balanceBefore = IERC20(USDSC_ADDRESS).balanceOf(address(this))`.
    ///         2) `minted = IMYieldToOne(USDSC_ADDRESS).claimYield()` mints fresh USDSC to this contract (must be yieldRecipient).
    ///         3) Calculate `gross = balanceBefore + minted` to handle both normal flow and external claimYield() calls.
    ///         4) `feeToStartale = gross * fee_on_yield_bps / 10_000`.
    ///         5) Compute `S_base = IERC20(USDSC_ADDRESS).totalSupply() - minted` (supply **before** this mint).
    ///         6) Read TVLs: `T_earn = earnVault.totalPrincipal()`, `T_yield = susdscVault.totalAssets()`.
    ///         7) Allocate net using carries:
    ///            `toEarn = floor((net*T_earn + carryEarn)/S_base)`, `carryEarn = (net*T_earn + carryEarn) % S_base`
    ///            `toOn   = floor((net*T_yield   + carryOn)/S_base)`,   `carryOn   = (net*T_yield   + carryOn)   % S_base`
    ///            `toStartaleExtra = net - (toEarn + toOn)`
    ///         8) Transfers:
    ///            - Startale: `feeToStartale + toStartaleExtra`
    ///            - EarnVault: transfer `toEarn` **then** call `earnVault.onYield(toEarn)`
    ///            - sUSDSC: transfer `toOn` (PPS rises)
    /// @custom:security nonReentrant and Pausable.
    function distribute() external whenNotPaused onlyRole(OPERATOR_ROLE) nonReentrant {
        // Review: Need to check if only specific role (yield recipient OR yield recipient manager) can call this
        uint256 balanceBefore = IERC20(USDSC_ADDRESS).balanceOf(address(this));
        uint256 minted = IMYieldToOne(USDSC_ADDRESS).claimYield();
        uint256 gross = balanceBefore + minted;
        
        if (gross == 0) return; // No yield to distribute

        uint256 feeToStartale;
        uint256 toEarn;
        uint256 toOn;
        uint256 toStartaleExtra;
        uint256 S_base;
        uint256 T_earn;
        uint256 T_yield;

        // Use helper for calculation, but we need to handle carries separately since we update state
        (feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield) = _calculateSplit(gross, true, false);

        // Handle zero S_base case
        if (S_base == 0) {
            if (feeToStartale > 0) IERC20(USDSC_ADDRESS).safeTransfer(treasury, feeToStartale);
            if (toStartaleExtra > 0) IERC20(USDSC_ADDRESS).safeTransfer(treasury, toStartaleExtra);
            emit Distributed(gross, feeToStartale, 0, 0, toStartaleExtra, 0, 0, 0);
            return;
        }

        // Update carry state variables (helper doesn't modify state)
        if (S_base > 0) {
            uint256 net = gross - feeToStartale;
            uint256 numEarn = net * T_earn + carryEarn;
            carryEarn = numEarn % S_base;

            uint256 numOn = net * T_yield + carryOn;
            carryOn = numOn % S_base;
        }

        // Execute transfers
        uint256 startaleTotal = feeToStartale + toStartaleExtra;
        if (startaleTotal > 0) IERC20(USDSC_ADDRESS).safeTransfer(treasury, startaleTotal);

        if (toEarn > 0) {
            IERC20(USDSC_ADDRESS).safeTransfer(address(earnVault), toEarn);
            // Immediately triggers onYield
            earnVault.onYield(toEarn);
        }
        if (toOn > 0) {
            IERC20(USDSC_ADDRESS).safeTransfer(address(susdscVault), toOn);
            // optional: susdscVault.syncDonation(toOn);
        }

        emit Distributed(gross, feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield);
    }

    // ---------- helpers ----------

    /// @notice Internal helper to calculate yield distribution split.
    /// @dev    Core calculation logic shared by preview functions and distribute().
    /// @param minted            Amount of fresh yield to allocate (pre-fee).
    /// @param useCarries        Whether to include carry calculations (true for distribute/previewDistribute).
    /// @param preMint           Whether this is a preview (true) or actual distribution (false).
    /// @return feeToStartale    Fee portion (bps of `minted`) to Startale.
    /// @return toEarn           Portion of net allocated to EarnVault (OFF).
    /// @return toOn             Portion of net allocated to sUSDSC (ON).
    /// @return toStartaleExtra  Remainder of net: ineligible cohorts + rounding.
    /// @return S_base           Total USDSC supply **before** this mint.
    /// @return T_earn           EarnVault TVL used for allocation.
    /// @return T_yield          sUSDSCVault TVL used for allocation.
    function _calculateSplit(uint256 minted, bool useCarries, bool preMint)
        internal view
        returns (
            uint256 feeToStartale,
            uint256 toEarn,
            uint256 toOn,
            uint256 toStartaleExtra,
            uint256 S_base,
            uint256 T_earn,
            uint256 T_yield
        )
    {
        if (minted == 0) {
            return (0, 0, 0, 0, _supplyBase(0), earnVault.totalPrincipal(), susdscVault.totalAssets());
        }

        feeToStartale = (minted * fee_on_yield_bps) / 10_000;
        uint256 net = minted - feeToStartale;

        uint256 SNow = IERC20(USDSC_ADDRESS).totalSupply();
        if (preMint) {
            // For preview functions: minted is pending/hypothetical, so S_base = current supply
            S_base = SNow;
        } else {
            // For actual distribution: minted is real, so S_base = supply before mint
            S_base = SNow > minted ? SNow - minted : 0;
        }

        T_earn = earnVault.totalPrincipal();
        T_yield = susdscVault.totalAssets();

        if (S_base == 0) {
            toStartaleExtra = net;
            return (feeToStartale, 0, 0, toStartaleExtra, S_base, T_earn, T_yield);
        }

        if (useCarries) {
            // Include carry calculations (for distribute/previewDistribute)
            uint256 _carryEarn = carryEarn;
            uint256 _carryOn = carryOn;

            uint256 numEarn = net * T_earn + _carryEarn;
            toEarn = numEarn / S_base;
            // Note: _carryEarn update not needed here as this is view function

            uint256 numOn = net * T_yield + _carryOn;
            toOn = numOn / S_base;
            // Note: _carryOn update not needed here as this is view function
        } else {
            // Simple calculation without carries (for previewSplit/previewSplitCurrent)
            toEarn = (net * T_earn) / S_base;
            toOn = (net * T_yield) / S_base;
        }

        toStartaleExtra = net - (toEarn + toOn);
    }

    /// @notice Computes the **base supply** used for allocation for a hypothetical `minted` amount.
    /// @dev    Defined as `totalSupply() > minted ? totalSupply() - minted : 0`.
    /// @param minted  Hypothetical fresh yield.
    /// @return        Total USDSC supply **before** the hypothetical mint.
    function _supplyBase(uint256 minted) internal view returns (uint256) {
        uint256 SNow = IERC20(USDSC_ADDRESS).totalSupply();
        return SNow > minted ? SNow - minted : 0;
    }
}
