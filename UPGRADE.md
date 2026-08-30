# Upside Xa Solidity v2.0 — Upgrade Guide

## What Changed

### REPLACED files (copy these over your existing ones):

| File | Changes |
|------|---------|
| `UpsideXaTypes.sol` | Added `StakeType`, `StakeStatus`, `DecayStatus` enums + `StakeRecord` struct |
| `UpsideToken.sol` | Added `adminBurn()` for decay burns. Refactored `_mint()` internal. Cleaned up |
| `BurnMechanism.sol` | Added `decayBurn()` + `decayBurnBatch()`. Separate voluntary vs decay tracking |
| `Governance.sol` | `registerContracts()` now takes 5 params (added `_ideaStaking`). Pause/unpause includes staking. Oracle propagated to staking |

### NEW files:

| File | Purpose |
|------|---------|
| `IdeaStaking.sol` | On-chain stake records. Escrows tokens, settles wins/losses, decay burns, sweep to treasury |

### UNCHANGED (keep your existing versions):

- `RewardIssuance.sol` — no changes needed
- `Treasury.sol` — no changes needed  
- `FounderVesting.sol` — no changes needed
- `Deployer.sol` — replaced by new `deploy.js` script (you can delete Deployer.sol)

### Updated:

- `scripts/deploy.js` — Deploys all 6 contracts, wires them together, verifies
- `test/UpsideXa.test.js` — 29 tests covering all contracts

## How to Upgrade

```powershell
cd C:\upside-xa\upside-xa-sol\upside-xa-sol

# 1. Replace contracts (back up originals first)
copy contracts\UpsideXaTypes.sol contracts\UpsideXaTypes.sol.bak
copy contracts\UpsideToken.sol contracts\UpsideToken.sol.bak
copy contracts\BurnMechanism.sol contracts\BurnMechanism.sol.bak
copy contracts\Governance.sol contracts\Governance.sol.bak

# 2. Copy new files into place (from downloaded solidity-v2 folder)
# Replace: UpsideXaTypes.sol, UpsideToken.sol, BurnMechanism.sol, Governance.sol
# Add: IdeaStaking.sol
# Replace: scripts\deploy.js, test\UpsideXa.test.js

# 3. Compile
npx hardhat compile

# 4. Test (local Hardhat network)
npx hardhat test

# 5. Deploy to testnet
npx hardhat run scripts/deploy.js --network polkadotTestnet
```

## Contract Architecture

```
Governance ──────────────────────────────────────────
  │  registers + emergency pause + oracle management
  ├── UpsideToken (ERC-20 + locks + adminBurn)
  ├── RewardIssuance (scoring → minting)
  ├── BurnMechanism (voluntary + decay burns)
  ├── IdeaStaking (escrow + settlement)
  └── Treasury (2-of-3 multisig)
```

## Key Design Decisions

1. **IdeaStaking is an escrow** — tokens transfer from user → contract → back on settlement
2. **Users must approve()** the IdeaStaking contract before staking (standard ERC-20 pattern)
3. **adminBurn()** on UpsideToken bypasses the burn contract for decay scenarios
4. **Oracle = admin** on testnet. Production will separate these roles
5. **Slashed tokens stay in IdeaStaking** until admin calls `sweepToTreasury()`
6. **Deployer.sol can be deleted** — the deploy script handles everything better
