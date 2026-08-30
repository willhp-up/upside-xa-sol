# Upside XA - Solidity Contracts

![test](https://github.com/willhp-up/upside-xa-sol/actions/workflows/test.yml/badge.svg)

Smart contracts for XA (https://app.upside-xa.com), a crowd-intelligence
investment platform where analysts submit timestamped market calls, stake
conviction tokens (UPC), and build verifiable scored records settled against
real market prices.

Six contracts, live on Polkadot Hub testnet since February 2026.
Deployed via Polkadot Hub's REVM backend: standard EVM bytecode from
vanilla Hardhat/solc, no contract modifications. (Hub's Revive framework
also offers a native PVM/RISC-V path via resolc; not used here.)

## Deployed Contracts (Polkadot Hub Testnet, chain ID 420420417)

| Contract       | Address                                      | Purpose                                        |
|----------------|----------------------------------------------|------------------------------------------------|
| UpsideToken    | `0x07EBC3844482E9dAd93F8D20c6e50f0F92a7ec60` | ERC-20 UPC with time locks, role-based mint/burn |
| RewardIssuance | `0xc560ab28059Dc6Bb198cf34b8B94c29AE2EFD8F2`                              | Oracle scores -> proportional reward distribution |
| BurnMechanism  | `0x54f2D2f6DD453FDcb619eD6D5B570aB279458123`                              | Burn events (25% cap), decay burns             |
| IdeaStaking    | `0x94e136E6a9cBa5e6A218D83544471787069434B0`                              | Call staking, endorsements, settlement, slashing |
| Governance     | `0x63ba5830Cfd2a04CdAb800140905eE8eD70C0a51`                              | Pause, oracle management, parameter control    |
| Treasury       | `0xB874A73442b07375618Fff97C3b06A6B66359a3b`                              | 2-of-3 multi-sig treasury                      |

Verified on Blockscout. `FounderVesting.sol` (founder lockup) is included
in source but not part of the current testnet deployment.

Mainnet target: Polkadot Hub mainnet (chain ID 420420419), Q4 2026.

## Note on source vs deployed bytecode

The repository head is v2.0.1: it includes a fix to the decay-burn
authorisation path (`UpsideToken.adminBurn` is now callable by the
registered BurnMechanism contract as well as the admin), found via the
test suite. The testnet deployment above runs v2.0 and predates this fix.
Redeployment is scheduled as part of the mainnet migration programme.

## Architecture

Governance is the control centre: it registers contract addresses,
propagates the oracle, and can pause the system. UpsideToken enforces
role-based minting (issuance contract only, with 90-day lock) and burning.
IdeaStaking records analyst stakes and endorsements and settles them
against oracle-reported outcomes, slashing losing stakes to the Treasury.

## Tokenomics

- Total supply: 5,000,000 UPC (18 decimals)
- Issuance pool: 80% (4,000,000), minted over 4+ years
- Reserve pool: 20% (1,000,000)
- Lock period: 90 days from mint
- Burn cap: 25% of available balance per event
- Score range: 0-1000 (representing 0.000-1.000)

## Build and Test

Requires Node.js (LTS).

    npm install
    npx hardhat compile
    npx hardhat test

Full suite: 29 tests covering token roles and locks, issuance lifecycle,
burn events and decay, staking and settlement, multi-sig treasury, and
governance (pause, oracle propagation, parameter changes), plus an
integration test of the full score -> mint -> lock -> settle -> burn cycle.

## Project Structure

    contracts/   UpsideXaTypes.sol, UpsideToken.sol, RewardIssuance.sol,
                 BurnMechanism.sol, IdeaStaking.sol, Governance.sol,
                 Treasury.sol, FounderVesting.sol
    scripts/     deploy.js and interaction scripts
    test/        UpsideXa.test.js (29 tests)

## License

Apache 2.0. Copyright 2026 Upside Technologies Ltd.
