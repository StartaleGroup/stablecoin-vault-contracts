// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IEarnVault} from "../../interfaces/vaults/earn/IEarnVault.sol";
import {IEarnVaultEventsAndErrors} from "../../interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol";

/// @title EarnVault (claimable yield)
/// @notice Users deposit USDR, accrue claimable USDR via index accounting, and can claim/withdraw anytime.
///         A distributor pushes yield: transfer USDR to this contract, then call onYield(amount).
/// Accounting:
///   - globalIndex is in RAY (1e27) for precision.
///   - User state: principal, userIndex, accrued.
///   - When yield arrives and totalPrincipal>0: globalIndex += amount*RAY/totalPrincipal.
///   - If totalPrincipal==0 at yield time: amount is transferred directly to treasury.
/// Invariant (funding): USDR balance >= claimReserve.
contract EarnVault is IEarnVault, IEarnVaultEventsAndErrors, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------- Constants --------
    uint256 public constant RAY = 1e27;  // High precision for yield calculations (MakerDAO standard)
    
    
    
    // -------- Roles --------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant YIELD_REDISTRIBUTOR_ROLE = keccak256("YIELD_REDISTRIBUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // -------- Immutables --------
    IERC20 public immutable USDR;


    // -------- Roles / endpoints --------
    address public yieldRedistributor;   // allowed to call onYield
    address public treasury;             // receives yield when no deposits exist, surplus sweeps
    address public pauser;               // allowed to pause/unpause the contract

    // -------- Optional blacklist --------
    mapping(address => bool) public isBlacklisted;

    // -------- Vault accounting --------
    uint256 public totalPrincipal;       // sum of user principals
    uint256 public globalIndex = RAY;    // global index (scaled 1e27 - RAY precision)
    uint256 public claimReserve;         // assets available to pay claims/withdraws
    uint256 private _carryRay;           // remainder in "RAY * principal" space for exact precision

    mapping(address => uint256) public principal;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public accrued;

    // -------- Events and Errors --------
    // All events and errors are inherited from IEarnVaultEventsAndErrors interface

    constructor(address usdr, address admin, address yieldRedistributorAddr, address treasuryAddr, address pauserAddr) {
        if (usdr == address(0) || admin == address(0)) revert CanNotBeZeroAddress();
        if (yieldRedistributorAddr == address(0) || treasuryAddr == address(0)) revert CanNotBeZeroAddress();
        if (pauserAddr == address(0)) revert CanNotBeZeroAddress();
        
        USDR = IERC20(usdr);
        yieldRedistributor = yieldRedistributorAddr;
        treasury = treasuryAddr;
        pauser = pauserAddr;
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(YIELD_REDISTRIBUTOR_ROLE, yieldRedistributorAddr);
        _grantRole(PAUSER_ROLE, pauserAddr);
    }

    // =========================
    // Admin / roles
    // =========================

    /// @notice Set the yield redistributor address
    /// @param who New yield redistributor address
    function setYieldRedistributor(address who) external onlyRole(ADMIN_ROLE) {
        if (who == address(0)) revert CanNotBeZeroAddress();
        address oldRedistributor = yieldRedistributor;
        _revokeRole(YIELD_REDISTRIBUTOR_ROLE, yieldRedistributor);
        _grantRole(YIELD_REDISTRIBUTOR_ROLE, who);
        yieldRedistributor = who;
        emit YieldRedistributorChanged(msg.sender, oldRedistributor, who);
    }

    /// @notice Set the treasury address  
    /// @param who New treasury address
    function setTreasury(address who) external onlyRole(ADMIN_ROLE) {
        if (who == address(0)) revert CanNotBeZeroAddress();
        address oldTreasury = treasury;
        treasury = who;
        emit TreasuryChanged(msg.sender, oldTreasury, who);
    }

    /// @notice Set the pauser address
    /// @param who New pauser address
    function setPauser(address who) external onlyRole(ADMIN_ROLE) {
        if (who == address(0)) revert CanNotBeZeroAddress();
        address oldPauser = pauser;
        _revokeRole(PAUSER_ROLE, pauser);
        _grantRole(PAUSER_ROLE, who);
        pauser = who;
        emit PauserChanged(msg.sender, oldPauser, who);
    }


    /// @notice Set blacklist status for an address
    /// @param who Address to update blacklist status for
    /// @param blacklisted Whether address should be blacklisted
    function setBlacklisted(address who, bool blacklisted) external onlyRole(ADMIN_ROLE) {
        bool oldStatus = isBlacklisted[who];
        isBlacklisted[who] = blacklisted;
        emit BlacklistStatusChanged(msg.sender, who, oldStatus, blacklisted);
    }

    /// @notice Pause the contract (emergency stop)
    /// @dev Can be called by admin or designated pauser
    function pause() external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) revert NotAuthorizedToPause();
        _pause();
    }
    
    /// @notice Unpause the contract
    /// @dev Can be called by admin or designated pauser  
    function unpause() external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) revert NotAuthorizedToPause();
        _unpause();
    }

    // =========================
    // Views
    // =========================

    function asset() external view returns (address) {
        return address(USDR);
    }

    function claimable(address user) external view returns (uint256) {
        uint256 p = principal[user];
        uint256 ui = userIndex[user];
        uint256 gi = globalIndex;
        if (p == 0) return accrued[user];
        if (gi > ui) {
            uint256 owed = Math.mulDiv(p, gi - ui, RAY);
            return accrued[user] + owed;
        }
        return accrued[user];
    }

    /// @notice Get user's total value (principal + claimable interest)
    function totalValue(address user) external view returns (uint256) {
        uint256 p = principal[user];
        uint256 ui = userIndex[user];
        uint256 gi = globalIndex;
        if (p == 0) return accrued[user];
        if (gi > ui) {
            uint256 owed = Math.mulDiv(p, gi - ui, RAY);
            return p + accrued[user] + owed;
        }
        return p + accrued[user];
    }

    /// @notice Get user's complete account info in one call
    function getUserInfo(address user) external view returns (
        uint256 userPrincipal,
        uint256 userClaimable, 
        uint256 userTotal,
        uint256 userLastIndex
    ) {
        userPrincipal = principal[user];
        userLastIndex = userIndex[user];
        
        // Inline claimable logic to avoid expensive external call
        uint256 p = userPrincipal;
        uint256 ui = userLastIndex;
        uint256 gi = globalIndex;
        
        if (p == 0) {
            userClaimable = accrued[user];
        } else if (gi > ui) {
            uint256 owed = Math.mulDiv(p, gi - ui, RAY);
            userClaimable = accrued[user] + owed;
        } else {
            userClaimable = accrued[user];
        }
        
        userTotal = userPrincipal + userClaimable;
    }

    /// @notice Get vault's overall statistics
    function getVaultStats() external view returns (
        uint256 vaultTotalPrincipal,
        uint256 vaultClaimReserve,
        uint256 vaultGlobalIndex,
        uint256 vaultBalance,
        uint256 vaultCarryRay
    ) {
        vaultTotalPrincipal = totalPrincipal;
        vaultClaimReserve = claimReserve;
        vaultGlobalIndex = globalIndex;
        vaultBalance = USDR.balanceOf(address(this));
        vaultCarryRay = _carryRay;
    }

    // =========================
    // User flows
    // =========================

    /// @notice Deposit USDR tokens to earn yield
    /// @dev Reserves principal 1:1 in claimReserve to ensure withdrawals are always possible
    /// @param amount Amount of USDR tokens to deposit
    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        
        USDR.safeTransferFrom(msg.sender, address(this), amount);
        principal[msg.sender] += amount;
        totalPrincipal += amount;
        claimReserve += amount;  // reserve principal 1:1

        emit Deposit(msg.sender, amount);
    }

    /// @notice Deposit USDR tokens using permit (gasless approval)
    /// @dev Same as deposit() but uses permit for approval in same transaction
    /// @dev Safely handles tokens that may not implement IERC20Permit
    /// @param amount Amount of USDR tokens to deposit
    /// @param deadline Permit deadline timestamp
    /// @param v Permit signature parameter v
    /// @param r Permit signature parameter r  
    /// @param s Permit signature parameter s
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        // Safely attempt permit - revert with clear error if not supported
        try IERC20Permit(address(USDR)).permit(msg.sender, address(this), amount, deadline, v, r, s) {
            // Permit succeeded, continue with deposit
        } catch {
            revert PermitFailed();
        }

        _settle(msg.sender);
        
        USDR.safeTransferFrom(msg.sender, address(this), amount);
        principal[msg.sender] += amount;
        totalPrincipal += amount;
        claimReserve += amount;  // reserve principal 1:1

        emit Deposit(msg.sender, amount);
    }

    /// @notice Withdraw any amount up to total value (principal + accrued interest)
    /// @param amount Total amount to withdraw (can include accrued interest)
    /// @dev Can withdraw: principal only, principal + partial interest, or full amount
    /// @dev For withdrawing everything including all interest, use withdrawAll()
    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        
        uint256 p = principal[msg.sender];
        uint256 userAccrued = accrued[msg.sender];
        uint256 userTotalValue = p + userAccrued;
        
        if (amount > userTotalValue) revert InsufficientPrincipal();

        uint256 principalToWithdraw = amount;
        uint256 interestToClaim = 0;
        
        if (amount > p) {
            // Need to claim some interest
            principalToWithdraw = p; // Withdraw all principal
            interestToClaim = amount - p; // Claim remaining from interest
        }
        
        // Update state
        principal[msg.sender] = p - principalToWithdraw;
        accrued[msg.sender] = userAccrued - interestToClaim;
        totalPrincipal -= principalToWithdraw;
        
        // Transfer funds
        claimReserve -= amount;
        USDR.safeTransfer(msg.sender, amount);
        
        // Emit events
        emit Withdraw(msg.sender, principalToWithdraw);
        if (interestToClaim > 0) {
            emit InterestClaimed(msg.sender, interestToClaim);
        }
    }

    /// @notice Withdraw all funds (principal + all accrued interest)
    /// @dev Convenience function that withdraws everything the user has
    /// @dev Equivalent to withdraw(principal + accrued) but simpler to use
    function withdrawAll() external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        _settle(msg.sender);
        
        uint256 p = principal[msg.sender];
        uint256 userAccrued = accrued[msg.sender];
        uint256 totalAmount = p + userAccrued;
        
        if (totalAmount == 0) revert NothingToClaim();
        
        // Update state
        principal[msg.sender] = 0;
        accrued[msg.sender] = 0;
        totalPrincipal -= p;
        claimReserve -= totalAmount;
        
        // Transfer all funds
        USDR.safeTransfer(msg.sender, totalAmount);
        
        // Emit events
        emit Withdraw(msg.sender, p);
        if (userAccrued > 0) {
            emit InterestClaimed(msg.sender, userAccrued);
        }
    }

    /// @notice Claim all accrued interest to caller's address
    /// @dev Settles user's position and transfers all accrued yield
    function claim() external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        _settle(msg.sender);
        uint256 amt = accrued[msg.sender];
        if (amt == 0) revert NothingToClaim();
        if (claimReserve < amt) revert InsufficientFunding();
        
        accrued[msg.sender] = 0;
        claimReserve -= amt;
        USDR.safeTransfer(msg.sender, amt);
        emit InterestClaimed(msg.sender, amt);
    }

    // =========================
    // Distributor hooks
    // =========================

    /// @notice Distribute yield to vault users (callable only by yield redistributor)
    /// @dev MUST be called AFTER transferring `amount` USDR to this contract
    /// @dev Enforces funding invariant: USDR.balance >= claimReserve + amount
    /// @param amount Amount of USDR yield to distribute
    function onYield(uint256 amount) external onlyRole(YIELD_REDISTRIBUTOR_ROLE) nonReentrant {
        if (amount == 0) return;
        
        // Verify actual balance before updating accounting
        uint256 bal = USDR.balanceOf(address(this));
        
        if (totalPrincipal == 0) {
            // No deposits: just need enough for treasury transfer
            if (bal < amount) revert InsufficientFunding();
            USDR.safeTransfer(treasury, amount);
            emit YieldTransferredToTreasury(amount);
            return;
        }
        
        // Deposits exist: need enough for claimReserve + new yield
        if (bal < claimReserve + amount) revert InsufficientFunding();
        
        // Exact, immediate index update with Ray remainder carry
        // delta = floor( (amount*RAY + _carryRay) / totalPrincipal )
        // _carryRay = (amount*RAY + _carryRay) % totalPrincipal
        unchecked {
            uint256 num = amount * RAY + _carryRay;
            uint256 delta = num / totalPrincipal;
            _carryRay = num % totalPrincipal;
            globalIndex += delta;
        }
        
        claimReserve += amount;
        emit YieldIndexed(amount, globalIndex, claimReserve);
    }


    // =========================
    // Internal helpers
    // =========================

    /// @dev Settles user's accrued yield based on globalIndex difference
    /// @dev Must ALWAYS be called before modifying principal[user] or accrued[user]
    /// @dev For first-time users, sets userIndex to current globalIndex to prevent over-allocation
    /// @param user Address to settle
    function _settle(address user) internal {
        uint256 p = principal[user];
        uint256 ui = userIndex[user];
        uint256 gi = globalIndex;
        if (p == 0) { 
            userIndex[user] = gi; 
            return; 
        }
        if (gi >= ui) {
            if (gi > ui) {
                uint256 owed = Math.mulDiv(p, gi - ui, RAY);
                accrued[user] += owed;
            }
            userIndex[user] = gi;  // Always update index for consistency
        }
    }

    /// @dev Check if user is not blacklisted, revert if they are
    /// @param user Address to check blacklist status for
    function _checkNotBlacklisted(address user) internal view {
        if (isBlacklisted[user]) revert AddressBlacklisted();
    }


    // =========================
    // Emergency (owner)
    // =========================

    /// @notice Recover ERC20 tokens sent to this contract
    /// @dev For non-USDR tokens or USDR surplus when paused
    /// @param token Token address to recover
    /// @param to Address to send tokens to
    /// @param amount Amount to recover
    function recoverERC20(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert CanNotBeZeroAddress();

        if (token == address(USDR)) {
            if (!paused()) revert ContractNotPaused();
            // allow sweeping only true surplus
            uint256 bal = USDR.balanceOf(address(this));
            uint256 minRequired = claimReserve;
            if (bal <= minRequired) revert InsufficientFunding();
            uint256 maxSweep = bal - minRequired;
            if (amount > maxSweep) revert ExceedsSurplus();
        } else {
            // For non-USDR tokens, check actual balance
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (amount > tokenBalance) revert ExceedsSurplus();
        }
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }

    /// @notice Sweep excess USDR yield to treasury (when vault has surplus above reserves)
    /// @dev Sweeps all surplus above minimum required reserves
    function sweepSurplusToTreasury() external onlyRole(ADMIN_ROLE) {
        uint256 bal = USDR.balanceOf(address(this));
        uint256 minRequired = claimReserve;
        
        if (bal <= minRequired) return; // No surplus to sweep
        
        uint256 surplus = bal - minRequired;
        USDR.safeTransfer(treasury, surplus);
        emit SurplusSweptToTreasury(surplus);
    }

    // =========================
    // ETH Safety
    // =========================

    /// @dev Reject ETH transfers to prevent accidental loss
    receive() external payable {
        revert EthNotAccepted();
    }

    /// @dev Reject ETH transfers to prevent accidental loss
    fallback() external payable {
        revert EthNotAccepted();
    }
}
