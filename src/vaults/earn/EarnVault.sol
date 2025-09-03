// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IEarnVault} from "../../interfaces/vaults/earn/IEarnVault.sol";

/// @title EarnVault (OFF path, claimable yield)
/// @notice Users deposit USDR, accrue claimable USDR via index accounting, and can claim/withdraw anytime.
///         A distributor pushes yield: transfer USDR to this contract, then call onYieldReceived(amount).
/// Accounting:
///   - accUSDRPerShare is in RAY (1e27) for precision.
///   - User state: principal, rewardDebt, pending.
///   - When yield arrives and totalPrincipal>0: acc += amount*RAY/totalPrincipal.
///   - If totalPrincipal==0 at yield time: amount is parked until deposits exist (applyParkedYield()).
/// Invariant (funding): USDR balance >= totalPrincipal + totalPending + parkedYield.
contract EarnVault is IEarnVault, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------- Constants --------
    uint256 public constant RAY = 1e27;  // High precision for yield calculations (MakerDAO standard)

    // -------- Immutables --------
    IERC20 public immutable USDR;

    // -------- Roles / endpoints --------
    address public distributor;   // allowed to call onYieldReceived/applyParkedYield
    address public treasury;      // sink for admin sweeps / optional parked handling

    // -------- Optional blacklist --------
    bool public blacklistEnabled;
    mapping(address => bool) public isBlacklisted;

    // -------- Vault accounting --------
    uint256 public totalPrincipal;       // sum of user principals
    uint256 public globalIndex = 1e27;   // global index (scaled 1e27 - RAY precision)
    uint256 public parkedYield;          // yield received while totalPrincipal==0 (deferred)
    uint256 public claimReserve;         // assets available to pay claims/withdraws

    mapping(address => uint256) public principal;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public accrued;

    // -------- Events --------
    event SetDistributor(address indexed who);
    event SetTreasury(address indexed who);
    event BlacklistModeSet(bool enabled);
    event BlacklistUpdated(address indexed who, bool blacklisted);

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, address indexed to, uint256 amount);

    event YieldIndexed(uint256 amount, uint256 newGlobalIndex, uint256 newClaimReserve);
    event YieldParked(uint256 amount, uint256 totalParked);
    event ParkedYieldApplied(uint256 amountApplied, uint256 remainingParked);
    event InterestClaimed(address indexed user, uint256 amount);

    event EmergencySweep(address indexed token, address indexed to, uint256 amount);

    // -------- Errors --------
    error NotDistributor();
    error AddressBlacklisted();
    error ZeroAmount();
    error InsufficientPrincipal();
    error BadAddress();
    error NothingToClaim();
    error InvariantFunding(); // USDR balance insufficent
    error ArithmeticOverflow(); // Integer overflow detected

    constructor(address _usdr, address _owner, address _distributor, address _treasury) 
        Ownable(_owner) {
        if (_usdr == address(0) || _owner == address(0)) revert BadAddress();
        USDR = IERC20(_usdr);
        distributor = _distributor;
        treasury = _treasury;
        emit SetDistributor(_distributor);
        emit SetTreasury(_treasury);
    }

    // =========================
    // Admin / roles
    // =========================

    function setDistributor(address who) external onlyOwner {
        if (who == address(0)) revert BadAddress();  // SECURITY FIX: Zero address check
        distributor = who;
        emit SetDistributor(who);
    }

    function setTreasury(address who) external onlyOwner {
        if (who == address(0)) revert BadAddress();  // SECURITY FIX: Zero address check
        treasury = who;
        emit SetTreasury(who);
    }

    function setBlacklistMode(bool enabled) external onlyOwner {
        blacklistEnabled = enabled;
        emit BlacklistModeSet(enabled);
    }

    function setBlacklisted(address who, bool blacklisted) external onlyOwner {
        isBlacklisted[who] = blacklisted;
        emit BlacklistUpdated(who, blacklisted);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

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
            uint256 owed = (p * (gi - ui)) / RAY;
            return accrued[user] + owed;
        }
        return accrued[user];
    }

    /// @notice Get user's total value (principal + claimable interest)
    function totalValue(address user) external view returns (uint256) {
        return principal[user] + this.claimable(user);
    }

    /// @notice Get user's complete account info in one call
    function getUserInfo(address user) external view returns (
        uint256 userPrincipal,
        uint256 userClaimable, 
        uint256 userTotal,
        uint256 userLastIndex
    ) {
        userPrincipal = principal[user];
        userClaimable = this.claimable(user);
        userTotal = userPrincipal + userClaimable;
        userLastIndex = userIndex[user];
    }

    /// @notice Get vault's overall statistics
    function getVaultStats() external view returns (
        uint256 vaultTotalPrincipal,
        uint256 vaultClaimReserve,
        uint256 vaultParkedYield,
        uint256 vaultGlobalIndex,
        uint256 vaultBalance
    ) {
        vaultTotalPrincipal = totalPrincipal;
        vaultClaimReserve = claimReserve;
        vaultParkedYield = parkedYield;
        vaultGlobalIndex = globalIndex;
        vaultBalance = USDR.balanceOf(address(this));
    }

    // =========================
    // User flows
    // =========================

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

    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        IERC20Permit(address(USDR)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        _settle(msg.sender);
        USDR.safeTransferFrom(msg.sender, address(this), amount);
        principal[msg.sender] += amount;
        totalPrincipal += amount;
        claimReserve += amount;  // reserve principal 1:1

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);  // SECURITY FIX: Add blacklist check
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        uint256 p = principal[msg.sender];
        if (amount > p) revert InsufficientPrincipal();

        uint256 interestOut = 0;
        if (amount == p) {
            // Full withdrawal: auto-claim all accrued interest
            interestOut = accrued[msg.sender];
            accrued[msg.sender] = 0;
            if (claimReserve < interestOut) revert InvariantFunding();
            claimReserve -= interestOut;
        }

        principal[msg.sender] = p - amount;
        totalPrincipal -= amount;
        claimReserve -= amount;

        USDR.safeTransfer(msg.sender, amount + interestOut);
        emit Withdraw(msg.sender, amount);
        if (interestOut > 0) {
            emit InterestClaimed(msg.sender, interestOut);
        }
    }

    function claim() external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);  // SECURITY FIX: Add blacklist check
        _settle(msg.sender);
        uint256 amt = accrued[msg.sender];
        if (amt == 0) revert NothingToClaim();
        if (claimReserve < amt) revert InvariantFunding();
        
        accrued[msg.sender] = 0;
        claimReserve -= amt;
        USDR.safeTransfer(msg.sender, amt);
        emit InterestClaimed(msg.sender, amt);
    }

    function claimTo(address to) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);  // SECURITY FIX: Add blacklist check
        if (to == address(0)) revert BadAddress();
        _settle(msg.sender);
        uint256 amt = accrued[msg.sender];
        if (amt == 0) revert NothingToClaim();
        if (claimReserve < amt) revert InvariantFunding();
        
        accrued[msg.sender] = 0;
        claimReserve -= amt;
        USDR.safeTransfer(to, amt);
        emit InterestClaimed(msg.sender, amt);
    }

    // =========================
    // Distributor hooks
    // =========================

    /// @dev Call AFTER transferring `amount` USDR to this contract.
    ///      Enforces funding: USDR.balance >= claimReserve + parkedYield + amount.
    function onYield(uint256 amount) external whenNotPaused {
        if (msg.sender != distributor && msg.sender != owner()) revert NotDistributor();
        if (amount == 0) return;
        
        // SECURITY FIX: Verify actual balance before updating accounting
        uint256 bal = USDR.balanceOf(address(this));
        
        if (totalPrincipal == 0) {
            // SECURITY FIX: Verify funding and use parkedYield instead of claimReserve
            if (bal < claimReserve + parkedYield + amount) revert InvariantFunding();
            parkedYield += amount;
            emit YieldParked(amount, parkedYield);
            return;
        }
        
        // SECURITY FIX: Verify funding before updating claimReserve
        if (bal < claimReserve + parkedYield + amount) revert InvariantFunding();
        
        // SECURITY FIX: Protect against integer overflow
        uint256 delta = (amount * RAY) / totalPrincipal;
        if (delta > 0) {
            // Check for overflow before adding
            if (globalIndex + delta < globalIndex) revert ArithmeticOverflow();
            globalIndex += delta;
        }
        claimReserve += amount;
        emit YieldIndexed(amount, globalIndex, claimReserve);
    }

    /// @dev Apply previously parked yield once deposits exist.
    function applyParkedYield() external whenNotPaused {
        if (msg.sender != distributor && msg.sender != owner()) revert NotDistributor();
        uint256 amt = parkedYield;
        if (amt == 0 || totalPrincipal == 0) return;

        // SECURITY FIX: Protect against integer overflow
        uint256 delta = (amt * RAY) / totalPrincipal;
        if (delta > 0) {
            // Check for overflow before adding
            if (globalIndex + delta < globalIndex) revert ArithmeticOverflow();
            globalIndex += delta;
        }
        
        parkedYield = 0;
        emit ParkedYieldApplied(amt, 0);
    }

    // =========================
    // Internal helpers
    // =========================

    function _settle(address user) internal {
        uint256 p = principal[user];
        uint256 ui = userIndex[user];
        uint256 gi = globalIndex;
        if (p == 0) { 
            userIndex[user] = gi; 
            return; 
        }
        if (gi > ui) {
            uint256 owed = (p * (gi - ui)) / RAY;
            accrued[user] += owed;
            userIndex[user] = gi;
        }
    }

    function _checkNotBlacklisted(address user) internal view {
        if (blacklistEnabled && isBlacklisted[user]) revert AddressBlacklisted();
    }

    // =========================
    // Emergency (owner)
    // =========================

    /// @dev Emergency sweep of tokens other than USDR, or USDR *surplus* if paused.
    function emergencySweep(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert BadAddress();

        if (token == address(USDR)) {
            if (!paused()) revert InvariantFunding(); // SECURITY FIX: Use custom error
            // allow sweeping only true surplus
            uint256 bal = USDR.balanceOf(address(this));
            uint256 minRequired = claimReserve + parkedYield;
            if (bal <= minRequired) revert InvariantFunding(); // SECURITY FIX: Use custom error
            uint256 maxSweep = bal - minRequired;
            if (amount > maxSweep) revert InvariantFunding(); // SECURITY FIX: Use custom error
        }
        IERC20(token).safeTransfer(to, amount);
        emit EmergencySweep(token, to, amount);
    }
}
