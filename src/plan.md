# Two-vault yield system (USDx asset) [ DRAFT ]

Components:
- ClaimVault (checkbox OFF): principal ledger + globalIndex; users deposit/withdraw 1:1 principal and claim interest; funds held in contract; ClaimVault.onYield(amount) indexes yield and increments claimReserve.
- sUSDRVault (checkbox ON): ERC-4626 vault (asset=USDR); users deposit USDR -> mint sUSDR; external transfers to the vault increase totalAssets without minting shares -> PPS rises.
- RewardRedistributor (yieldRecipient of USDR MYieldToOne): on distribute():
  1) minted = USDR.claimYield()
  2) fee = minted*10% -> Startale; net = minted - fee
  3) read TVLs: Tclaim = ClaimVault.totalPrincipal(); T4626 = sUSDRVault.totalAssets(); T = Tclaim + T4626
  4) toClaim = floor((net*Tclaim + carryClaim)/T); carryClaim = (net*Tclaim + carryClaim) % T
     to4626  = net - toClaim
  5) transfer toClaim to ClaimVault and call onYield(toClaim)
     transfer to4626 to sUSDRVault (PPS rises)

Key properties:
- Pro-rata split across cohorts by TVL with rounding-carry (long-run exactness).
- sUSDR price (PPS) = totalAssets/totalSupply; on-chain source of truth; AMMs arbitrage to it.
- Users with ON position redeem shares×PPS; OFF users claim interest or withdraw principal+unclaimed interest.

Files:
- vaults/earn/ClaimVault.sol  (roles: DISTRIBUTOR_ROLE, PAUSER_ROLE)
- vaults/4626/SUSDRVault.sol  (ERC-4626; roles: PAUSER_ROLE)
- distributor/RewardRedistributor.sol (roles: OPERATOR_ROLE; DEFAULT_ADMIN for params)
- interfaces/IClaimVault.sol, interfaces/IUSDRMExtension.sol

Deployment:
- Set USDR extension yieldRecipient = RewardRedistributor
- Grant ClaimVault.DISTRIBUTOR_ROLE to RewardRedistributor
- Configure redistributor params (treasury, vault addresses, feeBps=1000)

Testing invariants:
- After distribute, toClaim+to4626+fee == minted
- ClaimVault: claimReserve >= sum(accrued) + pending full-exit interest; index math correct
- sUSDRVault: totalAssets increases exactly by transfers; PPS non-decreasing barring withdrawals/loss
- Long-run split exact with carry (fuzz amounts/TVLs)
