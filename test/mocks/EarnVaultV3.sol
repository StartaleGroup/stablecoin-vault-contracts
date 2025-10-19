// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EarnVaultUpgradeable} from "../../src/vaults/earn/EarnVaultUpgradeable.sol";
import {EarnVaultStorageBase} from "../../src/vaults/earn/EarnVaultStorageBase.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IEarnVaultEventsAndErrors} from "../../src/interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title EarnVaultV3 - Version 3 with enhanced features
/// @notice Adds advanced features: yield compounding, fee management, and enhanced analytics
contract EarnVaultV3 is EarnVaultUpgradeable {
    using SafeERC20 for IERC20;
    
    /// @custom:storage-location erc7201:startale.storage.EarnVaultV3
    struct EarnVaultV3Storage {
        uint256 performanceFeeRate;     // Performance fee rate (in basis points)
        uint256 managementFeeRate;     // Management fee rate (in basis points)
        uint256 totalFeesCollected;    // Total fees collected
        bool autoCompoundEnabled;      // Auto-compound yield feature
        uint256 compoundThreshold;    // Minimum amount to trigger auto-compound
        mapping(address => uint256) userLastCompoundTime; // Last compound time per user
        uint256 totalCompounds;        // Total number of compounds performed
    }

    // ERC7201 storage slot for EarnVaultV3
    bytes32 private constant EARN_VAULT_V3_STORAGE_LOCATION = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;

    function _getEarnVaultV3Storage() internal pure returns (EarnVaultV3Storage storage $) {
        assembly {
            $.slot := EARN_VAULT_V3_STORAGE_LOCATION
        }
    }

    // New events for V3 features
    event PerformanceFeeSet(uint256 oldRate, uint256 newRate);
    event ManagementFeeSet(uint256 oldRate, uint256 newRate);
    event FeeCollected(uint256 amount, uint256 totalFees);
    event AutoCompoundToggled(bool enabled);
    event CompoundThresholdSet(uint256 threshold);
    event AutoCompoundExecuted(address indexed user, uint256 amount);

    // New errors for V3 features
    error InvalidFeeRate();
    error AutoCompoundNotEnabled();
    error InsufficientAmountForCompound();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize V3 (reinitializer for upgrades)
    function initializeV3() public reinitializer(3) {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        $.performanceFeeRate = 200; // Default 2% performance fee
        $.managementFeeRate = 50;  // Default 0.5% management fee
        $.totalFeesCollected = 0;
        $.autoCompoundEnabled = false;
        $.compoundThreshold = 100e6; // Default 100 USDSC threshold
        $.totalCompounds = 0;
    }

    /// @notice Set performance fee rate (only owner)
    function setPerformanceFeeRate(uint256 rate) external onlyOwner {
        if (rate > 10000) revert InvalidFeeRate(); // Max 100%
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        uint256 oldRate = $.performanceFeeRate;
        $.performanceFeeRate = rate;
        emit PerformanceFeeSet(oldRate, rate);
    }

    /// @notice Set management fee rate (only owner)
    function setManagementFeeRate(uint256 rate) external onlyOwner {
        if (rate > 10000) revert InvalidFeeRate(); // Max 100%
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        uint256 oldRate = $.managementFeeRate;
        $.managementFeeRate = rate;
        emit ManagementFeeSet(oldRate, rate);
    }

    /// @notice Toggle auto-compound feature (only owner)
    function setAutoCompoundEnabled(bool enabled) external onlyOwner {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        $.autoCompoundEnabled = enabled;
        emit AutoCompoundToggled(enabled);
    }

    /// @notice Set compound threshold (only owner)
    function setCompoundThreshold(uint256 threshold) external onlyOwner {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        $.compoundThreshold = threshold;
        emit CompoundThresholdSet(threshold);
    }

    /// @notice Execute auto-compound for a user
    function executeAutoCompound(address user) external {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        if (!$.autoCompoundEnabled) revert AutoCompoundNotEnabled();
        
        uint256 claimableAmount = this.claimable(user);
        if (claimableAmount < $.compoundThreshold) revert InsufficientAmountForCompound();
        
        // Auto-compound by adding claimable to principal
        _settle(user);
        EarnVaultStorage storage $base = _getStorage();
        uint256 p = $base.principal[user];
        uint256 accrued = $base.accrued[user];
        
        if (accrued > 0) {
            $base.principal[user] = p + accrued;
            $base.totalPrincipal += accrued;
            $base.accrued[user] = 0;
            $.userLastCompoundTime[user] = block.timestamp;
            $.totalCompounds++;
            
            emit AutoCompoundExecuted(user, accrued);
        }
    }

    /// @notice Override deposit to include auto-compound check
    function deposit(uint256 amount) external override whenNotPaused nonReentrant {
        EarnVaultStorage storage $ = _getStorage();
        EarnVaultV3Storage storage $v3 = _getEarnVaultV3Storage();
        
        _checkNotBlacklisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        
        // Check for auto-compound before deposit
        if ($v3.autoCompoundEnabled && this.claimable(msg.sender) >= $v3.compoundThreshold) {
            this.executeAutoCompound(msg.sender);
        }
        
        $.USDSC.safeTransferFrom(msg.sender, address(this), amount);
        $.principal[msg.sender] += amount;
        $.totalPrincipal += amount;
        $.claimReserve += amount;

        emit Deposit(msg.sender, amount);
    }

    /// @notice Override onYield to include fee collection
    function onYield(uint256 amount) external override onlyYieldRedistributor nonReentrant {
        EarnVaultStorage storage $ = _getStorage();
        EarnVaultV3Storage storage $v3 = _getEarnVaultV3Storage();
        
        if (amount == 0) return;
        
        uint256 bal = $.USDSC.balanceOf(address(this));
        
        if ($.totalPrincipal == 0) {
            if (bal < amount) revert InsufficientFunding();
            $.USDSC.safeTransfer($.treasury, amount);
            emit YieldTransferredToTreasury(amount);
            return;
        }
        
        if (bal < $.claimReserve + amount) revert InsufficientFunding();
        
        // Calculate and collect performance fee
        uint256 performanceFee = (amount * $v3.performanceFeeRate) / 10000;
        uint256 netYield = amount - performanceFee;
        
        if (performanceFee > 0) {
            $v3.totalFeesCollected += performanceFee;
            // Transfer fee to treasury
            $.USDSC.safeTransfer($.treasury, performanceFee);
            emit FeeCollected(performanceFee, $v3.totalFeesCollected);
        }
        
        // Update index with net yield
        unchecked {
            uint256 num = netYield * $.RAY + $._carryRay;
            uint256 delta = num / $.totalPrincipal;
            $._carryRay = num % $.totalPrincipal;
            $.globalIndex += delta;
        }
        
        $.claimReserve += netYield;
        emit YieldIndexed(netYield, $.globalIndex, $.claimReserve);
    }

    /// @notice Get V3 specific data
    function getPerformanceFeeRate() external view returns (uint256) {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        return $.performanceFeeRate;
    }

    function getManagementFeeRate() external view returns (uint256) {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        return $.managementFeeRate;
    }

    function getTotalFeesCollected() external view returns (uint256) {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        return $.totalFeesCollected;
    }

    function isAutoCompoundEnabled() external view returns (bool) {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        return $.autoCompoundEnabled;
    }

    function getCompoundThreshold() external view returns (uint256) {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        return $.compoundThreshold;
    }

    function getUserLastCompoundTime(address user) external view returns (uint256) {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        return $.userLastCompoundTime[user];
    }

    function getTotalCompounds() external view returns (uint256) {
        EarnVaultV3Storage storage $ = _getEarnVaultV3Storage();
        return $.totalCompounds;
    }

    /// @notice Get version info
    function getVersion() external pure override returns (string memory) {
        return "EarnVaultV3";
    }
}
